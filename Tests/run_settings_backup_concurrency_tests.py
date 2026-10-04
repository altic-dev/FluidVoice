#!/usr/bin/env python3
"""Test source-extracted backup methods with bounded real-actor dependency probes.

No production defaults, disk stores, UI, hardware, or network are used.
--ref REF --expect-overlap-gap reproduces a historical overlapping snapshot gap.
Normal execution needs only the current source, including its single-flight gate.
"""

import argparse
import os
from pathlib import Path
import subprocess
import tempfile


def declaration(source: str, marker: str) -> str:
    start = source.index(marker)
    brace = source.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref")
    parser.add_argument("--expect-overlap-gap", action="store_true")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    selected = subprocess.check_output(["xcode-select", "-p"], text=True, timeout=10).strip()
    developer_dir = os.environ.get("DEVELOPER_DIR", selected)
    if not (Path(developer_dir) / "Platforms/MacOSX.platform").is_dir():
        raise SystemExit("Set DEVELOPER_DIR to a full installed Xcode before running this test.")
    environment = dict(os.environ, DEVELOPER_DIR=developer_dir)
    source_path = "Sources/Fluid/Persistence/BackupService.swift"
    source = (
        subprocess.check_output(["git", "show", f"{args.ref}:{source_path}"], cwd=repo, text=True, timeout=10)
        if args.ref else (repo / source_path).read_text()
    )
    members = "\n".join(declaration(source, marker) for marker in (
        "    func makeBackupDocument() async throws -> AppBackupDocument",
        "    func restore(_ document: AppBackupDocument) async throws",
        "    private func validate(_ document: AppBackupDocument)",
    ))
    if "private var operationInProgress" in source:
        # Extract the actual gate storage and admission method, never a mirrored gate.
        gate_line = next(line for line in source.splitlines() if "private var operationInProgress" in line)
        members = gate_line + "\n" + declaration(source, "    private func beginOperation()") + "\n" + members
    errors = declaration(source, "enum BackupServiceError:")
    schema = declaration(source, "struct BackupFileVersion:")
    swift = r'''
import Foundation
SCHEMA
ERRORS
struct Payload: Codable {
    var owner: String
    var privateAIIdleUnload: Int?
    var meetingLanguage: String? = nil
    var promptConfigurations: [String: String]? = nil
}
struct AppBackupDocument {
    var schemaVersion: BackupFileVersion = .current
    var appVersion = "fixture"
    var exportedAt = Date()
    var settings: Payload
    var promptProfiles: [String] = []
    var appPromptBindings: [String] = []
    var transcriptionHistory: [String] = []
    var pronunciationProfiles: [String]?
}
@MainActor final class SettingsStore {
    static let shared = SettingsStore()
    var owner = "original"
    var privateAIIdleUnload = 30
    var meetingLanguage = "en"
    var configurations = ["__default__": "original"]
    var dictationPromptProfiles: [String] = []
    var appPromptBindings: [String] = []
    func makeBackupPayload() -> Payload {
        .init(owner: owner, privateAIIdleUnload: privateAIIdleUnload,
              meetingLanguage: meetingLanguage, promptConfigurations: configurations)
    }
    func restore(from payload: Payload, promptProfiles: [String], appPromptBindings: [String]) {
        owner = payload.owner
        if let idle = payload.privateAIIdleUnload { privateAIIdleUnload = idle }
        if let language = payload.meetingLanguage { meetingLanguage = language }
        if let configurations = payload.promptConfigurations { self.configurations = configurations }
        dictationPromptProfiles = promptProfiles
        self.appPromptBindings = appPromptBindings
    }
}
actor Gate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func pause() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
enum ProbeFailure: Error { case storage }
actor PronunciationDictionaryStore {
    static let shared = PronunciationDictionaryStore()
    var profiles = ["original"]
    var reject = false
    var exportGate: Gate?
    var restoreGate: Gate?
    var snapshots = 0, replacements = 0
    func setup(reject: Bool = false, exportGate: Gate? = nil, restoreGate: Gate? = nil) {
        profiles = ["original"]; self.reject = reject
        self.exportGate = exportGate; self.restoreGate = restoreGate
        snapshots = 0; replacements = 0
    }
    func allProfiles() async -> [String] {
        snapshots += 1
        let snapshot = profiles
        if let gate = exportGate { exportGate = nil; await gate.pause() }
        return snapshot
    }
    func replaceAllProfiles(_ profiles: [String]) async throws {
        replacements += 1
        if let gate = restoreGate { restoreGate = nil; await gate.pause() }
        if reject { throw ProbeFailure.storage }
        self.profiles = profiles
    }
    func ordinaryEdit(_ profiles: [String]) { self.profiles = profiles }
    func state() -> ([String], Int, Int) { (profiles, snapshots, replacements) }
}
@MainActor final class TranscriptionHistoryStore {
    static let shared = TranscriptionHistoryStore()
    var history = ["original"]
    var loaded = true
    var loadGate: Gate?
    var loads = 0, writes = 0
    func waitUntilLoaded() async throws {
        loads += 1
        if let gate = loadGate { loadGate = nil; await gate.pause() }
        if !loaded { throw ProbeFailure.storage }
    }
    func makeBackupPayload() -> [String] { history }
    func restore(from payload: [String]) { writes += 1; history = payload }
}
actor IdleDouble {
    var gate: Gate?
    var calls = 0
    var observations: [Int] = []
    func setup(gate: Gate? = nil) { self.gate = gate; calls = 0; observations = [] }
    func settingsChanged() async {
        calls += 1
        if let gate { self.gate = nil; await gate.pause() }
        observations.append(await SettingsStore.shared.privateAIIdleUnload)
    }
    func state() -> (Int, [Int]) { (calls, observations) }
}
enum PrivateAIIntegrationService { static let idleUnloader = IdleDouble() }
@MainActor final class NotificationCenter {
    static let `default` = NotificationCenter()
    var snapshots: [(String, [String])] = []
    var onPost: (() -> Void)?
    enum Name { case settingsBackupDidRestore }
    func post(name: Name, object: Any?) {
        snapshots.append((SettingsStore.shared.owner, TranscriptionHistoryStore.shared.history))
        onPost?()
    }
}
@MainActor final class BackupService {
MEMBERS
}
@MainActor var assertions = 0
@MainActor func expect(_ condition: Bool, _ message: String) {
    assertions += 1
    if !condition { fatalError("FAIL: " + message) }
}
@MainActor func busy(_ work: () async throws -> Void) async {
    do { try await work(); fatalError("Expected busy rejection") }
    catch BackupServiceError.operationInProgress {
        expect(BackupServiceError.operationInProgress.localizedDescription.contains("already running"), "busy error tells user to retry")
    } catch { fatalError("Wrong busy error: \(error)") }
}
@MainActor func reset(idleGate: Gate? = nil, exportGate: Gate? = nil, restoreGate: Gate? = nil) async {
    SettingsStore.shared.owner = "original"
    SettingsStore.shared.privateAIIdleUnload = 30
    SettingsStore.shared.meetingLanguage = "en"
    SettingsStore.shared.configurations = ["__default__": "original"]
    SettingsStore.shared.dictationPromptProfiles = []
    SettingsStore.shared.appPromptBindings = []
    TranscriptionHistoryStore.shared.history = ["original"]
    TranscriptionHistoryStore.shared.loaded = true
    TranscriptionHistoryStore.shared.loads = 0; TranscriptionHistoryStore.shared.writes = 0
    TranscriptionHistoryStore.shared.loadGate = nil
    NotificationCenter.default.snapshots = []; NotificationCenter.default.onPost = nil
    await PronunciationDictionaryStore.shared.setup(exportGate: exportGate, restoreGate: restoreGate)
    await PrivateAIIntegrationService.idleUnloader.setup(gate: idleGate)
}
func awaitGate(_ gate: Gate) async {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await gate.entered) {
        if ContinuousClock.now > deadline { fatalError("Timed out waiting for actor gate") }
        try? await Task.sleep(for: .milliseconds(1))
    }
}
@MainActor func document(_ owner: String, idle: Int? = 60) -> AppBackupDocument {
    .init(settings: .init(owner: owner, privateAIIdleUnload: idle),
          promptProfiles: [owner], appPromptBindings: [owner],
          transcriptionHistory: [owner], pronunciationProfiles: [owner])
}
@main struct Run {
    @MainActor static func main() async throws {
        let service = BackupService()
        // Export suspended after obtaining old pronunciation; concurrent import used
        // to make the eventual settings/History snapshot belong to a different backup.
        let exportGate = Gate()
        await reset(exportGate: exportGate)
        let firstExport = Task { try await service.makeBackupDocument() }
        await awaitGate(exportGate)
        OVERLAP_ACTION
        await exportGate.release()
        let snapshot = try await firstExport.value
        OVERLAP_ASSERTION
        CURRENT_TESTS
    }
}
'''.replace("SCHEMA", schema).replace("ERRORS", errors).replace("MEMBERS", members)

    if args.expect_overlap_gap:
        # Historical enum lacks the busy case, so remove the current-only helper.
        start = swift.index("@MainActor func busy(")
        end = swift.index("@MainActor func reset(", start)
        swift = swift[:start] + swift[end:]
        swift = swift.replace("OVERLAP_ACTION", 'try await service.restore(document("B", idle: nil))')
        swift = swift.replace("OVERLAP_ASSERTION", r'''
        expect(snapshot.pronunciationProfiles == ["original"] && snapshot.settings.owner == "B" && snapshot.transcriptionHistory == ["B"], "historical export/import overlap must expose mixed snapshot")
        print("REPRODUCED: old pronunciation + new settings/History from overlapping export/import")
''')
        swift = swift.replace("CURRENT_TESTS", 'print("Historical overlap probe completed")')
    else:
        swift = swift.replace("OVERLAP_ACTION", r'''
        await busy { try await service.restore(document("B", idle: nil)) }
        await busy { _ = try await service.makeBackupDocument() }
        let during = await PronunciationDictionaryStore.shared.state()
        expect(during.2 == 0 && during.1 == 1, "rejected overlap cannot enter profile writer/second snapshot")
        expect(SettingsStore.shared.owner == "original" && TranscriptionHistoryStore.shared.writes == 0 && NotificationCenter.default.snapshots.isEmpty, "rejected import cannot write or notify")
''')
        swift = swift.replace("OVERLAP_ASSERTION", r'''
        expect(snapshot.pronunciationProfiles == [snapshot.settings.owner] && snapshot.transcriptionHistory == [snapshot.settings.owner], "admitted export remains a consistent snapshot")
        try await service.restore(document("B", idle: nil))
        let freshExport = try await service.makeBackupDocument()
        expect(freshExport.pronunciationProfiles == ["B"] && freshExport.settings.owner == "B", "import and export can retry after owner finishes")
''')
        swift = swift.replace("CURRENT_TESTS", r'''
        // Reverse overlap: an admitted import has not yet replaced profiles.
        let restoreGate = Gate()
        await reset(restoreGate: restoreGate)
        let firstRestore = Task { try await service.restore(document("A")) }
        await awaitGate(restoreGate)
        await busy { _ = try await service.makeBackupDocument() }
        await busy { try await service.restore(document("B")) }
        let beforeReplace = await PronunciationDictionaryStore.shared.state()
        expect(beforeReplace.2 == 1 && beforeReplace.1 == 0 && TranscriptionHistoryStore.shared.loads == 0, "reverse overlap is rejected before export load or second profile write")
        await restoreGate.release(); try await firstRestore.value
        let afterRestore = try await service.makeBackupDocument()
        expect(afterRestore.settings.owner == "A" && afterRestore.pronunciationProfiles == ["A"] && afterRestore.transcriptionHistory == ["A"], "admitted restore publishes one complete document")

        // Retain ownership through timer replies and notification reentrancy.
        let idleGate = Gate()
        await reset(idleGate: idleGate)
        let idleRestore = Task { try await service.restore(document("A")) }
        await awaitGate(idleGate)
        await busy { _ = try await service.makeBackupDocument() }
        await busy { try await service.restore(document("B", idle: nil)) }
        expect(NotificationCenter.default.snapshots.count == 1 && NotificationCenter.default.snapshots.allSatisfy { $0.1 == [$0.0] }, "synchronous observers see matching settings/history")
        SettingsStore.shared.privateAIIdleUnload = 0
        idleRestore.cancel(); await idleGate.release(); try await idleRestore.value
        let idleState = await PrivateAIIntegrationService.idleUnloader.state()
        expect(idleState.1 == [0], "timer reads latest user preference after cancellation")
        try await service.restore(document("retry", idle: nil))
        expect(SettingsStore.shared.owner == "retry", "cancellation after commit releases busy flag")

        // Cancel a read-only export while actor reply is delayed: no document or write.
        let cancelledGate = Gate()
        await reset(exportGate: cancelledGate)
        let cancelledExport = Task { try await service.makeBackupDocument() }
        await awaitGate(cancelledGate); cancelledExport.cancel(); await cancelledGate.release()
        do { _ = try await cancelledExport.value; fatalError("Expected cancellation") } catch is CancellationError {}
        expect(SettingsStore.shared.owner == "original" && TranscriptionHistoryStore.shared.writes == 0 && NotificationCenter.default.snapshots.isEmpty, "cancelled export has no writes/notifications")
        _ = try await service.makeBackupDocument()
        try await service.restore(document("after-export-cancel", idle: nil))
        expect(SettingsStore.shared.owner == "after-export-cancel", "cancelled export releases gate for both operations")

        // A profile write admitted before cancellation must finish the matching
        // synchronous commit rather than leave new profiles with old settings.
        let cancelledRestoreGate = Gate()
        await reset(restoreGate: cancelledRestoreGate)
        let cancelledRestore = Task { try await service.restore(document("cancelled", idle: nil)) }
        await awaitGate(cancelledRestoreGate); cancelledRestore.cancel(); await cancelledRestoreGate.release()
        try await cancelledRestore.value
        let completed = try await service.makeBackupDocument()
        expect(completed.pronunciationProfiles == ["cancelled"] && completed.settings.owner == "cancelled" && completed.transcriptionHistory == ["cancelled"], "cancellation after profile admission finishes a consistent restore")
        expect(NotificationCenter.default.snapshots.count == 1, "completed cancelled restore notifies exactly once")

        // Cancellation before admission prevents all dependency work and releases gate.
        for isRestore in [false, true] {
            await reset()
            let task = Task { () throws -> Void in
                withUnsafeCurrentTask { $0?.cancel() }
                if isRestore { try await service.restore(document("unstarted")) }
                else { _ = try await service.makeBackupDocument() }
            }
            do { try await task.value; fatalError("Expected early cancellation") } catch is CancellationError {}
            let untouched = await PronunciationDictionaryStore.shared.state()
            expect(untouched.1 == 0 && untouched.2 == 0 && TranscriptionHistoryStore.shared.loads == 0, "pre-cancelled operation never touches dependencies")
            _ = try await service.makeBackupDocument()
            try await service.restore(document("retry", idle: nil))
            expect(SettingsStore.shared.owner == "retry", "early cancellation clears admission flag")
        }
        // Every failure path releases its hold and preserves non-effects.
        await reset()
        await PronunciationDictionaryStore.shared.setup(reject: true)
        do { try await service.restore(document("failed")); fatalError("Expected store failure") } catch ProbeFailure.storage {}
        expect(SettingsStore.shared.owner == "original" && TranscriptionHistoryStore.shared.writes == 0 && NotificationCenter.default.snapshots.isEmpty, "profile failure has no settings/history/notification effects")
        await PronunciationDictionaryStore.shared.setup()
        _ = try await service.makeBackupDocument()
        try await service.restore(document("retry", idle: nil))
        expect(SettingsStore.shared.owner == "retry", "profile failure clears gate")
        await reset()
        var invalid = document("invalid"); invalid.schemaVersion = .init(major: 99, minor: 0)
        do { try await service.restore(invalid); fatalError("Expected schema failure") } catch BackupServiceError.unsupportedSchemaVersion {}
        let rejected = await PronunciationDictionaryStore.shared.state()
        expect(rejected.2 == 0 && SettingsStore.shared.owner == "original", "schema validation rejects before profile write")
        _ = try await service.makeBackupDocument()
        expect(TranscriptionHistoryStore.shared.loads == 1, "schema failure clears gate")
        await reset(); TranscriptionHistoryStore.shared.loaded = false
        do { _ = try await service.makeBackupDocument(); fatalError("Expected load failure") } catch ProbeFailure.storage {}
        let unloaded = await PronunciationDictionaryStore.shared.state()
        expect(unloaded.1 == 0 && unloaded.2 == 0 && NotificationCenter.default.snapshots.isEmpty, "load failure has no profile or notification effects")
        TranscriptionHistoryStore.shared.loaded = true
        try await service.restore(document("retry", idle: nil))
        expect(SettingsStore.shared.owner == "retry", "load failure clears gate")

        // Export retains admission even before history has loaded; cancellation
        // is checked after the pre-existing non-cancellable load reply returns.
        let loadGate = Gate()
        await reset(); TranscriptionHistoryStore.shared.loadGate = loadGate
        let loading = Task { try await service.makeBackupDocument() }
        await awaitGate(loadGate)
        await busy { try await service.restore(document("blocked")) }
        await busy { _ = try await service.makeBackupDocument() }
        loading.cancel(); await loadGate.release()
        do { _ = try await loading.value; fatalError("Expected load cancellation") } catch is CancellationError {}
        let noSnapshot = await PronunciationDictionaryStore.shared.state()
        expect(noSnapshot.1 == 0, "cancelled history wait exits before pronunciation snapshot")
        _ = try await service.makeBackupDocument()

        for (idle, expectedCalls) in [(nil, 0), (Optional(30), 0), (Optional(60), 1), (Optional(0), 1)] {
            await reset(); try await service.restore(document("field", idle: idle))
            let state = await PrivateAIIntegrationService.idleUnloader.state()
            expect(state.0 == expectedCalls, "only changed present idle values reschedule")
            expect(SettingsStore.shared.privateAIIdleUnload == (idle ?? 30), "legacy absent idle preserves preference")
        }
        await reset()
        var legacy = document("legacy", idle: nil); legacy.pronunciationProfiles = nil
        try await service.restore(legacy)
        let legacyExport = try await service.makeBackupDocument()
        expect(legacyExport.pronunciationProfiles == [] && legacyExport.settings.owner == "legacy", "legacy import clears newer pronunciation profiles")
        expect(SettingsStore.shared.meetingLanguage == "en" && SettingsStore.shared.configurations == ["__default__": "original"], "absent additive settings remain unchanged")
        var modern = document("modern", idle: nil)
        modern.settings.meetingLanguage = "fr"; modern.settings.promptConfigurations = [:]
        try await service.restore(modern)
        expect(SettingsStore.shared.meetingLanguage == "fr" && SettingsStore.shared.configurations.isEmpty, "present empty configuration remains authoritative")
        await reset()
        NotificationCenter.default.onPost = { SettingsStore.shared.privateAIIdleUnload = 0 }
        try await service.restore(document("notice"))
        let notificationSettings = await PrivateAIIntegrationService.idleUnloader.state()
        expect(notificationSettings.1 == [0], "timer respects synchronous observer preference changes")

        // Deliberately document the limit: ordinary dictionary/settings edits do
        // not participate in BackupService admission. This gate cannot serialize them.
        let manualGate = Gate()
        await reset(exportGate: manualGate)
        let manualExport = Task { try await service.makeBackupDocument() }
        await awaitGate(manualGate)
        await PronunciationDictionaryStore.shared.ordinaryEdit(["manual"])
        SettingsStore.shared.owner = "manual"; TranscriptionHistoryStore.shared.history = ["manual"]
        await manualGate.release()
        let manualSnapshot = try await manualExport.value
        expect(manualSnapshot.pronunciationProfiles == ["original"] && manualSnapshot.settings.owner == "manual", "service gate does not falsely serialize ordinary dictionary/settings mutations")
        print("LIMIT: ordinary dictionary/settings edits remain outside backup-operation admission")
        print("PASS: \(assertions) production-method concurrency assertions")
''')
    with tempfile.TemporaryDirectory(prefix="fluidvoice-backup-concurrency-") as directory:
        swift_path = Path(directory) / "Probe.swift"
        binary = Path(directory) / "probe"
        swift_path.write_text(swift)
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(swift_path), "-o", str(binary)],
                       cwd=repo, env=environment, check=True, timeout=60)
        subprocess.run([str(binary)], env=environment, check=True, timeout=20)


if __name__ == "__main__":
    main()
