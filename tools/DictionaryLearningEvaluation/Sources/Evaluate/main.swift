import FluidAudio
import Foundation

struct Word: Codable {
    let clip: String
    let language: String
    let index: Int
    let text: String
    let reference: String?
    let start: Double
    let end: Double
    let values: [Float]
    let frames: Int
}

struct Hit: Codable {
    let score: Float
    let indices: [Int]
}

struct Trial: Codable {
    let language: String
    let target: String
    let known: String
    let clip: String
    let words: [Word]
    let hits: [Hit]
}

func normalized(_ text: String) -> String {
    text.lowercased().filter { $0.isLetter || $0.isNumber }
}

func align(_ hypothesis: [String], _ reference: [String]) -> [Int: String] {
    let n = hypothesis.count
    let m = reference.count
    var costs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    for i in 0...n {
        costs[i][0] = i
    }
    for j in 0...m {
        costs[0][j] = j
    }
    if n > 0, m > 0 {
        for i in 1...n {
            for j in 1...m {
                costs[i][j] = min(
                    costs[i - 1][j] + 1,
                    costs[i][j - 1] + 1,
                    costs[i - 1][j - 1] + (hypothesis[i - 1] == reference[j - 1] ? 0 : 1)
                )
            }
        }
    }
    var result: [Int: String] = [:]
    var i = n
    var j = m
    while i > 0 || j > 0 {
        if i > 0, j > 0,
           costs[i][j] == costs[i - 1][j - 1] + (hypothesis[i - 1] == reference[j - 1] ? 0 : 1)
        {
            result[i - 1] = reference[j - 1]
            i -= 1
            j -= 1
        } else if i > 0, costs[i][j] == costs[i - 1][j] + 1 {
            i -= 1
        } else {
            j -= 1
        }
    }
    return result
}

@main struct Evaluate {
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else {
            throw NSError(
                domain: "DictionaryLearningEvaluation",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Usage: Evaluate FLEURS_DIRECTORY MODEL_DIRECTORY OUTPUT_JSON",
                ]
            )
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let models = try await AsrModels.loadLocalOnly(
            from: URL(fileURLWithPath: CommandLine.arguments[2]), version: .v3
        )
        let manager = AsrManager(
            config: ASRConfig(
                tdtConfig: TdtConfig(blankId: AsrModelVersion.v3.blankId), encoderHiddenSize: 1024
            ))
        try await manager.initialize(models: models)
        var output: [Word] = []
        var clips: [String: (samples: [Float], features: EncoderFeatureSequence)] = [:]
        for language in ["en_us", "es_419", "fr_fr", "de_de", "ru_ru", "pl_pl", "el_gr", "da_dk"] {
            let directory = root.appendingPathComponent(language)
            let referenceLines = try String(
                contentsOf: directory.appendingPathComponent("\(language).trans.txt"), encoding: .utf8
            ).split(separator: "\n")
            let references = Dictionary(
                uniqueKeysWithValues: referenceLines.compactMap { line -> (String, [String])? in
                    let parts = line.split(separator: " ", maxSplits: 1)
                    guard parts.count == 2 else { return nil }
                    return (String(parts[0]), parts[1].split(separator: " ").map { normalized(String($0)) })
                })
            for file in try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ).filter({ $0.pathExtension == "wav" }).sorted(by: { $0.path < $1.path }) {
                let samples = try AudioConverter().resampleAudioFile(path: file.path)
                guard samples.count <= 238_080 else {
                    print("SKIP_LONG \(file.lastPathComponent)")
                    continue
                }
                await manager.setPronunciationCustomizationEnabled(true)
                let result = try await manager.transcribe(samples, source: .microphone)
                guard let features = await manager.consumePronunciationEncoderFeatures() else { continue }
                let words = WordAudioChunkExtractor.words(from: result.tokenTimings ?? [])
                let clip = file.deletingPathExtension().lastPathComponent
                clips[clip] = (samples, features)
                let labels = align(words.map { normalized($0.text) }, references[clip] ?? [])
                for (index, word) in words.enumerated() {
                    let start = max(0, Int((word.startTime / 0.08).rounded(.down)))
                    let end = min(features.frameCount, Int((word.endTime / 0.08).rounded(.up)))
                    guard end > start,
                          let embedding = PronunciationEmbeddingMatcher.embedding(
                              from: features, frameRange: start..<end
                          )
                    else { continue }
                    output.append(
                        Word(
                            clip: clip,
                            language: language,
                            index: index,
                            text: normalized(word.text),
                            reference: labels[index],
                            start: word.startTime,
                            end: word.endTime,
                            values: embedding.values,
                            frames: embedding.sourceFrameCount
                        ))
                }
                print("CLIP \(clip) \(words.count) words")
            }
        }
        var trials: [Trial] = []
        let grouped = Dictionary(grouping: output.filter { ($0.reference?.count ?? 0) >= 3 }) {
            "\($0.language):\($0.reference ?? "")"
        }
        for key in grouped.keys.sorted() {
            guard let occurrences = grouped[key] else { continue }
            guard Set(occurrences.map(\.clip)).count > 1,
                  let enrollment = occurrences.first(where: { $0.text != $0.reference }) ?? occurrences.first,
                  let target = enrollment.reference,
                  let source = clips[enrollment.clip]
            else { continue }
            let focalStart = Int((enrollment.start * 16_000).rounded(.down))
            let focalEnd = min(source.samples.count, Int((enrollment.end * 16_000).rounded(.up)))
            let contextStart = max(0, focalStart - 32_000) / 1280 * 1280
            let contextEnd = min(source.samples.count, contextStart + 238_080)
            guard focalEnd <= contextEnd, focalEnd > focalStart else { continue }
            let prototype = try await manager.pronunciationEmbedding(
                audioSamples: Array(source.samples[contextStart..<contextEnd]),
                focalSampleRange: (focalStart - contextStart)..<(focalEnd - contextStart)
            )
            for clip in clips.keys.sorted()
                where clip != enrollment.clip && clip.hasPrefix(enrollment.language)
            {
                guard let clipFeatures = clips[clip]?.features else { continue }
                let words = output.filter { $0.clip == clip }
                let matches = PronunciationEmbeddingMatcher.allMatches(
                    prototypes: [prototype], in: clipFeatures
                )[0]
                let hits = matches.map { match in
                    let start = Double(match.frameRange.lowerBound) * 0.08
                    let end = Double(match.frameRange.upperBound) * 0.08
                    let indices = words.indices.filter { index in
                        let word = words[index]
                        return max(0, min(word.end, end) - max(word.start, start))
                            / max(0.0001, word.end - word.start) >= 0.5
                    }
                    return Hit(score: match.score, indices: indices)
                }
                trials.append(
                    Trial(
                        language: enrollment.language,
                        target: target,
                        known: enrollment.text,
                        clip: clip,
                        words: words,
                        hits: hits
                    ))
            }
        }
        try JSONEncoder().encode(trials).write(
            to: URL(fileURLWithPath: CommandLine.arguments[3] + ".trials.json"), options: .atomic
        )
        try JSONEncoder().encode(output).write(
            to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .atomic
        )
        await manager.cleanup()
    }
}
