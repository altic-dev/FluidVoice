@testable import FluidVoice_Debug
import XCTest

/// Runs on the main actor, like Command Mode, to check `execute` never blocks it.
@MainActor
final class TerminalServiceTests: XCTestCase {
    func testOutputLargerThanPipeBufferIsReturnedInFull() async {
        let result = await TerminalService().execute(command: "head -c 300000 /dev/zero | tr '\\0' a", timeout: 10)
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(result.output.count, 300_000)
    }

    func testTimeoutStopsCommand() async {
        let start = Date()
        let result = await TerminalService().execute(command: "sleep 30", timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("timed out") == true, result.error ?? "nil")
    }

    func testMainActorStaysResponsiveWhileCommandRuns() async {
        var ticks = 0
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                ticks += 1
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        _ = await TerminalService().execute(command: "sleep 1", timeout: 10)
        ticker.cancel()
        XCTAssertGreaterThanOrEqual(ticks, 10)
    }

    func testCapturesStderrAndExitCode() async {
        let result = await TerminalService().execute(command: "echo out; echo err >&2; exit 3", timeout: 10)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.output, "out")
        XCTAssertEqual(result.error, "err")
    }

    func testBackgroundedChildDoesNotHoldResult() async {
        let start = Date()
        let result = await TerminalService().execute(command: "sleep 30 & echo done", timeout: 10)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(result.output, "done")
    }

    func testLaunchFailureIsReported() async {
        let result = await TerminalService().execute(command: "true", workingDirectory: "/nonexistent-\(UUID().uuidString)", timeout: 10)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.exitCode, -1)
    }
}
