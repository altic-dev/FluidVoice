import Foundation

/// Pronunciation follows the master switch; diagnostic audio capture remains opt-in.
nonisolated enum DictionaryPronunciationExperiment {
    static var enabled: Bool { DictionaryMatcherExperiment.sharedFeaturesEnabled }
    static var captureEnabled: Bool { enabled && UserDefaults.standard.bool(forKey: "DictionaryPronunciationDebugCapture") }

    /// Only the outer quiet edges are removed. Internal pauses and low-energy consonants remain.
    static func trimmedRange(_ samples: [Float], within range: Range<Int>? = nil) -> Range<Int>? {
        let range = range ?? 0..<samples.count
        guard range.lowerBound >= 0, range.upperBound <= samples.count, !range.isEmpty else { return nil }
        var first: Int?
        var last = 0
        for start in stride(from: range.lowerBound, to: range.upperBound, by: 320) {
            let end = min(start + 320, range.upperBound)
            let energy = samples[start..<end].reduce(Float(0)) { $0 + $1 * $1 } / Float(end - start)
            if energy.isFinite, energy >= 0.00_001 { // -50 dBFS RMS
                if first == nil { first = start }
                last = end
            }
        }
        guard let first else { return nil }
        return max(range.lowerBound, first - 1920)..<min(range.upperBound, last + 1920)
    }

    /// Cuts a single-word recording to the word itself. The recognizer's word times locate it;
    /// the word's own loudness tightens the edges, and a final p/t/k pop after a short gap is kept.
    /// Absolute loudness alone keeps room noise and silence, so it is only the fallback.
    static func wordRange(_ samples: [Float], words: [DictionaryAudioInspection.Word]) -> Range<Int>? {
        guard let first = words.first, let last = words.last, !samples.isEmpty else { return nil }
        let rate = 16_000.0, block = 160
        func rms(_ range: Range<Int>) -> Float {
            let slice = samples[range]
            return sqrt(slice.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, slice.count)))
        }
        let lower = max(0, Int((first.start - 0.16) * rate))
        let upper = min(samples.count, Int((last.end + 0.16) * rate))
        guard upper - lower >= block * 3 else { return nil }
        let levels = stride(from: lower, to: upper - block + 1, by: block).map { rms($0..<($0 + block)) }
        let leadingNoise = stride(from: 0, to: min(samples.count, 4800) - block + 1, by: block)
            .map { rms($0..<($0 + block)) }.sorted()
        let noise = leadingNoise.isEmpty ? 0 : leadingNoise[leadingNoise.count / 2]
        let gate = max((levels.max() ?? 0) * 0.08, noise * 3)
        guard let firstLoud = levels.firstIndex(where: { $0 > gate }),
              let lastLoud = levels.lastIndex(where: { $0 > gate }) else { return nil }
        var end = lower + (lastLoud + 1) * block
        let burstLimit = min(samples.count, end + 4000)
        var position = end
        while position + block <= burstLimit {
            if rms(position..<(position + block)) > max(noise * 4, 0.003) { end = position + block }
            position += block
        }
        let pad = 480
        let start = max(0, lower + firstLoud * block - pad)
        end = min(samples.count, end + pad)
        return start < end ? start..<end : nil
    }

    /// Encoder frames (1280 samples each) that contain speech. Words recorded slowly, such as
    /// "Slides… A… I", carry pauses that vanish when the same word is said quickly in a sentence.
    static func spokenFrames(_ samples: [Float], frames: Range<Int>) -> [Int] {
        let levels = frames.map { frame -> Float in
            let lower = min(samples.count, frame * 1280), upper = min(samples.count, lower + 1280)
            guard upper > lower else { return 0 }
            return sqrt(samples[lower..<upper].reduce(Float(0)) { $0 + $1 * $1 } / Float(upper - lower))
        }
        let gate = max((levels.max() ?? 0) * 0.08, 1e-4)
        let spoken = zip(frames, levels).filter { $0.1 > gate }.map(\.0)
        return spoken.count >= 3 ? spoken : Array(frames)
    }

    // swiftlint:disable:next discouraged_optional_collection
    static func normalized(_ values: [Float]) -> [Float]? {
        guard !values.isEmpty, values.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0, norm.isFinite else { return nil }
        return values.map { $0 / norm }
    }

    static func calibration(_ vectors: [[Float]]) -> (center: [Float], baseline: Float)? {
        let expectedCount = vectors.count
        let vectors = vectors.compactMap(self.normalized)
        guard vectors.count == expectedCount, vectors.count >= 3, let size = vectors.first?.count,
              vectors.allSatisfy({ $0.count == size }) else { return nil }
        var total: Float = 0
        var count = 0
        var center = [Float](repeating: 0, count: size)
        for i in vectors.indices {
            for j in 0..<i {
                total += zip(vectors[i], vectors[j]).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                count += 1
            }
            for d in center.indices {
                center[d] += vectors[i][d]
            }
        }
        let baseline = total / Float(count)
        // A nonpositive baseline cannot define a useful relative scale.
        guard baseline.isFinite, baseline > 0, let center = self.normalized(center) else { return nil }
        return (center, min(1, baseline))
    }
}

extension PronunciationDictionaryProfile {
    var edgeCalibration: (center: [Float], baseline: Float)? {
        guard DictionaryPronunciationExperiment.enabled, !self.hasOriginalAudio,
              self.enrollments.allSatisfy({ $0.edgeEmbedding?.count == self.hiddenSize && ($0.edgeFrameCount ?? 0) > 0 })
        else { return nil }
        return DictionaryPronunciationExperiment.calibration(self.enrollments.compactMap(\.edgeEmbedding))
    }
}

/// Bounded, local-only evidence. Off means no new PCM, embeddings or reports are written.
actor DictionaryPronunciationDebugArchive {
    static let shared = DictionaryPronunciationDebugArchive()
    private let directory: URL?

    init(directory: URL? = nil) { self.directory = directory }
    struct Score: Codable, Sendable {
        let word: String
        let start: Double
        let end: Double
        let raw: Float
        let baseline: Float
        let relative: Float
        let inputEmbedding: [Float]
    }

    private struct Record: Codable {
        let date: Date
        let kind: String
        let model: String
        let samples: Data
        let transcript: String
        let profiles: [PronunciationDictionaryProfile]
        let scores: [Score]
        let inspection: DictionaryAudioInspection?
        let trainingCapture: PronunciationEnrollmentCapture?
    }

    func save(
        kind: String,
        model: String,
        samples: [Float],
        transcript: String,
        profiles: [PronunciationDictionaryProfile],
        scores: [Score] = [],
        inspection: DictionaryAudioInspection? = nil,
        trainingCapture: PronunciationEnrollmentCapture? = nil
    ) {
        guard !Task.isCancelled, DictionaryPronunciationExperiment.captureEnabled, !samples.isEmpty,
              samples.count <= 16_000 * 120 else { return }
        do {
            let root = try self.directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("FluidVoice/DictionaryDebug", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(Record(
                date: Date(),
                kind: kind,
                model: model,
                samples: samples.withUnsafeBytes { Data($0) },
                transcript: transcript,
                profiles: profiles,
                scores: scores,
                inspection: inspection,
                trainingCapture: trainingCapture
            ))
            guard !Task.isCancelled, DictionaryPronunciationExperiment.captureEnabled else { return }
            try data.write(to: root.appendingPathComponent("\(UUID().uuidString).plist"), options: .atomic)
            let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
                .filter { $0.pathExtension == "plist" }
                .compactMap { url -> (URL, Date, Int)? in
                    guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
                    return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
                }.sorted { $0.1 > $1.1 }
            var bytes = 0
            for (index, file) in files.enumerated() {
                bytes += file.2
                if index >= 50 || bytes > 200_000_000 { try FileManager.default.removeItem(at: file.0) }
            }
        } catch {
            DebugLogger.shared.warning("Dictionary debug archive write failed: \(error.localizedDescription)", source: "PronunciationMatching")
        }
    }
}
