import Foundation

/// Format completed speaker turns only. Raw word evidence and partial captions stay verbatim.
nonisolated enum MeetingTranscriptNormalizer {
    static func normalize(
        _ segments: [MeetingTranscriptSegment],
        languageCode: String
    ) async throws -> [MeetingTranscriptSegment] {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            // No emoji catalog: discussing "fire emoji" in a meeting is not a dictation command.
            let normalizer = FluidTextNormalizer()
            var formatted = segments
            for index in formatted.indices {
                try Task.checkCancellation()
                guard formatted[index].status == .final else { continue }
                formatted[index].text = normalizer.normalize(
                    formatted[index].text, phase: .afterCleanup, languageCode: languageCode
                )
            }
            return formatted
        }
        let formatted = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        return formatted
    }
}
