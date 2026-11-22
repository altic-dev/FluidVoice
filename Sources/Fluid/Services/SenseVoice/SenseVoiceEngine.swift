import Accelerate
@preconcurrency import CoreML
import Foundation

// SenseVoiceSmall CoreML inference, ported from FluidInference/FluidAudio
// (Sources/FluidAudio/ASR/SenseVoice, Apache-2.0) and made self-contained so it does not
// depend on helpers missing from the FluidAudio fork FluidVoice pins.
//
// Pipeline (model repo `FluidInference/sensevoice-small-coreml`):
//   waveform ×32768 → [SenseVoicePreprocessor, fp32/CPU] → features [1, T, 560]
//   → zero-pad to the smallest encoder bucket ≥ T → [SenseVoiceSmall*, ANE] → ctc_logits
//   → greedy CTC (drop blank 0, collapse repeats) → SentencePiece detokenize → strip `<|…|>`.

/// Encoder weight variant. int8 and fp16 are only numerically correct on the Neural Engine
/// (the fp16 CPU/GPU path yields NaN); fp32 runs on any compute unit.
nonisolated enum SenseVoiceEncoderVariant: String, CaseIterable {
    case int8
    case fp16
    case fp32

    var modelName: String {
        switch self {
        case .int8: return "SenseVoiceSmall_int8"
        case .fp16: return "SenseVoiceSmall"
        case .fp32: return "SenseVoiceSmall_fp32"
        }
    }

    var bundleName: String {
        self.modelName + ".mlmodelc"
    }

    var computeUnits: MLComputeUnits {
        self == .fp32 ? .all : .cpuAndNeuralEngine
    }
}

nonisolated enum SenseVoiceConstants {
    static let sampleRate = 16_000
    static let featureDim = 560
    /// Fallback encoder buckets; the real list is read from the loaded model.
    static let defaultBuckets = [128, 256, 512, 1024, 1800]
    /// language / emotion / event / text-norm query tokens prepended to the logits.
    static let numQueryTokens = 4
    static let blankID = 0
    static let waveformScale: Float = 32_768
    /// `textnorm` embed index: 15 = woitn (no inverse text normalisation), 14 = withitn.
    static let textNormWithoutITN: Int32 = 15
    static let textNormWithITN: Int32 = 14
    static let preprocessorName = "SenseVoicePreprocessor"
    static let preprocessorBundle = "SenseVoicePreprocessor.mlmodelc"
    static let vocabularyFile = "vocab.json"
    static let configFile = "config.json"
    /// LFR hop: 10 ms fbank shift × n=6 → one encoder frame per 960 samples.
    static let samplesPerFrame = 960
    /// Below ~0.2 s the fbank/LFR front end has almost nothing to work with.
    static let minimumSamples = 3200
    /// Peak amplitude under which a buffer is treated as digital silence.
    static let silencePeak: Float = 1e-4
}

nonisolated struct SenseVoiceTranscription {
    let text: String
    /// Detected language tag (`zh`, `en`, `yue`, `ja`, `ko`, `nospeech`, …) of the first chunk.
    let detectedLanguage: String?
    /// All `<|…|>` tags of every chunk, in order (language, emotion, event, itn per chunk).
    let tags: [String]

    static let empty = SenseVoiceTranscription(text: "", detectedLanguage: nil, tags: [])
}

nonisolated enum SenseVoiceError: LocalizedError {
    case missingArtifact(String)
    case vocabularyUnreadable
    case modelOutputMissing(String)
    case invalidOutput(variant: SenseVoiceEncoderVariant)

    var errorDescription: String? {
        switch self {
        case let .missingArtifact(name):
            return "SenseVoice model file not found: \(name)"
        case .vocabularyUnreadable:
            return "SenseVoice vocab.json could not be parsed."
        case let .modelOutputMissing(name):
            return "SenseVoice model produced no `\(name)` output."
        case let .invalidOutput(variant):
            return "SenseVoice (\(variant.rawValue)) produced invalid numbers (NaN). "
                + "This encoder needs the Apple Neural Engine; it may be unavailable or busy on this Mac."
        }
    }
}

/// Loaded SenseVoice models. Prediction calls are serialised by the actor.
actor SenseVoiceEngine {
    nonisolated let variant: SenseVoiceEncoderVariant
    private let preprocessor: MLModel
    private let encoder: MLModel
    private let vocabulary: [String]
    private let encoderFrameCounts: [Int]

    /// Max samples handed to the model in one pass, a little under the largest bucket so the
    /// front end's frame rounding never spills over it.
    nonisolated let maxChunkSamples: Int

    init(directory: URL, variant: SenseVoiceEncoderVariant) throws {
        let preprocessorConfig = MLModelConfiguration()
        // Power spectrum / log exceed fp16 range and the identity convs fail ANE compile.
        preprocessorConfig.computeUnits = .cpuOnly
        let encoderConfig = MLModelConfiguration()
        encoderConfig.computeUnits = variant.computeUnits

        self.variant = variant
        self.preprocessor = try Self.loadModel(
            directory.appendingPathComponent(SenseVoiceConstants.preprocessorBundle),
            configuration: preprocessorConfig
        )
        self.encoder = try Self.loadModel(
            directory.appendingPathComponent(variant.bundleName),
            configuration: encoderConfig
        )
        self.vocabulary = try Self.loadVocabulary(directory.appendingPathComponent(SenseVoiceConstants.vocabularyFile))
        let frames = Self.acceptedFrameCounts(of: self.encoder)
        self.encoderFrameCounts = frames
        let maxFrames = frames.last ?? 1800
        // Keep ~2 frames of headroom for the front end's edge handling.
        let encoderLimit = (maxFrames - 2) * SenseVoiceConstants.samplesPerFrame
        // The exported preprocessor caps `waveform` (30 s in the current repo), which is far
        // below the encoder's 1800-frame bucket, so it usually sets the chunk size.
        let preprocessorLimit = Self.maximumWaveformSamples(of: self.preprocessor) ?? encoderLimit
        self.maxChunkSamples = max(SenseVoiceConstants.minimumSamples, min(encoderLimit, preprocessorLimit))
    }

    nonisolated var maxChunkSeconds: Double {
        Double(self.maxChunkSamples) / Double(SenseVoiceConstants.sampleRate)
    }

    var acceptedFrameCounts: [Int] {
        self.encoderFrameCounts
    }

    /// Transcribe 16 kHz mono samples in [-1, 1]. Long audio is split near quiet points.
    func transcribe(
        _ samples: [Float],
        language: Int32,
        textNorm: Int32 = SenseVoiceConstants.textNormWithoutITN
    ) throws -> SenseVoiceTranscription {
        guard samples.count >= SenseVoiceConstants.minimumSamples else { return .empty }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        guard peak >= SenseVoiceConstants.silencePeak else { return .empty }

        var texts: [String] = []
        var tags: [String] = []
        var detected: String?
        for range in Self.chunkRanges(for: samples, maxChunk: self.maxChunkSamples) {
            try Task.checkCancellation()
            var chunk = Array(samples[range])
            // Pad rather than drop: a short piece can still hold the end of a word.
            if chunk.count < SenseVoiceConstants.minimumSamples {
                chunk += [Float](repeating: 0, count: SenseVoiceConstants.minimumSamples - chunk.count)
            }
            let raw = try self.transcribeChunk(chunk, language: language, textNorm: textNorm)
            let parsed = Self.splitTags(raw)
            if detected == nil {
                detected = parsed.tags.first { Self.languageTags.contains($0) }
            }
            tags.append(contentsOf: parsed.tags)
            // The model's own "no speech" verdict: drop whatever stray tokens came with it.
            if parsed.tags.contains("nospeech") { continue }
            if parsed.text.isEmpty == false { texts.append(parsed.text) }
        }
        return SenseVoiceTranscription(text: Self.join(texts), detectedLanguage: detected, tags: tags)
    }

    // MARK: - Pipeline

    private func transcribeChunk(_ samples: [Float], language: Int32, textNorm: Int32) throws -> String {
        let features = try self.runPreprocessor(samples)
        let (logits, validFrames) = try self.runEncoder(features: features, language: language, textNorm: textNorm)
        let ids = try self.greedyCTC(logits: logits, frames: validFrames)
        return Self.detokenize(ids, vocabulary: self.vocabulary)
    }

    private func runPreprocessor(_ samples: [Float]) throws -> MLMultiArray {
        let n = samples.count
        let waveform = try MLMultiArray(shape: [1, n as NSNumber], dataType: .float32)
        let dst = waveform.dataPointer.assumingMemoryBound(to: Float.self)
        var scale = SenseVoiceConstants.waveformScale
        samples.withUnsafeBufferPointer { src in
            guard let srcBase = src.baseAddress else { return }
            vDSP_vsmul(srcBase, 1, &scale, dst, 1, vDSP_Length(n))
        }
        let input = try MLDictionaryFeatureProvider(dictionary: ["waveform": MLFeatureValue(multiArray: waveform)])
        let output = try self.preprocessor.prediction(from: input)
        guard let features = output.featureValue(for: "features")?.multiArrayValue else {
            throw SenseVoiceError.modelOutputMissing("features")
        }
        return features
    }

    private func runEncoder(features: MLMultiArray, language: Int32, textNorm: Int32) throws -> (MLMultiArray, Int) {
        let dim = SenseVoiceConstants.featureDim
        let maxFrames = self.encoderFrameCounts.last ?? 1800
        let t = min(features.shape[1].intValue, maxFrames)
        let bucket = self.encoderFrameCounts.first { $0 >= t } ?? maxFrames

        let speech = try MLMultiArray(shape: [1, bucket as NSNumber, dim as NSNumber], dataType: .float32)
        let sptr = speech.dataPointer.assumingMemoryBound(to: Float.self)
        memset(sptr, 0, bucket * dim * MemoryLayout<Float>.size)
        // Copy row by row honouring the source stride (CoreML may pad rows).
        let rowStride = features.strides[1].intValue
        if features.dataType == .float32 {
            let src = features.dataPointer.assumingMemoryBound(to: Float.self)
            for row in 0..<t {
                memcpy(sptr + row * dim, src + row * rowStride, dim * MemoryLayout<Float>.size)
            }
        } else {
            for row in 0..<t {
                for col in 0..<dim {
                    sptr[row * dim + col] = features[[0, row as NSNumber, col as NSNumber]].floatValue
                }
            }
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "speech": MLFeatureValue(multiArray: speech),
            "speech_lengths": MLFeatureValue(multiArray: Self.int32Scalar(Int32(t))),
            "language": MLFeatureValue(multiArray: Self.int32Scalar(language)),
            "textnorm": MLFeatureValue(multiArray: Self.int32Scalar(textNorm)),
        ])
        let output = try self.encoder.prediction(from: input)
        guard let logits = output.featureValue(for: "ctc_logits")?.multiArrayValue else {
            throw SenseVoiceError.modelOutputMissing("ctc_logits")
        }
        return (logits, SenseVoiceConstants.numQueryTokens + t)
    }

    /// Per-frame argmax (vDSP) + CTC collapse. Throws on NaN so a broken compute path is
    /// reported instead of silently returning garbage.
    private func greedyCTC(logits: MLMultiArray, frames requested: Int) throws -> [Int] {
        let frames = min(requested, logits.shape[1].intValue)
        let vocab = logits.shape[2].intValue
        let stride = logits.strides[1].intValue
        guard frames > 0 else { return [] }

        func scan(_ p: UnsafePointer<Float>) throws -> [Int] {
            var sum: Float = 0
            vDSP_sve(p, 1, &sum, vDSP_Length(SenseVoiceConstants.numQueryTokens * stride))
            if sum.isNaN { throw SenseVoiceError.invalidOutput(variant: self.variant) }
            var ids: [Int] = []
            var previous = -1
            for frame in 0..<frames {
                var best: Float = 0
                var index: vDSP_Length = 0
                vDSP_maxvi(p + frame * stride, 1, &best, &index, vDSP_Length(vocab))
                if best.isNaN { throw SenseVoiceError.invalidOutput(variant: self.variant) }
                let id = Int(index)
                if id != SenseVoiceConstants.blankID, id != previous { ids.append(id) }
                previous = id
            }
            return ids
        }

        if logits.dataType == .float32 {
            return try scan(logits.dataPointer.assumingMemoryBound(to: Float.self))
        }
        // fp16 output: widen once with vImage (Float16 is unavailable on x86_64 builds).
        let count = frames * stride
        var widened = [Float](repeating: 0, count: count)
        widened.withUnsafeMutableBufferPointer { dst in
            guard let dstBase = dst.baseAddress else { return }
            var srcBuffer = vImage_Buffer(
                data: logits.dataPointer, height: 1, width: vImagePixelCount(count), rowBytes: count * 2
            )
            var dstBuffer = vImage_Buffer(
                data: dstBase, height: 1, width: vImagePixelCount(count), rowBytes: count * 4
            )
            vImageConvert_Planar16FtoPlanarF(&srcBuffer, &dstBuffer, 0)
        }
        return try widened.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return [] }
            return try scan(base)
        }
    }

    // MARK: - Text

    nonisolated static let languageTags: Set<String> = ["zh", "en", "yue", "ja", "ko", "nospeech"]

    nonisolated static func detokenize(_ ids: [Int], vocabulary: [String]) -> String {
        ids.compactMap { $0 < vocabulary.count ? vocabulary[$0] : nil }
            .joined()
            .replacingOccurrences(of: "\u{2581}", with: " ")
    }

    /// Separates `<|…|>` tags from the transcript text.
    nonisolated static func splitTags(_ raw: String) -> (text: String, tags: [String]) {
        var tags: [String] = []
        var text = ""
        var rest = Substring(raw)
        while let open = rest.range(of: "<|") {
            text += rest[rest.startIndex..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "|>") else {
                rest = afterOpen
                break
            }
            tags.append(String(afterOpen[afterOpen.startIndex..<close.lowerBound]))
            rest = afterOpen[close.upperBound...]
        }
        text += rest
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (Self.removeSpacesBetweenCJK(collapsed), tags)
    }

    /// With inverse text-norm the model emits word pieces with `▁` even for Japanese/Chinese
    /// ("今日は とても 良い"). Drop a space when both neighbours are Han/kana/CJK punctuation;
    /// keep it around Latin words and in Korean, which is written with spaces.
    nonisolated static func removeSpacesBetweenCJK(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count > 2 else { return text }
        var output = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            if scalar == " ", index > 0, index + 1 < scalars.count,
               Self.isUnspacedCJK(scalars[index - 1]), Self.isUnspacedCJK(scalars[index + 1])
            {
                continue
            }
            output.append(scalar)
        }
        return String(output)
    }

    private nonisolated static func isUnspacedCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303f, // CJK punctuation
             0x3040...0x30ff, // hiragana, katakana
             0x3400...0x4dbf, 0x4e00...0x9fff, 0xf900...0xfaff, // Han
             0xff00...0xffef: // full-width forms
            return true
        default:
            return false
        }
    }

    /// Joins chunk texts: a space between Latin-script neighbours, nothing between CJK.
    nonisolated static func join(_ parts: [String]) -> String {
        var result = ""
        for part in parts {
            if let last = result.unicodeScalars.last, let first = part.unicodeScalars.first,
               Self.isSpaced(last), Self.isSpaced(first)
            {
                result += " "
            }
            result += part
        }
        return result
    }

    private nonisolated static func isSpaced(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11ff, 0x3130...0x318f, 0xac00...0xd7af:
            return true // Hangul: Korean separates words with spaces
        case 0x2e80...:
            return false // CJK and kana: no inter-chunk space
        default:
            break
        }
        return scalar.properties.isAlphabetic || ("0"..."9").contains(Character(scalar))
            || ".,!?;:".unicodeScalars.contains(scalar)
    }

    // MARK: - Chunking

    /// Splits audio into ≤ `maxChunk` pieces, cutting at the quietest 20 ms window within the
    /// last 6 s of each piece so words are not sliced in half.
    nonisolated static func chunkRanges(for samples: [Float], maxChunk: Int) -> [Range<Int>] {
        guard samples.count > maxChunk else { return [0..<samples.count] }
        let window = 320
        let searchSpan = min(maxChunk / 2, 6 * SenseVoiceConstants.sampleRate)
        var ranges: [Range<Int>] = []
        var start = 0
        while samples.count - start > maxChunk {
            // Leave at least `minimumSamples` for the remainder so the tail is never too short to run.
            let hardEnd = min(start + maxChunk, samples.count - SenseVoiceConstants.minimumSamples)
            var bestEnd = hardEnd
            var bestEnergy = Float.greatestFiniteMagnitude
            var position = hardEnd - window
            let lowerBound = hardEnd - searchSpan
            samples.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                while position >= lowerBound {
                    var energy: Float = 0
                    vDSP_svesq(base + position, 1, &energy, vDSP_Length(window))
                    if energy < bestEnergy {
                        bestEnergy = energy
                        bestEnd = position + window / 2
                    }
                    position -= window
                }
            }
            ranges.append(start..<bestEnd)
            start = bestEnd
        }
        ranges.append(start..<samples.count)
        return ranges
    }

    // MARK: - Loading

    private nonisolated static func loadModel(_ url: URL, configuration: MLModelConfiguration) throws -> MLModel {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SenseVoiceError.missingArtifact(url.lastPathComponent)
        }
        return try MLModel(contentsOf: url, configuration: configuration)
    }

    private nonisolated static func loadVocabulary(_ url: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SenseVoiceError.missingArtifact(url.lastPathComponent)
        }
        let data = try Data(contentsOf: url)
        if let list = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return list
        }
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            let pairs = dict.compactMap { key, value in Int(key).map { ($0, value) } }
            guard let maxID = pairs.map(\.0).max() else { throw SenseVoiceError.vocabularyUnreadable }
            var list = [String](repeating: "", count: maxID + 1)
            for (id, token) in pairs {
                list[id] = token
            }
            return list
        }
        throw SenseVoiceError.vocabularyUnreadable
    }

    /// Frame lengths the encoder's `speech [1, T, 560]` input accepts, ascending.
    private nonisolated static func acceptedFrameCounts(of model: MLModel) -> [Int] {
        guard let constraint = model.modelDescription.inputDescriptionsByName["speech"]?.multiArrayConstraint else {
            return SenseVoiceConstants.defaultBuckets
        }
        let shapes: [[NSNumber]]
        switch constraint.shapeConstraint.type {
        case .enumerated: shapes = constraint.shapeConstraint.enumeratedShapes
        case .unspecified: shapes = [constraint.shape]
        case .range:
            let range = constraint.shapeConstraint.sizeRangeForDimension
            if range.count == 3 {
                let upper = range[1].rangeValue
                let maxFrames = upper.location + upper.length
                return SenseVoiceConstants.defaultBuckets.filter { $0 <= maxFrames }
            }
            return SenseVoiceConstants.defaultBuckets
        @unknown default:
            return SenseVoiceConstants.defaultBuckets
        }
        let frames = Set(shapes.compactMap { $0.count == 3 ? $0[1].intValue : nil }).sorted()
        return frames.isEmpty ? SenseVoiceConstants.defaultBuckets : frames
    }

    /// Upper bound of the preprocessor's flexible `waveform [1, N]` input, if declared.
    private nonisolated static func maximumWaveformSamples(of model: MLModel) -> Int? {
        guard let constraint = model.modelDescription.inputDescriptionsByName["waveform"]?.multiArrayConstraint,
              constraint.shapeConstraint.type == .range
        else { return nil }
        let ranges = constraint.shapeConstraint.sizeRangeForDimension
        guard ranges.count == 2 else { return nil }
        let range = ranges[1].rangeValue
        // NSRange from CoreML: location = lower bound, length = upper − lower.
        let upper = range.location + range.length
        return upper > 0 ? upper : nil
    }

    private nonisolated static func int32Scalar(_ value: Int32) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1], dataType: .int32)
        array.dataPointer.assumingMemoryBound(to: Int32.self).pointee = value
        return array
    }
}
