#if arch(arm64)
import CoreML
import FluidAudio
import Foundation

/// Uses the provider's already-loaded models; never downloads or starts an ASR decoder.
nonisolated enum DictionaryTemporalEncoder {
    @concurrent static func encode(_ input: [Float], models: AsrModels) async throws -> DictionaryMatchFrames {
        guard !input.isEmpty, input.count <= 240_000, input.allSatisfy(\.isFinite) else {
            throw PronunciationDictionaryStoreError.inconsistentEnrollment
        }
        try Task.checkCancellation()
        let rms = sqrt(input.reduce(Double(0)) { $0 + Double($1) * Double($1) } / Double(input.count))
        let peak = Double(input.map(abs).max() ?? 0)
        let gain = Float(min(32, min(0.05 / max(rms, 1e-12), 0.95 / max(peak, 1e-12))))
        let audio = try MLMultiArray(shape: [1, 240_000], dataType: .float32)
        let pointer = audio.dataPointer.bindMemory(to: Float.self, capacity: 240_000)
        pointer.initialize(repeating: 0, count: 240_000)
        for i in input.indices {
            pointer[i] = input[i] * gain
        }
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: input.count)
        let provider = try MLDictionaryFeatureProvider(dictionary: ["audio_signal": audio, "audio_length": length])
        let pre = try await models.preprocessor.prediction(from: provider, options: AsrModels.optimizedPredictionOptions())
        try Task.checkCancellation()
        var fields: [String: MLFeatureValue] = [:]
        for key in models.encoderInputFeatureNames {
            fields[key] = pre.featureValue(for: key) ?? provider.featureValue(for: key)
        }
        let output = try await models.predictEncoder(from: MLDictionaryFeatureProvider(dictionary: fields), options: AsrModels.optimizedPredictionOptions())
        try Task.checkCancellation()
        guard let array = output.featureValue(for: "encoder")?.multiArrayValue,
              let encodedLength = output.featureValue(for: "encoder_length")?.multiArrayValue,
              array.dataType == .float32, array.shape.count == 3 else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        let hiddenSize = models.version.encoderHiddenSize
        let hiddenAxis = shape[1] == hiddenSize ? 1 : 2, timeAxis = hiddenAxis == 1 ? 2 : 1
        guard shape[hiddenAxis] == hiddenSize else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        let end = min(input.count, max(1, Int((Double(input.count) / 1280).rounded()) * 1280))
        let count = min(encodedLength[0].intValue, min(shape[timeAxis], (end + 1279) / 1280))
        guard (1...192).contains(count) else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        let data = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        var values: [Float] = []
        values.reserveCapacity(count * hiddenSize)
        for frame in 0..<count {
            for d in 0..<hiddenSize {
                values.append(data[frame * strides[timeAxis] + d * strides[hiddenAxis]])
            }
        }
        let frames = DictionaryMatchFrames(hiddenSize: hiddenSize, values: values)
        guard frames.isValid else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        return frames
    }
}
#endif
