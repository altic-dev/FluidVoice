import AppKit
import AVFoundation
import Combine
import Foundation

enum AgentPromptStatus: String, Decodable {
    case completed
    case error
}

enum AgentPromptResult: Equatable {
    case replied(String)
    case cancelled
    case busy
    case unavailable(String)
}

@MainActor
protocol AgentPromptHandling {
    func prompt(id: UUID, message: String, status: AgentPromptStatus) async -> AgentPromptResult
    func cancelPrompt(id: UUID)
}

@MainActor
protocol AgentPromptRecording {
    var unavailableReason: String? { get }
    var liveTranscript: AnyPublisher<String, Never> { get }
    var captureEnded: AnyPublisher<Void, Never> { get }
    func start() async -> Bool
    func stop() async -> String
    func cancel() async
    func refine(_ transcript: String) async -> String
}

@MainActor
private final class DictationAgentRecorder: AgentPromptRecording {
    private var asr: ASRService { AppServices.shared.asr }
    private var captureLease: ASRActivityLease?

    var unavailableReason: String? {
        if let activity = self.asr.activeExclusiveActivity {
            return ASRActivityError.activityInProgress(activity).localizedDescription
        }
        return self.asr.micStatus == .authorized ? nil : "FluidVoice needs microphone access."
    }

    var liveTranscript: AnyPublisher<String, Never> {
        self.asr.$partialTranscription.eraseToAnyPublisher()
    }

    var captureEnded: AnyPublisher<Void, Never> {
        self.asr.$activeExclusiveActivity
            .filter { $0 != .agentPrompt }
            .map { _ in () }
            .prefix(1)
            .eraseToAnyPublisher()
    }

    func start() async -> Bool {
        self.captureLease = nil
        return await self.asr.start(onAgentCaptureReserved: { self.captureLease = $0 }, onCaptureStarted: {
            TranscriptionSoundPlayer.shared.playStartSound()
        }) == .started
    }

    func stop() async -> String {
        guard let captureLease else { return "" }
        return await self.asr.stop(agentPromptLease: captureLease, onCaptureStopped: {
            TranscriptionSoundPlayer.shared.playStopSound()
        })
    }

    func cancel() async {
        guard let captureLease else { return }
        await self.asr.stopWithoutTranscription(agentPromptLease: captureLease)
    }

    func refine(_ transcript: String) async -> String {
        guard DictationAIPostProcessingGate.isConfigured(),
              let processed = try? await DictationPostProcessingService.shared.process(transcript)
        else { return transcript }
        let text = processed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? transcript : text
    }
}

@MainActor
final class AgentBridgeService: ObservableObject, AgentPromptHandling {
    static let shared = AgentBridgeService(
        recorder: DictationAgentRecorder(),
        isSessionLocked: GlobalHotkeyManager.currentSessionIsLocked,
        sessionDidLock: DistributedNotificationCenter.default()
            .publisher(for: Notification.Name("com.apple.screenIsLocked"))
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification))
            .map { _ in () }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    )

    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case processing
        case cancelling
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var agentMessage = ""
    @Published private(set) var agentStatus: AgentPromptStatus = .completed
    @Published private(set) var liveTranscript = ""

    private let recorder: any AgentPromptRecording
    private let isSessionLocked: () -> Bool
    private let panelController = AgentPromptPanelController()
    private var requestID: UUID?
    private var continuation: CheckedContinuation<AgentPromptResult, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var transcriptCancellable: AnyCancellable?
    private var captureEndCancellable: AnyCancellable?
    private var sessionLockCancellable: AnyCancellable?

    init(
        recorder: any AgentPromptRecording,
        isSessionLocked: @escaping () -> Bool,
        sessionDidLock: AnyPublisher<Void, Never>
    ) {
        self.recorder = recorder
        self.isSessionLocked = isSessionLocked
        self.sessionLockCancellable = sessionDidLock.sink { [weak self] in
            self?.cancelActivePrompt()
        }
    }

    func prompt(id: UUID, message: String, status: AgentPromptStatus) async -> AgentPromptResult {
        guard !self.isSessionLocked() else {
            return .unavailable("Unlock your Mac before replying by voice.")
        }
        guard self.phase == .idle else { return .busy }

        if let reason = self.recorder.unavailableReason {
            return .unavailable(reason)
        }

        self.requestID = id
        self.agentMessage = message
        self.agentStatus = status
        self.liveTranscript = ""
        self.phase = .starting
        self.panelController.show(bridge: self)

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.timeoutTask = Task {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                self.cancelPrompt(id: id)
            }
            Task { await self.startRecording(id: id) }
        }
    }

    private func startRecording(id: UUID) async {
        guard self.requestID == id, self.phase == .starting else { return }
        guard !self.isSessionLocked() else {
            self.complete(.cancelled)
            return
        }
        let started = await self.recorder.start()
        guard self.requestID == id, self.phase == .starting else { return }
        guard started else {
            self.complete(.unavailable("Could not start the microphone."))
            return
        }
        if self.isSessionLocked() {
            self.cancelActivePrompt()
            return
        }

        self.phase = .recording
        self.transcriptCancellable = self.recorder.liveTranscript.sink { [weak self] text in
            self?.liveTranscript = text
        }
        let captureEnd = self.recorder.captureEnded.sink { [weak self] in
            guard let self, self.phase == .recording else { return }
            self.complete(.cancelled)
        }
        if self.phase == .recording {
            self.captureEndCancellable = captureEnd
        }
    }

    func finishRecordingAndReply() {
        guard self.phase == .recording else { return }
        self.phase = .processing
        Task {
            if self.isSessionLocked() { self.cancelActivePrompt() }
            guard self.phase == .processing else {
                await self.recorder.cancel()
                self.complete(.cancelled)
                return
            }

            let raw = await self.recorder.stop().trimmingCharacters(in: .whitespacesAndNewlines)
            guard self.phase == .processing, !self.isSessionLocked(), !raw.isEmpty else {
                self.complete(.cancelled)
                return
            }
            let text = await self.recorder.refine(raw)
            let canReply = self.phase == .processing && !self.isSessionLocked()
            self.complete(canReply ? .replied(text) : .cancelled)
        }
    }

    func cancelPrompt(id: UUID) {
        guard self.requestID == id else { return }
        self.cancelActivePrompt()
    }

    func cancelActivePrompt() {
        switch self.phase {
        case .idle, .cancelling:
            return
        case .starting, .recording:
            self.phase = .cancelling
            self.resolve(.cancelled)
            Task {
                await self.recorder.cancel()
                self.complete(.cancelled)
            }
        case .processing:
            // The finish task owns the ASR stop. Keep the session reserved until that task exits.
            self.phase = .cancelling
            self.resolve(.cancelled)
        }
    }

    private func complete(_ result: AgentPromptResult) {
        self.requestID = nil
        self.phase = .idle
        self.resolve(result)
    }

    private func resolve(_ result: AgentPromptResult) {
        guard let continuation = self.continuation else { return }
        self.continuation = nil
        self.timeoutTask?.cancel()
        self.timeoutTask = nil
        self.transcriptCancellable?.cancel()
        self.transcriptCancellable = nil
        self.captureEndCancellable?.cancel()
        self.captureEndCancellable = nil
        self.panelController.hide()
        continuation.resume(returning: result)
    }
}
