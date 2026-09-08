import Carbon.HIToolbox
import CoreGraphics
@testable import FluidVoice_Debug
import XCTest

/// Covers the keycode-typing path used for remote-desktop targets, where clipboard
/// redirection is unusable because the client only re-advertises its clipboard after a focus
/// change.
final class RemoteDesktopTypingTests: XCTestCase {
    /// A deliberately small stand-in layout, so these tests do not depend on whatever keyboard
    /// the machine running them happens to have selected.
    private let asciiish: [Character: RemoteDesktopKeyStroke] = [
        "a": .init(keyCode: 0, needsShift: false),
        "A": .init(keyCode: 0, needsShift: true),
        "b": .init(keyCode: 11, needsShift: false),
        " ": .init(keyCode: 49, needsShift: false),
        "'": .init(keyCode: 39, needsShift: false),
        "\"": .init(keyCode: 39, needsShift: true),
        "-": .init(keyCode: 27, needsShift: false),
        ".": .init(keyCode: 47, needsShift: false),
    ]

    /// `.strokes` payload, or nil when the plan reported unmappable characters.
    private func strokes(_ text: String) -> [RemoteDesktopKeyStroke]? {
        switch RemoteDesktopKeyMapResolver.plan(for: text, map: self.asciiish) {
        case let .strokes(s): return s
        case .unmappable: return nil
        }
    }

    private func unmappable(_ text: String) -> [Character]? {
        switch RemoteDesktopKeyMapResolver.plan(for: text, map: self.asciiish) {
        case .strokes: return nil
        case let .unmappable(c): return c
        }
    }

    // MARK: - Transliteration

    func testSmartPunctuationIsTransliteratedToASCII() {
        XCTAssertEqual(RemoteDesktopKeyMapResolver.transliterate("it\u{2019}s"), "it's")
        XCTAssertEqual(RemoteDesktopKeyMapResolver.transliterate("\u{201C}quoted\u{201D}"), "\"quoted\"")
        XCTAssertEqual(RemoteDesktopKeyMapResolver.transliterate("a\u{2014}b"), "a--b")
        XCTAssertEqual(RemoteDesktopKeyMapResolver.transliterate("a\u{2013}b"), "a-b")
        XCTAssertEqual(RemoteDesktopKeyMapResolver.transliterate("wait\u{2026}"), "wait...")
        XCTAssertEqual(RemoteDesktopKeyMapResolver.transliterate("a\u{00A0}b"), "a b")
        XCTAssertEqual(RemoteDesktopKeyMapResolver.transliterate("\u{2022} item"), "- item")
    }

    func testTransliterationLeavesPlainTextUntouched() {
        let plain = "Can you send me the quarterly report by Friday?"
        XCTAssertEqual(RemoteDesktopKeyMapResolver.transliterate(plain), plain)
    }

    func testTransliterationDoesNotInventReplacementsForRealNonASCII() {
        // Accented letters and emoji have no unambiguous ASCII spelling, so they must survive
        // untouched and be reported as unmappable rather than silently mangled.
        XCTAssertEqual(RemoteDesktopKeyMapResolver.transliterate("caf\u{00E9}"), "caf\u{00E9}")
        XCTAssertEqual(RemoteDesktopKeyMapResolver.transliterate("hi \u{1F600}"), "hi \u{1F600}")
    }

    // MARK: - Stroke mapping

    func testStrokesSpellTheTextAndCarryShiftWhereNeeded() throws {
        let strokes = try XCTUnwrap(
            self.strokes("aAb")
        )
        XCTAssertEqual(strokes.map(\.keyCode), [0, 0, 11])
        XCTAssertEqual(strokes.map(\.needsShift), [false, true, false])
    }

    func testReturnAndTabAreNeverTypedIntoARemoteSession() throws {
        // Return commits and Tab moves focus. Every other key this path can press only inserts
        // a character, so refusing these bounds the worst case to wrong text rather than an
        // action taken inside the guest.
        for activating in ["a\nb", "a\r\nb", "a\tb", "a\rb"] {
            XCTAssertNil(
                self.strokes(activating),
                "\(activating.debugDescription) must not be typed"
            )
        }
        XCTAssertEqual(self.unmappable("a\nb"), ["\n"])
        XCTAssertEqual(self.unmappable("a\r\nb"), ["\r\n"])
        XCTAssertEqual(self.unmappable("a\tb"), ["\t"])
    }

    func testMappingIsAllOrNothing() {
        // A partially typed transcript is worse than none, so one unmappable character must
        // abort the whole attempt and let the caller fall back.
        XCTAssertNil(self.strokes("caf\u{00E9}"))
        XCTAssertNil(self.strokes("a\u{1F600}b"))
        XCTAssertNotNil(self.strokes("ab a"))
    }

    func testEmptyTextMapsToNoStrokes() throws {
        let strokes = try XCTUnwrap(self.strokes(""))
        XCTAssertTrue(strokes.isEmpty)
    }

    func testTransliteratedTextBecomesFullyTypeable() {
        // The point of transliteration: text that would otherwise abort now types cleanly.
        // Restricted to letters present in `asciiish` so this exercises transliteration
        // rather than the toy fixture's coverage.
        let raw = "ab\u{2019}a \u{201C}ba\u{201D}\u{2026}"
        XCTAssertNil(self.strokes(raw))
        let normalized = RemoteDesktopKeyMapResolver.transliterate(raw)
        XCTAssertNotNil(self.strokes(normalized))
    }

    // MARK: - Unmappable reporting

    func testUnmappableCharactersAreReportedOnceEachInOrder() throws {
        // 'c', 'f', 'l', 'i' and 'r' are absent from the toy fixture on purpose - the point is
        // first-occurrence order and de-duplication, not which letters a real layout has.
        let found = try XCTUnwrap(self.unmappable("caf\u{00E9} \u{00E9}clair \u{1F600}"))
        XCTAssertEqual(found, ["c", "f", "\u{00E9}", "l", "i", "r", "\u{1F600}"])
    }

    func testActivatingWhitespaceIsReportedAsUnmappable() {
        XCTAssertEqual(
            self.unmappable("a\nb\tb\r"),
            ["\n", "\t", "\r"],
            "Activating keys are reported so the caller falls back rather than pressing them"
        )
    }

    // MARK: - Layout resolution

    // MARK: - ANSI reference map

    func testReferenceMapUsesStandardANSIPositions() {
        let map = RemoteDesktopKeyMapResolver.ansiKeyMap
        XCTAssertEqual(map["a"], RemoteDesktopKeyStroke(keyCode: 0, needsShift: false))
        XCTAssertEqual(map["A"], RemoteDesktopKeyStroke(keyCode: 0, needsShift: true))
        XCTAssertEqual(map["v"], RemoteDesktopKeyStroke(keyCode: 9, needsShift: false))
        XCTAssertEqual(map["1"], RemoteDesktopKeyStroke(keyCode: 18, needsShift: false))
        XCTAssertEqual(map["!"], RemoteDesktopKeyStroke(keyCode: 18, needsShift: true))
        // 5 and 6 sit at 23 and 22 respectively on ANSI, which is easy to transpose by hand.
        XCTAssertEqual(map["5"], RemoteDesktopKeyStroke(keyCode: 23, needsShift: false))
        XCTAssertEqual(map["6"], RemoteDesktopKeyStroke(keyCode: 22, needsShift: false))
        XCTAssertEqual(map[" "], RemoteDesktopKeyStroke(keyCode: CGKeyCode(kVK_Space), needsShift: false))
    }

    func testReferenceMapCoversPrintableASCIIExactly() {
        let map = RemoteDesktopKeyMapResolver.ansiKeyMap
        for scalar in UInt32(0x20)...UInt32(0x7E) {
            let character = Character(UnicodeScalar(scalar)!)
            XCTAssertNotNil(
                map[character],
                "ANSI reference must type U+\(String(scalar, radix: 16, uppercase: true)) '\(character)'"
            )
        }
        XCTAssertEqual(map.count, 0x7E - 0x20 + 1, "and nothing beyond printable ASCII")
    }

    func testReferenceMapExcludesCharactersTheGuestWouldMistranslate() {
        // Deliberately independent of the machine's active input source: the guest applies its
        // own layout to the positions it receives, so a locally-typeable Cyrillic or accented
        // character must not be offered - it would silently produce something else in the guest.
        let map = RemoteDesktopKeyMapResolver.ansiKeyMap
        for absent in ["\u{00E9}", "\u{0439}", "\u{1F600}", "\u{20AC}", "\u{00A3}"] {
            XCTAssertNil(map[Character(absent)], "\(absent) must fall to the lossless path")
        }
    }

    func testReferenceMapNeverUsesKeypadOrISOSectionPositions() {
        // Keypad codes carry a different scan-code class than a person typing the same glyph,
        // and ANSI Windows maps the ISO section position to backslash.
        let map = RemoteDesktopKeyMapResolver.ansiKeyMap
        XCTAssertFalse(map.values.contains { (65...92).contains($0.keyCode) })
        XCTAssertFalse(map.values.contains { $0.keyCode == 10 })
        XCTAssertEqual(map["*"], RemoteDesktopKeyStroke(keyCode: 28, needsShift: true))
        XCTAssertEqual(map["+"], RemoteDesktopKeyStroke(keyCode: 24, needsShift: true))
    }

    func testReferenceMapPrefersUnshiftedWhereBothReachACharacter() {
        let map = RemoteDesktopKeyMapResolver.ansiKeyMap
        XCTAssertEqual(map["a"]?.needsShift, false)
        XCTAssertEqual(map[" "]?.needsShift, false)
    }

    // MARK: - Layout agreement

    func testLayoutSafeMapKeepsOnlyPositionsBothReadingsAgreeOn() {
        // A guest may mirror the local layout (RDP's default) or be plain ANSI. Only characters
        // whose position is identical under both are safe; the rest must take the lossless path.
        let ansi = RemoteDesktopKeyMapResolver.ansiKeyMap
        let safe = RemoteDesktopKeyMapResolver.currentSnapshot().typable

        XCTAssertFalse(safe.isEmpty, "a Latin layout must retain a usable set")
        for (character, stroke) in safe {
            XCTAssertEqual(stroke, ansi[character], "a safe stroke must match the ANSI position")
        }
        XCTAssertLessThanOrEqual(safe.count, ansi.count, "agreement can only narrow the set")

        let local = RemoteDesktopKeyMapResolver.localLayoutMap()
        if local.isEmpty == false {
            for (character, stroke) in safe {
                XCTAssertEqual(stroke, local[character], "a safe stroke must match the local position too")
            }
        }
    }

    func testLocalLayoutMapIsEmptyForMissingData() {
        XCTAssertTrue(RemoteDesktopKeyMapResolver.localLayoutMap(layoutData: nil, keyboardType: 0).isEmpty)
        XCTAssertTrue(RemoteDesktopKeyMapResolver.localLayoutMap(layoutData: Data(), keyboardType: 0).isEmpty)
    }

    // MARK: - Paste chord position

    func testPasteChordKeyMustSurviveLayoutAgreement() {
        // Forwarded as a scan code and translated by the guest, so it is subject to the same
        // ambiguity as the typing map: it must be a position both readings agree on, or nil.
        let safe = RemoteDesktopKeyMapResolver.currentSnapshot().typable
        let local = RemoteDesktopKeyMapResolver.localLayoutMap()
        let resolved = RemoteDesktopKeyMapResolver.layoutSafePasteKeyCode(local: local, safe: safe)
        if safe["v"] != nil {
            XCTAssertEqual(resolved, safe["v"]?.keyCode)
            XCTAssertEqual(resolved, 9, "on an agreeing Latin layout that is the ANSI position")
        }
    }

    func testPasteChordFallsBackToAnsiOnlyForNonLatinLayouts() throws {
        let ansiV = try XCTUnwrap(RemoteDesktopKeyMapResolver.ansiKeyMap["v"])

        // A non-Latin layout has no `v` to disagree about: the guest's Latin sublayout puts it
        // where ANSI does, so the lossless paste stays available instead of inserting nothing.
        let hebrewish: [Character: RemoteDesktopKeyStroke] = ["\u{05D5}": ansiV]
        XCTAssertEqual(
            RemoteDesktopKeyMapResolver.layoutSafePasteKeyCode(local: hebrewish, safe: [:]),
            RemoteDesktopKeyMapResolver.ansiPasteKeyCode,
            "a non-Latin layout must still be able to paste"
        )

        // A Latin rearrangement does have a `v`, somewhere else. The ANSI position is a
        // different letter there, so Ctrl plus it could be an unrelated shortcut: decline.
        let dvorakish: [Character: RemoteDesktopKeyStroke] = [
            "v": RemoteDesktopKeyStroke(keyCode: 47, needsShift: false),
        ]
        XCTAssertNil(
            RemoteDesktopKeyMapResolver.layoutSafePasteKeyCode(local: dvorakish, safe: [:]),
            "a rearranged Latin layout must not press an unknown position"
        )

        // Nothing read at all establishes nothing.
        XCTAssertNil(RemoteDesktopKeyMapResolver.layoutSafePasteKeyCode(local: [:], safe: [:]))
    }

    func testLayoutSafeMapFailsClosedWhenTheLocalLayoutIsUnreadable() {
        // An unknown layout cannot establish agreement, so it must yield nothing rather than
        // falling open to the full ANSI map.
        XCTAssertTrue(RemoteDesktopKeyMapResolver.localLayoutMap(layoutData: nil, keyboardType: 0).isEmpty)
        XCTAssertTrue(RemoteDesktopKeyMapResolver.localLayoutMap(layoutData: Data(), keyboardType: 0).isEmpty)
    }

    // MARK: - Caps Lock

    func testCapsLockInvertsShiftForLettersOnly() {
        // RDP synchronises lock state to the guest, so with Caps Lock on an unshifted 'a'
        // position arrives as 'A'. Letters must invert; digits and punctuation must not.
        let map = RemoteDesktopKeyMapResolver.ansiKeyMap
        let normalPlan = RemoteDesktopKeyMapResolver.plan(for: "aA1!", map: map, capsLockActive: false)
        let lockedPlan = RemoteDesktopKeyMapResolver.plan(for: "aA1!", map: map, capsLockActive: true)
        guard case let .strokes(normal) = normalPlan,
              case let .strokes(withCaps) = lockedPlan
        else { return XCTFail("expected both plans to produce strokes") }

        XCTAssertEqual(normal.map(\.needsShift), [false, true, false, true])
        XCTAssertEqual(
            withCaps.map(\.needsShift),
            [true, false, false, true],
            "letters invert, digits and punctuation are unaffected"
        )
        XCTAssertEqual(
            withCaps.map(\.keyCode),
            normal.map(\.keyCode),
            "Caps Lock changes shift only, never the key position"
        )
    }

    func testCapsLockDoesNotAffectUnmappableReporting() {
        let map = RemoteDesktopKeyMapResolver.ansiKeyMap
        guard case let .unmappable(chars) = RemoteDesktopKeyMapResolver.plan(
            for: "caf\u{00E9}", map: map, capsLockActive: true
        ) else { return XCTFail("expected unmappable") }
        XCTAssertEqual(chars, ["\u{00E9}"])
    }

    // MARK: - Per-character delay parsing

    func testTypeDelayDefaultsAndClamps() {
        XCTAssertEqual(
            TypingService.remoteDesktopTypeDelayMicros(override: nil),
            useconds_t(TypingService.remoteDesktopTypeDelayDefaultMs * 1000)
        )
        XCTAssertEqual(TypingService.remoteDesktopTypeDelayMicros(override: NSNumber(value: 5)), 5000)
        XCTAssertEqual(TypingService.remoteDesktopTypeDelayMicros(override: NSNumber(value: 0)), 0)

        let maximum = useconds_t(TypingService.remoteDesktopTypeDelayMaximumMs * 1000)
        XCTAssertEqual(TypingService.remoteDesktopTypeDelayMicros(override: NSNumber(value: Int32.max)), maximum)
        XCTAssertEqual(TypingService.remoteDesktopTypeDelayMicros(override: NSNumber(value: -5)), 0)
    }
    // MARK: - Warm-up parsing

    func testWarmupDefaultsAndClamps() {
        XCTAssertEqual(
            TypingService.remoteDesktopWarmupMicros(override: nil),
            useconds_t(TypingService.remoteDesktopWarmupDefaultMs * 1000)
        )
        XCTAssertEqual(TypingService.remoteDesktopWarmupMicros(override: NSNumber(value: 500)), 500_000)
        XCTAssertEqual(TypingService.remoteDesktopWarmupMicros(override: NSNumber(value: 0)), 0)

        let maximum = useconds_t(TypingService.remoteDesktopWarmupMaximumMs * 1000)
        XCTAssertEqual(TypingService.remoteDesktopWarmupMicros(override: NSNumber(value: Int32.max)), maximum)
        XCTAssertEqual(TypingService.remoteDesktopWarmupMicros(override: NSNumber(value: -1)), 0)
    }
}
