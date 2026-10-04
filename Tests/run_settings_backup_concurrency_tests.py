#!/usr/bin/env python3
"""Replay production backup methods with bounded, gated dependency doubles.

No app preferences, models, UI, hardware or disk stores are used. Gates model
delayed actor replies; this proves method ordering, not live actor latency.
Pass --ref COMMIT to compare the exact historical production method bodies.
"""

import argparse
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--ref")
parser.add_argument("--expect-atomicity-gap", action="store_true")
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
export_start = source.index("    func makeBackupDocument() async throws -> AppBackupDocument {")
export = source[export_start:source.index("    func encode(", export_start)]
restore_start = source.index("    func restore(_ document: AppBackupDocument) async throws {")
restore = source[restore_start:source.index("    func suggestedFilename(", restore_start)]
has_idle_reply = "await PrivateAIIntegrationService.idleUnloader.settingsChanged()" in restore

swift = r'''
import Foundation

struct Payload { var owner: String; var privateAIIdleUnload: Int? }
struct Schema { static let current = Self(); var valid = true }
struct AppBackupDocument {
    var schemaVersion: Schema = .current
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
    var dictationPromptProfiles: [String] = []
    var appPromptBindings: [String] = []
    func makeBackupPayload() -> Payload { .init(owner: owner, privateAIIdleUnload: privateAIIdleUnload) }
    func restore(from payload: Payload, promptProfiles: [String], appPromptBindings: [String]) {
        owner = payload.owner
        if let idle = payload.privateAIIdleUnload { privateAIIdleUnload = idle }
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
enum ProbeFailure: Error { case invalid }
actor PronunciationDictionaryStore {
    static let shared = PronunciationDictionaryStore()
    var profiles = ["original"]
    var reject = false
    var exportGate: Gate?
    func setup(reject: Bool = false, exportGate: Gate? = nil) {
        profiles = ["original"]; self.reject = reject; self.exportGate = exportGate
    }
    func allProfiles() async -> [String] {
        let snapshot = profiles
        if let gate = exportGate { exportGate = nil; await gate.pause() }
        return snapshot
    }
    func replaceAllProfiles(_ profiles: [String]) throws {
        if reject { throw ProbeFailure.invalid }
        self.profiles = profiles
    }
}
@MainActor final class TranscriptionHistoryStore {
    static let shared = TranscriptionHistoryStore()
    var history = ["original"]
    var loaded = true
    func waitUntilLoaded() async throws { if !loaded { throw ProbeFailure.invalid } }
    func makeBackupPayload() -> [String] { history }
    func restore(from payload: [String]) { history = payload }
}
actor IdleDouble {
    var gate: Gate?
    var calls = 0
    var observedSettings: [Int] = []
    func setup(gate: Gate? = nil) { self.gate = gate; calls = 0; observedSettings = [] }
    func settingsChanged() async {
        calls += 1
        if let gate { self.gate = nil; await gate.pause() }
        observedSettings.append(await SettingsStore.shared.privateAIIdleUnload)
    }
    func count() -> Int { calls }
    func observations() -> [Int] { observedSettings }
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
    func validate(_ document: AppBackupDocument) throws {
        if !document.schemaVersion.valid { throw ProbeFailure.invalid }
    }
    EXPORT
    RESTORE
}
@MainActor func expect(_ condition: Bool, _ message: String) {
    if !condition { fatalError("FAIL: " + message) }
    print("PASS: " + message)
}
@MainActor func reset(gate: Gate? = nil) async {
    SettingsStore.shared.owner = "original"
    SettingsStore.shared.privateAIIdleUnload = 30
    SettingsStore.shared.dictationPromptProfiles = []
    SettingsStore.shared.appPromptBindings = []
    TranscriptionHistoryStore.shared.history = ["original"]
    TranscriptionHistoryStore.shared.loaded = true
    NotificationCenter.default.snapshots = []
    NotificationCenter.default.onPost = nil
    await PronunciationDictionaryStore.shared.setup()
    await PrivateAIIntegrationService.idleUnloader.setup(gate: gate)
}
func awaitGate(_ gate: Gate) async {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await gate.entered) {
        if ContinuousClock.now > deadline { fatalError("Timed out waiting for actor gate") }
        await Task.yield()
    }
}
@MainActor func document(_ owner: String, idle: Int?) -> AppBackupDocument {
    .init(settings: .init(owner: owner, privateAIIdleUnload: idle), transcriptionHistory: [owner], pronunciationProfiles: [owner])
}
@main struct Run {
    @MainActor static func main() async throws {
        let service = BackupService()
        let hasIdleReply = ProcessInfo.processInfo.arguments.contains("idle-reply")
        let expectGap = ProcessInfo.processInfo.arguments.contains("expect-gap")
        // The second import can skip the idle await either because its field is
        // legacy/absent or because it matches the first import's restored value.
        for secondIdle in [nil, Optional(60)] {
            let gate = Gate()
            await reset(gate: hasIdleReply ? gate : nil)
            let first = Task { try await service.restore(document("A", idle: 60)) }
            if hasIdleReply { await awaitGate(gate) } else { try await first.value }
            let exported = try await service.makeBackupDocument()
            let exportMatches = exported.settings.owner == "A" && exported.transcriptionHistory == ["A"]
            expect(exportMatches != expectGap, "interleaved export atomicity (expected gap=\(expectGap), settings=\(exported.settings.owner), History=\(exported.transcriptionHistory))")
            try await service.restore(document("B", idle: secondIdle))
            await gate.release()
            try await first.value
            let restoreMatches = SettingsStore.shared.owner == "B" && TranscriptionHistoryStore.shared.history == ["B"]
            expect(restoreMatches != expectGap, "overlapping restore atomicity (expected gap=\(expectGap), second idle=\(String(describing: secondIdle)), settings=\(SettingsStore.shared.owner), History=\(TranscriptionHistoryStore.shared.history))")
            expect(NotificationCenter.default.snapshots.allSatisfy { $0.1 == [$0.0] } != expectGap, "synchronous restore observer atomicity")
        }
        for (idle, expectedCalls) in [(nil, 0), (Optional(30), 0), (Optional(60), 1), (Optional(0), 1)] {
            await reset()
            try await service.restore(document("field", idle: idle))
            let calls = await PrivateAIIntegrationService.idleUnloader.count()
            expect(calls == (hasIdleReply ? expectedCalls : 0), "only changed present idle values notify service (idle=\(String(describing: idle)))")
            expect(SettingsStore.shared.privateAIIdleUnload == (idle ?? 30), "absent idle preserves current setting")
        }
        if hasIdleReply {
            let gate = Gate()
            await reset(gate: gate)
            let task = Task { try await service.restore(document("A", idle: 60)) }
            await awaitGate(gate)
            SettingsStore.shared.owner = "manual-edit"
            SettingsStore.shared.privateAIIdleUnload = 0
            task.cancel()
            await gate.release()
            try await task.value
            expect(SettingsStore.shared.owner == "manual-edit" && TranscriptionHistoryStore.shared.history == ["A"], "cancelled timer reply cannot replace settings/History after commit")
            let observations = await PrivateAIIntegrationService.idleUnloader.observations()
            expect(observations == [0], "timer rescheduling reads the latest setting, not the old backup value")
            await reset()
            NotificationCenter.default.onPost = { SettingsStore.shared.privateAIIdleUnload = 0 }
            try await service.restore(document("notice", idle: 60))
            let noticeSettings = await PrivateAIIntegrationService.idleUnloader.observations()
            expect((noticeSettings == [0]) != expectGap, "timer respects synchronous observer preference changes (expected gap=\(expectGap))")
        }
        await reset()
        await PronunciationDictionaryStore.shared.setup(reject: true)
        do { try await service.restore(document("invalid", idle: 60)); fatalError("Expected pronunciation-store failure") } catch ProbeFailure.invalid {}
        let failureCalls = await PrivateAIIntegrationService.idleUnloader.count()
        expect(SettingsStore.shared.owner == "original" && TranscriptionHistoryStore.shared.history == ["original"] && failureCalls == 0 && NotificationCenter.default.snapshots.isEmpty, "failed pronunciation restore does not change settings/History/timer or notify")
        await reset()
        var invalid = document("invalid", idle: 60); invalid.schemaVersion.valid = false
        do { try await service.restore(invalid); fatalError("Expected validation failure") } catch ProbeFailure.invalid {}
        expect(SettingsStore.shared.owner == "original" && TranscriptionHistoryStore.shared.history == ["original"], "schema rejection leaves existing state unchanged")
        TranscriptionHistoryStore.shared.loaded = false
        do { _ = try await service.makeBackupDocument(); fatalError("Expected load failure") } catch ProbeFailure.invalid {}
        expect(SettingsStore.shared.owner == "original", "failed History load does not mutate settings")
        // Existing cross-actor snapshot limit, not introduced by the idle await:
        // a pronunciation snapshot may precede a complete intervening restore.
        await reset()
        let exportGate = Gate()
        await PronunciationDictionaryStore.shared.setup(exportGate: exportGate)
        let exportTask = Task { try await service.makeBackupDocument() }
        await awaitGate(exportGate)
        try await service.restore(document("B", idle: nil))
        await exportGate.release()
        let snapshot = try await exportTask.value
        expect(snapshot.transcriptionHistory == [snapshot.settings.owner], "export settings/History remain consistent across pronunciation actor reply")
        if snapshot.pronunciationProfiles != [snapshot.settings.owner] {
            print("KNOWN PREEXISTING LIMITATION: pronunciation snapshot differs from settings/History; total backup snapshot is not atomic")
        } else {
            print("INFO: pronunciation and settings/History snapshots are also consistent")
        }
        print("Backup concurrency production-method probe completed")
    }
}
'''.replace("    EXPORT", export).replace("    RESTORE", restore)

with tempfile.TemporaryDirectory(prefix="fluidvoice-backup-concurrency-") as directory:
    swift_path = Path(directory) / "Probe.swift"
    binary = Path(directory) / "probe"
    swift_path.write_text(swift)
    subprocess.run(
        ["xcrun", "swiftc", "-parse-as-library", str(swift_path), "-o", str(binary)],
        cwd=repo, env=environment, check=True, timeout=60,
    )
    flags = (["idle-reply"] if has_idle_reply else []) + (["expect-gap"] if args.expect_atomicity_gap else [])
    subprocess.run([str(binary), *flags], env=environment, check=True, timeout=20)
