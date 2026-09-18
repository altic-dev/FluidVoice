@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Milestone A of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md`: the backend contract, the
/// injectable registry, evidence validation, and proof that `MeetingProcessingPipeline.process`
/// really dispatches through a selected backend.
///
/// The dispatch tests deliberately fail the `asrServiceProvider` closure: a fixture backend must be
/// reached without any ASR model readiness work, which is what makes "selection happens before
/// expensive model loading" a checked property rather than a claim.
@MainActor
final class MeetingTranscriptionBackendTests: XCTestCase {
    // MARK: - Fixture backend

    private final class FixtureMeetingBackend: MeetingTranscriptionBackend {
        let descriptor: MeetingBackendDescriptor
        private let makeOutcome: @MainActor (MeetingBackendPlan) -> MeetingBackendOutcome
        /// Lets a test hand back a plan that contradicts the request it was given.
        private let planOverride: (@MainActor (MeetingBackendRequest) -> MeetingBackendPlan)?
        private(set) var planCallCount = 0
        private(set) var executeCallCount = 0
        private(set) var lastPlan: MeetingBackendPlan?
        private(set) var receivedManifest: MeetingAnalysisManifest??
        private(set) var observedStages: [MeetingProcessingStage] = []

        init(
            descriptor: MeetingBackendDescriptor,
            planOverride: (@MainActor (MeetingBackendRequest) -> MeetingBackendPlan)? = nil,
            makeOutcome: @escaping @MainActor (MeetingBackendPlan) -> MeetingBackendOutcome
        ) {
            self.descriptor = descriptor
            self.planOverride = planOverride
            self.makeOutcome = makeOutcome
        }

        func plan(_ request: MeetingBackendRequest) throws -> MeetingBackendPlan {
            self.planCallCount += 1
            let plan = self.planOverride?(request)
                ?? MeetingBackendPlan(request: request, descriptor: self.descriptor)
            self.lastPlan = plan
            return plan
        }

        func execute(
            plan: MeetingBackendPlan,
            manifest: MeetingAnalysisManifest?,
            progress: @escaping @MainActor (MeetingProcessingStage) -> Void
        ) async throws -> MeetingBackendOutcome {
            self.executeCallCount += 1
            self.receivedManifest = manifest
            progress(.transcribing)
            self.observedStages.append(.transcribing)
            return self.makeOutcome(plan)
        }
    }

    /// Calls the host's legacy executor with whatever request a test wants, to prove the host
    /// refuses anything but the exact request it froze.
    private final class LegacyCallbackBackend: MeetingTranscriptionBackend {
        let descriptor: MeetingBackendDescriptor
        private let executor: MeetingLegacyBackendExecutor
        private let rewriteRequest: @MainActor (MeetingBackendRequest) -> MeetingBackendRequest

        init(
            descriptor: MeetingBackendDescriptor,
            executor: @escaping MeetingLegacyBackendExecutor,
            rewriteRequest: @escaping @MainActor (MeetingBackendRequest) -> MeetingBackendRequest
        ) {
            self.descriptor = descriptor
            self.executor = executor
            self.rewriteRequest = rewriteRequest
        }

        func plan(_ request: MeetingBackendRequest) throws -> MeetingBackendPlan {
            MeetingBackendPlan(request: request, descriptor: self.descriptor)
        }

        func execute(
            plan: MeetingBackendPlan,
            manifest: MeetingAnalysisManifest?,
            progress: @escaping @MainActor (MeetingProcessingStage) -> Void
        ) async throws -> MeetingBackendOutcome {
            try .legacyCompatibility(await self.executor(self.rewriteRequest(plan.request), progress))
        }
    }

    /// Parks inside `execute` on a latch that ignores cancellation, then returns successfully —
    /// a backend that does not cooperate with `Task` cancellation.
    private final class BlockingFixtureBackend: MeetingTranscriptionBackend {
        let descriptor: MeetingBackendDescriptor
        private let latch: Latch
        private let onEnter: @MainActor () -> Void
        private let makeOutcome: @MainActor (MeetingBackendPlan) -> MeetingBackendOutcome
        private(set) var executeCallCount = 0
        private(set) var didProduceOutcome = false

        init(
            descriptor: MeetingBackendDescriptor,
            latch: Latch,
            onEnter: @escaping @MainActor () -> Void,
            makeOutcome: @escaping @MainActor (MeetingBackendPlan) -> MeetingBackendOutcome
        ) {
            self.descriptor = descriptor
            self.latch = latch
            self.onEnter = onEnter
            self.makeOutcome = makeOutcome
        }

        func plan(_ request: MeetingBackendRequest) throws -> MeetingBackendPlan {
            MeetingBackendPlan(request: request, descriptor: self.descriptor)
        }

        func execute(
            plan: MeetingBackendPlan,
            manifest: MeetingAnalysisManifest?,
            progress: @escaping @MainActor (MeetingProcessingStage) -> Void
        ) async throws -> MeetingBackendOutcome {
            self.executeCallCount += 1
            self.onEnter()
            await self.latch.wait()
            self.didProduceOutcome = true
            return self.makeOutcome(plan)
        }
    }

    /// Deliberately cancellation-deaf: a parked waiter is only resumed by `open()`.
    private actor Latch {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func wait() async {
            if self.isOpen { return }
            await withCheckedContinuation { self.park($0) }
        }

        func open() {
            self.isOpen = true
            let parked = self.waiters
            self.waiters.removeAll()
            for continuation in parked {
                continuation.resume()
            }
        }

        private func park(_ continuation: CheckedContinuation<Void, Never>) {
            self.waiters.append(continuation)
        }
    }

    private nonisolated static let fixtureBackendID = MeetingBackendID(rawValue: "fixture-test-backend")

    private func makeFixtureDescriptor(
        id: MeetingBackendID = MeetingTranscriptionBackendTests.fixtureBackendID,
        version: String = "test",
        trackKinds: Set<MeetingAudioTrackKind> = Set(MeetingAudioTrackKind.allCases),
        precisions: Set<MeetingTextUnitPrecision> = [.word, .utterance],
        resultContract: MeetingBackendResultContract = .legacyResult
    ) -> MeetingBackendDescriptor {
        MeetingBackendDescriptor(
            id: id,
            version: version,
            execution: .local,
            supportedLanguageCodes: ["en"],
            supportedTrackKinds: trackKinds,
            supportedFinalPrecisions: precisions,
            resultContract: resultContract,
            knownLimits: ["Fixture only; performs no inference."]
        )
    }

    // MARK: - Session fixtures

    private func makeChunk(sequence: Int, path: String) -> MeetingAudioChunk {
        MeetingAudioChunk(
            id: UUID(),
            sequence: sequence,
            relativeFilePath: path,
            presentationStart: MeetingMediaTime(value: Int64(sequence) * 1000, timescale: 1000),
            presentationEnd: MeetingMediaTime(value: Int64(sequence + 1) * 1000, timescale: 1000),
            discontinuities: [],
            sha256: "fixture-\(sequence)",
            byteCount: 1024,
            finalizationState: .finalized
        )
    }

    private func makeTrack(kind: MeetingAudioTrackKind, chunks: [MeetingAudioChunk]) -> MeetingAudioTrack {
        MeetingAudioTrack(
            id: UUID(),
            kind: kind,
            sourceIdentifier: kind.rawValue,
            sourceDisplayName: kind.rawValue,
            format: nil,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 0,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: nil
            ),
            health: .waiting,
            chunks: chunks
        )
    }

    private func makeSession(
        languageCode: String = "en",
        tracks: [MeetingAudioTrack]? = nil,
        processingAttempts: [MeetingProcessingAttempt] = []
    ) -> MeetingSession {
        var session = MeetingSession(
            configuration: MeetingCaptureConfiguration(
                mode: .onlineCall,
                title: "Backend fixture",
                languageCode: languageCode,
                microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic-1", displayName: "Mic")
            ),
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 0,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: nil
            )
        )
        session.audioTracks = tracks ?? [
            self.makeTrack(kind: .microphone, chunks: [self.makeChunk(sequence: 0, path: "tracks/microphone/chunk_0.caf")]),
        ]
        session.processingAttempts = processingAttempts
        return session
    }

    private func makeResult(attemptID: UUID, text: String) -> MeetingProcessingResult {
        MeetingProcessingResult(
            speakers: [],
            segments: [
                MeetingTranscriptSegment(
                    id: UUID(),
                    start: MeetingMediaTime(value: 0, timescale: 1000),
                    end: MeetingMediaTime(value: 1000, timescale: 1000),
                    sourceTrackID: UUID(),
                    speakerID: nil,
                    text: text,
                    revision: 1,
                    status: .final,
                    overlap: .none,
                    completeness: .complete
                ),
            ],
            attempt: MeetingProcessingAttempt(
                id: attemptID,
                startedAt: Date(),
                completedAt: Date(),
                stage: .completed,
                pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
                asrProvider: "fixture",
                asrModel: "fixture",
                diarizationModel: nil,
                lastCompletedTrackID: nil,
                errorCode: nil
            )
        )
    }

    private func makePipeline(
        registry: MeetingTranscriptionBackendRegistry,
        backendID: MeetingBackendID?,
        gate: MeetingProcessingSerializationGate = MeetingProcessingSerializationGate()
    ) -> MeetingProcessingPipeline {
        MeetingProcessingPipeline(
            asrServiceProvider: {
                XCTFail("Backend dispatch must not reach ASR readiness for a fixture backend")
                return ASRService()
            },
            serializationGate: gate,
            backendRegistry: registry,
            backendID: backendID
        )
    }

    func testRegistryRejectsFactoryIdentityMismatch() throws {
        let registry = MeetingTranscriptionBackendRegistry()
        registry.register(Self.fixtureBackendID) { [self] _ in
            FixtureMeetingBackend(descriptor: self.makeFixtureDescriptor(id: .legacyCompatibility)) { _ in
                fatalError("Mismatched factory must not execute")
            }
        }
        XCTAssertThrowsError(try registry.makeBackend(
            id: Self.fixtureBackendID,
            context: MeetingBackendHostContext(legacyExecutor: { _, _ in
                throw MeetingProcessingError.noRecoverableAudio
            })
        )) { error in
            XCTAssertEqual(error as? MeetingBackendError, .backendIdentityMismatch(
                requested: Self.fixtureBackendID, produced: .legacyCompatibility
            ))
        }
    }

    func testPipelineRejectsPlanForDifferentDirectory() async throws {
        let descriptor = self.makeFixtureDescriptor()
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
        registry.register(Self.fixtureBackendID) { _ in
            FixtureMeetingBackend(descriptor: descriptor, planOverride: { request in
                MeetingBackendPlan(request: MeetingBackendRequest(
                    attemptID: request.attemptID, session: request.session,
                    sessionDirectory: request.sessionDirectory.appendingPathComponent("another-session"),
                    configuration: request.configuration
                ), descriptor: descriptor)
            }) { _ in fatalError("Substituted plan must not execute") }
        }
        do {
            _ = try await self.makePipeline(registry: registry, backendID: nil).process(
                session: self.makeSession(), sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("Substituted request must fail before model work")
        } catch {
            XCTAssertEqual(
                error as? MeetingBackendError,
                .planDisagreesWithRequest(backend: Self.fixtureBackendID, defect: .request)
            )
        }
    }

    func testLegacyExecutorRejectsSubstitutedRequest() async throws {
        let descriptor = self.makeFixtureDescriptor()
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
        registry.register(Self.fixtureBackendID) { context in
            LegacyCallbackBackend(descriptor: descriptor, executor: context.legacyExecutor) { request in
                MeetingBackendRequest(
                    attemptID: UUID(), session: request.session, sessionDirectory: request.sessionDirectory,
                    configuration: request.configuration
                )
            }
        }
        do {
            _ = try await self.makePipeline(registry: registry, backendID: nil).process(
                session: self.makeSession(), sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("Substituted executor request must fail")
        } catch {
            XCTAssertEqual(
                error as? MeetingBackendError,
                .legacyExecutorRequestMismatch(backend: Self.fixtureBackendID)
            )
        }
    }

    func testCancelledNonCooperativeBackendDoesNotPublishAndReleasesLease() async throws {
        let gate = MeetingProcessingSerializationGate()
        let entered = Latch()
        let latch = Latch()
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
        registry.register(Self.fixtureBackendID) { [self] _ in
            BlockingFixtureBackend(
                descriptor: self.makeFixtureDescriptor(),
                latch: latch,
                onEnter: { Task { await entered.open() } }
            ) { plan in
                .legacyCompatibility(self.makeResult(attemptID: plan.attemptID, text: "cancelled"))
            }
        }
        let pipeline = self.makePipeline(registry: registry, backendID: nil, gate: gate)
        let task = Task {
            try await pipeline.process(
                session: self.makeSession(),
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
        }
        await entered.wait()
        task.cancel()
        await latch.open()
        do {
            _ = try await task.value
            XCTFail("Cancelled backend result must not be returned")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }

        registry.register(Self.fixtureBackendID) { [self] _ in
            FixtureMeetingBackend(descriptor: self.makeFixtureDescriptor()) { plan in
                .legacyCompatibility(self.makeResult(attemptID: plan.attemptID, text: "next"))
            }
        }
        let result = try await pipeline.process(
            session: self.makeSession(),
            sessionDirectory: FileManager.default.temporaryDirectory,
            progress: { _ in }
        )
        XCTAssertEqual(result.segments.map(\.text), ["next"])
    }

    func testMeetingPreferencePreservesUnknownIDsAndDoesNotChangeDictation() {
        let defaults = UserDefaults.standard
        let key = "MeetingTranscriptionBackendID"
        let oldValue = defaults.object(forKey: key)
        defer {
            if let oldValue { defaults.set(oldValue, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let settings = SettingsStore.shared
        let dictationModel = settings.selectedSpeechModel
        defaults.removeObject(forKey: key)
        XCTAssertEqual(settings.meetingTranscriptionBackendID, .productionDefault)
        let future = MeetingBackendID(rawValue: "future.unavailable-engine")
        settings.meetingTranscriptionBackendID = future
        XCTAssertEqual(settings.meetingTranscriptionBackendID, future)
        XCTAssertEqual(defaults.string(forKey: key), future.rawValue)
        XCTAssertEqual(settings.selectedSpeechModel, dictationModel)
    }

    func testMeetingPreferenceBackupPreservesUnknownIDAndMigratesMissingToDefault() async throws {
        let defaults = UserDefaults.standard
        let key = "MeetingTranscriptionBackendID"
        let oldValue = defaults.object(forKey: key)
        defer {
            if let oldValue { defaults.set(oldValue, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let settingsStore = SettingsStore.shared
        let future = MeetingBackendID(rawValue: "future.hosted-provider")
        settingsStore.meetingTranscriptionBackendID = future

        let document = try await BackupService.shared.makeBackupDocument()
        XCTAssertEqual(document.settings.meetingTranscriptionBackendID, future.rawValue)

        let encoded = try BackupService.shared.encode(document)
        let decoded = try BackupService.shared.decode(encoded)
        settingsStore.meetingTranscriptionBackendID = .legacyCompatibility
        settingsStore.restore(from: decoded.settings)
        XCTAssertEqual(settingsStore.meetingTranscriptionBackendID, future)

        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var payload = try XCTUnwrap(root["settings"] as? [String: Any])
        payload.removeValue(forKey: "meetingTranscriptionBackendID")
        root["settings"] = payload
        let legacy = try BackupService.shared.decode(JSONSerialization.data(withJSONObject: root))
        XCTAssertNil(legacy.settings.meetingTranscriptionBackendID)

        settingsStore.meetingTranscriptionBackendID = future
        settingsStore.restore(from: legacy.settings)
        XCTAssertEqual(settingsStore.meetingTranscriptionBackendID, .productionDefault)
    }

    func testSelectionIsFrozenDuringExecutionAndRefreshedForNextAttempt() async throws {
        let firstID = Self.fixtureBackendID
        let secondID = MeetingBackendID(rawValue: "fixture-second")
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: firstID)
        let entered = Latch()
        let latch = Latch()
        registry.register(firstID) { [self] _ in
            BlockingFixtureBackend(
                descriptor: self.makeFixtureDescriptor(),
                latch: latch,
                onEnter: { Task { await entered.open() } }
            ) { plan in
                .legacyCompatibility(self.makeResult(attemptID: plan.attemptID, text: "first"))
            }
        }
        registry.register(secondID) { [self] _ in
            FixtureMeetingBackend(descriptor: self.makeFixtureDescriptor(id: secondID)) { plan in
                .legacyCompatibility(self.makeResult(attemptID: plan.attemptID, text: "second"))
            }
        }
        var selected = firstID
        var selectionReads = 0
        let pipeline = MeetingProcessingPipeline(
            asrServiceProvider: { fatalError("Fixture must not load ASR") },
            serializationGate: MeetingProcessingSerializationGate(), backendRegistry: registry,
            backendIDProvider: { selectionReads += 1; return selected }
        )
        let session = self.makeSession()
        let task = Task {
            try await pipeline.process(
                session: session,
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
        }
        await entered.wait()
        selected = secondID
        await latch.open()
        let first = try await task.value
        XCTAssertEqual(first.segments.map(\.text), ["first"])
        XCTAssertEqual(selectionReads, 1)
        let second = try await pipeline.process(
            session: session,
            sessionDirectory: FileManager.default.temporaryDirectory,
            progress: { _ in }
        )
        XCTAssertEqual(second.segments.map(\.text), ["second"])
        XCTAssertEqual(selectionReads, 2)
    }

    // MARK: - Registry

    func testDefaultRegistryUsesProductionDefaultAndKeepsLegacyRollback() throws {
        let registry = MeetingTranscriptionBackendRegistry.makeDefault()
        XCTAssertEqual(registry.defaultBackendID, .productionDefault)
        XCTAssertEqual(registry.registeredBackendIDs, [.legacyCompatibility, .parakeetNemotron])

        let backend = try registry.makeBackend(
            id: registry.defaultBackendID,
            context: MeetingBackendHostContext(legacyExecutor: { _, _ in
                XCTFail("Legacy executor must not run while only resolving the backend")
                throw MeetingProcessingError.noRecoverableAudio
            })
        )
        XCTAssertEqual(backend.descriptor.id, .parakeetNemotron)
        XCTAssertEqual(backend.descriptor.execution, .local)
        XCTAssertEqual(
            backend.descriptor.supportedFinalPrecisions, [.word, .utterance]
        )
    }

    func testRegistryRejectsAnUnknownBackendIdentifier() {
        let registry = MeetingTranscriptionBackendRegistry.makeDefault()
        let unknown = MeetingBackendID(rawValue: "not-registered")
        XCTAssertFalse(registry.contains(unknown))
        XCTAssertThrowsError(
            try registry.makeBackend(
                id: unknown,
                context: MeetingBackendHostContext(legacyExecutor: { _, _ in
                    throw MeetingProcessingError.noRecoverableAudio
                })
            )
        ) { error in
            XCTAssertEqual(error as? MeetingBackendError, .unknownBackend(unknown))
        }
    }

    // MARK: - Pipeline dispatch

    func testPipelineDispatchesToTheInjectedBackendBeforeAnyModelWork() async throws {
        let session = self.makeSession()
        var captured: MeetingProcessingResult?
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
        var fixture: FixtureMeetingBackend?
        registry.register(Self.fixtureBackendID) { [self] _ in
            let backend = FixtureMeetingBackend(descriptor: self.makeFixtureDescriptor()) { plan in
                let result = self.makeResult(attemptID: plan.attemptID, text: "dispatched")
                captured = result
                return .legacyCompatibility(result)
            }
            fixture = backend
            return backend
        }

        let pipeline = self.makePipeline(registry: registry, backendID: nil)
        var stages: [MeetingProcessingStage] = []
        let result = try await pipeline.process(
            session: session,
            sessionDirectory: FileManager.default.temporaryDirectory,
            progress: { stages.append($0) }
        )

        let backend = try XCTUnwrap(fixture)
        XCTAssertEqual(backend.planCallCount, 1)
        XCTAssertEqual(backend.executeCallCount, 1)
        XCTAssertEqual(stages, [.transcribing], "the backend's progress reaches the caller unchanged")
        XCTAssertEqual(result.segments.map(\.text), ["dispatched"])
        XCTAssertEqual(result.attempt.id, captured?.attempt.id)

        let plan = try XCTUnwrap(backend.lastPlan)
        XCTAssertEqual(plan.backendID, Self.fixtureBackendID)
        XCTAssertEqual(plan.trackKindsByID.count, 1)
        XCTAssertEqual(plan.chunkIDsByTrackID.values.first?.count, 1)
    }

    func testPipelineReusesTheOpenAttemptIdentifierForTheRequest() async throws {
        let openAttempt = MeetingProcessingAttempt(
            id: UUID(),
            startedAt: Date(timeIntervalSinceNow: -60),
            completedAt: nil,
            stage: .transcribing,
            pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
            asrProvider: nil,
            asrModel: nil,
            diarizationModel: nil,
            lastCompletedTrackID: nil,
            errorCode: nil
        )
        let session = self.makeSession(processingAttempts: [openAttempt])
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
        var fixture: FixtureMeetingBackend?
        registry.register(Self.fixtureBackendID) { [self] _ in
            let backend = FixtureMeetingBackend(descriptor: self.makeFixtureDescriptor()) { plan in
                .legacyCompatibility(self.makeResult(attemptID: plan.attemptID, text: "retry"))
            }
            fixture = backend
            return backend
        }

        let pipeline = self.makePipeline(registry: registry, backendID: nil)
        let result = try await pipeline.process(
            session: session,
            sessionDirectory: FileManager.default.temporaryDirectory,
            progress: { _ in }
        )
        XCTAssertEqual(fixture?.lastPlan?.attemptID, openAttempt.id)
        XCTAssertEqual(result.attempt.id, openAttempt.id)
    }

    func testPipelineRejectsAnUnknownBackendIdentifierExplicitly() async {
        let registry = MeetingTranscriptionBackendRegistry.makeDefault()
        let unknown = MeetingBackendID(rawValue: "muse-cloud-v0")
        let pipeline = self.makePipeline(registry: registry, backendID: unknown)
        do {
            _ = try await pipeline.process(
                session: self.makeSession(),
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("An unregistered backend must not silently fall back to legacy")
        } catch {
            XCTAssertEqual(error as? MeetingBackendError, .unknownBackend(unknown))
        }
    }

    func testLegacyPreflightChecksStillRunBeforeBackendSelection() async {
        var factoryCallCount = 0
        func registry() -> MeetingTranscriptionBackendRegistry {
            let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
            registry.register(Self.fixtureBackendID) { [self] _ in
                factoryCallCount += 1
                return FixtureMeetingBackend(descriptor: self.makeFixtureDescriptor()) { plan in
                    .legacyCompatibility(self.makeResult(attemptID: plan.attemptID, text: "unused"))
                }
            }
            return registry
        }

        do {
            _ = try await self.makePipeline(registry: registry(), backendID: nil).process(
                session: self.makeSession(languageCode: "fr"),
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("Non-English sessions must still be rejected")
        } catch {
            guard case MeetingProcessingError.unsupportedLanguage = error else {
                return XCTFail("Expected unsupportedLanguage, got \(error)")
            }
        }

        do {
            _ = try await self.makePipeline(registry: registry(), backendID: nil).process(
                session: self.makeSession(tracks: [self.makeTrack(kind: .microphone, chunks: [])]),
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("A session with no chunks must still be rejected")
        } catch {
            guard case MeetingProcessingError.noRecoverableAudio = error else {
                return XCTFail("Expected noRecoverableAudio, got \(error)")
            }
        }

        XCTAssertEqual(factoryCallCount, 0, "preflight failures must not construct a backend")
    }

    /// Every chunk reports unreadable, so a manifest builds to explicit gaps without fixture audio.
    private struct UnreadableFixtureObserver: MeetingChunkAudioObserving {
        func observe(
            chunk: MeetingAudioChunk,
            trackID: MeetingAudioTrackID
        ) -> MeetingChunkObservationResult {
            .failed(.unreadable, detail: "fixture")
        }
    }

    func testPipelineSurfacesMalformedCanonicalEvidenceAsAValidationFailure() async throws {
        let session = self.makeSession()
        let trackID = try XCTUnwrap(session.audioTracks.first?.id)
        let epoch = MeetingAnalysisEpochID(trackID: trackID, ordinal: 0)

        // A scope defect — text the backend never really produced — still fails validation,
        // now on the canonical path after a real (all-gap) manifest was built and handed over.
        let scopeRegistry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
        scopeRegistry.register(Self.fixtureBackendID) { [self] _ in
            FixtureMeetingBackend(
                descriptor: self.makeFixtureDescriptor(resultContract: .canonicalEvidence)
            ) { plan in
                .canonicalEvidence(MeetingCanonicalResultBundle(
                    evidence: MeetingFinalTranscriptEvidence(
                        backendID: plan.backendID,
                        attemptID: plan.attemptID,
                        units: [
                            MeetingFinalTextUnit(
                                id: "u-0",
                                trackID: trackID,
                                analysisEpochID: epoch,
                                precision: .utterance,
                                text: "   ",
                                analysisStart: 2,
                                analysisEnd: 4,
                                speaker: .unassigned,
                                analysisSpanIDs: ["span-0"]
                            ),
                        ]
                    ),
                    coverageReceipts: []
                ))
            }
        }

        do {
            _ = try await MeetingProcessingPipeline(
                asrServiceProvider: {
                    XCTFail("Canonical fixture must not load ASR")
                    return ASRService()
                },
                serializationGate: MeetingProcessingSerializationGate(),
                backendRegistry: scopeRegistry,
                backendID: nil,
                chunkObserver: UnreadableFixtureObserver()
            ).process(
                session: session,
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("Empty evidence text must not pass through the pipeline")
        } catch {
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .emptyText(unitID: "u-0"))
        }
    }

    func testPipelineRejectsAnOutcomeThatContradictsTheDeclaredResultContract() async throws {
        // Declared canonical, returns the legacy shape: the pipeline must not reinterpret it.
        let canonicalRegistry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
        canonicalRegistry.register(Self.fixtureBackendID) { [self] _ in
            FixtureMeetingBackend(
                descriptor: self.makeFixtureDescriptor(resultContract: .canonicalEvidence)
            ) { plan in
                .legacyCompatibility(self.makeResult(attemptID: plan.attemptID, text: "wrong shape"))
            }
        }
        do {
            _ = try await MeetingProcessingPipeline(
                asrServiceProvider: {
                    XCTFail("Canonical fixture must not load ASR")
                    return ASRService()
                },
                serializationGate: MeetingProcessingSerializationGate(),
                backendRegistry: canonicalRegistry,
                backendID: nil,
                chunkObserver: UnreadableFixtureObserver()
            ).process(
                session: self.makeSession(),
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("A legacy outcome under a canonical contract must be rejected")
        } catch {
            XCTAssertEqual(
                error as? MeetingBackendError,
                .outcomeContractMismatch(backend: Self.fixtureBackendID, declared: .canonicalEvidence)
            )
        }

        // Declared legacy, returns canonical evidence: likewise a typed failure.
        let legacyRegistry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
        legacyRegistry.register(Self.fixtureBackendID) { [self] _ in
            FixtureMeetingBackend(descriptor: self.makeFixtureDescriptor(resultContract: .legacyResult)) { plan in
                .canonicalEvidence(MeetingCanonicalResultBundle(
                    evidence: MeetingFinalTranscriptEvidence(
                        backendID: plan.backendID,
                        attemptID: plan.attemptID,
                        units: []
                    ),
                    coverageReceipts: []
                ))
            }
        }
        do {
            _ = try await self.makePipeline(registry: legacyRegistry, backendID: nil).process(
                session: self.makeSession(),
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("Canonical evidence under a legacy contract must be rejected")
        } catch {
            XCTAssertEqual(
                error as? MeetingBackendError,
                .outcomeContractMismatch(backend: Self.fixtureBackendID, declared: .legacyResult)
            )
        }
    }

    // MARK: - Evidence validation

    private struct EvidenceFixture {
        let plan: MeetingBackendPlan
        let trackID: MeetingAudioTrackID
        let otherTrackID: MeetingAudioTrackID
        let epoch: MeetingAnalysisEpochID
    }

    private func makeEvidenceFixture(
        precisions: Set<MeetingTextUnitPrecision> = [.word, .utterance]
    ) throws -> EvidenceFixture {
        let microphone = self.makeTrack(
            kind: .microphone,
            chunks: [self.makeChunk(sequence: 0, path: "tracks/microphone/chunk_0.caf")]
        )
        let application = self.makeTrack(
            kind: .applicationAudio,
            chunks: [self.makeChunk(sequence: 0, path: "tracks/application/chunk_0.caf")]
        )
        let session = self.makeSession(tracks: [microphone, application])
        let request = MeetingBackendRequest(
            attemptID: UUID(),
            session: session,
            sessionDirectory: FileManager.default.temporaryDirectory,
            configuration: MeetingFinalProcessingConfiguration()
        )
        let plan = MeetingBackendPlan(
            request: request,
            descriptor: self.makeFixtureDescriptor(precisions: precisions)
        )
        return try EvidenceFixture(
            plan: plan,
            trackID: microphone.id,
            otherTrackID: application.id,
            epoch: MeetingAnalysisEpochID(trackID: microphone.id, ordinal: 0)
        )
    }

    private func makeUnit(
        _ fixture: EvidenceFixture,
        id: String = "u-0",
        precision: MeetingTextUnitPrecision = .word,
        text: String = "hello",
        analysisStart: TimeInterval = 1,
        analysisEnd: TimeInterval = 2,
        trackID: MeetingAudioTrackID? = nil,
        epoch: MeetingAnalysisEpochID? = nil,
        speaker: MeetingBackendSpeakerAssignment? = nil,
        analysisSpanIDs: [String]? = nil,
        confidence: Double? = nil
    ) -> MeetingFinalTextUnit {
        let resolvedEpoch = epoch ?? fixture.epoch
        return MeetingFinalTextUnit(
            id: id,
            trackID: trackID ?? fixture.trackID,
            analysisEpochID: resolvedEpoch,
            precision: precision,
            text: text,
            analysisStart: analysisStart,
            analysisEnd: analysisEnd,
            speaker: speaker ?? .assigned(MeetingBackendSpeakerToken(analysisEpochID: resolvedEpoch, label: "slot-0")),
            analysisSpanIDs: analysisSpanIDs ?? ["span-0"],
            confidence: confidence
        )
    }

    private func evidence(
        _ fixture: EvidenceFixture,
        units: [MeetingFinalTextUnit],
        activity: [MeetingBackendSpeakerActivity] = []
    ) -> MeetingFinalTranscriptEvidence {
        MeetingFinalTranscriptEvidence(
            backendID: fixture.plan.backendID,
            attemptID: fixture.plan.attemptID,
            units: units,
            speakerActivity: activity
        )
    }

    func testEvidenceAcceptsWordAndUtteranceUnitsAndOptionalActivity() throws {
        let fixture = try self.makeEvidenceFixture()
        let payload = self.evidence(
            fixture,
            units: [
                self.makeUnit(fixture, id: "w-0", precision: .word, analysisStart: 1, analysisEnd: 1.4),
                self.makeUnit(
                    fixture, id: "utt-0", precision: .utterance, text: "a whole sentence",
                    analysisStart: 2, analysisEnd: 6, speaker: .unassigned, confidence: 0.75
                ),
                self.makeUnit(
                    fixture, id: "utt-1", precision: .utterance, text: "overlapped",
                    analysisStart: 6, analysisEnd: 7,
                    speaker: .ambiguous([
                        MeetingBackendSpeakerToken(analysisEpochID: fixture.epoch, label: "slot-0"),
                        MeetingBackendSpeakerToken(analysisEpochID: fixture.epoch, label: "slot-1"),
                    ])
                ),
            ],
            activity: [
                MeetingBackendSpeakerActivity(
                    token: MeetingBackendSpeakerToken(analysisEpochID: fixture.epoch, label: "slot-0"),
                    start: 1,
                    end: 1.4
                ),
            ]
        )
        XCTAssertEqual(try payload.validated(against: fixture.plan), payload)
    }

    func testEvidenceRejectsUnitsWithoutDeclaredPrecisionSupport() throws {
        let fixture = try self.makeEvidenceFixture(precisions: [.utterance])
        let payload = self.evidence(fixture, units: [self.makeUnit(fixture, id: "w-0", precision: .word)])
        XCTAssertThrowsError(try payload.validated(against: fixture.plan)) { error in
            XCTAssertEqual(
                error as? MeetingBackendEvidenceError,
                .unsupportedPrecision(unitID: "w-0", precision: .word)
            )
        }
    }

    func testEvidenceScopeValidationAdmitsInvalidTimingForQuarantine() throws {
        // Scope validation answers "does this reference something planned?", not "is this timing
        // usable?". Impossible bounds are quarantined per unit at assembly time so every input
        // unit still receives exactly one sidecar disposition.
        let fixture = try self.makeEvidenceFixture()
        let invalidIntervals: [(TimeInterval, TimeInterval)] = [
            (.nan, 2),
            (1, .nan),
            (1, .infinity),
            (-1, 2),
            (2, 2),
            (3, 1),
        ]
        for (start, end) in invalidIntervals {
            let payload = self.evidence(fixture, units: [
                self.makeUnit(fixture, analysisStart: start, analysisEnd: end),
            ])
            XCTAssertNoThrow(
                try payload.validated(against: fixture.plan),
                "start=\(start) end=\(end) is a quarantine matter, not a scope error"
            )
        }
    }

    func testEvidenceRejectsDuplicateAndEmptyUnitIdentifiers() throws {
        let fixture = try self.makeEvidenceFixture()
        let duplicates = self.evidence(fixture, units: [
            self.makeUnit(fixture, id: "same", analysisStart: 1, analysisEnd: 2),
            self.makeUnit(fixture, id: "same", analysisStart: 3, analysisEnd: 4),
        ])
        XCTAssertThrowsError(try duplicates.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .duplicateUnitID("same"))
        }

        let empty = self.evidence(fixture, units: [self.makeUnit(fixture, id: "  ")])
        XCTAssertThrowsError(try empty.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .emptyUnitID)
        }
    }

    func testEvidenceRejectsSourcesOutsideThePlannedScope() throws {
        let fixture = try self.makeEvidenceFixture()

        let unknownTrack = self.evidence(fixture, units: [self.makeUnit(
            fixture, trackID: UUID(), epoch: fixture.epoch
        )])
        XCTAssertThrowsError(try unknownTrack.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .unknownSourceTrack(unitID: "u-0"))
        }

        let noSpans = self.evidence(fixture, units: [self.makeUnit(fixture, analysisSpanIDs: [])])
        XCTAssertThrowsError(try noSpans.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .missingAnalysisSpans(unitID: "u-0"))
        }

        let duplicateSpans = self.evidence(fixture, units: [self.makeUnit(
            fixture,
            analysisSpanIDs: ["span-0", "span-0"]
        )])
        XCTAssertThrowsError(try duplicateSpans.validated(against: fixture.plan)) { error in
            XCTAssertEqual(
                error as? MeetingBackendEvidenceError,
                .duplicateAnalysisSpanID(unitID: "u-0")
            )
        }

        // A microphone unit may not carry an epoch minted for the application track: the epoch is
        // what scopes speaker state, so crossing tracks here would silently merge identities.
        let foreignEpoch = self.evidence(fixture, units: [self.makeUnit(
            fixture,
            epoch: MeetingAnalysisEpochID(trackID: fixture.otherTrackID, ordinal: 0)
        )])
        XCTAssertThrowsError(try foreignEpoch.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .analysisEpochOutOfScope(unitID: "u-0"))
        }

        let negativeEpoch = self.evidence(fixture, units: [self.makeUnit(
            fixture,
            epoch: MeetingAnalysisEpochID(trackID: fixture.trackID, ordinal: -1),
            speaker: .unassigned
        )])
        XCTAssertThrowsError(try negativeEpoch.validated(against: fixture.plan)) { error in
            XCTAssertEqual(
                error as? MeetingBackendEvidenceError,
                .invalidAnalysisEpochOrdinal(unitID: "u-0")
            )
        }
    }

    func testEvidenceRejectsSpeakerTokensFromAnotherEpochOrTrack() throws {
        let fixture = try self.makeEvidenceFixture()

        let laterEpochToken = self.evidence(fixture, units: [self.makeUnit(
            fixture,
            speaker: .assigned(MeetingBackendSpeakerToken(
                analysisEpochID: MeetingAnalysisEpochID(trackID: fixture.trackID, ordinal: 1),
                label: "slot-0"
            ))
        )])
        XCTAssertThrowsError(try laterEpochToken.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .speakerTokenOutOfScope(unitID: "u-0"))
        }

        let crossTrackCandidate = self.evidence(fixture, units: [self.makeUnit(
            fixture,
            speaker: .ambiguous([
                MeetingBackendSpeakerToken(analysisEpochID: fixture.epoch, label: "slot-0"),
                MeetingBackendSpeakerToken(
                    analysisEpochID: MeetingAnalysisEpochID(trackID: fixture.otherTrackID, ordinal: 0),
                    label: "slot-0"
                ),
            ])
        )])
        XCTAssertThrowsError(try crossTrackCandidate.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .speakerTokenOutOfScope(unitID: "u-0"))
        }

        let singleCandidateAmbiguity = self.evidence(fixture, units: [self.makeUnit(
            fixture,
            speaker: .ambiguous([MeetingBackendSpeakerToken(analysisEpochID: fixture.epoch, label: "slot-0")])
        )])
        XCTAssertThrowsError(try singleCandidateAmbiguity.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .invalidAmbiguity(unitID: "u-0"))
        }

        let emptyTokenLabel = self.evidence(fixture, units: [self.makeUnit(
            fixture,
            speaker: .assigned(MeetingBackendSpeakerToken(
                analysisEpochID: fixture.epoch,
                label: "  "
            ))
        )])
        XCTAssertThrowsError(try emptyTokenLabel.validated(against: fixture.plan)) { error in
            XCTAssertEqual(
                error as? MeetingBackendEvidenceError,
                .emptySpeakerTokenLabel(unitID: "u-0")
            )
        }
    }

    func testEvidenceScopeAdmitsOutOfRangeConfidenceForQuarantine() throws {
        // An out-of-range confidence is a value defect, not a scope violation: it quarantines the
        // unit at assembly rather than failing the payload. Absent confidence stays fine.
        let fixture = try self.makeEvidenceFixture()
        for value in [Double.nan, -0.01, 1.01, .infinity] {
            let payload = self.evidence(fixture, units: [self.makeUnit(fixture, confidence: value)])
            XCTAssertNoThrow(try payload.validated(against: fixture.plan), "confidence=\(value)")
        }
        let absent = self.evidence(fixture, units: [self.makeUnit(fixture, confidence: nil)])
        XCTAssertNoThrow(try absent.validated(against: fixture.plan))
    }

    func testEvidenceRejectsMismatchedBackendOrAttemptAndBadActivity() throws {
        let fixture = try self.makeEvidenceFixture()
        let otherBackend = MeetingBackendID(rawValue: "someone-else")

        let wrongBackend = MeetingFinalTranscriptEvidence(
            backendID: otherBackend,
            attemptID: fixture.plan.attemptID,
            units: [self.makeUnit(fixture)]
        )
        XCTAssertThrowsError(try wrongBackend.validated(against: fixture.plan)) { error in
            XCTAssertEqual(
                error as? MeetingBackendEvidenceError,
                .backendMismatch(expected: fixture.plan.backendID, actual: otherBackend)
            )
        }

        let wrongAttempt = MeetingFinalTranscriptEvidence(
            backendID: fixture.plan.backendID,
            attemptID: UUID(),
            units: [self.makeUnit(fixture)]
        )
        XCTAssertThrowsError(try wrongAttempt.validated(against: fixture.plan)) { error in
            guard case .attemptMismatch = (error as? MeetingBackendEvidenceError) else {
                return XCTFail("expected attemptMismatch, got \(error)")
            }
        }

        let badActivity = self.evidence(
            fixture,
            units: [self.makeUnit(fixture)],
            activity: [MeetingBackendSpeakerActivity(
                token: MeetingBackendSpeakerToken(analysisEpochID: fixture.epoch, label: "slot-0"),
                start: 5,
                end: 5
            )]
        )
        XCTAssertThrowsError(try badActivity.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .invalidActivityTiming(index: 0))
        }

        let unplannedActivityTrack = self.evidence(
            fixture,
            units: [self.makeUnit(fixture)],
            activity: [MeetingBackendSpeakerActivity(
                token: MeetingBackendSpeakerToken(
                    analysisEpochID: MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0),
                    label: "slot-0"
                ),
                start: 1,
                end: 2
            )]
        )
        XCTAssertThrowsError(try unplannedActivityTrack.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .activityTokenOutOfScope(index: 0))
        }

        let negativeActivityEpoch = self.evidence(
            fixture,
            units: [self.makeUnit(fixture)],
            activity: [MeetingBackendSpeakerActivity(
                token: MeetingBackendSpeakerToken(
                    analysisEpochID: MeetingAnalysisEpochID(trackID: fixture.trackID, ordinal: -1),
                    label: "slot-0"
                ),
                start: 1,
                end: 2
            )]
        )
        XCTAssertThrowsError(try negativeActivityEpoch.validated(against: fixture.plan)) { error in
            XCTAssertEqual(
                error as? MeetingBackendEvidenceError,
                .invalidActivityEpochOrdinal(index: 0)
            )
        }
    }
}
