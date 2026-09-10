@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class MediaPlaybackServiceTests: XCTestCase {
    func testVerifiedPauseAndResumeAreOrdered() async {
        let transport = FakeMediaPlaybackTransport([self.state(true), self.state(false), self.state(false), self.state(true)])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        service.recordingStopped(sessionID: 1)
        service.sessionFinished(sessionID: 1)
        await service.waitUntilSettled()
        let commands = await transport.commands
        let maxInFlight = await transport.maximumInFlight
        XCTAssertEqual(commands, [.pause, .play])
        XCTAssertEqual(maxInFlight, 1)
    }

    func testUnavailableOrPausedMediaNeverStartsPlayback() async {
        for result in [MediaPlaybackQueryResult.unavailable("no_media"), self.state(false), self.state(nil)] {
            let transport = FakeMediaPlaybackTransport([result])
            let service = self.service(transport)
            service.recordingStarted(sessionID: 1, enabled: true)
            await service.waitUntilSettled()
            service.sessionFinished(sessionID: 1)
            await service.waitUntilSettled()
            let commands = await transport.commands
            XCTAssertTrue(commands.isEmpty)
        }
    }

    func testDisabledSettingDoesNoMediaIO() async {
        let transport = FakeMediaPlaybackTransport([])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: false)
        await service.waitUntilSettled()
        let count = await transport.queryCount
        XCTAssertEqual(count, 0)
    }

    func testStopDuringQueryPreventsLatePause() async {
        let transport = FakeMediaPlaybackTransport([])
        await transport.holdQuery(1)
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await transport.waitForQuery(1)
        service.recordingStopped(sessionID: 1)
        await transport.releaseQuery(self.state(true))
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertTrue(commands.isEmpty)
        service.sessionFinished(sessionID: 1)
        await service.waitUntilSettled()
    }

    func testFailedStartDuringQueryNeverPauses() async {
        let transport = FakeMediaPlaybackTransport([])
        await transport.holdQuery(1)
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await transport.waitForQuery(1)
        service.sessionFinished(sessionID: 1)
        await transport.releaseQuery(self.state(true))
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertTrue(commands.isEmpty)
    }

    func testFailedStartDuringPauseRestoresPlaybackOnce() async {
        let transport = FakeMediaPlaybackTransport([self.state(true), self.state(false), self.state(false), self.state(true)])
        await transport.holdCommand(1)
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await transport.waitForCommand(1)
        service.sessionFinished(sessionID: 1)
        service.sessionFinished(sessionID: 1)
        await transport.releaseCommand(.helperCompleted)
        await service.waitUntilSettled()
        let commands = await transport.commands
        let maxInFlight = await transport.maximumInFlight
        XCTAssertEqual(commands, [.pause, .play])
        XCTAssertEqual(maxInFlight, 1)
    }

    func testNewRecordingSupersedesPendingQueryAndOldFinish() async {
        let transport = FakeMediaPlaybackTransport([self.state(true), self.state(false)])
        await transport.holdQuery(1)
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await transport.waitForQuery(1)
        service.recordingStarted(sessionID: 2, enabled: true)
        service.sessionFinished(sessionID: 1)
        await transport.releaseQuery(self.state(true))
        await service.waitUntilSettled()
        let commands = await transport.commands
        let count = await transport.queryCount
        XCTAssertEqual(commands, [.pause])
        XCTAssertEqual(count, 3)
    }

    func testStopDuringPauseWaitsForConfirmationBeforeResume() async {
        let transport = FakeMediaPlaybackTransport([self.state(true), self.state(false), self.state(false), self.state(true)])
        await transport.holdCommand(1)
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await transport.waitForCommand(1)
        service.recordingStopped(sessionID: 1)
        service.sessionFinished(sessionID: 1)
        let pendingCommands = await transport.commands
        XCTAssertEqual(pendingCommands, [.pause])
        await transport.releaseCommand(.helperCompleted)
        await service.waitUntilSettled()
        let commands = await transport.commands
        let maxInFlight = await transport.maximumInFlight
        XCTAssertEqual(commands, [.pause, .play])
        XCTAssertEqual(maxInFlight, 1)
    }

    func testNewRecordingDuringResumeQueryRetainsPause() async {
        let transport = FakeMediaPlaybackTransport([
            self.state(true), self.state(false), self.state(false), self.state(false), self.state(true),
        ])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        await transport.holdQuery(3)
        service.sessionFinished(sessionID: 1)
        await transport.waitForQuery(3)
        service.recordingStarted(sessionID: 2, enabled: true)
        await transport.releaseQuery(self.state(false))
        await service.waitUntilSettled()
        let beforeFinish = await transport.commands
        XCTAssertEqual(beforeFinish, [.pause])
        service.sessionFinished(sessionID: 1)
        service.sessionFinished(sessionID: 2)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause, .play])
    }

    func testTransientResumeQueryFailureRetriesBeforePlaying() async {
        let transport = FakeMediaPlaybackTransport([
            self.state(true), self.state(false), .unavailable("temporary"), self.state(false), self.state(true),
        ])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        service.sessionFinished(sessionID: 1)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause, .play])
    }

    func testResumeQueryFailureStopsAfterBoundedRetries() async {
        let transport = FakeMediaPlaybackTransport([
            self.state(true), self.state(false), .unavailable("temporary"),
            .unavailable("temporary"), .unavailable("temporary"),
        ])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        service.sessionFinished(sessionID: 1)
        await service.waitUntilSettled()
        let commands = await transport.commands
        let count = await transport.queryCount
        XCTAssertEqual(commands, [.pause])
        XCTAssertEqual(count, 5)
    }

    func testResumeRetryDoesNotPlayChangedItem() async {
        let transport = FakeMediaPlaybackTransport([
            self.state(true), self.state(false), .unavailable("temporary"), self.state(false, title: "Other"),
        ])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        service.sessionFinished(sessionID: 1)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause])
    }

    func testNewRecordingDuringUnavailableResumeQueryRetainsPause() async {
        let transport = FakeMediaPlaybackTransport([
            self.state(true), self.state(false), self.state(false), self.state(false), self.state(true),
        ])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        await transport.holdQuery(3)
        service.sessionFinished(sessionID: 1)
        await transport.waitForQuery(3)
        service.recordingStarted(sessionID: 2, enabled: true)
        await transport.releaseQuery(.unavailable("temporary"))
        await service.waitUntilSettled()
        let beforeFinish = await transport.commands
        XCTAssertEqual(beforeFinish, [.pause])
        service.sessionFinished(sessionID: 2)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause, .play])
    }

    func testUnconfirmedPauseDoesNotResumeOrSpamCommands() async {
        let transport = FakeMediaPlaybackTransport([self.state(true), self.state(true), self.state(true)])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        service.sessionFinished(sessionID: 1)
        for id in 2...10 {
            service.recordingStarted(sessionID: id, enabled: true)
            await service.waitUntilSettled()
            service.sessionFinished(sessionID: id)
        }
        await service.waitUntilSettled()
        let commands = await transport.commands
        let count = await transport.queryCount
        XCTAssertEqual(commands, [.pause])
        XCTAssertEqual(count, 3)
    }

    func testNewRecordingDuringPlayWaitsBeforePausingAgain() async {
        let transport = FakeMediaPlaybackTransport([
            self.state(true), self.state(false), self.state(false), self.state(true), self.state(true), self.state(false),
        ])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        await transport.holdCommand(2)
        service.sessionFinished(sessionID: 1)
        await transport.waitForCommand(2)
        service.recordingStarted(sessionID: 2, enabled: true)
        service.sessionFinished(sessionID: 1)
        await transport.releaseCommand(.helperCompleted)
        await service.waitUntilSettled()
        let commands = await transport.commands
        let maxInFlight = await transport.maximumInFlight
        XCTAssertEqual(commands, [.pause, .play, .pause])
        XCTAssertEqual(maxInFlight, 1)
    }

    func testPauseRemainsOwnedUntilTranscriptionFinishes() async {
        let transport = FakeMediaPlaybackTransport([self.state(true), self.state(false), self.state(false), self.state(true)])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        service.recordingStopped(sessionID: 1)
        await service.waitUntilSettled()
        let beforeFinish = await transport.commands
        XCTAssertEqual(beforeFinish, [.pause])
        service.sessionFinished(sessionID: 1)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause, .play])
    }

    func testCooldownHasBoundedExit() async {
        let transport = FakeMediaPlaybackTransport([
            self.state(true), self.state(true), self.state(true), self.state(true), self.state(false),
        ])
        let clock = MediaTestClock()
        let service = MediaPlaybackService(transport: transport, settle: {}, now: { clock.value })
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        clock.advance(11)
        service.recordingStarted(sessionID: 2, enabled: true)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause, .pause])
    }

    func testChangedPlayerOrItemAndManualPlayAreNotResumed() async {
        for changed in [self.state(false, pid: 2), self.state(false, title: "Other"), self.state(true)] {
            let transport = FakeMediaPlaybackTransport([self.state(true), self.state(false), changed])
            let service = self.service(transport)
            service.recordingStarted(sessionID: 1, enabled: true)
            await service.waitUntilSettled()
            service.sessionFinished(sessionID: 1)
            await service.waitUntilSettled()
            let commands = await transport.commands
            XCTAssertEqual(commands, [.pause])
        }
    }

    func testUnknownVerificationNeverClaimsOwnership() async {
        let transport = FakeMediaPlaybackTransport([
            self.state(true), .unavailable("timeout"), .unavailable("empty_output"),
        ])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        service.sessionFinished(sessionID: 1)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause])
    }

    func testCommandTimeoutStillChecksForAppliedPause() async {
        let transport = FakeMediaPlaybackTransport([self.state(true), self.state(false), self.state(false), self.state(true)])
        await transport.holdCommand(1)
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await transport.waitForCommand(1)
        await transport.releaseCommand(.failed("helper_timeout"))
        await service.waitUntilSettled()
        service.sessionFinished(sessionID: 1)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause, .play])
    }

    func testShutdownRestoresConfirmedPauseAndRejectsNewStarts() async {
        let transport = FakeMediaPlaybackTransport([self.state(true), self.state(false), self.state(false), self.state(true)])
        let service = self.service(transport)
        service.recordingStarted(sessionID: 1, enabled: true)
        await service.waitUntilSettled()
        await service.shutdown()
        service.recordingStarted(sessionID: 2, enabled: true)
        await service.waitUntilSettled()
        let commands = await transport.commands
        XCTAssertEqual(commands, [.pause, .play])
    }

    func testRawQueryFailuresAreDistinct() {
        for (text, reason) in [("", "empty_output"), ("NIL\n", "no_media_reported"), ("{", "invalid_payload")] {
            guard case let .unavailable(actual) = MediaPlaybackProcessTransport.decode(Data(text.utf8)) else {
                return XCTFail("Expected unavailable: \(reason)")
            }
            XCTAssertEqual(actual, reason)
        }
    }

    func testRawQueryAcceptsMissingTitleAndDoesNotOverrideExplicitPause() {
        let text = #"{"payload":{"PID":"42","bundleIdentifier":"com.apple.WebKit.GPU","isPlaying":false,"playbackRate":1}}"#
        guard case let .snapshot(snapshot) = MediaPlaybackProcessTransport.decode(Data(text.utf8)) else {
            return XCTFail("Expected player state")
        }
        XCTAssertEqual(snapshot.processID, 42)
        XCTAssertNil(snapshot.title)
        XCTAssertEqual(snapshot.isPlaying, false)
    }

    func testProcessDrainsBothPipesBeforeCompletion() async {
        let result = await Task.detached {
            MediaHelperProcess.run(arguments: ["-e", "print 'x' x 200000; print STDERR 'y' x 200000;"])
        }.value
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.output.count, 200_000)
    }

    func testProcessTimeoutTerminatesHelper() async {
        let result = await Task.detached {
            MediaHelperProcess.run(arguments: ["-e", "sleep 10;"], timeout: 0.1)
        }.value
        XCTAssertEqual(result.failure, "helper_timeout")
    }

    func testProcessOutputIsBounded() async {
        let result = await Task.detached {
            MediaHelperProcess.run(arguments: ["-e", "print 'x' x 5000000;"])
        }.value
        XCTAssertEqual(result.failure, "output_limit")
        XCTAssertTrue(result.output.isEmpty)
    }

    private func service(_ transport: FakeMediaPlaybackTransport) -> MediaPlaybackService {
        MediaPlaybackService(transport: transport, settle: {}, now: { 0 })
    }

    private func state(_ playing: Bool?, pid: Int32 = 1, title: String = "Netflix") -> MediaPlaybackQueryResult {
        .snapshot(MediaPlaybackSnapshot(bundleIdentifier: "com.apple.WebKit.GPU", processID: pid, title: title, isPlaying: playing))
    }
}

private actor FakeMediaPlaybackTransport: MediaPlaybackTransport {
    private var results: [MediaPlaybackQueryResult]
    private var heldQueryIndex: Int?
    private var heldCommandIndex: Int?
    private var queryContinuation: CheckedContinuation<MediaPlaybackQueryResult, Never>?
    private var commandContinuation: CheckedContinuation<MediaPlaybackCommandResult, Never>?
    private var queryWaiter: (Int, CheckedContinuation<Void, Never>)?
    private var commandWaiter: (Int, CheckedContinuation<Void, Never>)?
    private var inFlight = 0
    private(set) var maximumInFlight = 0
    private(set) var queryCount = 0
    private(set) var commands: [MediaPlaybackCommand] = []

    init(_ results: [MediaPlaybackQueryResult]) { self.results = results }

    func query() async -> MediaPlaybackQueryResult {
        self.inFlight += 1
        self.maximumInFlight = max(self.maximumInFlight, self.inFlight)
        defer { self.inFlight -= 1 }
        self.queryCount += 1
        if let (count, continuation) = self.queryWaiter, self.queryCount >= count {
            self.queryWaiter = nil
            continuation.resume()
        }
        if self.queryCount == self.heldQueryIndex {
            return await withCheckedContinuation { self.queryContinuation = $0 }
        }
        return self.results.isEmpty ? .unavailable("exhausted") : self.results.removeFirst()
    }

    func send(_ command: MediaPlaybackCommand) async -> MediaPlaybackCommandResult {
        self.inFlight += 1
        self.maximumInFlight = max(self.maximumInFlight, self.inFlight)
        defer { self.inFlight -= 1 }
        self.commands.append(command)
        if let (count, continuation) = self.commandWaiter, self.commands.count >= count {
            self.commandWaiter = nil
            continuation.resume()
        }
        if self.commands.count == self.heldCommandIndex {
            return await withCheckedContinuation { self.commandContinuation = $0 }
        }
        return .helperCompleted
    }

    func holdQuery(_ index: Int) { self.heldQueryIndex = index }
    func holdCommand(_ index: Int) { self.heldCommandIndex = index }
    func releaseQuery(_ result: MediaPlaybackQueryResult) {
        self.queryContinuation?.resume(returning: result)
        self.queryContinuation = nil
    }

    func releaseCommand(_ result: MediaPlaybackCommandResult) {
        self.commandContinuation?.resume(returning: result)
        self.commandContinuation = nil
    }

    func waitForQuery(_ count: Int) async {
        guard self.queryCount < count else { return }
        await withCheckedContinuation { self.queryWaiter = (count, $0) }
    }

    func waitForCommand(_ count: Int) async {
        guard self.commands.count < count else { return }
        await withCheckedContinuation { self.commandWaiter = (count, $0) }
    }
}

private final nonisolated class MediaTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0

    var value: TimeInterval {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.time
    }

    func advance(_ seconds: TimeInterval) {
        self.lock.lock()
        self.time += seconds
        self.lock.unlock()
    }
}
