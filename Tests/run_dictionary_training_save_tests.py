#!/usr/bin/env python3
"""Run production Swift method bodies against deterministic, gated dependency fakes.

This avoids loading ASR models or the app UI. It verifies method control flow,
not the real provider, disk store, or SwiftUI integration.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
selected_toolchain = subprocess.check_output(["xcode-select", "-p"], text=True).strip()
developer_dir = os.environ.get("DEVELOPER_DIR", selected_toolchain)
if ".app/Contents/Developer" not in developer_dir or not (Path(developer_dir) / "usr/bin/xcodebuild").is_file():
    raise SystemExit("Set DEVELOPER_DIR to an installed full Xcode before running this test.")
os.environ["DEVELOPER_DIR"] = developer_dir

source = (repo / 'Sources/Fluid/UI/CustomDictionaryView.swift').read_text()
method = source[source.index('    private func addTrainedReplacement() async {'):source.index('    private func removeTrainingVariant(')].replace('private func addTrainedReplacement', 'func addTrainedReplacement')
merge = source[source.index('enum CustomDictionaryTrainingMerge {'):source.index('private struct ReplacementConfirmation:')]
settings = (repo / 'Sources/Fluid/Persistence/SettingsStore.swift').read_text()
entry_start = settings.rfind('\n', 0, settings.index('struct CustomDictionaryEntry:')) + 1
entry = settings[entry_start:settings.index('    var vocabularyBoostingEnabled:')]
swift = r'''
import Foundation
final class SettingsStore: @unchecked Sendable {
    static let shared = SettingsStore()
    var customDictionaryEntries: [CustomDictionaryEntry] = []
    ENTRY
}
struct PronunciationEnrollmentCapture: Equatable, Sendable { var modelKey = "test" }
enum DictionaryMatcherExperiment {
    static var sharedFeaturesEnabled = true
    static var generation = UUID()
}
struct VoiceTrainingAliasFilter {
    struct Result { let accepted: [String]; let rejected: [String] = []; let lookupAvailable = true }
    static func filter(_ values: [String]) async -> Result { Result(accepted: values) }
}
final class DebugLogger {
    static let shared = DebugLogger()
    func info(_ message: String, source: String) {}
    func error(_ message: String, source: String) {}
}
actor Gate {
    var entered = false
    var waiting: CheckedContinuation<Void, Never>?
    func pause() async { entered = true; await withCheckedContinuation { waiting = $0 } }
    func release() { waiting?.resume(); waiting = nil }
}
actor PronunciationDictionaryStore {
    static let shared = PronunciationDictionaryStore()
    var gate: Gate?
    var lateGate: Gate?
    var forceFailure = false
    var writes: [UUID] = []
    func configure(gate: Gate?, lateGate: Gate? = nil, failure: Bool = false) {
        self.gate = gate; self.lateGate = lateGate; forceFailure = failure; writes = []
    }
    func upsert(dictionaryEntryID: UUID, label: String, modelKey: String, enrollments: [PronunciationEnrollmentCapture], automaticMatchingEnabled: Bool, canPersist: @Sendable () -> Bool) async throws {
        guard canPersist() else { throw CancellationError() }
        if let gate { await gate.pause() }
        guard canPersist(), !forceFailure else { throw CancellationError() }
        writes.append(dictionaryEntryID)
        if let lateGate { await lateGate.pause() }
    }
}
MERGE
@MainActor final class SaveHarness {
    var canAddTrainedReplacement = true
    var isTrainingProcessing = false
    var trainingSaveID: UUID?
    var normalizedTrainingReplacement = "FluidVoice"
    var trainingPronunciationEnrollments = [PronunciationEnrollmentCapture()]
    var activePronunciationMatching = true
    var trainingVariants = ["fluid boys"]
    var pronunciationEnabled = true
    var trainingHasError = false
    var trainingStatusMessage = ""
    var entries: [SettingsStore.CustomDictionaryEntry] = []
    var wizardSavedWord = ""
    enum Step { case recording, saved }
    var wizardStep = Step.recording
    var writes = 0
    func saveEntries() { writes += 1; SettingsStore.shared.customDictionaryEntries = entries }
    func resetTraining() { trainingSaveID = nil; isTrainingProcessing = false; trainingPronunciationEnrollments = []; trainingVariants = [] }
    METHOD
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
@main struct Runner {
    @MainActor static func main() async throws {
        typealias Entry = SettingsStore.CustomDictionaryEntry
        var passes = 0
        func baseline() -> [Entry] {
            [Entry(triggers: ["fluid voice"], replacement: "FluidVoice"), Entry(triggers: ["other"], replacement: "Other")]
        }
        func reset(_ entries: [Entry]) -> SaveHarness {
            SettingsStore.shared.customDictionaryEntries = entries
            DictionaryMatcherExperiment.sharedFeaturesEnabled = true
            DictionaryMatcherExperiment.generation = UUID()
            return SaveHarness()
        }
        func waitForGate(_ gate: Gate) async { while !(await gate.entered) { await Task.yield() } }
        // Production save and merge retain existing profile UUID and save new entries under the written UUID.
        for existing in [true, false] {
            let original = existing ? baseline() : []
            let view = reset(original)
            await PronunciationDictionaryStore.shared.configure(gate: nil)
            await view.addTrainedReplacement()
            let profiles = await PronunciationDictionaryStore.shared.writes
            check(view.writes == 1 && view.wizardStep == .saved, "Normal save must succeed")
            check(profiles == [SettingsStore.shared.customDictionaryEntries.first!.id], "Profile and text rule UUID must agree")
            if existing { check(profiles.first == original[0].id, "Retraining must preserve original UUID") }
            check(!view.isTrainingProcessing, "Successful save must release processing state")
            passes += 1
        }
        // Deterministic interleavings while production save is suspended in profile persistence.
        for mutation in 0..<6 {
            let original = baseline()
            let view = reset(original)
            let gate = Gate()
            await PronunciationDictionaryStore.shared.configure(gate: gate)
            let save = Task { await view.addTrainedReplacement() }
            await waitForGate(gate)
            var latest = original
            switch mutation {
            case 0: latest.append(Entry(triggers: ["new"], replacement: "New"))
            case 1: latest.removeLast()
            case 2: latest[1].triggers = ["updated"]
            case 3: latest = [Entry(triggers: ["imported"], replacement: "Imported")]
            case 4: latest.removeFirst()
            default: latest[0].replacement = "Edited"
            }
            SettingsStore.shared.customDictionaryEntries = latest
            await gate.release()
            await save.value
            check(SettingsStore.shared.customDictionaryEntries == latest, "Concurrent edit must survive mutation \(mutation)")
            check(view.writes == 0, "Stale save must never publish its list")
            check(view.trainingHasError && view.trainingStatusMessage.contains("dictionary changed"), "Conflict must show retry")
            check(!view.isTrainingProcessing && view.trainingSaveID == nil, "Conflict must release processing state")
            check(!view.trainingPronunciationEnrollments.isEmpty && !view.trainingVariants.isEmpty, "Conflict must retain captures")
            let writes = await PronunciationDictionaryStore.shared.writes
            check(writes.isEmpty, "Persistence guard must reject changed dictionary")
            passes += 1
        }
        // An edit after the profile write but before the MainActor resumes must still preserve the dictionary.
        do {
            let original = baseline()
            let view = reset(original)
            let lateGate = Gate()
            await PronunciationDictionaryStore.shared.configure(gate: nil, lateGate: lateGate)
            let save = Task { await view.addTrainedReplacement() }
            await waitForGate(lateGate)
            let latest = [original[1]]
            SettingsStore.shared.customDictionaryEntries = latest
            await lateGate.release(); await save.value
            check(SettingsStore.shared.customDictionaryEntries == latest && view.writes == 0, "Post-write edit must survive")
            check(view.trainingHasError && !view.isTrainingProcessing, "Post-write conflict must be retryable")
            passes += 1
        }
        // Stale failing saves cannot clear or replace the UI state belonging to a newer save.
        do {
            let view = reset(baseline())
            let gate = Gate()
            await PronunciationDictionaryStore.shared.configure(gate: gate, failure: true)
            let save = Task { await view.addTrainedReplacement() }
            await waitForGate(gate)
            let newSaveID = UUID()
            view.trainingSaveID = newSaveID
            view.trainingStatusMessage = "new save"
            await gate.release(); await save.value
            check(view.trainingSaveID == newSaveID && view.isTrainingProcessing, "Stale failure must preserve newer activity")
            check(view.trainingStatusMessage == "new save" && !view.trainingHasError, "Stale failure must preserve newer UI")
            check(view.writes == 0, "Stale failing save must not write dictionary")
            passes += 1
        }
        // Store failures are visible and leave captures available for retry.
        do {
            let original = baseline()
            let view = reset(original)
            await PronunciationDictionaryStore.shared.configure(gate: nil, failure: true)
            await view.addTrainedReplacement()
            check(view.trainingHasError && !view.isTrainingProcessing && view.trainingSaveID == nil, "Failure must release processing state")
            check(view.writes == 0 && SettingsStore.shared.customDictionaryEntries == original, "Failure must preserve dictionary")
            check(!view.trainingPronunciationEnrollments.isEmpty, "Failure must retain captures")
            passes += 1
        }
        // Existing text-only training remains independent of the profile store.
        do {
            let view = reset([])
            view.activePronunciationMatching = false
            await PronunciationDictionaryStore.shared.configure(gate: nil, failure: true)
            await view.addTrainedReplacement()
            check(view.writes == 1 && view.wizardStep == .saved, "Text-only training must save")
            check(await PronunciationDictionaryStore.shared.writes.isEmpty, "Text-only training must not write profiles")
            passes += 1
        }
        print("PASS \(passes) dictionary save scenarios using the production save method and merge code")
    }
}
'''.replace('ENTRY', entry).replace('MERGE', merge).replace('METHOD', method)
swift = swift.replace('check(await PronunciationDictionaryStore.shared.writes.isEmpty,', 'let textOnlyWrites = await PronunciationDictionaryStore.shared.writes\n            check(textOnlyWrites.isEmpty,')
isolation_swift = r'''
import Foundation
@MainActor enum SettingsStore {
    ENTRY
}
actor SnapshotReader {
    func validates(_ entries: [SettingsStore.CustomDictionaryEntry]) throws -> Bool {
        let encoded = try JSONEncoder().encode(entries)
        let decoded = try JSONDecoder().decode([SettingsStore.CustomDictionaryEntry].self, from: encoded)
        let canPersist: @Sendable () -> Bool = { decoded == entries }
        return canPersist() && Set(decoded).count == entries.count
    }
}
@main struct IsolationRunner {
    @MainActor static func main() async throws {
        let original = [SettingsStore.CustomDictionaryEntry(triggers: ["fluid voice"], replacement: "FluidVoice")]
        let matches = try await SnapshotReader().validates(original)
        precondition(matches, "Dictionary values must retain identity and content across actors")
        print("PASS dictionary snapshot Codable, Hashable and Equatable under Swift 6 MainActor defaults")
    }
}
'''.replace('ENTRY', entry)
with tempfile.TemporaryDirectory(prefix="fluidvoice-dictionary-regression-") as directory:
    root = Path(directory)
    (root / 'dictionary-proof.swift').write_text(swift)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(root/'dictionary-proof.swift'), '-o', str(root/'dictionary-proof')], check=True)
    subprocess.run([str(root/'dictionary-proof')], check=True)
    (root / 'dictionary-isolation.swift').write_text(isolation_swift)
    subprocess.run([
        'xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6',
        '-default-isolation', 'MainActor', '-strict-concurrency=complete', '-warnings-as-errors',
        str(root/'dictionary-isolation.swift'), '-o', str(root/'dictionary-isolation'),
    ], check=True)
    subprocess.run([str(root/'dictionary-isolation')], check=True)
