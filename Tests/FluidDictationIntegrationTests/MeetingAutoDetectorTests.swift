@testable import FluidVoice_Debug
import Foundation
import XCTest

// MARK: - Fakes (protocols only — no CoreAudio/AX/NSWorkspace)

@MainActor
private final class FakeClock: MeetingClockProviding {
    var current: Date
    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) { self.current = date }
    func now() -> Date { self.current }
}

@MainActor
private final class FakeWorkspaceEvents: WorkspaceEventsProviding {
    var onEvent: ((WorkspaceEvent) -> Void)?
    func start(isRegistryApp: @escaping (String) -> Bool, onBackfill: @escaping ([WorkspaceEvent]) -> Void) {}
    func stop() {}
}

@MainActor
private final class FakeMicActivity: MicActivitySignalProviding {
    var onEdge: ((MicActivityEdge) -> Void)?
    func start() {}
    func stop() {}
}

@MainActor
private final class FakeAudioProcessActivity: AudioProcessActivityProviding {
    var activeBundleIdentifiers: Set<String> = []

    func isAudioActive(forBundleIdentifiers bundleIdentifiers: Set<String>) -> Bool {
        !self.activeBundleIdentifiers.isDisjoint(with: bundleIdentifiers)
    }
}

@MainActor
private final class FakeWindowSnapshotProvider: WindowSnapshotProviding {
    var axTitles: [String] = []
    func snapshot(interestPIDs: Set<Int32>) -> [WindowSnapshot] { [] }
    func titles(processID: Int32) async -> [String] { self.axTitles }
}

@MainActor
private final class FakeBrowserTabReader: BrowserTabReading {
    func frontmostTabURL(bundleIdentifier: String, processID: Int32) async -> BrowserTabURL? { nil }
}

@MainActor
private final class FakeActivityGate: DetectionActivityGate {
    var isIdle = true
    var preflightResult = true
    func preflightPasses() -> Bool { self.preflightResult }
}

/// Plain reference box so the detector's enablement closures don't need to capture `self` while
/// `DetectorHarness` is still mid-initialization.
@MainActor
private final class ToggleFlags {
    var nativeEnabled = true
    var browserEnabled = true
}

@MainActor
private final class DetectorHarness {
    let clock = FakeClock()
    let gate = FakeActivityGate()
    let flags = ToggleFlags()
    let audioProcessActivity = FakeAudioProcessActivity()
    let windowProvider = FakeWindowSnapshotProvider()
    var prompts: [MeetingAutoDetector.PromptRequest] = []
    var nudges = 0
    var invalidated: [UUID] = []
    let detector: MeetingAutoDetector

    var nativeEnabled: Bool {
        get { self.flags.nativeEnabled }
        set { self.flags.nativeEnabled = newValue }
    }

    var browserEnabled: Bool {
        get { self.flags.browserEnabled }
        set { self.flags.browserEnabled = newValue }
    }

    init() {
        let flags = self.flags
        self.detector = MeetingAutoDetector(
            workspaceEvents: FakeWorkspaceEvents(),
            micActivity: FakeMicActivity(),
            audioProcessActivity: self.audioProcessActivity,
            windowSnapshotProvider: self.windowProvider,
            browserTabReader: FakeBrowserTabReader(),
            activityGate: self.gate,
            clock: self.clock,
            isNativeDetectionEnabled: { flags.nativeEnabled },
            isBrowserDetectionEnabled: { flags.browserEnabled }
        )
        self.detector.onPromptRequested = { [weak self] request in self?.prompts.append(request) }
        self.detector.onStillRecordingNudge = { [weak self] in self?.nudges += 1 }
        self.detector.onEpisodeInvalidated = { [weak self] episodeID in self?.invalidated.append(episodeID) }
    }

    func advance(_ seconds: TimeInterval) {
        self.clock.current.addTimeInterval(seconds)
    }

    /// Arms + fronts a native app, then confirms it with a matching window and a coincident mic edge.
    @discardableResult
    func confirmZoom(pid: Int32 = 100) -> UUID? {
        self.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: pid), at: self.clock.now())
        self.detector.handleWindowSnapshot(
            [.init(processID: pid, windowID: 900, title: "Zoom Meeting", layer: 0)],
            at: self.clock.now()
        )
        self.detector.handleMicEdge(.init(isActive: true), at: self.clock.now())
        return self.prompts.last?.episodeID
    }
}

@MainActor
final class MeetingAutoDetectorTests: XCTestCase {
    // MARK: Prompt suppression

    func testPromptSuppressionAllowsDetectedMeetingAppFullScreen() {
        let reason = MeetingDetectionPromptController.suppressionReason(
            frontmostBundleIdentifier: "us.zoom.xos",
            isFrontmostFullScreen: true,
            isDictationOverlayPresented: false,
            requestBundleIdentifier: "us.zoom.xos"
        )
        XCTAssertNil(reason)
    }

    func testPromptSuppressionBlocksDifferentFullScreenAppAndDictationOverlay() {
        let fullScreenReason = MeetingDetectionPromptController.suppressionReason(
            frontmostBundleIdentifier: "com.apple.iWork.Keynote",
            isFrontmostFullScreen: true,
            isDictationOverlayPresented: false,
            requestBundleIdentifier: "us.zoom.xos"
        )
        XCTAssertEqual(fullScreenReason, .fullscreenOtherApp)

        let overlayReason = MeetingDetectionPromptController.suppressionReason(
            frontmostBundleIdentifier: "us.zoom.xos",
            isFrontmostFullScreen: true,
            isDictationOverlayPresented: true,
            requestBundleIdentifier: "us.zoom.xos"
        )
        XCTAssertEqual(overlayReason, .dictationOverlay)
    }

    func testPromptAutoDismissRemainingTimeClampsElapsedTime() {
        XCTAssertEqual(MeetingDetectionPromptController.remainingAutoDismissSeconds(20, after: 7.5), 12.5)
        XCTAssertEqual(MeetingDetectionPromptController.remainingAutoDismissSeconds(2, after: 4), 0)
        XCTAssertEqual(MeetingDetectionPromptController.remainingAutoDismissSeconds(2, after: -1), 2)
    }

    func testPromptDefaultsToTopCenterOfVisibleFrame() {
        let visibleFrame = NSRect(x: 100, y: 50, width: 1_200, height: 800)
        let frame = MeetingDetectionPromptController.defaultFrame(
            panelSize: MeetingDetectionPromptController.panelSize,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame.midX, visibleFrame.midX)
        XCTAssertEqual(frame.maxY, visibleFrame.maxY - 12)
        XCTAssertEqual(frame.size, MeetingDetectionPromptController.panelSize)
    }

    func testSuppressedReminderRetriesThenTimesOutWithinBudget() {
        XCTAssertEqual(
            MeetingDetectionPromptController.reminderPresentationDecision(remainingBudget: 20, isSuppressed: false),
            .present
        )
        XCTAssertEqual(
            MeetingDetectionPromptController.reminderPresentationDecision(remainingBudget: 20, isSuppressed: true),
            .retryAfter(MeetingDetectionPromptController.suppressionRetryInterval)
        )
        XCTAssertEqual(
            MeetingDetectionPromptController.reminderPresentationDecision(remainingBudget: 0.2, isSuppressed: true),
            .retryAfter(0.2)
        )
        XCTAssertEqual(
            MeetingDetectionPromptController.reminderPresentationDecision(remainingBudget: 0, isSuppressed: true),
            .timeout
        )
        XCTAssertEqual(
            MeetingDetectionPromptController.reminderPresentationDecision(remainingBudget: 0, isSuppressed: false),
            .timeout
        )
    }

    func testReplacingPromptTimesOutThePreviousEpisodeOnly() {
        let first = UUID()
        let second = UUID()
        XCTAssertEqual(
            MeetingDetectionPromptController.episodeToTimeoutOnReplacement(existing: first, incoming: second),
            first
        )
        XCTAssertNil(MeetingDetectionPromptController.episodeToTimeoutOnReplacement(existing: first, incoming: first))
        XCTAssertNil(MeetingDetectionPromptController.episodeToTimeoutOnReplacement(existing: nil, incoming: second))
    }

    func testCheapSuppressionDecisionShortCircuitsAX() {
        XCTAssertEqual(
            MeetingDetectionPromptController.cheapSuppressionDecision(
                frontmostBundleIdentifier: "us.zoom.xos",
                frontmostProcessIdentifier: 100,
                isDictationOverlayPresented: true,
                requestBundleIdentifier: "us.zoom.xos"
            ),
            .suppressed(.dictationOverlay)
        )
        XCTAssertEqual(
            MeetingDetectionPromptController.cheapSuppressionDecision(
                frontmostBundleIdentifier: "us.zoom.xos",
                frontmostProcessIdentifier: 100,
                isDictationOverlayPresented: false,
                requestBundleIdentifier: "us.zoom.xos"
            ),
            .presentNow
        )
        XCTAssertEqual(
            MeetingDetectionPromptController.cheapSuppressionDecision(
                frontmostBundleIdentifier: "com.apple.iWork.Keynote",
                frontmostProcessIdentifier: 200,
                isDictationOverlayPresented: false,
                requestBundleIdentifier: "us.zoom.xos"
            ),
            .queryFullscreen(200)
        )
        XCTAssertEqual(
            MeetingDetectionPromptController.cheapSuppressionDecision(
                frontmostBundleIdentifier: nil,
                frontmostProcessIdentifier: nil,
                isDictationOverlayPresented: false,
                requestBundleIdentifier: "us.zoom.xos"
            ),
            .presentNow
        )
    }

    func testSilentInvalidationOnlyMatchesVisibleOrPendingPrompt() {
        let visible = UUID()
        let pending = UUID()
        let other = UUID()
        XCTAssertTrue(
            MeetingDetectionPromptController.shouldSilentlyInvalidatePrompt(
                episodeID: visible,
                visibleEpisodeID: visible,
                pendingEpisodeID: pending
            )
        )
        XCTAssertTrue(
            MeetingDetectionPromptController.shouldSilentlyInvalidatePrompt(
                episodeID: pending,
                visibleEpisodeID: visible,
                pendingEpisodeID: pending
            )
        )
        XCTAssertFalse(
            MeetingDetectionPromptController.shouldSilentlyInvalidatePrompt(
                episodeID: other,
                visibleEpisodeID: visible,
                pendingEpisodeID: pending
            )
        )
    }

    func testStartErrorMessageSurfacesCaptureAndPreflightFailures() {
        XCTAssertEqual(
            MeetingDetectionPromptController.startErrorMessage(
                from: MeetingCaptureError.applicationUnavailable("us.zoom.xos"),
                appDisplayName: "Zoom"
            ),
            "Zoom is no longer available to record."
        )
        XCTAssertEqual(
            MeetingDetectionPromptController.startErrorMessage(
                from: MeetingAutoDetector.StartError.cannotStart,
                appDisplayName: "Zoom"
            ),
            "Can't start recording right now."
        )
        XCTAssertEqual(
            MeetingDetectionPromptController.startErrorMessage(
                from: MeetingCaptureError.microphonePermissionDenied,
                appDisplayName: "Zoom"
            ),
            "Microphone permission is required to record this meeting."
        )
    }

    func testCaptureTargetFailsClosedWhenPreferredAppIsRequiredAndMissing() {
        let chrome = MeetingApplicationIdentity(bundleIdentifier: "com.google.Chrome", displayName: "Chrome")
        let zoom = MeetingApplicationIdentity(bundleIdentifier: "us.zoom.xos", displayName: "Zoom")

        XCTAssertEqual(
            try MeetingCaptureSourceCatalog.resolveApplication(
                from: [chrome, zoom],
                preferredBundleIdentifier: "us.zoom.xos",
                requirePreferredApplication: true
            ).bundleIdentifier,
            "us.zoom.xos"
        )

        XCTAssertThrowsError(
            try MeetingCaptureSourceCatalog.resolveApplication(
                from: [chrome],
                preferredBundleIdentifier: "us.zoom.xos",
                requirePreferredApplication: true
            )
        ) { error in
            guard let captureError = error as? MeetingCaptureError,
                  case .applicationUnavailable("us.zoom.xos") = captureError
            else {
                return XCTFail("expected applicationUnavailable, got \(error)")
            }
        }

        XCTAssertEqual(
            try MeetingCaptureSourceCatalog.resolveApplication(
                from: [chrome],
                preferredBundleIdentifier: "us.zoom.xos",
                requirePreferredApplication: false
            ).bundleIdentifier,
            "com.google.Chrome",
            "manual/default setup may still fall back when the preferred app is absent"
        )

        XCTAssertEqual(
            try MeetingCaptureSourceCatalog.resolveApplication(
                from: [chrome],
                preferredBundleIdentifier: nil,
                requirePreferredApplication: false
            ).bundleIdentifier,
            "com.google.Chrome"
        )
    }

    // MARK: Coincidence window

    func testParkedTabWithLateMicNeverPrompts() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.google.Chrome", processID: 1), at: h.clock.now())
        h.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: "/abc-defg-hij"), pid: 1, bundleIdentifier: "com.google.Chrome", at: h.clock.now())

        h.advance(40) // evidence is now stale relative to the coincidence window
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.google.Chrome", processID: 1), at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())

        XCTAssertTrue(h.prompts.isEmpty, "evidence older than the 30s coincidence window must not confirm")
    }

    // MARK: Fail-closed on unreadable AXURL

    func testUnreadableAXURLNeverPrompts() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.google.Chrome", processID: 1), at: h.clock.now())
        h.detector.handleBrowserTabURL(nil, pid: 1, bundleIdentifier: "com.google.Chrome", at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty)
    }

    // MARK: YouTube-hostname never matches

    func testYouTubeNeverMatchesInCallURL() {
        XCTAssertFalse(MeetingInCallURLMatcher.isInCallURL(host: "www.youtube.com", path: "/watch"))
        XCTAssertFalse(MeetingInCallURLMatcher.isInCallURL(host: "youtube.com", path: "/live/abc-defg-hij"))
    }

    // MARK: Tier-1 frontmost-at-edge gate

    func testZoomConfirmsOnlyWhenFrontmostNearTheMicEdge() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 5), at: h.clock.now())
        h.detector.handleWindowSnapshot(
            [.init(processID: 5, windowID: 42, title: "Zoom Meeting", layer: 0)],
            at: h.clock.now()
        )
        h.advance(20) // beyond the 15s frontmost lead
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty, "stale frontmost must not confirm")

        let h2 = DetectorHarness()
        XCTAssertNotNil(h2.confirmZoom(), "frontmost within the lead window must confirm")
    }

    func testZoomNonMeetingWindowTitlesNeverConfirm() {
        for title in ["Zoom Workplace", "Zoom Client Healthcheck", ""] {
            let h = DetectorHarness()
            h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 5), at: h.clock.now())
            h.detector.handleWindowSnapshot(
                [.init(processID: 5, windowID: 42, title: title, layer: 0)],
                at: h.clock.now()
            )
            h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
            XCTAssertTrue(h.prompts.isEmpty, "\(title) must not count as meeting evidence")
        }
    }

    func testZoomTitleConfirmsWithAudioAndWindowEvidence() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 5), at: h.clock.now())
        h.detector.handleWindowSnapshot(
            [.init(processID: 5, windowID: 42, title: "Zoom", layer: 0)],
            at: h.clock.now()
        )
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
    }

    func testProcessAudioConfirmsMutedZoomJoinWithoutDeviceMicEdge() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 5), at: h.clock.now())
        h.detector.handleWindowSnapshot(
            [.init(processID: 5, windowID: 42, title: "Zoom", layer: 0)],
            at: h.clock.now()
        )
        h.audioProcessActivity.activeBundleIdentifiers = ["us.zoom.caphost"]
        h.detector.pollAudioProcessActivity(at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
    }

    func testAudioEvidenceAloneNeverPromptsAndWindowEvidenceAloneNeverPrompts() {
        let audioOnly = DetectorHarness()
        audioOnly.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 5), at: audioOnly.clock.now())
        audioOnly.detector.handleAudioProcessActivity(true, pid: 5, at: audioOnly.clock.now())
        XCTAssertTrue(audioOnly.prompts.isEmpty)

        let windowOnly = DetectorHarness()
        windowOnly.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 5), at: windowOnly.clock.now())
        windowOnly.detector.handleWindowSnapshot(
            [.init(processID: 5, windowID: 42, title: "Zoom", layer: 0)],
            at: windowOnly.clock.now()
        )
        XCTAssertTrue(windowOnly.prompts.isEmpty)
    }

    // MARK: Backfill arms only

    func testBackfillAlonesNeverConfirms() {
        let h = DetectorHarness()
        h.detector.handleBackfill([.init(kind: .launched, bundleIdentifier: "us.zoom.xos", processID: 7)])
        h.detector.handleWindowSnapshot(
            [.init(processID: 7, windowID: 1, title: "Zoom Meeting", layer: 0)],
            at: h.clock.now()
        )
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty, "backfill seeds no frontmost timestamp, so it can never confirm by itself")
    }

    // MARK: Episode dedup + back-to-back re-arm

    func testDuplicateConfirmDoesNotReprompt() {
        let h = DetectorHarness()
        h.confirmZoom()
        XCTAssertEqual(h.prompts.count, 1)
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1, "the same window key must not re-arm while still live")
    }

    func testBackToBackMeetingAfterReleaseRearmsTheSameWindow() {
        let h = DetectorHarness()
        let firstEpisode = h.confirmZoom()
        XCTAssertNotNil(firstEpisode)
        h.detector.timeoutDismissed(episodeID: firstEpisode!)

        // Window disappears; after grace + the 60s release window the episode is evicted.
        h.detector.handleWindowSnapshot([], at: h.clock.now())
        h.advance(70)
        h.detector.tick(at: h.clock.now())

        // A fresh meeting on the same window number re-arms.
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 100), at: h.clock.now())
        h.detector.handleWindowSnapshot(
            [.init(processID: 100, windowID: 900, title: "Zoom Meeting", layer: 0)],
            at: h.clock.now()
        )
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 2, "a genuinely new meeting must re-arm after the old episode ends")
    }

    func testTeamsBackToBackRearmsViaMicReleaseDespitePersistentWindow() {
        // Teams' main window never closes, so window loss can't end the episode — mic release must.
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.microsoft.teams2", processID: 300), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 300, windowID: 950, title: nil, layer: 0)], at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
        h.detector.timeoutDismissed(episodeID: h.prompts[0].episodeID)

        h.detector.handleMicEdge(.init(isActive: false), at: h.clock.now())
        h.advance(70)
        h.detector.tick(at: h.clock.now())

        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.microsoft.teams2", processID: 300), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 300, windowID: 950, title: nil, layer: 0)], at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 2, "a second Teams meeting after mic release must re-prompt even though the main window persisted")
    }

    func testProcessAudioInactiveForSixtySecondsEndsEpisodeAndReprompts() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 100), at: h.clock.now())
        h.detector.handleWindowSnapshot(
            [.init(processID: 100, windowID: 900, title: "Zoom", layer: 0)],
            at: h.clock.now()
        )
        h.detector.handleAudioProcessActivity(true, pid: 100, at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
        h.detector.timeoutDismissed(episodeID: h.prompts[0].episodeID)

        h.detector.handleAudioProcessActivity(false, pid: 100, at: h.clock.now())
        h.advance(70)
        h.detector.tick(at: h.clock.now())

        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 100), at: h.clock.now())
        h.detector.handleWindowSnapshot(
            [.init(processID: 100, windowID: 900, title: "Zoom", layer: 0)],
            at: h.clock.now()
        )
        h.detector.handleAudioProcessActivity(true, pid: 100, at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 2)
    }

    // MARK: Stop mid-call, no re-prompt

    func testStoppingOurRecordingMidCallDoesNotReprompt() {
        let h = DetectorHarness()
        let episodeID = h.confirmZoom()!
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))

        // The window is still there (the user is still in the call) — no eviction, no re-prompt.
        h.detector.handleWindowSnapshot(
            [.init(processID: 100, windowID: 900, title: "Zoom Meeting", layer: 0)],
            at: h.clock.now()
        )
        h.advance(70)
        h.detector.tick(at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1, "stopping our own recording must not retire a still-live episode")
    }

    // MARK: Manual start consumes the episode

    func testStartTappedIsSingleShot() {
        let h = DetectorHarness()
        let episodeID = h.confirmZoom()!
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))
        XCTAssertFalse(h.detector.startTapped(episodeID: episodeID), "a second Start on the same episode must be a no-op")
    }

    func testStartTappedFailsWhenPreflightNoLongerPasses() {
        let h = DetectorHarness()
        let episodeID = h.confirmZoom()!
        h.gate.preflightResult = false
        XCTAssertFalse(h.detector.startTapped(episodeID: episodeID))
    }

    func testCanStartDoesNotConsumeEpisode() {
        let h = DetectorHarness()
        let episodeID = h.confirmZoom()!
        XCTAssertTrue(h.detector.canStart(episodeID: episodeID))
        XCTAssertTrue(h.detector.canStart(episodeID: episodeID), "canStart must not consume")
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))
        XCTAssertFalse(h.detector.canStart(episodeID: episodeID))
    }

    func testAdoptStartedEpisodeSkipsPreflightAndStartTappedStaysSingleShot() {
        let h = DetectorHarness()
        let episodeID = h.confirmZoom()!
        h.gate.preflightResult = false
        XCTAssertFalse(h.detector.startTapped(episodeID: episodeID))
        h.detector.adoptStartedEpisode(episodeID: episodeID)
        XCTAssertFalse(h.detector.canStart(episodeID: episodeID))
        XCTAssertFalse(h.detector.startTapped(episodeID: episodeID))
        h.detector.adoptStartedEpisode(episodeID: episodeID)
    }

    func testAdoptStartedEpisodeAfterTimeoutOwnsTheEpisodeAndResetsDismissals() {
        let h = DetectorHarness()
        var suggested = false
        h.detector.onSuggestDisablingAutoDetect = { suggested = true }

        for pid: Int32 in [1, 2] {
            let episodeID = h.confirmZoom(pid: pid)!
            h.detector.dismissTapped(episodeID: episodeID, at: h.clock.now())
            h.advance(3600)
        }

        let timedOut = h.confirmZoom(pid: 3)!
        h.detector.timeoutDismissed(episodeID: timedOut)
        XCTAssertFalse(h.detector.startTapped(episodeID: timedOut))
        XCTAssertFalse(h.detector.canStart(episodeID: timedOut))
        h.detector.adoptStartedEpisode(episodeID: timedOut)

        h.detector.handleWindowSnapshot([], at: h.clock.now())
        h.advance(65)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1, "adopting after timeout must still arm the still-recording nudge")

        let dismissedEpisode = h.confirmZoom(pid: 4)!
        h.detector.dismissTapped(episodeID: dismissedEpisode, at: h.clock.now())
        XCTAssertFalse(suggested, "adopting after timeout must still reset the rolling counter")
    }

    // MARK: Preflight gate silence

    func testMissingScreenRecordingAtConfirmRequestsSetup() {
        let h = DetectorHarness()
        h.gate.preflightResult = false
        h.confirmZoom()
        XCTAssertEqual(h.prompts.count, 1)
        XCTAssertEqual(h.prompts.first?.cta, .setup)
    }

    func testBusyEvidenceStaysSilentThenPromptsWhenIdle() {
        let h = DetectorHarness()
        h.gate.isIdle = false
        h.confirmZoom()
        XCTAssertTrue(h.prompts.isEmpty)
        h.gate.isIdle = true
        h.detector.handleWindowSnapshot(
            [.init(processID: 100, windowID: 900, title: "Zoom Meeting", layer: 0)],
            at: h.clock.now()
        )
        XCTAssertEqual(h.prompts.count, 1)
        XCTAssertEqual(h.prompts.first?.cta, .record)
    }

    func testRedactedZoomUsesAXMeetingTitleEvenWhenWorkplaceComesFirst() async {
        let h = DetectorHarness()
        h.windowProvider.axTitles = ["Zoom Workplace", "Zoom Meeting"]
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 100), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 100, windowID: 900, title: nil, layer: 0)], at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        await Task.yield()
        XCTAssertEqual(h.prompts.count, 1)
        XCTAssertEqual(h.prompts.first?.cta, .record)
    }

    func testRedactedZoomWithoutAXTitlesDedupesUnreadableHealth() async {
        let h = DetectorHarness()
        var health: [MeetingAutoDetector.Health] = []
        h.detector.onHealthChanged = { health.append($0) }
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 100), at: h.clock.now())
        let redacted: [WindowSnapshot] = [.init(processID: 100, windowID: 900, title: nil, layer: 0)]
        h.detector.handleWindowSnapshot(redacted, at: h.clock.now())
        h.detector.handleWindowSnapshot(redacted, at: h.clock.now())
        await Task.yield()
        XCTAssertEqual(health, [.zoomWindowTitleUnreadable])
        XCTAssertTrue(h.prompts.isEmpty)
    }

    func testRedactedZoomWithOnlyWorkplaceIsReadableButDoesNotPrompt() async {
        let h = DetectorHarness()
        h.windowProvider.axTitles = ["Zoom Workplace"]
        var health: [MeetingAutoDetector.Health] = []
        h.detector.onHealthChanged = { health.append($0) }
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 100), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 100, windowID: 900, title: nil, layer: 0)], at: h.clock.now())
        await Task.yield()
        XCTAssertEqual(health, [.ready])
        XCTAssertTrue(h.prompts.isEmpty)
    }

    func testPrimaryActionSetupNeverRoutesToRecording() {
        XCTAssertEqual(
            MeetingDetectionPromptController.primaryAction(for: .setup),
            .openSetup
        )
        XCTAssertEqual(
            MeetingDetectionPromptController.primaryAction(for: .record),
            .startRecording
        )
    }

    func testTeamsNilWindowTitleStillPrompts() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(
            .init(kind: .activated, bundleIdentifier: "com.microsoft.teams2", processID: 100),
            at: h.clock.now()
        )
        h.detector.handleWindowSnapshot(
            [.init(processID: 100, windowID: 901, title: nil, layer: 0)],
            at: h.clock.now()
        )
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
        XCTAssertEqual(h.prompts.first?.cta, .record)
    }

    // MARK: Dismissal suppression + rolling counter

    func testExplicitDismissSuppressesTheBundleForThirtyMinutes() {
        let h = DetectorHarness()
        let firstEpisode = h.confirmZoom(pid: 1)!
        h.detector.dismissTapped(episodeID: firstEpisode, at: h.clock.now())

        h.detector.handleWindowSnapshot([], at: h.clock.now()) // window loss + eviction so the same window can re-arm
        h.advance(70)
        h.detector.tick(at: h.clock.now())

        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 1), at: h.clock.now())
        h.detector.handleWindowSnapshot(
            [.init(processID: 1, windowID: 900, title: "Zoom Meeting", layer: 0)],
            at: h.clock.now()
        )
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1, "the bundle stays suppressed for 30 minutes after an explicit dismiss")
    }

    func testTimeoutDismissDoesNotSuppressOrCount() {
        let h = DetectorHarness()
        let episodeID = h.confirmZoom()!
        h.detector.timeoutDismissed(episodeID: episodeID)

        h.detector.handleWindowSnapshot([], at: h.clock.now())
        h.advance(70)
        h.detector.tick(at: h.clock.now())

        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 100), at: h.clock.now())
        h.detector.handleWindowSnapshot(
            [.init(processID: 100, windowID: 900, title: "Zoom Meeting", layer: 0)],
            at: h.clock.now()
        )
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 2, "a 20s auto-dismiss must not suppress the bundle")
    }

    func testThreeDismissalsWithinFourteenDaysSuggestsDisabling() {
        let h = DetectorHarness()
        var suggested = false
        h.detector.onSuggestDisablingAutoDetect = { suggested = true }

        for pid: Int32 in [1, 2, 3] {
            let episodeID = h.confirmZoom(pid: pid)!
            h.detector.dismissTapped(episodeID: episodeID, at: h.clock.now())
            h.advance(3600)
        }
        XCTAssertTrue(suggested)
    }

    func testAcceptedStartResetsTheDismissalCounter() {
        let h = DetectorHarness()
        var suggested = false
        h.detector.onSuggestDisablingAutoDetect = { suggested = true }

        for pid: Int32 in [1, 2] {
            let episodeID = h.confirmZoom(pid: pid)!
            h.detector.dismissTapped(episodeID: episodeID, at: h.clock.now())
            h.advance(3600)
        }
        let acceptedEpisode = h.confirmZoom(pid: 3)!
        XCTAssertTrue(h.detector.startTapped(episodeID: acceptedEpisode))

        let dismissedEpisode = h.confirmZoom(pid: 4)!
        h.detector.dismissTapped(episodeID: dismissedEpisode, at: h.clock.now())
        XCTAssertFalse(suggested, "an accepted Start must reset the rolling counter")
    }

    // MARK: Lock / sleep disarm

    func testDisarmClearsAllTransientState() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 9), at: h.clock.now())
        h.detector.handleWindowSnapshot(
            [.init(processID: 9, windowID: 1, title: "Zoom Meeting", layer: 0)],
            at: h.clock.now()
        )
        h.detector.disarmAndClearTransientState()
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty, "disarm must drop frontmost/window evidence so a later edge cannot confirm")
    }

    func testEvictingUnconsumedEpisodeInvalidatesAndConsumedDoesNot() {
        let h = DetectorHarness()
        let unconsumed = h.confirmZoom(pid: 1)!
        let consumed = h.confirmZoom(pid: 2)!
        XCTAssertTrue(h.detector.startTapped(episodeID: consumed))

        h.detector.handleWindowSnapshot([], at: h.clock.now())
        h.advance(70)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.invalidated, [unconsumed])
    }

    func testDisarmInvalidatesUnconsumedEpisodesOnly() {
        let h = DetectorHarness()
        let unconsumed = h.confirmZoom(pid: 1)!
        let consumed = h.confirmZoom(pid: 2)!
        XCTAssertTrue(h.detector.startTapped(episodeID: consumed))

        h.detector.disarmAndClearTransientState()
        XCTAssertEqual(h.invalidated, [unconsumed])
    }

    // MARK: Still-recording nudge

    func testStillRecordingNudgeFiresOnceAfterWindowGoneSixtySeconds() {
        let h = DetectorHarness()
        let episodeID = h.confirmZoom()!
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))

        h.detector.handleWindowSnapshot([], at: h.clock.now())
        h.advance(65)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)

        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1, "the nudge fires once per session")
    }

    // MARK: Registry / URL matcher sanity

    func testRegistryTierLookup() {
        XCTAssertEqual(MeetingAppRegistry.tier(forBundleIdentifier: "us.zoom.xos"), .nativeTier1)
        XCTAssertEqual(MeetingAppRegistry.tier(forBundleIdentifier: "com.google.Chrome"), .browserTier2)
        XCTAssertEqual(MeetingAppRegistry.tier(forBundleIdentifier: "com.google.Chrome.app.abcdef"), .browserTier2)
        XCTAssertNil(MeetingAppRegistry.tier(forBundleIdentifier: "com.tinyspeck.slackmacgap"))
        XCTAssertNil(MeetingAppRegistry.tier(forBundleIdentifier: "com.apple.FaceTime"))
    }

    func testInCallURLMatcherAcceptsRoomsAndRejectsLandingPages() {
        XCTAssertTrue(MeetingInCallURLMatcher.isInCallURL(host: "meet.google.com", path: "/abc-defg-hij"))
        XCTAssertFalse(MeetingInCallURLMatcher.isInCallURL(host: "meet.google.com", path: "/"))
        XCTAssertTrue(MeetingInCallURLMatcher.isInCallURL(host: "us04web.zoom.us", path: "/j/123456789"))
        XCTAssertFalse(MeetingInCallURLMatcher.isInCallURL(host: "zoom.us", path: "/pricing"))
        XCTAssertTrue(MeetingInCallURLMatcher.isInCallURL(host: "teams.microsoft.com", path: "/l/meetup-join/abc"))
        XCTAssertTrue(MeetingInCallURLMatcher.isInCallURL(host: "whereby.com", path: "/my-room"))
        XCTAssertFalse(MeetingInCallURLMatcher.isInCallURL(host: "whereby.com", path: "/pricing"))
        XCTAssertTrue(MeetingInCallURLMatcher.isInCallURL(host: "meet.jit.si", path: "/SomeRoomName"))
    }

    // MARK: windowID preference in MeetingWindowSelector

    func testWindowSelectorPrefersPreferredWindowIDWhenEligible() {
        let candidates = [
            MeetingWindowCandidate(windowID: 1, title: "Untitled", frame: CGRect(x: 0, y: 0, width: 400, height: 400), layer: 0, zOrderIndex: 0),
            MeetingWindowCandidate(windowID: 2, title: "Small", frame: CGRect(x: 0, y: 0, width: 210, height: 110), layer: 0, zOrderIndex: 1),
        ]
        let selected = MeetingWindowSelector.selectWindow(from: candidates, preferredWindowID: 2)
        XCTAssertEqual(selected?.windowID, 2, "the preferred window must win even though it ranks lower")
    }

    func testWindowSelectorFallsBackWhenPreferredWindowIsGone() {
        let candidates = [
            MeetingWindowCandidate(windowID: 1, title: "Untitled", frame: CGRect(x: 0, y: 0, width: 400, height: 400), layer: 0, zOrderIndex: 0),
        ]
        let selected = MeetingWindowSelector.selectWindow(from: candidates, preferredWindowID: 999)
        XCTAssertEqual(selected?.windowID, 1)
    }
}
