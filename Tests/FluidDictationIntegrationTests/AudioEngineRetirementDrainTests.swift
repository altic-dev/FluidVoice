@testable import FluidVoice_Debug
import Foundation
import XCTest

final class AudioEngineRetirementDrainTests: XCTestCase {
    func testReleaseAndWaitCompletesAfterOffMainDeinit() async throws {
        let drain = AudioEngineRetirementDrain(label: "test.audio-engine-retirement.single")
        let recorder = DeinitRecorder()
        var probe: DeinitProbe? = DeinitProbe(id: 1, recorder: recorder)
        let token = AudioEngineRetirementToken(try XCTUnwrap(probe))
        probe = nil

        await drain.releaseAndWait(token, timeout: 1)

        XCTAssertEqual(
            recorder.events,
            [DeinitEvent(id: 1, occurredOnMainThread: false)]
        )
    }

    func testAwaitedReleaseRunsAfterPreviouslyScheduledRelease() async throws {
        let drain = AudioEngineRetirementDrain(label: "test.audio-engine-retirement.serial")
        let recorder = DeinitRecorder()
        var first: DeinitProbe? = DeinitProbe(id: 1, recorder: recorder)
        var second: DeinitProbe? = DeinitProbe(id: 2, recorder: recorder)
        let firstToken = AudioEngineRetirementToken(try XCTUnwrap(first))
        let secondToken = AudioEngineRetirementToken(try XCTUnwrap(second))
        first = nil
        second = nil

        drain.schedule(firstToken)
        await drain.releaseAndWait(secondToken, timeout: 1)

        XCTAssertEqual(
            recorder.events,
            [
                DeinitEvent(id: 1, occurredOnMainThread: false),
                DeinitEvent(id: 2, occurredOnMainThread: false),
            ]
        )
    }

    func testWaitForScheduledReleasesTimesOutWhenEngineDeinitIsBlocked() async throws {
        let drain = AudioEngineRetirementDrain(label: "test.audio-engine-retirement.timeout")
        let releaseStarted = DispatchSemaphore(value: 0)
        let allowRelease = DispatchSemaphore(value: 0)
        var probe: BlockingDeinitProbe? = BlockingDeinitProbe(
            releaseStarted: releaseStarted,
            allowRelease: allowRelease
        )
        let token = AudioEngineRetirementToken(try XCTUnwrap(probe))
        probe = nil

        drain.schedule(token)
        XCTAssertEqual(releaseStarted.wait(timeout: .now() + 1), .success)

        let completedBeforeTimeout = await drain.waitForScheduledReleases(timeout: 0.01)
        XCTAssertFalse(completedBeforeTimeout)

        allowRelease.signal()
        let completedAfterRelease = await drain.waitForScheduledReleases(timeout: 1)
        XCTAssertTrue(completedAfterRelease)
    }

}

private final class BlockingDeinitProbe {
    private let releaseStarted: DispatchSemaphore
    private let allowRelease: DispatchSemaphore

    init(releaseStarted: DispatchSemaphore, allowRelease: DispatchSemaphore) {
        self.releaseStarted = releaseStarted
        self.allowRelease = allowRelease
    }

    deinit {
        self.releaseStarted.signal()
        self.allowRelease.wait()
    }
}

private final class DeinitProbe {
    private let id: Int
    private let recorder: DeinitRecorder

    init(id: Int, recorder: DeinitRecorder) {
        self.id = id
        self.recorder = recorder
    }

    deinit {
        self.recorder.record(
            DeinitEvent(id: self.id, occurredOnMainThread: Thread.isMainThread)
        )
    }
}

private struct DeinitEvent: Equatable {
    let id: Int
    let occurredOnMainThread: Bool
}

private final class DeinitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [DeinitEvent] = []

    var events: [DeinitEvent] {
        self.lock.withLock { self.recordedEvents }
    }

    func record(_ event: DeinitEvent) {
        self.lock.withLock {
            self.recordedEvents.append(event)
        }
    }
}
