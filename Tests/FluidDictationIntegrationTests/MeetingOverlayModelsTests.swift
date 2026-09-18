@testable import FluidVoice_Debug
import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import XCTest

final class MeetingOverlayGeometryTests: XCTestCase {
    private let pill = MeetingOverlayPresentation.pill.visibleSize
    private let captions = MeetingOverlayPresentation.captions.visibleSize
    private let screen = CGRect(x: 100, y: 50, width: 1440, height: 900)

    func testCanonicalPresentationVisibleSizes() {
        XCTAssertEqual(MeetingOverlayPresentation.pill.visibleSize, CGSize(width: 84, height: 32))
        XCTAssertEqual(MeetingOverlayPresentation.captions.visibleSize, CGSize(width: 340, height: 156))
        XCTAssertEqual(MeetingOverlayPresentation.pill.toggled.visibleSize, CGSize(width: 340, height: 156))
        XCTAssertEqual(MeetingOverlayPresentation.captions.toggled.visibleSize, CGSize(width: 84, height: 32))
    }

    func testCaptionsViewportAndFooterHeightsSumToCanvasHeight() {
        XCTAssertEqual(
            MeetingOverlayPresentation.captionsViewportHeight + MeetingOverlayPresentation.captionsFooterHeight,
            MeetingOverlayPresentation.captions.visibleSize.height
        )
        XCTAssertEqual(MeetingOverlayPresentation.captionsViewportHeight, 121)
        XCTAssertEqual(MeetingOverlayPresentation.captionsFooterHeight, 35)
    }

    func testCaptionsContentInsetsSumToViewportAndCanvasWidth() {
        XCTAssertEqual(MeetingOverlayPresentation.captionsHorizontalInset, 16)
        XCTAssertEqual(MeetingOverlayPresentation.captionsTopInset, 12)
        XCTAssertEqual(MeetingOverlayPresentation.captionsBottomInset, 7)
        XCTAssertEqual(MeetingOverlayPresentation.captionsControlsHeight, 38)
        XCTAssertEqual(
            MeetingOverlayPresentation.captionsControlsHeight
                + MeetingOverlayPresentation.captionsTopInset
                + MeetingOverlayPresentation.captionsContentHeight
                + MeetingOverlayPresentation.captionsBottomInset,
            MeetingOverlayPresentation.captionsViewportHeight
        )
        XCTAssertEqual(
            MeetingOverlayPresentation.captionsContentWidth
                + (2 * MeetingOverlayPresentation.captionsHorizontalInset),
            MeetingOverlayPresentation.captions.visibleSize.width
        )
        XCTAssertEqual(MeetingOverlayPresentation.captionsContentWidth, 308)
        XCTAssertEqual(MeetingOverlayPresentation.captionsContentHeight, 64)
    }

    func testRollingCaptionLayoutUsesBoundedTextAndKeepsLatestGlyph() {
        let text = String(repeating: "older words ", count: 500) + "最新の字幕 مرحبا 👩🏽‍💻 é"
        let layout = MeetingRollingCaptionLayout.make(text)
        XCTAssertLessThanOrEqual(layout.attributedText.string.count, MeetingRollingCaptionLayout.maximumInputCharacters)
        XCTAssertNotNil(layout.layoutManager.textStorage)
        XCTAssertEqual(layout.selectedGlyphRange.upperBound, layout.layoutManager.numberOfGlyphs)
        XCTAssertEqual(MeetingRollingCaptionLayout.contentSize, CGSize(width: 308, height: 64))
        XCTAssertTrue(CGRect(origin: .zero, size: MeetingRollingCaptionLayout.contentSize).contains(layout.inkBounds))
    }

    func testRollingCaptionLayoutHandlesShortUnicodeAndLongUnbrokenTokens() {
        for text in ["", "短い字幕", "שלום RTL 😀 cafe\u{301}", String(repeating: "x", count: 1200)] {
            let layout = MeetingRollingCaptionLayout.make(text)
            XCTAssertNotNil(layout.layoutManager.textStorage)
            XCTAssertTrue(layout.inkBounds.isEmpty || CGRect(origin: .zero, size: MeetingRollingCaptionLayout.contentSize).contains(layout.inkBounds))
        }
    }

    @MainActor
    func testCaptionHostingFrameNeverGrowsAcrossTextUpdates() {
        func content(_ text: String) -> some View {
            VStack(spacing: 0) {
                Color.clear.frame(height: MeetingOverlayPresentation.captionsControlsHeight)
                Color.clear.frame(height: MeetingOverlayPresentation.captionsTopInset)
                MeetingRollingCaptionView(text: text)
                    .frame(width: MeetingOverlayPresentation.captionsContentWidth,
                           height: MeetingOverlayPresentation.captionsContentHeight)
                Color.clear.frame(height: MeetingOverlayPresentation.captionsBottomInset)
                Color.gray.frame(height: MeetingOverlayPresentation.captionsFooterHeight)
            }
            .frame(width: 340, height: 156)
        }
        let host = NSHostingView(rootView: content(""))
        host.frame = CGRect(x: 0, y: 0, width: 340, height: 156)
        for text in ["short", String(repeating: "caption growing 👩🏽‍💻 字幕 ", count: 500), "rewritten latest caption"] {
            host.rootView = content(text)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.frame.size, CGSize(width: 340, height: 156))
            XCTAssertEqual(host.fittingSize.width, 340, accuracy: 0.01)
            XCTAssertEqual(host.fittingSize.height, 156, accuracy: 0.01)
        }
    }

    func testSelectedRangeStartsAtAWholeLineAndDropsOlderLines() {
        let layout = MeetingRollingCaptionLayout.make(String(repeating: "Older words wrap into complete lines. ", count: 40) + "Newest words")
        var lineRanges: [NSRange] = []
        layout.layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.layoutManager.numberOfGlyphs)) { _, _, _, range, _ in
            lineRanges.append(range)
        }
        XCTAssertGreaterThan(layout.selectedGlyphRange.location, 0)
        XCTAssertTrue(lineRanges.contains { $0.location == layout.selectedGlyphRange.location })
        XCTAssertEqual(layout.selectedGlyphRange.upperBound, layout.layoutManager.numberOfGlyphs)
        XCTAssertLessThanOrEqual(layout.inkBounds.height, MeetingOverlayPresentation.captionsContentHeight)
        let cannotFit = MeetingRollingCaptionLayout.make("A full line", height: 1)
        XCTAssertEqual(cannotFit.selectedGlyphRange.length, 0, "Never fall back to a vertically clipped line")
    }

    func testUnclampedLayoutVisibleSurfaceMatchesCanonicalPresentationSize() {
        let padding = MeetingOverlayPadding.uniform(24)
        for presentation in [MeetingOverlayPresentation.pill, .captions] {
            let size = presentation.visibleSize
            let layout = MeetingOverlayGeometry.layout(
                anchor: MeetingOverlayVisibleAnchor(centerX: 820, bottomY: 114),
                visibleSize: size,
                padding: padding,
                screenVisible: self.screen
            )
            XCTAssertEqual(layout.visibleSurfaceFrame.size, size)
            XCTAssertEqual(
                layout.panelFrame.size,
                CGSize(
                    width: size.width + padding.left + padding.right,
                    height: size.height + padding.top + padding.bottom
                )
            )
        }
    }

    func testPillSizeAtUnclampedAnchorUsesUniformPadding() {
        let layout = MeetingOverlayGeometry.layout(
            anchor: MeetingOverlayVisibleAnchor(centerX: 820, bottomY: 114),
            visibleSize: self.pill,
            padding: 16,
            screenVisible: self.screen
        )
        XCTAssertEqual(layout.visibleSurfaceFrame, CGRect(x: 778, y: 114, width: 84, height: 32))
        XCTAssertEqual(layout.panelFrame, CGRect(x: 762, y: 98, width: 116, height: 64))
        XCTAssertTrue(self.screen.contains(layout.visibleSurfaceFrame))
    }

    func testCaptionsSizeUsesEdgeInsetsLikePadding() {
        let padding = MeetingOverlayPadding(top: 4, left: 8, bottom: 12, right: 16)
        let layout = MeetingOverlayGeometry.layout(
            anchor: MeetingOverlayVisibleAnchor(centerX: 820, bottomY: 114),
            visibleSize: self.captions,
            padding: padding,
            screenVisible: self.screen
        )
        XCTAssertEqual(layout.visibleSurfaceFrame, CGRect(x: 650, y: 114, width: 340, height: 156))
        XCTAssertEqual(layout.panelFrame, CGRect(x: 642, y: 102, width: 364, height: 172))
        XCTAssertTrue(self.screen.contains(layout.visibleSurfaceFrame))
    }

    func testVisibleSurfaceIsClampedOnEveryScreenEdgeBeforePadding() {
        let padding = MeetingOverlayPadding(top: 10, left: 12, bottom: 14, right: 16)
        let cases: [(MeetingOverlayVisibleAnchor, CGSize, CGRect)] = [
            (MeetingOverlayVisibleAnchor(centerX: self.screen.minX, bottomY: 200), self.pill, CGRect(x: 100, y: 200, width: 84, height: 32)),
            (MeetingOverlayVisibleAnchor(centerX: self.screen.maxX, bottomY: 200), self.pill, CGRect(x: 1456, y: 200, width: 84, height: 32)),
            (MeetingOverlayVisibleAnchor(centerX: 820, bottomY: self.screen.minY - 40), self.pill, CGRect(x: 778, y: 50, width: 84, height: 32)),
            (MeetingOverlayVisibleAnchor(centerX: 820, bottomY: self.screen.maxY), self.pill, CGRect(x: 778, y: 918, width: 84, height: 32)),
            (MeetingOverlayVisibleAnchor(centerX: self.screen.minX, bottomY: self.screen.minY - 8), self.captions, CGRect(x: 100, y: 50, width: 340, height: 156)),
            (MeetingOverlayVisibleAnchor(centerX: self.screen.maxX, bottomY: self.screen.maxY), self.captions, CGRect(x: 1200, y: 794, width: 340, height: 156)),
        ]

        for (anchor, size, expectedVisible) in cases {
            let layout = MeetingOverlayGeometry.layout(
                anchor: anchor,
                visibleSize: size,
                padding: padding,
                screenVisible: self.screen
            )
            XCTAssertEqual(layout.visibleSurfaceFrame, expectedVisible)
            XCTAssertTrue(self.screen.contains(layout.visibleSurfaceFrame))
            XCTAssertEqual(
                layout.panelFrame,
                CGRect(
                    x: expectedVisible.minX - padding.left,
                    y: expectedVisible.minY - padding.bottom,
                    width: expectedVisible.width + padding.left + padding.right,
                    height: expectedVisible.height + padding.top + padding.bottom
                )
            )
        }
    }

    func testUndersizedScreenShrinksVisibleSurfaceThenAddsPadding() {
        let tiny = CGRect(x: 40, y: 20, width: 100, height: 50)
        let padding: CGFloat = 18
        let layout = MeetingOverlayGeometry.layout(
            anchor: MeetingOverlayVisibleAnchor(centerX: 90, bottomY: 10),
            visibleSize: self.captions,
            padding: padding,
            screenVisible: tiny
        )
        XCTAssertEqual(layout.visibleSurfaceFrame, tiny)
        XCTAssertEqual(layout.panelFrame, CGRect(x: 22, y: 2, width: 136, height: 86))
        XCTAssertTrue(tiny.contains(layout.visibleSurfaceFrame))
        XCTAssertFalse(tiny.contains(layout.panelFrame))
    }

    func testTargetWiderAndTallerThanScreenPinsToOriginDeterministically() {
        let screen = CGRect(x: 12, y: 8, width: 200, height: 80)
        let layout = MeetingOverlayGeometry.layout(
            anchor: MeetingOverlayVisibleAnchor(centerX: 10_000, bottomY: 10_000),
            visibleSize: CGSize(width: 480, height: 132),
            padding: MeetingOverlayPadding(top: 1, left: 2, bottom: 3, right: 4),
            screenVisible: screen
        )
        XCTAssertEqual(layout.visibleSurfaceFrame, screen)
        XCTAssertEqual(layout.panelFrame, CGRect(x: 10, y: 5, width: 206, height: 84))
    }
}

final class MeetingOverlayPresentationReducerTests: XCTestCase {
    func testNewSessionInitializesFromPreferenceAndDuplicateStartPreservesTemporaryState() {
        var reducer = MeetingOverlayPresentationReducer(preference: .pill)
        let session = UUID()
        reducer.apply(.recordingStarted(sessionID: session))
        XCTAssertEqual(reducer.presentation, .pill)
        XCTAssertEqual(reducer.sessionID, session)

        reducer.apply(.toggleRequested)
        XCTAssertEqual(reducer.presentation, .captions)

        reducer.apply(.recordingStarted(sessionID: session))
        XCTAssertEqual(reducer.presentation, .captions)
        XCTAssertEqual(reducer.preference, .pill)

        let next = UUID()
        reducer.apply(.recordingStarted(sessionID: next))
        XCTAssertEqual(reducer.sessionID, next)
        XCTAssertEqual(reducer.presentation, .pill)
    }

    func testDegradeAndRecoverPreservePresentation() {
        var reducer = MeetingOverlayPresentationReducer(preference: .pill)
        let session = UUID()
        reducer.apply(.recordingStarted(sessionID: session))
        reducer.apply(.toggleRequested)
        XCTAssertEqual(reducer.presentation, .captions)

        reducer.apply(.recordingDegraded)
        reducer.apply(.recordingStateChanged)
        reducer.apply(.recordingStarted(sessionID: session))
        XCTAssertEqual(reducer.presentation, .captions)
        XCTAssertEqual(reducer.sessionID, session)
        XCTAssertEqual(reducer.preference, .pill)
    }

    func testMidMeetingPreferenceChangeAppliesToNextMeetingOnly() {
        var reducer = MeetingOverlayPresentationReducer(preference: .pill)
        let first = UUID()
        reducer.apply(.recordingStarted(sessionID: first))
        reducer.apply(.toggleRequested)
        reducer.apply(.preferenceChanged(.captions))
        XCTAssertEqual(reducer.preference, .captions)
        XCTAssertEqual(reducer.presentation, .captions)

        reducer.apply(.recordingStopped)
        XCTAssertNil(reducer.presentation)
        XCTAssertNil(reducer.sessionID)
        XCTAssertEqual(reducer.preference, .captions)

        let second = UUID()
        reducer.apply(.recordingStarted(sessionID: second))
        XCTAssertEqual(reducer.presentation, .captions)

        reducer.apply(.preferenceChanged(.pill))
        XCTAssertEqual(reducer.preference, .pill)
        XCTAssertEqual(reducer.presentation, .captions)

        reducer.apply(.recordingStopped)
        reducer.apply(.recordingStarted(sessionID: UUID()))
        XCTAssertEqual(reducer.presentation, .pill)
    }

    func testStopClearsSessionAndIgnoresToggleUntilNextStart() {
        var reducer = MeetingOverlayPresentationReducer(preference: .captions)
        reducer.apply(.toggleRequested)
        XCTAssertNil(reducer.presentation)

        let session = UUID()
        reducer.apply(.recordingStarted(sessionID: session))
        XCTAssertEqual(reducer.presentation, .captions)

        reducer.apply(.recordingStopped)
        reducer.apply(.recordingStopped)
        reducer.apply(.toggleRequested)
        reducer.apply(.recordingDegraded)
        reducer.apply(.recordingStateChanged)
        XCTAssertNil(reducer.presentation)
        XCTAssertNil(reducer.sessionID)

        reducer.apply(.recordingStarted(sessionID: session))
        XCTAssertEqual(reducer.presentation, .captions)
    }

    func testRapidTogglesAreDeterministic() {
        var reducer = MeetingOverlayPresentationReducer(preference: .pill)
        reducer.apply(.recordingStarted(sessionID: UUID()))
        reducer.apply(.toggleRequested)
        reducer.apply(.toggleRequested)
        reducer.apply(.toggleRequested)
        reducer.apply(.toggleRequested)
        XCTAssertEqual(reducer.presentation, .pill)
        reducer.apply(.toggleRequested)
        XCTAssertEqual(reducer.presentation, .captions)
        reducer.apply(.toggleRequested)
        XCTAssertEqual(reducer.presentation, .pill)
    }

    func testPreferenceRoundTripAndCaseIterable() {
        XCTAssertEqual(MeetingOverlayPreference.allCases, [.pill, .captions])
        for preference in MeetingOverlayPreference.allCases {
            let data = try! JSONEncoder().encode(preference)
            let decoded = try! JSONDecoder().decode(MeetingOverlayPreference.self, from: data)
            XCTAssertEqual(decoded, preference)
        }
    }
}
