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

    private init() {}

    func meetingResidencyParticipant() -> MeetingModelParticipant {
        MeetingModelParticipant(
            owner: "dictionary-vad",
            snapshot: {
                let generation = DictionaryMatcherExperiment.generation
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

    /// Eligibility must survive the actual load. Disabling and re-enabling changes the
    /// generation, so neither an old snapshot nor a late model completion can revive it.
    static func prepareIfCurrent(
        expectedGeneration: String,
        isEnabled: () -> Bool = { DictionaryMatcherExperiment.sharedFeaturesEnabled },
        generation: () -> String = { DictionaryMatcherExperiment.generation },
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
        guard DictionaryMatcherExperiment.sharedFeaturesEnabled else { return }
        let generation = DictionaryMatcherExperiment.generation
        do {
            try await self.detector.prepare()
            guard DictionaryMatcherExperiment.sharedFeaturesEnabled, generation == DictionaryMatcherExperiment.generation, !Task.isCancelled else { return }
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
        self.stop()
        guard DictionaryMatcherExperiment.sharedFeaturesEnabled else { return }
        let detector = self.detector
        let generation = DictionaryMatcherExperiment.generation
        guard let captureToken = asr.dictionaryCaptureToken else { return }

        self.task = Task { @MainActor [weak asr] in
            do {
                guard DictionaryMatcherExperiment.sharedFeaturesEnabled, generation == DictionaryMatcherExperiment.generation, !Task.isCancelled, let asr,
                      asr.dictionaryCaptureToken == captureToken,
                      let detectorSession = try await detector.beginSession()
                else {
                    return
                }
                defer {
                    Task { await detector.endSession(detectorSession) }
                }

                var cursor = DictionaryTrainingAudioCursor(generation: asr.dictionaryTrainingAudioGeneration)
                while !Task.isCancelled {
                    guard DictionaryMatcherExperiment.sharedFeaturesEnabled, generation == DictionaryMatcherExperiment.generation, asr.isRunning,
                          asr.dictionaryCaptureToken == captureToken else { return }
                    cursor.synchronize(generation: asr.dictionaryTrainingAudioGeneration)

                    let chunk = asr.dictionaryTrainingAudioChunk(
                        at: cursor.sampleOffset,
                        count: DictionaryTrainingEndpointDetector.chunkSize
                    )
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
                    guard DictionaryMatcherExperiment.sharedFeaturesEnabled, generation == DictionaryMatcherExperiment.generation, !Task.isCancelled,
                          asr.isRunning,
                          asr.dictionaryCaptureToken == captureToken
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
        self.task?.cancel()
        self.task = nil
    }
}
