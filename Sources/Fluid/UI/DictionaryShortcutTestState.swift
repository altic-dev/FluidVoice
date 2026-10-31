import Foundation

/// Local UI state only. Never starts/stops capture or changes shared dictation output.
struct DictionaryShortcutTestState {
    enum Phase: Equatable { case idle, recording, processing }
    enum Result: Equatable { case none, recognized, missed, empty }

    private(set) var phase: Phase = .idle
    private(set) var result: Result = .none
    private(set) var text = ""
    private(set) var successes = 0
    private(set) var attemptID: UUID?
    private(set) var recording: DictionaryTestRecording?
    private var pendingSamples: [Float] = []

    mutating func begin(editorFocused: Bool, appActive: Bool, dictionaryCapture: Bool) {
        self.cancel()
        guard editorFocused, appActive, !dictionaryCapture else { return }
        self.recording = nil
        self.attemptID = UUID()
        self.phase = .recording
        self.result = .none
        self.text = ""
    }

    mutating func receiveAudio(_ samples: [Float]) {
        guard self.phase == .processing, self.attemptID != nil, !samples.isEmpty, samples.count <= 16_000 * 120 else { return }
        self.pendingSamples = samples
    }

    mutating func useHistory(id: UUID, text: String, url: URL) {
        self.cancel()
        self.text = text
        self.result = .none
        self.recording = DictionaryTestRecording(id: id, text: text, samples: [], audioURL: url)
    }

    mutating func stopped() {
        guard self.phase == .recording else { return }
        self.phase = .processing
    }

    mutating func receive(_ text: String, word: String) {
        guard self.phase == .processing, self.attemptID != nil else { return }
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.result = self.text.isEmpty ? .empty : (DictionaryWordTestResult.containsWord(word, in: self.text) ? .recognized : .missed)
        if let id = self.attemptID, !self.pendingSamples.isEmpty {
            self.recording = DictionaryTestRecording(id: id, text: self.text, samples: self.pendingSamples, audioURL: nil)
        }
        if self.result == .recognized { self.successes += 1 }
        self.cancel()
    }

    mutating func expire(_ attemptID: UUID) {
        guard self.attemptID == attemptID else { return }
        self.result = .empty
        self.cancel()
    }

    mutating func edit(_ text: String) {
        guard text != self.text else { return }
        self.cancel()
        self.recording = nil
        self.text = text
        self.result = .none
    }

    mutating func cancel() {
        self.phase = .idle
        self.attemptID = nil
        self.pendingSamples = []
    }
}

enum DictionaryCaptureAction {
    static func title(failed: Bool, count: Int) -> String {
        if failed { return "Record again" }
        return count < 1 ? "Record" : "Record more"
    }
}

enum DictionaryWordTestResult {
    static func containsWord(_ word: String, in transcript: String) -> Bool {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: word)
        return transcript.range(of: "(?<![\\p{L}\\p{N}_])" + escaped + "(?![\\p{L}\\p{N}_])", options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// One exact textbox attempt. Changing the text invalidates its audio score.
struct DictionaryTestRecording: Identifiable, Sendable {
    let id: UUID
    let text: String
    let samples: [Float]
    let audioURL: URL?
}
