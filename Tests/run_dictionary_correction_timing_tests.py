#!/usr/bin/env python3
"""Exercise production AX handlers with deterministic field/scheduler fakes.

No app, permissions, models or real-time sleeps. This checks debounce requests,
not real editor AX delivery or whether the final overlay becomes visible.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parent.parent
tracker_path = Path(sys.argv[1]) if len(sys.argv) > 1 else repo / 'Sources/Fluid/Services/AutomaticDictionaryCorrectionTracker.swift'
tracker = tracker_path.read_text()
settings = (repo / 'Sources/Fluid/Persistence/SettingsStore.swift').read_text()

def block(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

selection = block(tracker, '    func handleObservedSelectionChange()')
value = block(tracker, '    func handleObservedValueChange()')
delay = block(settings, '    enum AutomaticDictionaryPromptDelay:')
swift = r'''
import Foundation
struct DictionaryCorrectionExample {}
struct DictionaryLearningAudioEvidence {}
struct DictionaryNegativeCorrection {}
DETECTOR
@MainActor final class SettingsStore {
    static let shared = SettingsStore()
    DELAY
    var automaticDictionaryPromptDelay: AutomaticDictionaryPromptDelay = .three
}
@MainActor final class DictionaryVoiceSpellingLearner {
    static let shared = DictionaryVoiceSpellingLearner()
    func cancel(recordingID: UUID) {}
}
struct Recording { let id = UUID() }
@MainActor final class Harness {
    struct PendingCorrection {
        let id = UUID()
        let beforeValue: String
        var afterValue: String
        let insertedRange: NSRange
        var correctedRange: NSRange?
    }
    struct Session {
        var element = 0
        var learningRecording: Recording?
        var lastValue = "claud"
        var lastSelection = NSRange(location: 5, length: 0)
        var insertedRange = NSRange(location: 0, length: 5)
        var pendingCorrection: PendingCorrection?
    }
    static var selected: NSRange? = NSRange(location: 5, length: 0)
    static var value = "claud"
    static let maximumFieldLength = 100_000
    static var inactivityFallbackNanoseconds: UInt64 { SettingsStore.shared.automaticDictionaryPromptDelay.inactivityNanoseconds }
    static var completionSignalDelayNanoseconds: UInt64 { SettingsStore.shared.automaticDictionaryPromptDelay.completionNanoseconds }
    static func selectedRange(of element: Int) -> NSRange? { selected }
    static func stringValue(of element: Int) -> String? { value }
    var session: Session? = Session()
    var scheduled: [(UUID, UInt64)] = []
    func scheduleCandidateEvaluation(for id: UUID?, after delay: UInt64) {
        if let id { scheduled.append((id, delay)) }
    }
    func cancel() { session = nil }
    VALUE
    SELECTION
}
@main struct Checks {
    @MainActor static func main() {
        for delay in SettingsStore.AutomaticDictionaryPromptDelay.allCases {
            SettingsStore.shared.automaticDictionaryPromptDelay = delay
            let h = Harness()
            // A real text edit must schedule even when the caret stays unchanged.
            Harness.value = "claude"
            Harness.selected = NSRange(location: 5, length: 0)
            h.handleObservedValueChange()
            precondition(h.scheduled.count == 1)
            precondition(h.scheduled.last!.1 == delay.inactivityNanoseconds)
            let id = h.scheduled.last!.0
            for _ in 0..<100 { h.handleObservedSelectionChange() }
            precondition(h.scheduled.count == 1, "Duplicate notifications must not postpone evaluation")
            // Missing AX selection also must not replace the deadline or baseline.
            Harness.selected = nil
            h.handleObservedSelectionChange()
            precondition(h.scheduled.count == 1)
            // A genuine move inside the word waits for inactivity.
            Harness.selected = NSRange(location: 2, length: 0)
            h.handleObservedSelectionChange()
            precondition(h.scheduled.count == 2 && h.scheduled.last!.1 == delay.inactivityNanoseconds)
            // Moving outside signals completion, no slower than the chosen delay.
            Harness.selected = NSRange(location: 20, length: 0)
            h.handleObservedSelectionChange()
            precondition(h.scheduled.count == 3 && h.scheduled.last!.1 == min(delay.inactivityNanoseconds, 1_000_000_000))
            precondition(h.scheduled.allSatisfy { $0.0 == id })
            h.handleObservedSelectionChange()
            precondition(h.scheduled.count == 3)
            // More typing still resets the inactivity timer after duplicate events.
            Harness.value = "claudex"
            h.handleObservedValueChange()
            precondition(h.scheduled.count == 4 && h.scheduled.last!.1 == delay.inactivityNanoseconds)
            h.cancel()
            h.handleObservedSelectionChange()
            h.handleObservedValueChange()
            precondition(h.scheduled.count == 4)
        }
        // Track caret moves before an edit, so the first duplicate is ignored too.
        let h = Harness()
        Harness.selected = NSRange(location: 2, length: 0)
        h.handleObservedSelectionChange()
        precondition(h.session!.lastSelection == Harness.selected && h.scheduled.isEmpty)
        h.session!.pendingCorrection = .init(beforeValue: "claud", afterValue: "claude", insertedRange: .init(location: 0, length: 5), correctedRange: .init(location: 0, length: 6))
        h.handleObservedSelectionChange()
        precondition(h.scheduled.isEmpty)
        print("PASS: production handlers preserve deadlines across duplicate/missing AX events; real edits/moves, all delays, completion cap, cancellation and pre-edit baseline")
    }
}
'''
swift = swift.replace('DETECTOR', (repo / 'Sources/Fluid/Services/AutomaticDictionaryCorrectionDetector.swift').read_text() + (repo / 'Sources/Fluid/Services/DictionaryCorrectionEditPolicy.swift').read_text()).replace('DELAY', delay).replace('VALUE', value).replace('SELECTION', selection)
selected = os.environ.get('DEVELOPER_DIR', subprocess.check_output(['xcode-select', '-p'], text=True).strip())
if '.app/Contents/Developer' not in selected:
    raise SystemExit('Select a full Xcode toolchain before running this test')
env = dict(os.environ, DEVELOPER_DIR=selected)
with tempfile.TemporaryDirectory(prefix='fluid-correction-timing-') as tmp:
    path = Path(tmp) / 'main.swift'
    path.write_text(swift)
    binary = Path(tmp) / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(path), '-o', str(binary)], check=True, env=env)
    subprocess.run([str(binary)], check=True, env=env)
