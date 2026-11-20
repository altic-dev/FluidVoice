import Foundation

/// Format completed speaker turns only. Raw word evidence and partial captions stay verbatim.
nonisolated enum MeetingTranscriptNormalizer {
    static func normalize(
        _ segments: [MeetingTranscriptSegment],
        languageCode: String,
        dictionaryEntries: [SettingsStore.CustomDictionaryEntry] = []
    ) async throws -> [MeetingTranscriptSegment] {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            // No emoji catalog: discussing "fire emoji" in a meeting is not a dictation command.
            let normalizer = FluidTextNormalizer()
            let rules = DictionaryReplacementRule.compile(for: dictionaryEntries)
            var formatted = segments
            for index in formatted.indices {
                try Task.checkCancellation()
                guard formatted[index].status == .final,
                      !formatted[index].text.contains("\0"),
                      formatted[index].text.utf8.count <= FluidTextNormalizer.maximumUTF8Length else { continue }
                for rule in rules {
                    try Task.checkCancellation()
                    formatted[index].text = DictionaryReplacementProtection.replacingMatches(
                        in: formatted[index].text,
                        regex: rule.regex,
                        template: rule.template,
                        canonical: rule.canonical
                    )
                }
                // Match dictation ordering: saved rules first, then quantity formatting.
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
