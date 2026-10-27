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
    func testDisabledFluidMeetCannotReopenOverlaysOrCreateMeetingServices() {
        let original = UserDefaults.standard.object(forKey: "FluidMeetEnabled")
        defer { UserDefaults.standard.set(original, forKey: "FluidMeetEnabled") }
        let services = AppServices.shared
        SettingsStore.shared.fluidMeetEnabled = false
        let hadCoordinator = services.isMeetingSessionCoordinatorMaterialized
        let windows = NSApp.windows.count
        MeetingFloatingCaptionsController.shared.show(from: nil)
        MeetingRecordingPillController.shared.expand()
        MeetingStillRecordingNudgeController.shared.present()
        MeetingDetectionPromptController.shared.present(.init(
            episodeID: UUID(), bundleIdentifier: "us.zoom.xos", pid: 42, tier: .nativeTier1
        ))
        XCTAssertEqual(services.isMeetingSessionCoordinatorMaterialized, hadCoordinator)
        XCTAssertEqual(NSApp.windows.count, windows)
        XCTAssertNil(MeetingRecordingPillController.shared.currentOverlayFrame)
        XCTAssertFalse(MeetingStillRecordingNudgeController.shared.isPresented)
        XCTAssertNil(MeetingDetectionPromptController.shared.request)
    }

    func testDisabledFluidMeetIgnoresMenuStartWithoutNavigationOrError() async {
        let original = UserDefaults.standard.object(forKey: "FluidMeetEnabled")
        defer { UserDefaults.standard.set(original, forKey: "FluidMeetEnabled") }
        SettingsStore.shared.fluidMeetEnabled = false
        let manager = MenuBarManager()
        var called = false
        await manager.startMeetingRecordingInBackground { called = true }
        XCTAssertFalse(called)
        XCTAssertFalse(manager.meetingStartRequested)
        XCTAssertNil(manager.meetingStartError)
        XCTAssertNil(manager.requestedNavigationDestination)
    }

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

@MainActor
final class MeetingHistorySnapshotTests: XCTestCase {
    private func session() -> MeetingSession {
        MeetingSession(
            configuration: MeetingCaptureConfiguration(mode: .inRoom, title: "History", microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic", displayName: "Mic")),
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)
        )
    }

    func testSavedCorrectionUpdatesOnlyItsMeetingWithoutDiskReload() async {
        let loader = HistorySnapshotLoader()
        let snapshot = MeetingHistorySnapshot { try await loader.load() }
        let original = self.session()
        let other = self.session()
        let initial = Task { await snapshot.refresh() }
        await loader.waitForCall(1)
        loader.finish(.success([original, other]))
        await initial.value
        var corrected = original
        corrected.title = "Corrected"
        snapshot.applySavedSession(corrected)
        XCTAssertEqual(snapshot.sessions, [corrected, other])
        XCTAssertEqual(loader.calls, 1, "publishing a saved correction performs no history read")
        snapshot.applySavedSession(original) // Undo uses the same publication path.
        XCTAssertEqual(snapshot.sessions, [original, other])
        XCTAssertEqual(loader.calls, 1)
    }

    func testRapidCorrectionsCannotBeOverwrittenByAnOlderHistoryRead() async {
        let loader = HistorySnapshotLoader()
        let snapshot = MeetingHistorySnapshot { try await loader.load() }
        let original = self.session()
        let initial = Task { await snapshot.refresh() }
        await loader.waitForCall(1)
        loader.finish(.success([original]))
        await initial.value
        let refresh = Task { await snapshot.refresh() }
        await loader.waitForCall(2)
        var first = original
        first.title = "First correction"
        snapshot.applySavedSession(first)
        var second = first
        second.title = "Second correction"
        snapshot.applySavedSession(second)
        XCTAssertEqual(snapshot.sessions, [second])
        loader.finish(.success([original]))
        await loader.waitForCall(3)
        XCTAssertEqual(snapshot.sessions, [second], "stale rows never replace the saved result")
        loader.finish(.failure(NSError(domain: "test", code: 1)))
        await refresh.value
        XCTAssertEqual(snapshot.sessions, [second], "refresh failure keeps the saved correction")
        XCTAssertEqual(loader.calls, 3, "rapid corrections coalesce into one follow-up read")
    }

    func testSavedSessionDuringInitialLoadIsNotLostOrDuplicated() async {
        let loader = HistorySnapshotLoader()
        let snapshot = MeetingHistorySnapshot { try await loader.load() }
        let saved = self.session()
        let initial = Task { await snapshot.refresh() }
        await loader.waitForCall(1)
        snapshot.applySavedSession(saved)
        snapshot.applySavedSession(saved)
        XCTAssertEqual(snapshot.sessions, [saved])
        loader.finish(.success([]))
        await loader.waitForCall(2)
        XCTAssertEqual(snapshot.sessions, [saved])
        loader.finish(.success([saved]))
        await initial.value
        XCTAssertEqual(snapshot.sessions, [saved])
        XCTAssertTrue(snapshot.hasLoaded)
    }

    func testSnapshotKeepsRowsDuringRefreshAndFailureThenRecovers() async {
        let loader = HistorySnapshotLoader()
        let snapshot = MeetingHistorySnapshot { try await loader.load() }
        XCTAssertFalse(snapshot.hasLoaded)
        XCTAssertEqual(loader.calls, 0)
        let original = self.session()
        let initial = Task { await snapshot.refresh() }
        await loader.waitForCall(1)
        loader.finish(.success([original]))
        await initial.value
        XCTAssertEqual(snapshot.sessions.map(\.id), [original.id])
        XCTAssertTrue(snapshot.hasLoaded)

        let refresh = Task { await snapshot.refresh() }
        await loader.waitForCall(2)
        XCTAssertEqual(snapshot.sessions.map(\.id), [original.id])
        XCTAssertTrue(snapshot.hasLoaded)
        loader.finish(.failure(NSError(domain: "test", code: 1)))
        await refresh.value
        XCTAssertEqual(snapshot.sessions.map(\.id), [original.id])
        XCTAssertNotNil(snapshot.errorMessage)

        let retry = Task { await snapshot.refresh() }
        await loader.waitForCall(3)
        loader.finish(.success([]))
        await retry.value
        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertNil(snapshot.errorMessage)
    }

    func testRefreshDuringReadDoesNotPublishStaleRows() async {
        let loader = HistorySnapshotLoader()
        let snapshot = MeetingHistorySnapshot { try await loader.load() }
        let stale = self.session()
        let first = Task { await snapshot.refresh() }
        await loader.waitForCall(1)
        let secondStarted = self.expectation(description: "Second refresh registered")
        let second = Task {
            secondStarted.fulfill()
            await snapshot.refresh()
        }
        await self.fulfillment(of: [secondStarted], timeout: 2)
        loader.finish(.success([stale]))
        await loader.waitForCall(2)
        XCTAssertFalse(snapshot.hasLoaded)
        XCTAssertTrue(snapshot.sessions.isEmpty)
        loader.finish(.success([]))
        await first.value
        await second.value
        XCTAssertEqual(loader.calls, 2)
        XCTAssertTrue(snapshot.hasLoaded)
        XCTAssertTrue(snapshot.sessions.isEmpty)
    }
}

@MainActor
final class MeetingCorrectionUndoRegistrationTests: XCTestCase {
    func testNativeUndoWalksCorrectionsAndStopsWithoutCreatingRedo() async {
        let manager = UndoManager()
        manager.groupsByEvent = false
        let registration = MeetingCorrectionUndoRegistration()
        defer { registration.detach() }
        var count = 0
        let calls = (0..<3).map { self.expectation(description: "Undo \($0)") }
        registration.refresh(manager: manager, sessionID: UUID(), isEnabled: true) {
            calls[count].fulfill()
            count += 1
            return count < 3
        }
        XCTAssertEqual(manager.undoActionName, "Meeting Correction")
        for call in calls {
            XCTAssertTrue(manager.canUndo)
            manager.undo()
            await self.fulfillment(of: [call], timeout: 2)
        }
        XCTAssertEqual(count, 3)
        XCTAssertFalse(manager.canUndo)
        XCTAssertFalse(manager.canRedo)
    }

    func testEditingAndLeavingOnlyRemoveMeetingUndoNotOtherTextUndo() {
        let manager = UndoManager()
        manager.groupsByEvent = false
        let registration = MeetingCorrectionUndoRegistration()
        let other = NativeUndoCounter()
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: other) { $0.calls += 1 }
        manager.endUndoGrouping()
        let sessionID = UUID()
        var corrections = 0
        let action: @MainActor () async -> Bool = { corrections += 1; return false }
        registration.refresh(manager: manager, sessionID: sessionID, isEnabled: true, action: action)
        registration.refresh(manager: manager, sessionID: sessionID, isEnabled: false, action: action)
        manager.undo()
        XCTAssertEqual(other.calls, 1, "native text undo remains available while editing")
        XCTAssertEqual(corrections, 0)
        registration.refresh(manager: manager, sessionID: sessionID, isEnabled: true, action: action)
        registration.detach()
        XCTAssertFalse(manager.canUndo, "leaving the transcript cannot undo an invisible meeting")
    }

    func testFailedSaveKeepsNativeUndoAvailableForRetry() async {
        let manager = UndoManager()
        manager.groupsByEvent = false
        let registration = MeetingCorrectionUndoRegistration()
        defer { registration.detach() }
        let failed = self.expectation(description: "Failed save")
        let retried = self.expectation(description: "Retried save")
        var calls = 0
        registration.refresh(manager: manager, sessionID: UUID(), isEnabled: true) {
            calls += 1
            if calls == 1 { failed.fulfill(); return true }
            retried.fulfill()
            return false
        }
        manager.undo()
        await self.fulfillment(of: [failed], timeout: 2)
        XCTAssertTrue(manager.canUndo)
        manager.undo()
        await self.fulfillment(of: [retried], timeout: 2)
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(manager.canUndo)
    }

    func testPendingSaveCannotRegisterUndoInAnotherMeeting() async {
        let manager = UndoManager()
        manager.groupsByEvent = false
        let registration = MeetingCorrectionUndoRegistration()
        defer { registration.detach() }
        let started = self.expectation(description: "First save started")
        let finished = self.expectation(description: "First save finished")
        let next = self.expectation(description: "Next meeting undone")
        var continuation: CheckedContinuation<Bool, Never>?
        registration.refresh(manager: manager, sessionID: UUID(), isEnabled: true) {
            let result = await withCheckedContinuation { continuation = $0; started.fulfill() }
            finished.fulfill()
            return result
        }
        manager.undo()
        await self.fulfillment(of: [started], timeout: 2)
        registration.refresh(manager: manager, sessionID: UUID(), isEnabled: true) { next.fulfill(); return false }
        continuation?.resume(returning: true)
        await self.fulfillment(of: [finished], timeout: 2)
        manager.undo()
        await self.fulfillment(of: [next], timeout: 2)
        XCTAssertFalse(manager.canUndo)
    }
}

@MainActor
private final class NativeUndoCounter {
    var calls = 0
}

@MainActor
private final class HistorySnapshotLoader {
    private(set) var calls = 0
    private var pending: CheckedContinuation<[MeetingSession], Error>?
    private var observer: (Int, CheckedContinuation<Void, Never>)?

    func load() async throws -> [MeetingSession] {
        try await withCheckedThrowingContinuation { continuation in
            self.pending = continuation
            self.calls += 1
            if let observer = self.observer, self.calls >= observer.0 {
                self.observer = nil
                observer.1.resume()
            }
        }
    }

    func waitForCall(_ count: Int) async {
        if self.calls >= count { return }
        await withCheckedContinuation { self.observer = (count, $0) }
    }

    func finish(_ result: Result<[MeetingSession], Error>) {
        let pending = self.pending
        self.pending = nil
        pending?.resume(with: result)
    }
}

@MainActor
extension MeetingMenuBarStartTests {
    func testMeetingShortcutIgnoresBusyStatesAndDuplicateStops() async throws {
        let previous = UserDefaults.standard.object(forKey: "FluidMeetEnabled")
        defer { UserDefaults.standard.set(previous, forKey: "FluidMeetEnabled") }
        SettingsStore.shared.fluidMeetEnabled = true
        let manager = MenuBarManager()
        let id = UUID()
        var starts = 0
        var stops = 0
        for state in [MeetingCoordinatorState.preparing(id), .stopping(id), .processing(id, .transcribing)] {
            manager.configureMeetingShortcutForTesting(state: state) { stops += 1 }
            await manager.toggleMeetingRecordingFromShortcut { starts += 1 }
        }
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(stops, 0)
        manager.configureMeetingShortcutForTesting(state: .recording(id)) { stops += 1 }
        await manager.toggleMeetingRecordingFromShortcut { starts += 1 }
        await manager.toggleMeetingRecordingFromShortcut { starts += 1 }
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(starts, 0)
        manager.configureMeetingShortcutForTesting(state: .completed(id)) { stops += 1 }
        await manager.toggleMeetingRecordingFromShortcut {
            starts += 1
            await manager.toggleMeetingRecordingFromShortcut { starts += 1 }
        }
        XCTAssertEqual(starts, 1)
        XCTAssertFalse(manager.meetingStartRequested)
        XCTAssertNil(manager.requestedNavigationDestination)
    }

    func testMeetingShortcutCannotInterruptDictationAndFailureAllowsRetry() async throws {
        let previous = UserDefaults.standard.object(forKey: "FluidMeetEnabled")
        defer { UserDefaults.standard.set(previous, forKey: "FluidMeetEnabled") }
        SettingsStore.shared.fluidMeetEnabled = true
        let asr = ASRService()
        let manager = MenuBarManager()
        manager.configure(asrService: asr)
        let lease = try asr.acquireExclusiveActivity(.dictation)
        var starts = 0
        await manager.toggleMeetingRecordingFromShortcut { starts += 1 }
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(asr.activeExclusiveActivity, .dictation)
        asr.releaseExclusiveActivity(lease)
        await manager.toggleMeetingRecordingFromShortcut { throw MeetingCaptureError.microphoneUnavailable }
        XCTAssertFalse(manager.meetingStartRequested)
        XCTAssertNotNil(manager.meetingStartError)
        await manager.toggleMeetingRecordingFromShortcut { starts += 1 }
        XCTAssertEqual(starts, 1)
        XCTAssertNil(manager.meetingStartError)
        XCTAssertNil(manager.requestedNavigationDestination)
    }
}

@MainActor
final class MeetingPageActionAvailabilityTests: XCTestCase {
    private func session() -> MeetingSession {
        MeetingSession(
            configuration: MeetingCaptureConfiguration(mode: .inRoom, title: "Meeting", microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic", displayName: "Mic")),
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)
        )
    }

    func testCompletedAndFailedMeetingsKeepNewMeetingVisibleWhileSummaryBlocksItsAction() {
        for state in [MeetingTranscriptionCanvasState.result(self.session()), .failed(session: nil, message: "Failed")] {
            for summaryRunning in [false, true] {
                let actions = MeetingPageActionAvailability(state: state, isSummaryRunning: summaryRunning)
                XCTAssertTrue(actions.showsNewMeeting)
                XCTAssertEqual(actions.canStartNewMeeting, !summaryRunning)
                XCTAssertTrue(actions.canEditSetup)
            }
        }
    }

    func testSetupAndActiveCaptureNeverOfferAnotherMeeting() {
        let session = self.session()
        let states: [MeetingTranscriptionCanvasState] = [
            .setup(isStarting: false, recentSession: nil),
            .setup(isStarting: true, recentSession: session),
            .recording(session: session, trackHealth: [:], liveTranscript: .empty),
            .stopping(session: session, trackHealth: [:], liveTranscript: .empty),
            .processing(session: session, stage: .transcribing),
        ]
        for (index, state) in states.enumerated() {
            let actions = MeetingPageActionAvailability(state: state, isSummaryRunning: false)
            XCTAssertFalse(actions.showsNewMeeting)
            XCTAssertFalse(actions.canStartNewMeeting)
            XCTAssertEqual(actions.canEditSetup, index == 0)
        }
    }
}

@MainActor
extension MeetingMenuBarStartTests {
    func testSavedOnlineApplicationIsUsedWithoutAutomaticDetection() throws {
        var defaults = MeetingRecordingDefaults.unconfigured
        defaults.isConfigured = true
        defaults.applicationBundleIdentifier = "us.zoom.xos"
        let app = MeetingApplicationIdentity(bundleIdentifier: "us.zoom.xos", processID: 42, displayName: "Zoom")
        let config = try self.savedSourceConfiguration(defaults: defaults, applications: [app])
        XCTAssertEqual(config.mode, .onlineCall)
        XCTAssertEqual(config.application, app)
        XCTAssertEqual(config.platform?.identifier, app.bundleIdentifier)
    }

    func testUnavailableSavedApplicationCannotSilentlyBecomeMicrophoneOnly() {
        var defaults = MeetingRecordingDefaults.unconfigured
        defaults.isConfigured = true
        defaults.applicationBundleIdentifier = "us.zoom.xos"
        XCTAssertThrowsError(try self.savedSourceConfiguration(defaults: defaults, applications: [
            MeetingApplicationIdentity(bundleIdentifier: "com.microsoft.teams2", processID: 43, displayName: "Teams"),
        ]))
    }

    func testSavedInRoomModeDoesNotCaptureASavedApplication() throws {
        var defaults = MeetingRecordingDefaults.unconfigured
        defaults.isConfigured = true
        defaults.mode = .inRoom
        defaults.applicationBundleIdentifier = "us.zoom.xos"
        let app = MeetingApplicationIdentity(bundleIdentifier: "us.zoom.xos", processID: 42, displayName: "Zoom")
        let config = try self.savedSourceConfiguration(defaults: defaults, applications: [app])
        XCTAssertEqual(config.mode, .inRoom)
        XCTAssertNil(config.application)
    }

    private func savedSourceConfiguration(
        defaults: MeetingRecordingDefaults,
        applications: [MeetingApplicationIdentity]
    ) throws -> MeetingCaptureConfiguration {
        try AppServices.menuBarMeetingConfiguration(
            defaults: defaults,
            target: nil,
            microphones: .init(identities: [.init(captureDeviceID: "mic", displayName: "Mic")], defaultCoreAudioUID: nil),
            applications: applications,
            preferredInputUID: nil
        )
    }
}
