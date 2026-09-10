import AppKit
@testable import FluidVoice_Debug
import XCTest

// Safari turns one synthesized unicode key event into a single `keypress` carrying only the first
// character, so editors that build their text from `keypress` insert "H" for "Hello world". Only
// Google Docs and Slides in a WebKit browser lose text this way, and only those targets may be
// pushed off the direct-typing path onto the clipboard.

final class TypingServicePasteOnlyRoutingTests: XCTestCase {
    private func reason(_ bundleIdentifier: String?, _ title: String?) -> String? {
        TypingService.pasteOnlyReason(bundleIdentifier: bundleIdentifier, focusedWindowTitle: title)
    }

    func testKnownBundleIdentifierMatchesWithoutAWindowTitle() {
        XCTAssertEqual(
            self.reason("com.mitchellh.ghostty", nil),
            "bundleID=com.mitchellh.ghostty",
            "apps that never accept synthesized typing must match on bundle ID alone, before any AX lookup"
        )
    }

    func testTheWindowTitleIsOnlyReadWhenTheBundleIdentifierCouldMatch() {
        var lookups = 0
        func reasonCountingLookups(_ bundleIdentifier: String?) -> String? {
            TypingService.pasteOnlyReason(
                bundleIdentifier: bundleIdentifier,
                focusedWindowTitle: {
                    lookups += 1
                    return "Quarterly notes - Google Docs"
                }()
            )
        }

        _ = reasonCountingLookups("com.apple.Notes")
        XCTAssertEqual(lookups, 0, "a native app must not trigger an Accessibility round trip")

        _ = reasonCountingLookups("com.mitchellh.ghostty")
        XCTAssertEqual(lookups, 0, "a bundle ID match resolves before the title is ever needed")

        _ = reasonCountingLookups("com.apple.Safari")
        XCTAssertEqual(lookups, 1, "only a WebKit browser reads the focused window title")
    }

    func testSafariMatchesGoogleDocsAndSlides() {
        XCTAssertEqual(
            self.reason("com.apple.Safari", "Quarterly notes - Google Docs"),
            "document=Google Docs",
            "Docs in Safari drops everything after the first character and needs the clipboard path"
        )
        XCTAssertEqual(
            self.reason("com.apple.Safari", "Launch deck - Google Slides"),
            "document=Google Slides",
            "Slides truncates the same way Docs does"
        )
    }

    func testGoogleSheetsKeepsTheDirectTypingPath() {
        XCTAssertNil(
            self.reason("com.apple.Safari", "Budget - Google Sheets"),
            "Sheets inserts the full string in Safari, so forcing it onto the clipboard would be a regression"
        )
    }

    func testChromiumAndGeckoKeepTheDirectTypingPath() {
        XCTAssertNil(
            self.reason("com.google.Chrome", "Quarterly notes - Google Docs"),
            "Chromium fires no keypress and inserts the full string"
        )
        XCTAssertNil(
            self.reason("org.mozilla.firefox", "Quarterly notes - Google Docs"),
            "Gecko fires one keypress per character and inserts the full string"
        )
    }

    func testOrdinaryBrowsingDoesNotMatch() {
        XCTAssertNil(
            self.reason("com.apple.Safari", "Apple"),
            "a WebKit browser alone is not enough; only the affected documents may be rerouted"
        )
    }

    func testNativeAppsAreNeverForcedOntoTheClipboard() {
        XCTAssertNil(
            self.reason("com.apple.Notes", "Quarterly notes - Google Docs"),
            "a matching window title in a native app must not trigger the browser rule"
        )
        XCTAssertNil(
            self.reason(nil, nil),
            "an unidentifiable target keeps the default path"
        )
    }
}
