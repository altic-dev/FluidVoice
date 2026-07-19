import AVFoundation
import Combine
import Foundation

/// Orchestrates one Kinward voice turn: capture -> transcribe (reusing the existing
/// Parakeet/Whisper/etc. ASRService pipeline, same as dictation and Command Mode) -> send to
/// the Kinward backend directly via KinwardClient -> speak the reply back with
/// AVSpeechSynthesizer.
///
/// Deliberately independent of ContentView's `activeRecordingMode` state machine (dictate /
/// promptMode / edit / command). It drives `AppServices.shared.asr` directly instead, so both
/// the dedicated hotkey (KinwardHotkeyMonitor) and the wake-word listener (KinwardWakeWordService)
/// can trigger it without threading a new case through that large, overlay/notch-coupled state
/// machine. Trade-off: Kinward Mode doesn't currently light up the notch/menu-bar overlay the way
/// Command Mode does - only MenuBarManager's coarse processing indicator.
@MainActor
final class KinwardModeService: ObservableObject {
    static let shared = KinwardModeService()

    enum State: Equatable {
        case idle
        case listening
        case thinking
        case speaking
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastTranscript: String = ""
    @Published private(set) var lastReply: String = ""

    private let synthesizer = AVSpeechSynthesizer()
    private var speechDelegate: SpeechDelegate?

    private init() {}

    var isBusy: Bool {
        self.state != .idle
    }

    /// Wake word / hotkey down-stroke: begin capturing. No-ops if something else already owns
    /// the mic (e.g. Marc is mid-dictation) rather than stealing it.
    func beginTurn() async {
        guard self.state == .idle else { return }
        guard AppServices.shared.asr.isRunning == false else {
            DebugLogger.shared.warning("KinwardModeService: mic already in use, ignoring beginTurn", source: "KinwardMode")
            return
        }
        self.state = .listening
        await AppServices.shared.asr.start()
    }

    /// Hotkey up-stroke / wake-word endpoint reached: stop capturing, send to Kinward, speak
    /// the reply.
    func endTurnAndRespond() async {
        guard self.state == .listening else { return }
        let transcript = await AppServices.shared.asr.stop()
        self.lastTranscript = transcript

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.state = .idle
            return
        }

        self.state = .thinking

        do {
            let response = try await KinwardClient.shared.sendMessage(trimmed)
            self.lastReply = response.responseText
            self.speak(response.responseText)
        } catch {
            let message = error.localizedDescription
            DebugLogger.shared.error("KinwardModeService: request failed - \(message)", source: "KinwardMode")
            self.state = .error(message)
            self.speak(message)
        }
    }

    /// Convenience for a single-hotkey-press toggle (press to talk, press again to send) rather
    /// than a hold-to-talk gesture.
    func toggleTurn() {
        Task {
            switch self.state {
            case .idle:
                await self.beginTurn()
            case .listening:
                await self.endTurnAndRespond()
            case .thinking, .speaking, .error:
                // Busy - ignore extra presses rather than interrupting an in-flight turn.
                break
            }
        }
    }

    func cancel() {
        Task {
            if AppServices.shared.asr.isRunning {
                _ = await AppServices.shared.asr.stopWithoutTranscription()
            }
            self.synthesizer.stopSpeaking(at: .immediate)
            self.state = .idle
        }
    }

    // MARK: - Speech output

    private func speak(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.state = .idle
            return
        }

        let utterance = AVSpeechUtterance(string: text)
        let voiceIdentifier = SettingsStore.shared.kinwardTTSVoiceIdentifier
        if !voiceIdentifier.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        }

        let delegate = SpeechDelegate { [weak self] in
            self?.state = .idle
        }
        self.speechDelegate = delegate
        self.synthesizer.delegate = delegate

        self.state = .speaking
        self.synthesizer.speak(utterance)
    }

    /// True while a reply is being spoken - the wake-word listener checks this (and
    /// `AppServices.shared.asr.isRunning`) to avoid re-triggering on its own audio output.
    var isSpeaking: Bool {
        self.state == .speaking
    }

    private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
        private let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            Task { @MainActor in self.onFinish() }
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            Task { @MainActor in self.onFinish() }
        }
    }
}
