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
        let (service, controller, scheduler) = self.makeService()
        let pauseTask = Task { await service.pauseIfPlaying() }

        await controller.waitUntilQueryRegistered()
        XCTAssertEqual(scheduler.scheduledDelays, [2.5])
        controller.complete(with: try self.makeTrackInfo(isPlaying: true, playbackRate: 1))

        let didPause = await pauseTask.value
        XCTAssertTrue(didPause)
        XCTAssertEqual(controller.pauseCallCount, 1)

        scheduler.advance(by: 2.5)
        XCTAssertEqual(controller.pauseCallCount, 1)
    }

    func testCallbackAfterFormerOneSecondBoundaryStillRequestsPause() async throws {
        let (service, controller, scheduler) = self.makeService()
        let pauseTask = Task { await service.pauseIfPlaying() }

        await controller.waitUntilQueryRegistered()
        XCTAssertEqual(scheduler.scheduledDelays, [MediaPlaybackService.nowPlayingQueryTimeoutSeconds])
        XCTAssertGreaterThan(MediaPlaybackService.nowPlayingQueryTimeoutSeconds, 2)

        scheduler.advance(by: 1.1)
        controller.complete(with: try self.makeTrackInfo(isPlaying: true, playbackRate: 1))

        let didPause = await pauseTask.value
        XCTAssertTrue(didPause)
        XCTAssertEqual(controller.pauseCallCount, 1)

        scheduler.advance(by: 1.4)
        XCTAssertEqual(controller.pauseCallCount, 1)
    }

    func testTimeoutThenLatePlayingCallbackNeverPauses() async throws {
        let (service, controller, scheduler) = self.makeService()
        let pauseTask = Task { await service.pauseIfPlaying() }

        await controller.waitUntilQueryRegistered()
        scheduler.advance(by: 2.5)

        let didPause = await pauseTask.value
        XCTAssertFalse(didPause)
        XCTAssertEqual(controller.pauseCallCount, 0)

        controller.complete(with: try self.makeTrackInfo(isPlaying: true, playbackRate: 1))
        XCTAssertEqual(controller.pauseCallCount, 0)
    }

    func testDuplicatePlayingCallbacksIssueOnePause() async throws {
        let (service, controller, _) = self.makeService()
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

        let explicitlyPaused = await self.pauseResult(
            for: try self.makeTrackInfo(isPlaying: false, playbackRate: 1)
        )
        XCTAssertFalse(explicitlyPaused.didPause)
        XCTAssertEqual(explicitlyPaused.pauseCallCount, 0)

        let zeroRate = await self.pauseResult(
            for: try self.makeTrackInfo(isPlaying: nil, playbackRate: 0)
        )
        XCTAssertFalse(zeroRate.didPause)
        XCTAssertEqual(zeroRate.pauseCallCount, 0)

        let positiveRate = await self.pauseResult(
            for: try self.makeTrackInfo(isPlaying: nil, playbackRate: 1)
        )
        XCTAssertTrue(positiveRate.didPause)
        XCTAssertEqual(positiveRate.pauseCallCount, 1)
    }

    func testResumeOnlyPlaysWhenPauseOwnershipIsTrue() async {
        let (service, controller, _) = self.makeService()

        await service.resumeIfWePaused(false)
        XCTAssertEqual(controller.playCallCount, 0)

        await service.resumeIfWePaused(true)
        XCTAssertEqual(controller.playCallCount, 1)
    }

    private func makeService() -> (
        service: MediaPlaybackService,
        controller: FakeMediaPlaybackController,
        scheduler: ManualTimeoutScheduler
    ) {
        let controller = FakeMediaPlaybackController()
        let scheduler = ManualTimeoutScheduler()
        let service = MediaPlaybackService(
            mediaController: controller,
            queryTimeoutSeconds: MediaPlaybackService.nowPlayingQueryTimeoutSeconds,
            timeoutScheduler: scheduler.schedule
        )
        return (service, controller, scheduler)
    }

    private func pauseResult(for trackInfo: TrackInfo?) async -> (
        didPause: Bool,
        pauseCallCount: Int
    ) {
        let (service, controller, _) = self.makeService()
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
}

@MainActor
private final class FakeMediaPlaybackController: MediaPlaybackControlling {
    private var callback: ((TrackInfo?) -> Void)?
    private var registrationWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var pauseCallCount = 0
    private(set) var playCallCount = 0

    func getTrackInfo(_ onReceive: @escaping (TrackInfo?) -> Void) {
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
