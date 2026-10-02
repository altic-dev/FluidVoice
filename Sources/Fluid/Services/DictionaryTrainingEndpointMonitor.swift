import Foundation

struct DictionaryTrainingAudioCursor {
    private(set) var sampleOffset = 0
    private var generation: Int

    init(generation: Int) {
        self.generation = generation
    }

    mutating func synchronize(generation: Int) {
        guard generation != self.generation else { return }
        self.generation = generation
        self.sampleOffset = 0
    }

    mutating func consume(_ sampleCount: Int) {
        self.sampleOffset += sampleCount
    }
}

@MainActor
final class DictionaryTrainingEndpointMonitor {
    static let shared = DictionaryTrainingEndpointMonitor()

    private let detector = DictionaryTrainingEndpointDetector()
    private var task: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?

    init() {}

    func meetingResidencyParticipant() -> MeetingModelParticipant {
        MeetingModelParticipant(
            owner: "dictionary-vad",
            snapshot: {
                let generation = "dictionary-recording"
                guard let resident = await self.detector.residencySnapshot() else { return nil }
                return MeetingResidentModel(id: resident.id, configuration: generation)
            },
            suspend: {
                self.stop()
                await self.detector.unloadForMeeting()
            },
            restore: { snapshot in
                _ = try await Self.prepareIfCurrent(
                    expectedGeneration: snapshot.configuration,
                    prepare: { try await self.detector.prepare() },
                    unload: { await self.detector.unloadForMeeting() }
                )
            }
        )
    }

    /// Keep model restoration bounded to the caller's resource configuration.
    /// Speech-end detection serves spelling capture regardless of pronunciation settings.
    static func prepareIfCurrent(
        expectedGeneration: String,
        isEnabled: () -> Bool = { true },
        generation: () -> String = { "dictionary-recording" },
        prepare: () async throws -> Void,
        unload: () async -> Void
    ) async throws -> Bool {
        guard isEnabled(), generation() == expectedGeneration, !Task.isCancelled else { return false }
        try await prepare()
        guard isEnabled(), generation() == expectedGeneration, !Task.isCancelled else {
            await unload()
            return false
        }
        return true
    }

    func prepare() async {
        do {
            try await self.detector.prepare()
            guard !Task.isCancelled else { return }
            DebugLogger.shared.debug(
                "Dictionary training endpoint detector ready",
                source: "DictionaryTrainingEndpointMonitor"
            )
        } catch {
            DebugLogger.shared.warning(
                "Dictionary training endpoint detector unavailable: \(error.localizedDescription)",
                source: "DictionaryTrainingEndpointMonitor"
            )
        }
    }

    func start(
        asr: ASRService,
        onSpeechEnded: @escaping @MainActor () -> Void
    ) {
        guard let captureToken = asr.dictionaryCaptureToken else { return }
        self.start(
            isCurrent: { [weak asr] in asr?.isRunning == true && asr?.dictionaryCaptureToken == captureToken },
            audioGeneration: { [weak asr] in asr?.dictionaryTrainingAudioGeneration ?? 0 },
            readChunk: { [weak asr] offset in
                asr?.dictionaryTrainingAudioChunk(at: offset, count: DictionaryTrainingEndpointDetector.chunkSize) ?? []
            },
            onSpeechEnded: onSpeechEnded
        )
    }

    /// The same loop is replayable with recorded PCM; microphone ownership stays with ASRService.
    func start(
        isCurrent: @escaping @MainActor () -> Bool,
        audioGeneration: @escaping @MainActor () -> Int,
        readChunk: @escaping @MainActor (Int) -> [Float],
        maximumDuration: Duration = .seconds(15),
        onSpeechEnded: @escaping @MainActor () -> Void
    ) {
        self.stop()
        let detector = self.detector
        // Bound capture even if model preparation fails or never produces an endpoint.
        self.deadlineTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: maximumDuration) } catch { return }
            guard !Task.isCancelled, isCurrent() else { return }
            self?.task?.cancel()
            onSpeechEnded()
        }
        self.task = Task { @MainActor [weak self] in
            do {
                guard !Task.isCancelled, isCurrent() else { return }
                guard let detectorSession = try await detector.beginSession() else { return }
                defer {
                    Task { await detector.endSession(detectorSession) }
                }

                var cursor = DictionaryTrainingAudioCursor(generation: audioGeneration())
                while !Task.isCancelled {
                    guard isCurrent() else { return }
                    cursor.synchronize(generation: audioGeneration())
                    let chunk = readChunk(cursor.sampleOffset)
                    guard !chunk.isEmpty else {
                        try await Task.sleep(nanoseconds: 40_000_000)
                        continue
                    }
                    cursor.consume(chunk.count)

                    guard let event = try await detector.process(
                        chunk,
                        session: detectorSession
                    ) else {
                        continue
                    }
                    guard !Task.isCancelled, isCurrent()
                    else {
                        return
                    }

                    switch event {
                    case .speechStarted:
                        DebugLogger.shared.debug(
                            "Dictionary training speech started",
                            source: "DictionaryTrainingEndpointMonitor"
                        )
                    case .speechEnded:
                        DebugLogger.shared.debug(
                            "Dictionary training speech ended; stopping sample",
                            source: "DictionaryTrainingEndpointMonitor"
                        )
                        self?.deadlineTask?.cancel()
                        onSpeechEnded()
                        return
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                DebugLogger.shared.warning(
                    "Dictionary training endpoint detection failed: \(error.localizedDescription)",
                    source: "DictionaryTrainingEndpointMonitor"
                )
            }
        }
    }

    func stop() {
        self.deadlineTask?.cancel()
        self.deadlineTask = nil
        self.task?.cancel()
        self.task = nil
    }
}
