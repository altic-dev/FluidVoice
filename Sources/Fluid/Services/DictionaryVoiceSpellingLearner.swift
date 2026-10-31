import Foundation

/// Voice matching caught a word under a new spelling ("Nickdom" for Snigdham). If the user keeps
/// the replacement, the spelling becomes a saved text rule, so next time the text layer replaces it
/// directly and voice matching is not needed. Editing the replaced word within the window drops it.
@MainActor
final class DictionaryVoiceSpellingLearner {
    static let shared = DictionaryVoiceSpellingLearner()

    nonisolated static let confirmationWindow: Duration = .seconds(120)
    private static let maximumPending = 20
    private static let maximumSpellingsPerWord = 20

    private struct Pending {
        let id: UUID
        let spelling: DictionaryVoiceSpelling
        let recordingID: UUID?
        let task: Task<Void, Never>
    }

    private var pending: [Pending] = []
    private let window: Duration
    private let isEnabled: @MainActor () -> Bool
    private let canWrite: @MainActor () -> Bool
    private let load: @MainActor () -> [SettingsStore.CustomDictionaryEntry]
    private let save: @MainActor ([SettingsStore.CustomDictionaryEntry]) -> Void

    init(
        window: Duration = DictionaryVoiceSpellingLearner.confirmationWindow,
        isEnabled: @escaping @MainActor () -> Bool = { SettingsStore.shared.automaticDictionaryLearningEnabled },
        canWrite: @escaping @MainActor () -> Bool = { !AppServices.shared.asr.isRunningOrStarting },
        load: @escaping @MainActor () -> [SettingsStore.CustomDictionaryEntry] = { SettingsStore.shared.customDictionaryEntries },
        save: @escaping @MainActor ([SettingsStore.CustomDictionaryEntry]) -> Void = {
            SettingsStore.shared.customDictionaryEntries = $0
            // The text layer caches compiled rules; without this the learned spelling would not apply yet.
            // No vocabulary notification: that would restart the speech engine for a text-only change.
            ASRService.invalidateDictionaryCache()
        }
    ) {
        self.window = window
        self.isEnabled = isEnabled
        self.canWrite = canWrite
        self.load = load
        self.save = save
    }

    var pendingCount: Int { self.pending.count }

    /// Called once the dictation has been delivered where its edits can be observed.
    func propose(_ spellings: [DictionaryVoiceSpelling], recordingID: UUID? = nil) {
        guard self.isEnabled() else { return }
        for spelling in spellings where Self.isLearnable(spelling) {
            guard self.pending.count < Self.maximumPending,
                  !self.pending.contains(where: { $0.spelling == spelling }) else { continue }
            let id = UUID()
            let window = self.window
            let task = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: window) } catch { return }
                // Keep learned-rule writes outside an active capture.
                for _ in 0..<30 {
                    guard let self, !Task.isCancelled else { return }
                    if self.canWrite() { break }
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
                self?.commit(id)
            }
            self.pending.append(Pending(id: id, spelling: spelling, recordingID: recordingID, task: task))
        }
    }

    /// The user edited a delivered word. Any pending spelling for that word was a wrong match.
    func reject(editedText: String) {
        let edited = DictionaryAudioSpan.normalized(editedText)
        guard !edited.isEmpty else { return }
        for item in self.pending where DictionaryAudioSpan.normalized(item.spelling.label) == edited {
            item.task.cancel()
            DebugLogger.shared.info("DICTIONARY_VOICE_SPELLING dropped after user edit", source: "CustomDictionary")
        }
        self.pending.removeAll { DictionaryAudioSpan.normalized($0.spelling.label) == edited }
    }

    func cancelAll() {
        self.pending.forEach { $0.task.cancel() }
        self.pending.removeAll()
    }

    /// An unobserved field cannot confirm that its replacements were kept.
    func cancel(recordingID: UUID) {
        for item in self.pending where item.recordingID == recordingID {
            item.task.cancel()
        }
        self.pending.removeAll { $0.recordingID == recordingID }
    }

    private func commit(_ id: UUID) {
        guard let index = self.pending.firstIndex(where: { $0.id == id }) else { return }
        let spelling = self.pending.remove(at: index).spelling
        guard self.isEnabled(), self.canWrite() else { return }
        var entries = self.load()
        // The word may have been deleted or renamed meanwhile; only add to the same word.
        guard let entryIndex = entries.firstIndex(where: {
            $0.id == spelling.entryID && $0.replacement.caseInsensitiveCompare(spelling.label) == .orderedSame
        }) else { return }
        let trigger = spelling.spelling.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
        let existing = entries[entryIndex].triggers.map(DictionaryAudioSpan.normalized)
        guard !trigger.isEmpty, !existing.contains(DictionaryAudioSpan.normalized(trigger)),
              entries[entryIndex].triggers.count < Self.maximumSpellingsPerWord else { return }
        // A manual rule may have been added while this proposal was waiting. It owns its
        // spellings and canonical words, including phrases contained in this new spelling.
        let otherEntries = entries.filter { $0.id != spelling.entryID }
        let words = trigger.split(whereSeparator: \.isWhitespace).map(String.init)
        guard DictionaryAudioSpan.textClaimed(words: words, entries: otherEntries).isEmpty else { return }
        entries[entryIndex] = SettingsStore.CustomDictionaryEntry(
            id: entries[entryIndex].id,
            triggers: entries[entryIndex].triggers + [trigger],
            replacement: entries[entryIndex].replacement
        )
        self.save(entries)
        DebugLogger.shared.info("DICTIONARY_VOICE_SPELLING saved new spelling for a dictionary word", source: "CustomDictionary")
    }

    /// Never learn a spelling that is the word itself, or a bare common word that would
    /// replace ordinary speech everywhere.
    static func isLearnable(_ spelling: DictionaryVoiceSpelling) -> Bool {
        let heard = DictionaryAudioSpan.normalized(spelling.spelling)
        guard !heard.isEmpty, heard.count <= 60, heard != DictionaryAudioSpan.normalized(spelling.label) else { return false }
        return !Self.commonWords.contains(heard)
    }

    private static let commonWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "to", "of", "in", "on", "at", "it", "is", "i", "you", "he", "she",
        "we", "they", "me", "my", "be", "do", "so", "no", "yes", "this", "that", "there", "then", "them", "with",
    ]
}
