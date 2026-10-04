#if arch(arm64)
import FluidAudio

/// Each enrollment keeps its own center and duration. No cross-recording averaging.
enum DictionaryPronunciationReferences {
    struct Reference {
        let profile: PronunciationDictionaryProfile
        let sampleNumber: Int
        let embedding: PronunciationEmbedding
    }

    static func make(profiles: [PronunciationDictionaryProfile], hiddenSize: Int? = nil) -> [Reference] {
        profiles.flatMap { profile -> [Reference] in
            guard !ParakeetSpeechModelCatalog.isOutdatedCompactPronunciationModelKey(profile.modelKey),
                  profile.enrollments.allSatisfy({ $0.modelKey == profile.modelKey })
            else { return [] }
            guard hiddenSize == nil || profile.hiddenSize == hiddenSize else { return [] }
            if let calibration = profile.edgeCalibration {
                let frames = profile.enrollments.compactMap(\.edgeFrameCount)
                return [Reference(profile: profile, sampleNumber: 0, embedding: PronunciationEmbedding(
                    values: calibration.center, sourceFrameCount: max(1, frames.reduce(0, +) / frames.count)
                ))]
            }
            return profile.enrollments.enumerated().compactMap { index, capture in
                guard capture.values.count == profile.hiddenSize, capture.sourceFrameCount > 0,
                      capture.values.allSatisfy(\.isFinite)
                else { return nil }
                // A singleton prototype only normalizes this recording's vector.
                guard let embedding = PronunciationEmbeddingMatcher.prototype(from: [
                    PronunciationEmbedding(values: capture.values, sourceFrameCount: capture.sourceFrameCount),
                ]) else { return nil }
                return Reference(profile: profile, sampleNumber: index + 1, embedding: embedding)
            }
        }
    }
}
#endif
