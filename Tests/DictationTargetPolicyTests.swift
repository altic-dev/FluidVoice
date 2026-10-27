import Foundation

@main
enum DictationTargetPolicyTests {
    private struct Case {
        let name: String
        let enabled: Bool
        let focused: Int32?
        let original: Int32?
        let stillFocused: Bool
        let expectedPID: Int32?
        let restores: Bool
    }

    static func main() {
        let cases: [Case] = [
            .init(name: "off follows app B", enabled: false, focused: 200, original: 100, stillFocused: false, expectedPID: 200, restores: false),
            .init(name: "on restores app A", enabled: true, focused: 200, original: 100, stillFocused: false, expectedPID: 100, restores: true),
            .init(name: "off follows another field in A", enabled: false, focused: 100, original: 100, stillFocused: false, expectedPID: 100, restores: false),
            .init(name: "on restores original field in A", enabled: true, focused: 100, original: 100, stillFocused: false, expectedPID: 100, restores: true),
            .init(name: "already focused needs no restore", enabled: true, focused: 100, original: 100, stillFocused: true, expectedPID: 100, restores: false),
            .init(name: "off works without recording context", enabled: false, focused: 200, original: nil, stillFocused: false, expectedPID: 200, restores: false),
            .init(name: "overlay recovers saved target", enabled: false, focused: 999, original: 100, stillFocused: false, expectedPID: 100, restores: true),
            .init(name: "unknown focus recovers saved target", enabled: false, focused: nil, original: 100, stillFocused: false, expectedPID: 100, restores: true),
            .init(name: "invalid focus is not a destination", enabled: false, focused: 0, original: 100, stillFocused: false, expectedPID: 100, restores: true),
            .init(name: "missing target does not invent a PID", enabled: true, focused: nil, original: nil, stillFocused: false, expectedPID: nil, restores: true),
        ]
        for test in cases {
            let result = DictationTargetPolicy.resolve(
                returnToStartingField: test.enabled,
                focusedPID: test.focused,
                ownPID: 999,
                originalPID: test.original,
                originalFieldIsFocused: test.stillFocused
            )
            precondition(result.pid == test.expectedPID && result.shouldRestoreOriginalFocus == test.restores, test.name)
        }
        print("PASS: \(cases.count) dictation destination cases, including app switches, field switches, overlays and missing focus")
    }
}
