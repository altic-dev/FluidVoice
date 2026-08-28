import CoreAudio
@testable import FluidVoice_Debug
import Foundation
#if arch(arm64)
import MediaRemoteAdapter
#endif
import XCTest

#if arch(arm64)
@MainActor
final class MediaPlaybackServiceTests: XCTestCase {
    func testPlayingCallbackBeforeTimeoutRequestsPause() async throws {
        let (service, controller, scheduler, _) = self.makeService()
        let pauseTask = Task { await service.pauseIfPlaying() }

        await controller.waitUntilQueryRegistered()
        XCTAssertEqual(scheduler.scheduledDelays, [2.5])
        try controller.complete(with: self.makeTrackInfo(isPlaying: true, playbackRate: 1))

        let didPause = await pauseTask.value
        XCTAssertTrue(didPause)
        XCTAssertEqual(controller.pauseCallCount, 1)

        scheduler.advance(by: 2.5)
        XCTAssertEqual(controller.pauseCallCount, 1)
    }

    func testCallbackAfterFormerOneSecondBoundaryStillRequestsPause() async throws {
        let (service, controller, scheduler, _) = self.makeService()
        let pauseTask = Task { await service.pauseIfPlaying() }

        await controller.waitUntilQueryRegistered()
        XCTAssertEqual(scheduler.scheduledDelays, [MediaPlaybackService.nowPlayingQueryTimeoutSeconds])
        XCTAssertGreaterThan(MediaPlaybackService.nowPlayingQueryTimeoutSeconds, 2)

        scheduler.advance(by: 1.1)
        try controller.complete(with: self.makeTrackInfo(isPlaying: true, playbackRate: 1))

        let didPause = await pauseTask.value
        XCTAssertTrue(didPause)
        XCTAssertEqual(controller.pauseCallCount, 1)

        scheduler.advance(by: 1.4)
        XCTAssertEqual(controller.pauseCallCount, 1)
    }

    func testTimeoutThenLatePlayingCallbackNeverPauses() async throws {
        let (service, controller, scheduler, volumeController) = self.makeService()
        let pauseTask = Task { await service.pauseIfPlaying() }

        await controller.waitUntilQueryRegistered()
        scheduler.advance(by: 2.5)

        let didPause = await pauseTask.value
        XCTAssertFalse(didPause)
        XCTAssertEqual(controller.pauseCallCount, 0)

        try controller.complete(with: self.makeTrackInfo(isPlaying: true, playbackRate: 1))
        XCTAssertEqual(controller.pauseCallCount, 0)
        XCTAssertEqual(volumeController.captureCallCount, 0)
    }

    func testDuplicatePlayingCallbacksIssueOnePause() async throws {
        let (service, controller, _, _) = self.makeService()
        let pauseTask = Task { await service.pauseIfPlaying() }
        let playingTrack = try self.makeTrackInfo(isPlaying: true, playbackRate: 1)

        await controller.waitUntilQueryRegistered()
        controller.complete(with: playingTrack, retainingCallback: true)
        controller.complete(with: playingTrack)

        let didPause = await pauseTask.value
        XCTAssertTrue(didPause)
        XCTAssertEqual(controller.pauseCallCount, 1)
    }

    func testPlaybackStateResolutionDoesNotPauseFalseCasesAndUsesRateFallback() async throws {
        let nilResult = await self.pauseResult(for: nil)
        XCTAssertFalse(nilResult.didPause)
        XCTAssertEqual(nilResult.pauseCallCount, 0)

        let explicitlyPaused = try await self.pauseResult(
            for: self.makeTrackInfo(isPlaying: false, playbackRate: 1)
        )
        XCTAssertFalse(explicitlyPaused.didPause)
        XCTAssertEqual(explicitlyPaused.pauseCallCount, 0)

        let zeroRate = try await self.pauseResult(
            for: self.makeTrackInfo(isPlaying: nil, playbackRate: 0)
        )
        XCTAssertFalse(zeroRate.didPause)
        XCTAssertEqual(zeroRate.pauseCallCount, 0)

        let positiveRate = try await self.pauseResult(
            for: self.makeTrackInfo(isPlaying: nil, playbackRate: 1)
        )
        XCTAssertTrue(positiveRate.didPause)
        XCTAssertEqual(positiveRate.pauseCallCount, 1)
    }

    func testResumeOnlyPlaysWhenPauseOwnershipIsTrue() async throws {
        let (service, controller, _, _) = self.makeService()
        let pauseTask = Task { await service.pauseIfPlaying() }

        await controller.waitUntilQueryRegistered()
        try controller.complete(with: self.makeTrackInfo(isPlaying: true, playbackRate: 1))
        let didPause = await pauseTask.value
        XCTAssertTrue(didPause)

        await service.resumeIfWePaused(false)
        XCTAssertEqual(controller.playCallCount, 0)

        await service.resumeIfWePaused(true)
        XCTAssertEqual(controller.playCallCount, 1)
    }

    func testDuckingScalesAndRestoresEveryChannelWithoutPlaybackCommands() async throws {
        let original = self.makeSnapshot([0.8, 0.4])
        let volumeController = FakeSystemAudioVolumeController(capturedSnapshot: original)
        let (service, controller, _, _) = self.makeService(
            configuration: .init(duckInsteadOfPausing: true, duckVolumeLevel: 0.2),
            volumeController: volumeController
        )

        let suppressionTask = Task { await service.pauseIfPlaying() }
        await controller.waitUntilQueryRegistered()
        try controller.complete(with: self.makeTrackInfo(isPlaying: true, playbackRate: 1))

        let didSuppress = await suppressionTask.value
        XCTAssertTrue(didSuppress)
        XCTAssertEqual(controller.pauseCallCount, 0)
        XCTAssertEqual(volumeController.appliedSnapshots.count, 1)
        XCTAssertEqual(volumeController.appliedSnapshots[0].channels[0].volume, 0.16, accuracy: 0.0001)
        XCTAssertEqual(volumeController.appliedSnapshots[0].channels[1].volume, 0.08, accuracy: 0.0001)

        await service.resumeIfWePaused(true)

        XCTAssertEqual(controller.playCallCount, 0)
        XCTAssertEqual(volumeController.appliedSnapshots.count, 2)
        XCTAssertEqual(volumeController.appliedSnapshots[1].channels[0].volume, 0.8, accuracy: 0.0001)
        XCTAssertEqual(volumeController.appliedSnapshots[1].channels[1].volume, 0.4, accuracy: 0.0001)
    }

    func testFailedDuckFallsBackToPauseAndResume() async throws {
        let volumeController = FakeSystemAudioVolumeController(capturedSnapshot: self.makeSnapshot([0.8, 0.4]))
        volumeController.applyOutcomes = [.failed]
        let (service, controller, _, _) = self.makeService(
            configuration: .init(duckInsteadOfPausing: true, duckVolumeLevel: 0.2),
            volumeController: volumeController
        )

        let suppressionTask = Task { await service.pauseIfPlaying() }
        await controller.waitUntilQueryRegistered()
        try controller.complete(with: self.makeTrackInfo(isPlaying: true, playbackRate: 1))

        let didSuppress = await suppressionTask.value
        XCTAssertTrue(didSuppress)
        XCTAssertEqual(controller.pauseCallCount, 1)

        await service.resumeIfWePaused(true)
        XCTAssertEqual(controller.playCallCount, 1)
    }

    func testBalancedAverageDoesNotHidePerChannelUserChange() async throws {
        let original = self.makeSnapshot([0.8, 0.4])
        let volumeController = FakeSystemAudioVolumeController(capturedSnapshot: original)
        let (service, controller, _, _) = self.makeService(
            configuration: .init(duckInsteadOfPausing: true, duckVolumeLevel: 0.2),
            volumeController: volumeController
        )

        let suppressionTask = Task { await service.pauseIfPlaying() }
        await controller.waitUntilQueryRegistered()
        try controller.complete(with: self.makeTrackInfo(isPlaying: true, playbackRate: 1))
        let didSuppress = await suppressionTask.value
        XCTAssertTrue(didSuppress)

        // Same average as the applied [0.16, 0.08], but the user changed balance.
        volumeController.currentSnapshot = self.makeSnapshot([0.20, 0.04])
        await service.resumeIfWePaused(true)

        XCTAssertEqual(volumeController.appliedSnapshots.count, 1)
        XCTAssertEqual(controller.playCallCount, 0)
    }

    func testSuppressionConfigurationDoesNotChangeWhileTrackQueryIsInFlight() async throws {
        let controller = FakeMediaPlaybackController()
        let scheduler = ManualTimeoutScheduler()
        let volumeController = FakeSystemAudioVolumeController(capturedSnapshot: self.makeSnapshot([0.8, 0.4]))
        var configuration = MediaPlaybackService.SuppressionConfiguration(
            duckInsteadOfPausing: false,
            duckVolumeLevel: 0.2
        )
        let service = MediaPlaybackService(
            mediaController: controller,
            volumeController: volumeController,
            suppressionConfigurationProvider: { configuration },
            queryTimeoutSeconds: MediaPlaybackService.nowPlayingQueryTimeoutSeconds,
            timeoutScheduler: scheduler.schedule
        )

        let suppressionTask = Task { await service.pauseIfPlaying() }
        await controller.waitUntilQueryRegistered()
        configuration = .init(duckInsteadOfPausing: true, duckVolumeLevel: 0.2)
        try controller.complete(with: self.makeTrackInfo(isPlaying: true, playbackRate: 1))

        let didSuppress = await suppressionTask.value
        XCTAssertTrue(didSuppress)
        XCTAssertEqual(controller.pauseCallCount, 1)
        XCTAssertEqual(volumeController.captureCallCount, 0)
    }

    func testPartialDuckIsUndoneBeforePauseFallback() async throws {
        let volumeController = FakeSystemAudioVolumeController(capturedSnapshot: self.makeSnapshot([0.8, 0.4]))
        volumeController.applyOutcomes = [.partial, .applied]
        let (service, controller, _, _) = self.makeService(
            configuration: .init(duckInsteadOfPausing: true, duckVolumeLevel: 0.2),
            volumeController: volumeController
        )

        let suppressionTask = Task { await service.pauseIfPlaying() }
        await controller.waitUntilQueryRegistered()
        try controller.complete(with: self.makeTrackInfo(isPlaying: true, playbackRate: 1))

        let didSuppress = await suppressionTask.value
        XCTAssertTrue(didSuppress)
        XCTAssertEqual(volumeController.appliedSnapshots.count, 2)
        XCTAssertEqual(volumeController.appliedSnapshots[1].channels[0].volume, 0.8, accuracy: 0.0001)
        XCTAssertEqual(volumeController.appliedSnapshots[1].channels[1].volume, 0.4, accuracy: 0.0001)
        XCTAssertEqual(controller.pauseCallCount, 1)

        await service.resumeIfWePaused(true)
        XCTAssertEqual(controller.playCallCount, 1)
    }

    func testActiveSuppressionRejectsASecondSessionUntilRestore() async throws {
        let volumeController = FakeSystemAudioVolumeController(capturedSnapshot: self.makeSnapshot([0.8, 0.4]))
        let (service, controller, _, _) = self.makeService(
            configuration: .init(duckInsteadOfPausing: true, duckVolumeLevel: 0.2),
            volumeController: volumeController
        )

        let firstTask = Task { await service.pauseIfPlaying() }
        await controller.waitUntilQueryRegistered()
        try controller.complete(with: self.makeTrackInfo(isPlaying: true, playbackRate: 1))
        let firstDidSuppress = await firstTask.value
        XCTAssertTrue(firstDidSuppress)

        let secondDidSuppress = await service.pauseIfPlaying()
        XCTAssertFalse(secondDidSuppress)
        XCTAssertEqual(controller.queryCallCount, 1)
        XCTAssertEqual(volumeController.captureCallCount, 1)

        await service.resumeIfWePaused(true)
    }

    private func makeService(
        configuration: MediaPlaybackService.SuppressionConfiguration = .init(
            duckInsteadOfPausing: false,
            duckVolumeLevel: 0.2
        ),
        volumeController: FakeSystemAudioVolumeController = FakeSystemAudioVolumeController()
    ) -> (
        service: MediaPlaybackService,
        controller: FakeMediaPlaybackController,
        scheduler: ManualTimeoutScheduler,
        volumeController: FakeSystemAudioVolumeController
    ) {
        let controller = FakeMediaPlaybackController()
        let scheduler = ManualTimeoutScheduler()
        let service = MediaPlaybackService(
            mediaController: controller,
            volumeController: volumeController,
            suppressionConfigurationProvider: { configuration },
            queryTimeoutSeconds: MediaPlaybackService.nowPlayingQueryTimeoutSeconds,
            timeoutScheduler: scheduler.schedule
        )
        return (service, controller, scheduler, volumeController)
    }

    private func pauseResult(for trackInfo: TrackInfo?) async -> (
        didPause: Bool,
        pauseCallCount: Int
    ) {
        let (service, controller, _, _) = self.makeService()
        let pauseTask = Task { await service.pauseIfPlaying() }

        await controller.waitUntilQueryRegistered()
        controller.complete(with: trackInfo)

        return (await pauseTask.value, controller.pauseCallCount)
    }

    private func makeTrackInfo(isPlaying: Bool?, playbackRate: Double?) throws -> TrackInfo {
        var payload: [String: Any] = [:]
        if let isPlaying {
            payload["isPlaying"] = isPlaying
        }
        if let playbackRate {
            payload["playbackRate"] = playbackRate
        }
        let data = try JSONSerialization.data(withJSONObject: ["payload": payload])
        return try JSONDecoder().decode(TrackInfo.self, from: data)
    }

    private func makeSnapshot(_ volumes: [Float]) -> OutputVolumeSnapshot {
        OutputVolumeSnapshot(
            deviceID: 42,
            channels: volumes.enumerated().map { index, volume in
                .init(
                    selector: kAudioDevicePropertyVolumeScalar,
                    element: AudioObjectPropertyElement(index + 1),
                    volume: volume
                )
            }
        )
    }
}

@MainActor
private final class FakeMediaPlaybackController: MediaPlaybackControlling {
    private var callback: ((TrackInfo?) -> Void)?
    private var registrationWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var pauseCallCount = 0
    private(set) var playCallCount = 0
    private(set) var queryCallCount = 0

    func getTrackInfo(_ onReceive: @escaping (TrackInfo?) -> Void) {
        self.queryCallCount += 1
        self.callback = onReceive
        let waiters = self.registrationWaiters
        self.registrationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func pause() {
        self.pauseCallCount += 1
    }

    func play() {
        self.playCallCount += 1
    }

    func waitUntilQueryRegistered() async {
        guard self.callback == nil else { return }
        await withCheckedContinuation { continuation in
            self.registrationWaiters.append(continuation)
        }
    }

    func complete(with trackInfo: TrackInfo?, retainingCallback: Bool = false) {
        let callback = self.callback
        if !retainingCallback {
            self.callback = nil
        }
        callback?(trackInfo)
    }
}

private final class FakeSystemAudioVolumeController: SystemAudioVolumeControlling {
    var capturedSnapshot: OutputVolumeSnapshot?
    var currentSnapshot: OutputVolumeSnapshot?
    var applyOutcomes: [SystemAudioVolumeController.ApplyOutcome] = []
    private(set) var captureCallCount = 0
    private(set) var appliedSnapshots: [OutputVolumeSnapshot] = []
    private(set) var virtualMainApplyCallCount = 0

    init(capturedSnapshot: OutputVolumeSnapshot? = nil) {
        self.capturedSnapshot = capturedSnapshot
        self.currentSnapshot = capturedSnapshot
    }

    func captureOutputVolume() -> OutputVolumeSnapshot? {
        self.captureCallCount += 1
        return self.capturedSnapshot
    }

    func apply(_ snapshot: OutputVolumeSnapshot) -> SystemAudioVolumeController.ApplyOutcome {
        self.appliedSnapshots.append(snapshot)
        let outcome = self.applyOutcomes.isEmpty ? .applied : self.applyOutcomes.removeFirst()
        if case .applied = outcome {
            self.currentSnapshot = snapshot
        }
        return outcome
    }

    func applyVirtualMainVolume(_ snapshot: OutputVolumeSnapshot) -> Bool {
        self.virtualMainApplyCallCount += 1
        self.currentSnapshot = snapshot
        return true
    }

    func reread(_ snapshot: OutputVolumeSnapshot) -> OutputVolumeSnapshot? {
        self.currentSnapshot
    }
}

@MainActor
private final class ManualTimeoutScheduler {
    private struct ScheduledAction {
        let deadline: TimeInterval
        let action: @MainActor @Sendable () -> Void
    }

    private var currentTime: TimeInterval = 0
    private var scheduledActions: [ScheduledAction] = []

    var scheduledDelays: [TimeInterval] {
        self.scheduledActions.map(\.deadline)
    }

    func schedule(after delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) {
        self.scheduledActions.append(
            ScheduledAction(deadline: self.currentTime + delay, action: action)
        )
    }

    func advance(by interval: TimeInterval) {
        self.currentTime += interval
        let readyActions = self.scheduledActions.filter { $0.deadline <= self.currentTime }
        self.scheduledActions.removeAll { $0.deadline <= self.currentTime }
        readyActions.forEach { $0.action() }
    }
}
#endif
