import AppKit
import CoreGraphics
@testable import FluidVoice_Debug
import Foundation
import SwiftUI
import XCTest

final class MeetingOverlayGeometryTests: XCTestCase {
    private let pill = MeetingOverlayPresentation.pill.visibleSize
    private let captions = MeetingOverlayPresentation.captions.visibleSize
    private let screen = CGRect(x: 100, y: 50, width: 1440, height: 900)

    func testNewMeetingPillStartsAtScreenCenterAndDictationOffset() {
        let full = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        let visible = CGRect(x: -1860, y: 250, width: 1860, height: 1000)
        let anchor = MeetingOverlayGeometry.initialPillAnchor(screenFrame: full, screenVisible: visible, bottomOffset: 40)
        XCTAssertEqual(anchor.centerX, full.midX) // A side Dock must not shift the center.
        XCTAssertEqual(anchor.bottomY, visible.minY + 40)
        let layout = MeetingOverlayGeometry.layout(anchor: anchor, visibleSize: self.pill, padding: 24, screenVisible: visible)
        XCTAssertEqual(layout.visibleSurfaceFrame.midX, full.midX)
        XCTAssertEqual(layout.visibleSurfaceFrame.minY, visible.minY + 40)
    }

    func testInitialPillOffsetStaysInsideVisibleScreen() {
        let low = MeetingOverlayGeometry.initialPillAnchor(screenFrame: self.screen, screenVisible: self.screen, bottomOffset: -500)
        let high = MeetingOverlayGeometry.initialPillAnchor(screenFrame: self.screen, screenVisible: self.screen, bottomOffset: 5000)
        XCTAssertEqual(low.bottomY, self.screen.minY + 10)
        XCTAssertEqual(high.bottomY, self.screen.maxY - self.pill.height - 40)
    }

    func testDraggedAnchorSurvivesLayoutButDoesNotBecomeNextMeetingDefault() {
        let dragged = MeetingOverlayVisibleAnchor(centerX: 300, bottomY: 450)
        let layout = MeetingOverlayGeometry.layout(anchor: dragged, visibleSize: self.pill, padding: 24, screenVisible: self.screen)
        XCTAssertEqual(layout.visibleSurfaceFrame.midX, dragged.centerX)
        XCTAssertEqual(layout.visibleSurfaceFrame.minY, dragged.bottomY)
        let next = MeetingOverlayGeometry.initialPillAnchor(screenFrame: self.screen, screenVisible: self.screen, bottomOffset: 30)
        XCTAssertEqual(next.centerX, self.screen.midX)
        XCTAssertEqual(next.bottomY, self.screen.minY + 30)
    }

    func testCanonicalPresentationVisibleSizes() {
        XCTAssertGreaterThan(self.captions.width, self.pill.width)
        XCTAssertGreaterThan(self.captions.height, self.pill.height)
        XCTAssertEqual(MeetingOverlayPresentation.pill.toggled.visibleSize, self.captions)
        XCTAssertEqual(MeetingOverlayPresentation.captions.toggled.visibleSize, self.pill)
    }

    func testCaptionsViewportAndFooterHeightsSumToCanvasHeight() {
        XCTAssertEqual(
            MeetingOverlayPresentation.captionsViewportHeight + MeetingOverlayPresentation.captionsFooterHeight,
            MeetingOverlayPresentation.captions.visibleSize.height
        )
        XCTAssertGreaterThan(MeetingOverlayPresentation.captionsViewportHeight, MeetingOverlayPresentation.captionsFooterHeight)
    }

    func testCaptionsContentInsetsSumToViewportAndCanvasWidth() {
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
        XCTAssertGreaterThan(MeetingOverlayPresentation.captionsContentWidth, 0)
        XCTAssertGreaterThan(MeetingOverlayPresentation.captionsContentHeight, 0)
    }

    func testRollingCaptionLayoutUsesBoundedTextAndKeepsLatestGlyph() {
        let text = String(repeating: "older words ", count: 500) + "最新の字幕 مرحبا 👩🏽‍💻 é"
        let layout = MeetingRollingCaptionLayout.make(text)
        XCTAssertLessThanOrEqual(layout.attributedText.string.count, MeetingRollingCaptionLayout.maximumInputCharacters)
        XCTAssertNotNil(layout.layoutManager.textStorage)
        XCTAssertEqual(layout.selectedGlyphRange.upperBound, layout.layoutManager.numberOfGlyphs)
        XCTAssertEqual(
            MeetingRollingCaptionLayout.contentSize,
            CGSize(width: MeetingOverlayPresentation.captionsContentWidth, height: MeetingOverlayPresentation.captionsContentHeight)
        )
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
                    .frame(
                        width: MeetingOverlayPresentation.captionsContentWidth,
                        height: MeetingOverlayPresentation.captionsContentHeight
                    )
                Color.clear.frame(height: MeetingOverlayPresentation.captionsBottomInset)
                Color.gray.frame(height: MeetingOverlayPresentation.captionsFooterHeight)
            }
            .frame(width: self.captions.width, height: self.captions.height)
        }
        let host = NSHostingView(rootView: content(""))
        host.frame = CGRect(origin: .zero, size: self.captions)
        for text in ["short", String(repeating: "caption growing 👩🏽‍💻 字幕 ", count: 500), "rewritten latest caption"] {
            host.rootView = content(text)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.frame.size, self.captions)
            XCTAssertEqual(host.fittingSize.width, self.captions.width, accuracy: 0.01)
            XCTAssertEqual(host.fittingSize.height, self.captions.height, accuracy: 0.01)
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
        XCTAssertEqual(layout.visibleSurfaceFrame, CGRect(x: 820 - self.pill.width / 2, y: 114, width: self.pill.width, height: self.pill.height))
        XCTAssertEqual(layout.panelFrame, layout.visibleSurfaceFrame.insetBy(dx: -16, dy: -16))
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
        let expectedVisible = CGRect(x: 820 - self.captions.width / 2, y: 114, width: self.captions.width, height: self.captions.height)
        XCTAssertEqual(layout.visibleSurfaceFrame, expectedVisible)
        XCTAssertEqual(layout.panelFrame, CGRect(
            x: expectedVisible.minX - padding.left,
            y: expectedVisible.minY - padding.bottom,
            width: expectedVisible.width + padding.left + padding.right,
            height: expectedVisible.height + padding.top + padding.bottom
        ))
        XCTAssertTrue(self.screen.contains(layout.visibleSurfaceFrame))
    }

    func testVisibleSurfaceIsClampedOnEveryScreenEdgeBeforePadding() {
        let padding = MeetingOverlayPadding(top: 10, left: 12, bottom: 14, right: 16)
        let cases: [(MeetingOverlayVisibleAnchor, CGSize, CGRect)] = [
            (MeetingOverlayVisibleAnchor(centerX: self.screen.minX, bottomY: 200), self.pill, CGRect(origin: CGPoint(x: self.screen.minX, y: 200), size: self.pill)),
            (
                MeetingOverlayVisibleAnchor(centerX: self.screen.maxX, bottomY: 200),
                self.pill,
                CGRect(origin: CGPoint(x: self.screen.maxX - self.pill.width, y: 200), size: self.pill)
            ),
            (
                MeetingOverlayVisibleAnchor(centerX: 820, bottomY: self.screen.minY - 40),
                self.pill,
                CGRect(origin: CGPoint(x: 820 - self.pill.width / 2, y: self.screen.minY), size: self.pill)
            ),
            (
                MeetingOverlayVisibleAnchor(centerX: 820, bottomY: self.screen.maxY),
                self.pill,
                CGRect(origin: CGPoint(x: 820 - self.pill.width / 2, y: self.screen.maxY - self.pill.height), size: self.pill)
            ),
            (
                MeetingOverlayVisibleAnchor(centerX: self.screen.minX, bottomY: self.screen.minY - 8),
                self.captions,
                CGRect(origin: CGPoint(x: self.screen.minX, y: self.screen.minY), size: self.captions)
            ),
            (
                MeetingOverlayVisibleAnchor(centerX: self.screen.maxX, bottomY: self.screen.maxY),
                self.captions,
                CGRect(origin: CGPoint(x: self.screen.maxX - self.captions.width, y: self.screen.maxY - self.captions.height), size: self.captions)
            ),
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

    func testPreferenceRoundTripAndCaseIterable() throws {
        XCTAssertEqual(MeetingOverlayPreference.allCases, [.pill, .captions])
        for preference in MeetingOverlayPreference.allCases {
            let data = try JSONEncoder().encode(preference)
            let decoded = try JSONDecoder().decode(MeetingOverlayPreference.self, from: data)
            XCTAssertEqual(decoded, preference)
        }
    }
}

@MainActor
final class MeetingMenuBarStartTests: XCTestCase {
    func testRepeatedStartIsIgnoredAndNeverNavigates() async {
        let manager = MenuBarManager()
        var calls = 0
        await manager.startMeetingRecordingInBackground {
            calls += 1
            XCTAssertTrue(manager.meetingStartRequested)
            await manager.startMeetingRecordingInBackground { calls += 1 }
        }
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(manager.meetingStartRequested)
        XCTAssertNil(manager.meetingStartError)
        XCTAssertNil(manager.requestedNavigationDestination)
    }

    func testFailureClearsPendingStartAndAllowsRetryWithoutNavigation() async {
        let manager = MenuBarManager()
        await manager.startMeetingRecordingInBackground { throw MeetingCaptureError.microphoneUnavailable }
        XCTAssertFalse(manager.meetingStartRequested)
        XCTAssertNotNil(manager.meetingStartError)
        XCTAssertNil(manager.requestedNavigationDestination)
        var retried = false
        await manager.startMeetingRecordingInBackground { retried = true }
        XCTAssertTrue(retried)
        XCTAssertNil(manager.meetingStartError)
        XCTAssertFalse(manager.meetingStartRequested)
        XCTAssertNil(manager.requestedNavigationDestination)
    }

    func testAutomaticSourceUsesExactProcessAndWindow() throws {
        let configuration = try self.configuration(targetPID: 42, availablePID: 42)
        XCTAssertEqual(configuration.mode, .onlineCall)
        XCTAssertEqual(configuration.application?.processID, 42)
        XCTAssertEqual(configuration.application?.windowID, 123)
        XCTAssertEqual(configuration.microphone.coreAudioUID, "system-mic")
        XCTAssertEqual(configuration.microphone.role, .unknown)
    }

    func testStaleProcessCannotFallBackToAnotherApplication() {
        XCTAssertThrowsError(try self.configuration(targetPID: 42, availablePID: 43))
    }

    func testNoDetectedMeetingUsesMicrophoneOnly() throws {
        let configuration = try self.configuration(targetPID: nil, availablePID: 43)
        XCTAssertEqual(configuration.mode, .inRoom)
        XCTAssertNil(configuration.application)
        XCTAssertNil(configuration.platform)
    }

    func testInRoomModeIgnoresDetectedApplication() throws {
        let configuration = try self.configuration(targetPID: 42, availablePID: 42, mode: .inRoom)
        XCTAssertEqual(configuration.mode, .inRoom)
        XCTAssertNil(configuration.application)
    }

    private func configuration(
        targetPID: Int32?,
        availablePID: Int32,
        mode: MeetingCaptureMode = .onlineCall
    ) throws -> MeetingCaptureConfiguration {
        var defaults = MeetingRecordingDefaults.unconfigured
        defaults.mode = mode
        return try AppServices.menuBarMeetingConfiguration(
            defaults: defaults,
            target: targetPID.map { MeetingAutoDetector.ResolvedTarget(bundleIdentifier: "meeting.app", pid: $0, windowID: 123) },
            microphones: MeetingMicrophoneCatalogSnapshot(
                identities: [MeetingMicrophoneIdentity(captureDeviceID: "system-mic", coreAudioUID: "system-mic", displayName: "Microphone")],
                defaultCoreAudioUID: "system-mic"
            ),
            applications: [MeetingApplicationIdentity(bundleIdentifier: "meeting.app", processID: availablePID, displayName: "Meeting App")],
            preferredInputUID: nil
        )
    }
}
