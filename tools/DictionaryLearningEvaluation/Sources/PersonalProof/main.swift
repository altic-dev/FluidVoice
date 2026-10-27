import FluidAudio
import Foundation

struct Token: Codable {
    let text: String
    let start: Double
    let end: Double
}

struct Hit: Codable {
    let score: Float
    let text: String
    let start: Double
    let end: Double
    let targetOnly: Bool
}

struct Trial: Codable {
    let target: String
    let enrollmentStart: Double
    let positiveOccurrences: Int
    let hits: [Hit]
}

func normalize(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
@main struct PersonalProof {
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else {
            throw NSError(
                domain: "DictionaryLearningEvaluation",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Usage: PersonalProof AUDIO MODEL_DIRECTORY OUTPUT_JSON",
                ]
            )
        }
        let source = try AudioConverter().resampleAudioFile(path: CommandLine.arguments[1])
        let models = try await AsrModels.loadLocalOnly(
            from: URL(fileURLWithPath: CommandLine.arguments[2]), version: .v3
        )
        let manager = AsrManager(
            config: ASRConfig(
                tdtConfig: TdtConfig(blankId: AsrModelVersion.v3.blankId), encoderHiddenSize: 1024
            ))
        try await manager.initialize(models: models)
        var windows: [(offset: Int, features: EncoderFeatureSequence, words: [Token])] = []
        var allWords: [Token] = []
        for start in stride(from: 0, to: source.count, by: 238_080) {
            let samples = Array(source[start..<min(source.count, start + 238_080)])
            guard samples.count >= 16_000 else {
                print("SKIP_TAIL samples=\(samples.count)")
                continue
            }
            await manager.setPronunciationCustomizationEnabled(true)
            let result = try await manager.transcribe(samples, source: .microphone)
            guard let features = await manager.consumePronunciationEncoderFeatures() else { continue }
            let words = WordAudioChunkExtractor.words(from: result.tokenTimings ?? []).map {
                Token(
                    text: normalize($0.text),
                    start: $0.startTime + Double(start) / 16_000,
                    end: $0.endTime + Double(start) / 16_000
                )
            }
            windows.append((start, features, words))
            allWords += words
            print("WINDOW \(start) \(result.text)")
        }
        var trials: [Trial] = []
        for target in ["nvidia", "jensen", "huang", "design", "ai"] {
            let occurrences = allWords.filter { $0.text == target }
            guard let enrollment = occurrences.first else { continue }
            let lower = Int((enrollment.start * 16_000).rounded(.down))
            let upper = Int((enrollment.end * 16_000).rounded(.up))
            let contextStart = max(0, lower - 32_000) / 1280 * 1280
            let contextEnd = min(source.count, contextStart + 238_080)
            let prototype = try await manager.pronunciationEmbedding(
                audioSamples: Array(source[contextStart..<contextEnd]),
                focalSampleRange: (lower - contextStart)..<(upper - contextStart)
            )
            var hits: [Hit] = []
            var positives = 0
            for window in windows {
                // Entire enrollment ASR window is excluded; never count replay as held-out speech.
                if enrollment.start >= Double(window.offset) / 16_000,
                   enrollment.start < Double(window.offset + 238_080) / 16_000
                {
                    continue
                }
                positives += window.words.filter { $0.text == target }.count
                let matchStart = ProcessInfo.processInfo.systemUptime
                let matches = PronunciationEmbeddingMatcher.allMatches(
                    prototypes: [prototype], in: window.features
                )[0]
                let matchMs = (ProcessInfo.processInfo.systemUptime - matchStart) * 1000
                print("MATCH_MS target=\(target) frames=\(window.features.frameCount) elapsed=\(matchMs)")
                for match in matches {
                    let start = Double(window.offset) / 16_000 + Double(match.frameRange.lowerBound) * 0.08
                    let end = Double(window.offset) / 16_000 + Double(match.frameRange.upperBound) * 0.08
                    let words = window.words.filter {
                        max(0, min($0.end, end) - max($0.start, start)) / max(0.0001, $0.end - $0.start) >= 0.5
                    }
                    guard !words.isEmpty else { continue }
                    hits.append(
                        Hit(
                            score: match.score,
                            text: words.map(\.text).joined(separator: " "),
                            start: start,
                            end: end,
                            targetOnly: words.count == 1 && words[0].text == target
                        ))
                }
            }
            trials.append(
                Trial(
                    target: target,
                    enrollmentStart: enrollment.start,
                    positiveOccurrences: positives,
                    hits: hits
                ))
        }
        try JSONEncoder().encode(trials).write(
            to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .atomic
        )
        await manager.cleanup()
    }
}
