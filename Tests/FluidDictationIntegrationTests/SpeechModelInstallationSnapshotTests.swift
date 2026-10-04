@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
private final class InstallationCapture {
    var modelID = "first"
}

private actor InstallationScanGate {
    private(set) var calls = 0
    private(set) var observedIDs: [[String]] = []
    private var continuations: [CheckedContinuation<Set<String>, Error>] = []

    func scan(_ probes: [SpeechModelInstallationSnapshot.Probe]) async throws -> Set<String> {
        self.calls += 1
        self.observedIDs.append(probes.map(\.modelID))
        return try await withCheckedThrowingContinuation { self.continuations.append($0) }
    }

    func complete(_ result: Result<Set<String>, Error>) {
        self.continuations.removeFirst().resume(with: result)
    }
}

@MainActor
final class SpeechModelInstallationSnapshotTests: XCTestCase {
    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !(await condition()), Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let completed = await condition()
        XCTAssertTrue(completed, "Snapshot operation must finish within the test deadline")
    }

    func testRapidRefreshScansOnlyInitialAndLatestSnapshotAndRejectsOldResult() async throws {
        let gate = InstallationScanGate()
        let capture = InstallationCapture()
        let snapshot = SpeechModelInstallationSnapshot(capture: {
            [.init(modelID: capture.modelID, kind: .builtIn)]
        }, scanner: { try await gate.scan($0) })
        snapshot.refresh()
        try await self.waitUntil { await gate.calls == 1 }
        capture.modelID = "middle"
        snapshot.refresh()
        capture.modelID = "latest"
        snapshot.refresh()
        await gate.complete(.success(["first"]))
        try await self.waitUntil { await gate.calls == 2 }
        XCTAssertEqual(snapshot.state, .checking)
        XCTAssertTrue(snapshot.installedIDs.isEmpty, "An outdated scan must not publish")
        XCTAssertFalse(snapshot.canUseModelActions)
        await gate.complete(.success(["latest"]))
        try await self.waitUntil { snapshot.state == .ready }
        XCTAssertEqual(snapshot.installedIDs, ["latest"])
        let observed = await gate.observedIDs
        XCTAssertEqual(observed, [["first"], ["latest"]])
        XCTAssertTrue(snapshot.canUseModelActions)
    }

    func testCancelDrainsOldWorkerBeforeRetryAndNeverPublishesCanceledResult() async throws {
        let gate = InstallationScanGate()
        let snapshot = SpeechModelInstallationSnapshot(capture: { [] }, scanner: { try await gate.scan($0) })
        snapshot.refresh()
        try await self.waitUntil { await gate.calls == 1 }
        snapshot.cancel()
        XCTAssertEqual(snapshot.state, .failed)
        snapshot.refresh()
        let beforeDrain = await gate.calls
        XCTAssertEqual(beforeDrain, 1, "A retry must not start overlapping filesystem work")
        await gate.complete(.success(["canceled"]))
        try await self.waitUntil { await gate.calls == 2 }
        XCTAssertFalse(snapshot.isInstalled(modelID: "canceled"))
        await gate.complete(.success(["retry"]))
        try await self.waitUntil { snapshot.state == .ready }
        XCTAssertEqual(snapshot.installedIDs, ["retry"])
    }

    func testFailureClearsOldIDsAndAllowsSuccessfulRetry() async throws {
        let gate = InstallationScanGate()
        let snapshot = SpeechModelInstallationSnapshot(capture: { [] }, scanner: { try await gate.scan($0) })
        snapshot.refresh()
        try await self.waitUntil { await gate.calls == 1 }
        await gate.complete(.success(["old"]))
        try await self.waitUntil { snapshot.state == .ready }
        snapshot.refresh()
        try await self.waitUntil { await gate.calls == 2 }
        await gate.complete(.failure(CocoaError(.fileReadNoSuchFile)))
        try await self.waitUntil { snapshot.state == .failed }
        XCTAssertTrue(snapshot.installedIDs.isEmpty)
        XCTAssertFalse(snapshot.canUseModelActions)
        snapshot.refresh()
        try await self.waitUntil { await gate.calls == 3 }
        await gate.complete(.success(["new"]))
        try await self.waitUntil { snapshot.state == .ready }
        XCTAssertEqual(snapshot.installedIDs, ["new"])
    }

    func testStalledIOHasBoundedFailureAndRejectsLateSuccess() async throws {
        let gate = InstallationScanGate()
        let snapshot = SpeechModelInstallationSnapshot(timeoutNanoseconds: 20_000_000, capture: { [] }, scanner: { try await gate.scan($0) })
        snapshot.refresh()
        try await self.waitUntil { await gate.calls == 1 }
        try await self.waitUntil { snapshot.state == .failed }
        XCTAssertTrue(snapshot.installedIDs.isEmpty)
        XCTAssertFalse(snapshot.canUseModelActions)
        await gate.complete(.success(["late"]))
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(snapshot.state, .failed)
        XCTAssertFalse(snapshot.isInstalled(modelID: "late"))
    }

    func testCompletedDeadlineCannotCancelLaterRefresh() async throws {
        let gate = InstallationScanGate()
        let snapshot = SpeechModelInstallationSnapshot(timeoutNanoseconds: 100_000_000, capture: { [] }, scanner: { try await gate.scan($0) })
        snapshot.refresh()
        try await self.waitUntil { await gate.calls == 1 }
        await gate.complete(.success(["one"]))
        try await self.waitUntil { snapshot.state == .ready }
        try await Task.sleep(for: .milliseconds(70))
        snapshot.refresh()
        try await self.waitUntil { await gate.calls == 2 }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(snapshot.state, .checking, "The first canceled deadline must not cancel the new request")
        await gate.complete(.success(["two"]))
        try await self.waitUntil { snapshot.state == .ready }
    }

    func testOffMainScannerChecksExactWhisperSizeAndHasNoStatefulSideEffects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let models = root.appendingPathComponent("WhisperModels", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let file = models.appendingPathComponent("fixture.bin")
        try Data([1, 2, 3]).write(to: file)
        let selection = SettingsStore.shared.selectedSpeechModel
        let ids = try await SpeechModelInstallationSnapshot.scan(
            [
                .init(modelID: "bundled", kind: .builtIn),
                .init(modelID: "exact", kind: .whisper(file: "fixture.bin", expectedBytes: 3)),
                .init(modelID: "wrong-size", kind: .whisper(file: "fixture.bin", expectedBytes: 4)),
                .init(modelID: "missing", kind: .whisper(file: "missing.bin", expectedBytes: 3)),
                .init(modelID: "unsupported", kind: .unavailable),
            ],
            cachesDirectory: root,
            modelsDirectory: root
        )
        XCTAssertEqual(ids, ["bundled", "exact"])
        XCTAssertEqual(try Data(contentsOf: file), Data([1, 2, 3]))
        XCTAssertEqual(SettingsStore.shared.selectedSpeechModel, selection)
    }
}
