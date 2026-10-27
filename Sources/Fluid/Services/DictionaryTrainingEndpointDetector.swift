import Foundation
#if arch(arm64)
import FluidAudio
#endif

actor DictionaryTrainingEndpointDetector {
    static let chunkSize = 4096

    enum Event: Sendable {
        case speechStarted
        case speechEnded
    }

    struct Session: Equatable, Sendable {
        let id: UUID
    }

    #if arch(arm64)
    private var manager: VadManager?
    private var managerTask: Task<VadManager, Error>?
    private var activeSessionID: UUID?
    private var streamState: VadStreamState?
    private var hasDetectedSpeech = false

    func prepare() async throws {
        try await MeetingModelResidencyCoordinator.ordinary(owner: "dictionary-vad", modelID: "silero-vad") {
            _ = try await self.preparedManager()
        }
    }

    func beginSession() async throws -> Session? {
        try await MeetingModelResidencyCoordinator.ordinary(owner: "dictionary-vad", modelID: "silero-vad") {
            try await self.beginPreparedSession()
        }
    }

    private func beginPreparedSession() async throws -> Session? {
        let manager = try await self.preparedManager()
        let session = Session(id: UUID())
        self.activeSessionID = session.id
        self.streamState = await manager.makeStreamState()
        self.hasDetectedSpeech = false
        return session
    }

    func process(_ samples: [Float], session: Session) async throws -> Event? {
        try await MeetingModelResidencyCoordinator.ordinary(owner: "dictionary-vad", modelID: "silero-vad") {
            try await self.processPrepared(samples, session: session)
        }
    }

    private func processPrepared(_ samples: [Float], session: Session) async throws -> Event? {
        guard samples.count == Self.chunkSize,
              self.activeSessionID == session.id,
              let manager,
              let streamState
        else {
            return nil
        }

        let result = try await manager.processStreamingChunk(
            samples,
            state: streamState,
            config: .default
        )
        guard self.activeSessionID == session.id else { return nil }

        self.streamState = result.state
        guard let event = result.event else { return nil }

        switch event.kind {
        case .speechStart:
            self.hasDetectedSpeech = true
            return .speechStarted
        case .speechEnd:
            return self.hasDetectedSpeech ? .speechEnded : nil
        }
    }

    func endSession(_ session: Session) {
        guard self.activeSessionID == session.id else { return }
        self.activeSessionID = nil
        self.streamState = nil
        self.hasDetectedSpeech = false
    }

    func residencySnapshot() -> MeetingResidentModel? {
        self.manager == nil ? nil : MeetingResidentModel(id: "silero-vad", configuration: "default")
    }

    func unloadForMeeting() async {
        // Admission is closed and all inference operations have returned before suspension.
        // Join a preparation defensively before dropping its last model reference.
        let preparation = self.managerTask
        preparation?.cancel()
        _ = await preparation?.result
        self.managerTask = nil
        self.manager = nil
        self.activeSessionID = nil
        self.streamState = nil
        self.hasDetectedSpeech = false
    }

    private func preparedManager() async throws -> VadManager {
        if let manager {
            return manager
        }
        if let managerTask {
            do {
                let manager = try await managerTask.value
                self.manager = manager
                self.managerTask = nil
                return manager
            } catch {
                self.managerTask = nil
                throw error
            }
        }

        let task = Task<VadManager, Error> {
            try await VadManager()
        }
        self.managerTask = task

        do {
            let manager = try await task.value
            self.manager = manager
            self.managerTask = nil
            return manager
        } catch {
            self.managerTask = nil
            throw error
        }
    }
    #else
    func residencySnapshot() -> MeetingResidentModel? { nil }

    func unloadForMeeting() async {}

    func prepare() async throws {}

    func beginSession() async throws -> Session? {
        nil
    }

    func process(_: [Float], session _: Session) async throws -> Event? {
        nil
    }

    func endSession(_: Session) {}
    #endif
}
