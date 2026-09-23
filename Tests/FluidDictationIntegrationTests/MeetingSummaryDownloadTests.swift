@testable import FluidVoice_Debug
import Foundation
import XCTest

#if PRIVATE_AI_PROVIDER && canImport(FluidIntelligence)
final class MeetingSummaryDownloadTests: XCTestCase {
    func testSummaryCancellationAndTimeoutTerminateBlockedHelper() async throws {
        for timedOut in [false, true] {
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/cat")
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            defer {
                if process.isRunning { process.terminate() }
                input.fileHandleForWriting.closeFile()
                output.fileHandleForReading.closeFile()
            }
            let guardScope = FluidSummaryProcessGuard(process: process)
            let exited = expectation(description: "Blocked helper exits")
            let read = Task.detached {
                let data = output.fileHandleForReading.availableData
                process.waitUntilExit()
                exited.fulfill()
                return data
            }
            guardScope.terminate(timedOut: timedOut)
            await fulfillment(of: [exited], timeout: 2)
            let result = await read.value
            XCTAssertTrue(result.isEmpty)
            XCTAssertFalse(process.isRunning)
            XCTAssertEqual(guardScope.finish(), timedOut)
        }
    }

    func testCompletedSummaryDisarmsLateCancellationAndTimeout() throws {
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.standardInput = input
        process.standardOutput = Pipe()
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
            input.fileHandleForWriting.closeFile()
        }
        let guardScope = FluidSummaryProcessGuard(process: process)
        XCTAssertFalse(guardScope.finish())
        guardScope.terminate()
        guardScope.terminate(timedOut: true)
        XCTAssertTrue(process.isRunning, "A late watchdog must not terminate a reused helper")
        XCTAssertFalse(guardScope.finish())
    }

    func testKilledSummaryHelperInputReturnsErrorInsteadOfSignallingHost() throws {
        let pipe = Pipe()
        try FluidSummaryProcessGuard.configureInputHandle(pipe.fileHandleForWriting)
        pipe.fileHandleForReading.closeFile()
        defer { pipe.fileHandleForWriting.closeFile() }
        XCTAssertThrowsError(try pipe.fileHandleForWriting.write(contentsOf: Data(repeating: 42, count: 96_000)))
    }

    func testSummaryDownloadCancelsUnderlyingWork() async throws {
        let coordinator = FluidPrivateAIModelDownloadCoordinator()
        let started = expectation(description: "Download started")
        let work = Task {
            try await coordinator.prepare(modelID: "summary", cancelsWithCaller: true) {
                started.fulfill()
                try await Task.sleep(for: .seconds(10))
                return URL(fileURLWithPath: "/tmp/summary")
            }
        }
        await fulfillment(of: [started], timeout: 1)
        work.cancel()
        do {
            _ = try await work.value
            XCTFail("Cancelling must stop the underlying summary download")
        } catch is CancellationError {} catch {
            XCTFail("Unexpected error: \(error)")
        }
        // A cancelled attempt must relinquish its slot so a retry starts new work.
        let result = try await coordinator.prepare(modelID: "summary", cancelsWithCaller: true) {
            URL(fileURLWithPath: "/tmp/retry")
        }
        XCTAssertEqual(result.lastPathComponent, "retry")
    }

    func testOtherModelDownloadsKeepTheirExistingSharedWorkBehavior() async throws {
        let coordinator = FluidPrivateAIModelDownloadCoordinator()
        let started = expectation(description: "Download started")
        let work = Task {
            try await coordinator.prepare(modelID: "dictation") {
                started.fulfill()
                try await Task.sleep(for: .milliseconds(40))
                return URL(fileURLWithPath: "/tmp/dictation")
            }
        }
        await fulfillment(of: [started], timeout: 1)
        work.cancel()
        let result = try await work.value
        XCTAssertEqual(result.lastPathComponent, "dictation")
    }
}
#endif
