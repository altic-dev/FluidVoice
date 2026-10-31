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
    var frontmostProcessID: Int32?
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
    var snapshotOverride: AudioProcessActivitySnapshot?
    var snapshotCount = 0
    var beforeSnapshot: (() -> Void)?

    func snapshot() async -> AudioProcessActivitySnapshot {
        self.snapshotCount += 1
        self.beforeSnapshot?()
        if let snapshotOverride { return snapshotOverride }
        let processes = self.activeBundleIdentifiers.map { bundle in
            let owner = bundle == "us.zoom.caphost" ? "us.zoom.xos" : bundle
            return AudioProcessDescriptor(
                processID: 55,
                bundleIdentifier: bundle,
                executablePath: "/Applications/\(owner).app/Contents/Helpers/\(bundle)",
                isInputRunning: bundle != "us.zoom.caphost",
                isOutputRunning: true
            )
        }
        let owners = self.activeBundleIdentifiers.map { bundle in
            let owner = bundle == "us.zoom.caphost" ? "us.zoom.xos" : bundle
            return MeetingProcessOwner(
                processID: 5,
                bundleIdentifier: owner,
                bundlePath: "/Applications/\(owner).app"
            )
        }
        return AudioProcessActivitySnapshot(processes: processes, owners: owners, queryState: .valid)
    }
}

@MainActor
private final class FakeWindowSnapshotProvider: WindowSnapshotProviding {
    var axTitles: [String] = []
    var lastInterestPIDs: Set<Int32> = []
    func snapshot(interestPIDs: Set<Int32>) -> [WindowSnapshot] {
        self.lastInterestPIDs = interestPIDs
        return []
    }

    func titles(processID: Int32) async -> [String] { self.axTitles }
}

@MainActor
private final class FakeBrowserTabReader: BrowserTabReading {
    var result: BrowserTabURL?
    var readPIDs: [Int32] = []
    func frontmostTabURL(bundleIdentifier: String, processID: Int32) async -> BrowserTabURL? {
        self.readPIDs.append(processID)
        return self.result
    }
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
    var lastSpeechAt: Date?
}

@MainActor
private final class DetectorHarness {
    let clock = FakeClock()
    let gate = FakeActivityGate()
    let flags = ToggleFlags()
    let audioProcessActivity = FakeAudioProcessActivity()
    let windowProvider = FakeWindowSnapshotProvider()
    let workspace = FakeWorkspaceEvents()
    let browserReader = FakeBrowserTabReader()
    var prompts: [MeetingAutoDetector.PromptRequest] = []
    var nudges = 0
    var withdrawals = 0
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

    init(rejectionLogger: @escaping (String) -> Void = { _ in }) {
        let flags = self.flags
        self.detector = MeetingAutoDetector(
            workspaceEvents: self.workspace,
            micActivity: FakeMicActivity(),
            audioProcessActivity: self.audioProcessActivity,
            windowSnapshotProvider: self.windowProvider,
            browserTabReader: self.browserReader,
            activityGate: self.gate,
            clock: self.clock,
            isNativeDetectionEnabled: { flags.nativeEnabled },
            isBrowserDetectionEnabled: { flags.browserEnabled },
            lastSpeechAt: { flags.lastSpeechAt },
            rejectionLogger: rejectionLogger
        )
        self.detector.onPromptRequested = { [weak self] request in self?.prompts.append(request) }
        self.detector.onStillRecordingNudge = { [weak self] in self?.nudges += 1 }
        self.detector.onStillRecordingNudgeWithdrawn = { [weak self] in self?.withdrawals += 1 }
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

    /// A Google Meet call in Chrome, confirmed from the front tab.
    @discardableResult
    func confirmChromeMeet(pid: Int32 = 8) -> UUID? {
        self.workspace.frontmostProcessID = pid
        self.detector.handleBackfill([.init(kind: .launched, bundleIdentifier: "com.google.Chrome", processID: pid)])
        self.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: "/abc-defg-hij"), pid: pid, bundleIdentifier: "com.google.Chrome", at: self.clock.now())
        self.detector.handleMicEdge(.init(isActive: true), at: self.clock.now())
        return self.prompts.last?.episodeID
    }

    /// What the audio system reports for Chrome: its helper holds the microphone, or nothing does.
    func pollChrome(microphoneInUse: Bool, pid: Int32 = 8, readable: Bool = true) async {
        let chrome = MeetingProcessOwner(processID: pid, bundleIdentifier: "com.google.Chrome", bundlePath: "/Applications/Google Chrome.app")
        let helper = AudioProcessDescriptor(
            processID: 4242,
            bundleIdentifier: "com.google.Chrome.helper",
            executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
            isInputRunning: microphoneInUse,
            isOutputRunning: true
        )
        self.audioProcessActivity.snapshotOverride = AudioProcessActivitySnapshot(
            processes: [helper],
            owners: [chrome],
            queryState: readable ? .valid : .unknown
        )
        await self.detector.pollAudioProcessActivity(at: self.clock.now())
    }

    /// Teams keeps a window open all day, so only its audio says whether a call is on.
    @discardableResult
    func confirmTeams(pid: Int32 = 300) -> UUID? {
        self.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.microsoft.teams2", processID: pid), at: self.clock.now())
        self.detector.handleWindowSnapshot([.init(processID: pid, windowID: 950, title: nil, layer: 0)], at: self.clock.now())
        self.detector.handleMicEdge(.init(isActive: true), at: self.clock.now())
        return self.prompts.last?.episodeID
    }
}

@MainActor
final class MeetingAutoDetectorTests: XCTestCase {
    func testAutomaticSourcePublishesConfirmedTargetWithoutConsumingPrompt() throws {
        let h = DetectorHarness()
        var changes: [MeetingAutoDetector.ResolvedTarget?] = []
        h.detector.onAutomaticTargetChanged = { changes.append($0) }
        XCTAssertNil(h.detector.automaticTarget)
        let episode = try XCTUnwrap(h.confirmZoom())
        XCTAssertEqual(h.detector.automaticTarget?.bundleIdentifier, "us.zoom.xos")
        XCTAssertEqual(h.detector.automaticTarget?.pid, 100)
        XCTAssertEqual(h.detector.automaticTarget?.windowID, 900)
        XCTAssertTrue(h.detector.canStart(episodeID: episode), "Selecting a source must not consume or start a recording")
        let count = changes.count
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(changes.count, count, "Unchanged evidence must not trigger source refreshes")
        h.detector.timeoutDismissed(episodeID: episode)
        XCTAssertNotNil(h.detector.automaticTarget, "Prompt timeout must not hide a live source from the manual page")
        h.detector.handleWindowSnapshot([], at: h.clock.now())
        XCTAssertNil(h.detector.automaticTarget, "Do not retain a source through the episode's teardown grace period")
    }

    func testAutomaticSourceClearsWhenDetectionDisabledOrStopped() {
        let h = DetectorHarness()
        h.confirmZoom()
        XCTAssertNotNil(h.detector.automaticTarget)
        h.nativeEnabled = false
        h.detector.tick(at: h.clock.now())
        XCTAssertNil(h.detector.automaticTarget)
        h.nativeEnabled = true
        h.detector.tick(at: h.clock.now())
        XCTAssertNotNil(h.detector.automaticTarget)
        h.detector.stop()
        XCTAssertNil(h.detector.automaticTarget)
    }

    func testAutomaticSourceDoesNotGuessBetweenTwoLiveMeetings() {
        let h = DetectorHarness()
        h.confirmZoom(pid: 100)
        h.confirmZoom(pid: 200)
        h.detector.handleWindowSnapshot([
            .init(processID: 100, windowID: 900, title: "Zoom Meeting", layer: 0),
            .init(processID: 200, windowID: 900, title: "Zoom Meeting", layer: 0),
        ], at: h.clock.now())
        XCTAssertNil(h.detector.automaticTarget)
        h.detector.handleWorkspaceEvent(.init(kind: .terminated, bundleIdentifier: "us.zoom.xos", processID: 200), at: h.clock.now())
        XCTAssertEqual(h.detector.automaticTarget?.pid, 100)
        h.detector.disarmAndClearTransientState()
        XCTAssertNil(h.detector.automaticTarget)
    }

    // MARK: - Generic HAL ownership resolver

    func testAudioResolverMapsHelpersInsideEachRegisteredNativeBundle() {
        let apps = [
            ("com.microsoft.teams2", "/Applications/Microsoft Teams.app"),
            ("com.microsoft.teams", "/Applications/Classic Teams.app"),
            ("us.zoom.xos", "/Applications/zoom.us.app"),
            ("com.cisco.webexmeetingsapp", "/Applications/Webex.app"),
            ("Cisco-Systems.Spark", "/Applications/Webex New.app"),
        ]
        for (bundle, root) in apps {
            let result = MeetingAudioProcessResolver.activeOwnerInputByPID(snapshot: .init(
                processes: [.init(
                    processID: 900,
                    bundleIdentifier: "helper.unknown",
                    executablePath: root + "/Contents/Helpers/Module.app/Contents/MacOS/Module",
                    isInputRunning: true,
                    isOutputRunning: false
                )],
                owners: [.init(processID: 42, bundleIdentifier: bundle, bundlePath: root)],
                queryState: .valid
            ))
            XCTAssertEqual(result?[42], true, "helper attribution should work for \(bundle)")
        }
    }

    func testAudioResolverRejectsPrefixSpoofRelativeMissingAndAmbiguousOwners() {
        // nil requests the fixture default; an empty collection tests explicitly missing data.
        // swiftlint:disable:next discouraged_optional_collection
        func resolve(_ processPath: String?, owners: [MeetingProcessOwner]) -> [Int32: Bool]? {
            MeetingAudioProcessResolver.activeOwnerInputByPID(snapshot: .init(
                processes: [.init(processID: 1, bundleIdentifier: nil, executablePath: processPath, isInputRunning: true, isOutputRunning: false)],
                owners: owners,
                queryState: .valid
            ))
        }
        let owner = MeetingProcessOwner(processID: 10, bundleIdentifier: "com.microsoft.teams2", bundlePath: "/Applications/Teams.app")
        XCTAssertEqual(resolve("/Applications/Teams.app.evil/Contents/MacOS/x", owners: [owner]), [:])
        XCTAssertNil(resolve(nil, owners: [owner]))
        XCTAssertNil(resolve("Applications/Teams.app/Contents/MacOS/x", owners: [owner]))
        XCTAssertNil(resolve(
            "/Applications/Teams.app/Contents/MacOS/x",
            owners: [owner, .init(processID: 11, bundleIdentifier: "com.microsoft.teams2", bundlePath: "/Applications/Teams.app")]
        ))
        XCTAssertEqual(
            resolve("/Applications/Teams.app/Contents/MacOS/x", owners: [.init(processID: 10, bundleIdentifier: "com.google.Chrome", bundlePath: "/Applications/Teams.app")]),
            [:],
            "browser owners must never become native audio owners"
        )
        XCTAssertEqual(
            resolve("/Applications/Teams.app/Contents/MacOS/x", owners: [.init(processID: 10, bundleIdentifier: "com.microsoft.teams2", bundlePath: "relative/Teams.app")]),
            [:]
        )
    }

    func testAudioResolverRejectsBrowserOwnerAndUnknownQuery() {
        let browser = MeetingProcessOwner(processID: 3, bundleIdentifier: "com.google.Chrome", bundlePath: "/Applications/Chrome.app")
        let process = AudioProcessDescriptor(
            processID: 4,
            bundleIdentifier: nil,
            executablePath: "/Applications/Chrome.app/Contents/MacOS/Chrome",
            isInputRunning: true,
            isOutputRunning: true
        )
        XCTAssertNil(MeetingAudioProcessResolver.activeOwnerInputByPID(snapshot: .init(processes: [process], owners: [browser], queryState: .unknown)))
    }

    func testAudioResolverRejectsSymlinkEscapingBundle() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("meeting-resolver-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Teams.app")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data().write(to: outside.appendingPathComponent("Module"))
        let link = app.appendingPathComponent("Contents")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = MeetingAudioProcessResolver.activeOwnerInputByPID(snapshot: .init(
            processes: [.init(processID: 1, bundleIdentifier: nil, executablePath: link.path + "/Module", isInputRunning: true, isOutputRunning: false)],
            owners: [.init(processID: 2, bundleIdentifier: "com.microsoft.teams2", bundlePath: app.path)],
            queryState: .valid
        ))
        XCTAssertEqual(result, [:])
    }

    func testGenericOutputOnlyHelperDoesNotCreateNewPrompt() async {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.microsoft.teams2", processID: 5), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 5, windowID: 9, title: nil, layer: 0)], at: h.clock.now())
        h.audioProcessActivity.snapshotOverride = .init(
            processes: [.init(
                processID: 55,
                bundleIdentifier: "teams.helper",
                executablePath: "/Applications/com.microsoft.teams2.app/Contents/Helpers/Module",
                isInputRunning: false,
                isOutputRunning: true
            )],
            owners: [.init(processID: 5, bundleIdentifier: "com.microsoft.teams2", bundlePath: "/Applications/com.microsoft.teams2.app")],
            queryState: .valid
        )
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty)
    }

    func testNativePollTakesOneSnapshot() async {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .launched, bundleIdentifier: "com.microsoft.teams2", processID: 5), at: h.clock.now())
        h.detector.handleWorkspaceEvent(.init(kind: .launched, bundleIdentifier: "us.zoom.xos", processID: 6), at: h.clock.now())
        h.audioProcessActivity.snapshotOverride = .init(processes: [], owners: [], queryState: .valid)
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        XCTAssertEqual(h.audioProcessActivity.snapshotCount, 1)
    }

    func testSnapshotCannotApplyToReusedPIDAfterTermination() async {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .launched, bundleIdentifier: "com.microsoft.teams2", processID: 5), at: h.clock.now())
        h.audioProcessActivity.snapshotOverride = .init(
            processes: [.init(
                processID: 55,
                bundleIdentifier: "teams.helper",
                executablePath: "/Applications/Teams.app/Contents/Helpers/Module",
                isInputRunning: true,
                isOutputRunning: true
            )],
            owners: [.init(processID: 5, bundleIdentifier: "com.microsoft.teams2", bundlePath: "/Applications/Teams.app")],
            queryState: .valid
        )
        h.audioProcessActivity.beforeSnapshot = {
            h.detector.handleWorkspaceEvent(.init(kind: .terminated, bundleIdentifier: "com.microsoft.teams2", processID: 5), at: h.clock.now())
            h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.microsoft.teams2", processID: 5), at: h.clock.now())
            h.detector.handleWindowSnapshot([.init(processID: 5, windowID: 7, title: nil, layer: 0)], at: h.clock.now())
        }
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty)
    }

    func testUnknownAudioQueryCannotCreateNativePrompt() async {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.microsoft.teams2", processID: 5), at: h.clock.now())
        h.detector.handleAudioProcessActivity(true, pid: 5, at: h.clock.now())
        h.audioProcessActivity.snapshotOverride = .init(processes: [], owners: [], queryState: .unknown)
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 5, windowID: 1, title: nil, layer: 0)], at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty)
    }

    func testUnknownQueryResetsContinuousInactivityAndPreservesEpisode() async {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 5), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 5, windowID: 1, title: "Zoom", layer: 0)], at: h.clock.now())
        h.detector.handleAudioProcessActivity(true, pid: 5, at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
        h.detector.handleAudioProcessActivity(false, pid: 5, at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: false), at: h.clock.now())
        h.advance(30)
        h.audioProcessActivity.snapshotOverride = .init(processes: [], owners: [], queryState: .unknown)
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        h.advance(70)
        h.detector.tick(at: h.clock.now())
        XCTAssertTrue(h.invalidated.isEmpty)
        h.audioProcessActivity.snapshotOverride = .init(processes: [], owners: [], queryState: .valid)
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        h.detector.tick(at: h.clock.now())
        XCTAssertTrue(h.invalidated.isEmpty)
        h.advance(61)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.invalidated, [h.prompts[0].episodeID])
    }

    func testUnknownNativeSnapshotDoesNotBlockBrowserURLDetection() async {
        let h = DetectorHarness()
        h.audioProcessActivity.snapshotOverride = .init(processes: [], owners: [], queryState: .unknown)
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.google.Chrome", processID: 8), at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        h.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: "/abc-defg-hij"), pid: 8, bundleIdentifier: "com.google.Chrome", at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
        XCTAssertEqual(h.prompts.first?.tier, .browserTier2)
    }

    func testProcessOwnerLookupDoesNotBlockMainAndPreservesSnapshot() async {
        let entered = expectation(description: "owner lookup on worker")
        let release = DispatchSemaphore(value: 0)
        let owners = [MeetingProcessOwner(processID: 42, bundleIdentifier: "us.zoom.xos", bundlePath: "/Applications/zoom.us.app")]
        let provider = CoreAudioProcessActivityProvider(
            readOwners: {
                XCTAssertFalse(Thread.isMainThread)
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
                return owners
            },
            readActivity: { snapshotOwners in
                XCTAssertFalse(Thread.isMainThread)
                return .init(processes: [], owners: snapshotOwners, queryState: .valid)
            }
        )
        let task = Task { await provider.snapshot() }
        await fulfillment(of: [entered], timeout: 1)
        // This main-actor continuation must run while the owner lookup is blocked.
        release.signal()
        let snapshot = await task.value
        XCTAssertEqual(snapshot.owners, owners)
        XCTAssertEqual(snapshot.queryState, .valid)
    }

    func testCancelledProcessOwnerLookupSkipsAudioQuery() async {
        let entered = expectation(description: "owner lookup on worker")
        let release = DispatchSemaphore(value: 0)
        let provider = CoreAudioProcessActivityProvider(
            readOwners: {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 2)
                return []
            },
            readActivity: { _ in
                XCTFail("A cancelled meeting poll must not start an audio query")
                return .init(processes: [], owners: [], queryState: .valid)
            }
        )
        let task = Task { await provider.snapshot() }
        await fulfillment(of: [entered], timeout: 1)
        task.cancel()
        release.signal()
        let snapshot = await task.value
        XCTAssertEqual(snapshot.queryState, .unknown)
        XCTAssertTrue(snapshot.owners.isEmpty)
    }

    func testLiveAudioProcessOwnershipProbe() async throws {
        guard ProcessInfo.processInfo.environment["FV_DETECTOR_LIVE_PROBE"] == "1" else {
            throw XCTSkip("Opt-in read-only live Core Audio ownership probe")
        }
        let snapshot = await CoreAudioProcessActivityProvider().snapshot()
        XCTAssertEqual(snapshot.queryState, .valid)
        let result = try XCTUnwrap(MeetingAudioProcessResolver.activeOwnerInputByPID(snapshot: snapshot))
        for owner in snapshot.owners {
            print("FV_DETECTOR_PROBE owner=\(owner.bundleIdentifier) pid=\(owner.processID) active=\(result[owner.processID] != nil) input=\(result[owner.processID] == true)")
        }
        for process in snapshot.processes where process.bundleIdentifier?.contains("teams") == true {
            print("FV_DETECTOR_PROBE process=\(process.bundleIdentifier ?? "unknown") pid=\(process.processID) input=\(process.isInputRunning) output=\(process.isOutputRunning)")
            if process.isInputRunning {
                let owner = try XCTUnwrap(snapshot.owners.first { $0.bundleIdentifier == "com.microsoft.teams2" })
                XCTAssertEqual(result[owner.processID], true)
            }
        }
    }

    func testActiveBeforeForegroundCanRecoverAfterStaleWindowDeadline() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .launched, bundleIdentifier: "com.microsoft.teams2", processID: 5), at: h.clock.now())
        h.detector.handleAudioProcessActivity(true, pid: 5, at: h.clock.now())
        h.advance(31)
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.microsoft.teams2", processID: 5), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 5, windowID: 2, title: nil, layer: 0)], at: h.clock.now())
        h.detector.handleAudioProcessActivity(true, pid: 5, at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
    }

    func testUnrelatedMicReleaseDoesNotEndProcessConfirmedEpisode() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 5), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 5, windowID: 3, title: "Zoom", layer: 0)], at: h.clock.now())
        h.detector.handleAudioProcessActivity(true, pid: 5, at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
        h.detector.handleMicEdge(.init(isActive: false), at: h.clock.now())
        h.advance(61)
        h.detector.tick(at: h.clock.now())
        h.detector.handleAudioProcessActivity(true, pid: 5, at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
    }

    // MARK: - Prompt suppression

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
        let visibleFrame = NSRect(x: 100, y: 50, width: 1200, height: 800)
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

    // MARK: - Coincidence window

    func testParkedTabWithLateMicNeverPrompts() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.google.Chrome", processID: 1), at: h.clock.now())
        h.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: "/abc-defg-hij"), pid: 1, bundleIdentifier: "com.google.Chrome", at: h.clock.now())

        h.advance(40) // evidence is now stale relative to the coincidence window
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.google.Chrome", processID: 1), at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())

        XCTAssertTrue(h.prompts.isEmpty, "evidence older than the 30s coincidence window must not confirm")
    }

    // MARK: - Fail-closed on unreadable AXURL

    func testUnreadableAXURLNeverPrompts() {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.google.Chrome", processID: 1), at: h.clock.now())
        h.detector.handleBrowserTabURL(nil, pid: 1, bundleIdentifier: "com.google.Chrome", at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty)
    }

    // MARK: - YouTube-hostname never matches

    func testYouTubeNeverMatchesInCallURL() {
        XCTAssertFalse(MeetingInCallURLMatcher.isInCallURL(host: "www.youtube.com", path: "/watch"))
        XCTAssertFalse(MeetingInCallURLMatcher.isInCallURL(host: "youtube.com", path: "/live/abc-defg-hij"))
    }

    // MARK: - Tier-1 frontmost-at-edge gate

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

    func testProcessAudioConfirmsMutedZoomJoinWithoutDeviceMicEdge() async {
        let h = DetectorHarness()
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 5), at: h.clock.now())
        h.detector.handleWindowSnapshot(
            [.init(processID: 5, windowID: 42, title: "Zoom", layer: 0)],
            at: h.clock.now()
        )
        h.audioProcessActivity.activeBundleIdentifiers = ["us.zoom.caphost"]
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
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

    // MARK: - Backfill arms only

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

    func testBackfilledBrowserInFrontAtMicEdgeConfirms() {
        let h = DetectorHarness()
        h.browserEnabled = true
        h.workspace.frontmostProcessID = 8
        h.detector.handleBackfill([.init(kind: .launched, bundleIdentifier: "com.google.Chrome", processID: 8)])
        h.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: "/abc-defg-hij"), pid: 8, bundleIdentifier: "com.google.Chrome", at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1, "a browser already in front when the mic opens is frontmost evidence; the in-call URL still gates it")
        XCTAssertEqual(h.prompts.first?.serviceName, "Google Meet")
    }

    func testBackfilledBrowserInFrontWithoutInCallURLDoesNotConfirm() {
        let h = DetectorHarness()
        h.browserEnabled = true
        h.workspace.frontmostProcessID = 8
        h.detector.handleBackfill([.init(kind: .launched, bundleIdentifier: "com.google.Chrome", processID: 8)])
        h.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: "/landing"), pid: 8, bundleIdentifier: "com.google.Chrome", at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty, "frontmost-now never substitutes for window evidence")
    }

    func testBackfilledNativeAppInFrontAtMicEdgeStillNeedsActivation() {
        let h = DetectorHarness()
        h.workspace.frontmostProcessID = 7
        h.detector.handleBackfill([.init(kind: .launched, bundleIdentifier: "us.zoom.xos", processID: 7)])
        h.detector.handleWindowSnapshot(
            [.init(processID: 7, windowID: 1, title: "Zoom Meeting", layer: 0)],
            at: h.clock.now()
        )
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty, "native apps keep the activation rule; their windows persist all day")
    }

    // MARK: - Episode dedup + back-to-back re-arm

    func testDuplicateConfirmDoesNotReprompt() {
        let h = DetectorHarness()
        h.confirmZoom()
        XCTAssertEqual(h.prompts.count, 1)
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1, "the same window key must not re-arm while still live")
    }

    func testBackToBackMeetingAfterReleaseRearmsTheSameWindow() throws {
        let h = DetectorHarness()
        let firstEpisode = h.confirmZoom()
        XCTAssertNotNil(firstEpisode)
        try h.detector.timeoutDismissed(episodeID: XCTUnwrap(firstEpisode))

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

    // MARK: - Stop mid-call, no re-prompt

    func testStoppingOurRecordingMidCallDoesNotReprompt() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmZoom())
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

    // MARK: - Manual start consumes the episode

    func testStartTappedIsSingleShot() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmZoom())
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))
        XCTAssertFalse(h.detector.startTapped(episodeID: episodeID), "a second Start on the same episode must be a no-op")
    }

    func testStartTappedFailsWhenPreflightNoLongerPasses() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmZoom())
        h.gate.preflightResult = false
        XCTAssertFalse(h.detector.startTapped(episodeID: episodeID))
    }

    func testCanStartDoesNotConsumeEpisode() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmZoom())
        XCTAssertTrue(h.detector.canStart(episodeID: episodeID))
        XCTAssertTrue(h.detector.canStart(episodeID: episodeID), "canStart must not consume")
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))
        XCTAssertFalse(h.detector.canStart(episodeID: episodeID))
    }

    func testAdoptStartedEpisodeSkipsPreflightAndStartTappedStaysSingleShot() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmZoom())
        h.gate.preflightResult = false
        XCTAssertFalse(h.detector.startTapped(episodeID: episodeID))
        h.detector.adoptStartedEpisode(episodeID: episodeID)
        XCTAssertFalse(h.detector.canStart(episodeID: episodeID))
        XCTAssertFalse(h.detector.startTapped(episodeID: episodeID))
        h.detector.adoptStartedEpisode(episodeID: episodeID)
    }

    func testAdoptStartedEpisodeAfterTimeoutOwnsTheEpisodeAndResetsDismissals() throws {
        let h = DetectorHarness()
        var suggested = false
        h.detector.onSuggestDisablingAutoDetect = { suggested = true }

        for pid: Int32 in [1, 2] {
            let episodeID = try XCTUnwrap(h.confirmZoom(pid: pid))
            h.detector.dismissTapped(episodeID: episodeID, at: h.clock.now())
            h.advance(3600)
        }

        let timedOut = try XCTUnwrap(h.confirmZoom(pid: 3))
        h.detector.timeoutDismissed(episodeID: timedOut)
        XCTAssertFalse(h.detector.startTapped(episodeID: timedOut))
        XCTAssertFalse(h.detector.canStart(episodeID: timedOut))
        h.detector.adoptStartedEpisode(episodeID: timedOut)

        h.detector.handleWindowSnapshot([], at: h.clock.now())
        h.advance(65)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1, "adopting after timeout must still arm the still-recording nudge")

        let dismissedEpisode = try XCTUnwrap(h.confirmZoom(pid: 4))
        h.detector.dismissTapped(episodeID: dismissedEpisode, at: h.clock.now())
        XCTAssertFalse(suggested, "adopting after timeout must still reset the rolling counter")
    }

    // MARK: - Preflight gate silence

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

    func testRepeatedBusyEvidenceLogsOnceWithoutBlockingLaterPrompt() {
        var lines: [String] = []
        let h = DetectorHarness(rejectionLogger: { lines.append($0) })
        h.gate.isIdle = false
        h.confirmZoom()
        let target = h.detector.automaticTarget
        for _ in 0..<100 {
            h.detector.handleWindowSnapshot(
                [.init(processID: 100, windowID: 900, title: "Zoom Meeting", layer: 0)],
                at: h.clock.now()
            )
        }
        XCTAssertEqual(lines.filter { $0.contains("reason=busy") }.count, 1)
        XCTAssertTrue(h.prompts.isEmpty)
        XCTAssertEqual(h.detector.automaticTarget, target)
        h.gate.isIdle = true
        h.detector.handleWindowSnapshot(
            [.init(processID: 100, windowID: 900, title: "Zoom Meeting", layer: 0)],
            at: h.clock.now()
        )
        XCTAssertEqual(h.prompts.count, 1)
        XCTAssertEqual(h.prompts.first?.cta, .record)
    }

    func testRejectionLoggingResetsOnTerminationStopAndSleep() {
        var lines: [String] = []
        let h = DetectorHarness(rejectionLogger: { lines.append($0) })
        h.gate.isIdle = false
        h.confirmZoom()
        h.detector.handleWorkspaceEvent(.init(kind: .terminated, bundleIdentifier: "us.zoom.xos", processID: 100), at: h.clock.now())
        h.confirmZoom()
        XCTAssertEqual(lines.filter { $0.contains("reason=busy") }.count, 2)
        h.detector.stop()
        h.confirmZoom()
        XCTAssertEqual(lines.filter { $0.contains("reason=busy") }.count, 3)
        h.detector.disarmAndClearTransientState()
        h.confirmZoom()
        XCTAssertEqual(lines.filter { $0.contains("reason=busy") }.count, 4)
        XCTAssertTrue(h.prompts.isEmpty)
    }

    func testRejectionLoggingIsIndependentPerCandidateAndReason() {
        var lines: [String] = []
        let h = DetectorHarness(rejectionLogger: { lines.append($0) })
        h.gate.isIdle = false
        h.confirmZoom(pid: 100)
        h.confirmZoom(pid: 200)
        XCTAssertEqual(lines.filter { $0.contains("reason=busy") }.count, 2)
        h.advance(31)
        for _ in 0..<2 {
            h.detector.handleWindowSnapshot(
                [.init(processID: 200, windowID: 900, title: "Zoom Meeting", layer: 0)],
                at: h.clock.now()
            )
        }
        XCTAssertEqual(lines.filter { $0.contains("reason=deadline") }.count, 1)
        XCTAssertTrue(h.prompts.isEmpty)
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

    // MARK: - Dismissal suppression + rolling counter

    func testExplicitDismissSuppressesTheBundleForThirtyMinutes() throws {
        let h = DetectorHarness()
        let firstEpisode = try XCTUnwrap(h.confirmZoom(pid: 1))
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

    func testTimeoutDismissDoesNotSuppressOrCount() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmZoom())
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

    func testThreeDismissalsWithinFourteenDaysSuggestsDisabling() throws {
        let h = DetectorHarness()
        var suggested = false
        h.detector.onSuggestDisablingAutoDetect = { suggested = true }

        for pid: Int32 in [1, 2, 3] {
            let episodeID = try XCTUnwrap(h.confirmZoom(pid: pid))
            h.detector.dismissTapped(episodeID: episodeID, at: h.clock.now())
            h.advance(3600)
        }
        XCTAssertTrue(suggested)
    }

    func testAcceptedStartResetsTheDismissalCounter() throws {
        let h = DetectorHarness()
        var suggested = false
        h.detector.onSuggestDisablingAutoDetect = { suggested = true }

        for pid: Int32 in [1, 2] {
            let episodeID = try XCTUnwrap(h.confirmZoom(pid: pid))
            h.detector.dismissTapped(episodeID: episodeID, at: h.clock.now())
            h.advance(3600)
        }
        let acceptedEpisode = try XCTUnwrap(h.confirmZoom(pid: 3))
        XCTAssertTrue(h.detector.startTapped(episodeID: acceptedEpisode))

        let dismissedEpisode = try XCTUnwrap(h.confirmZoom(pid: 4))
        h.detector.dismissTapped(episodeID: dismissedEpisode, at: h.clock.now())
        XCTAssertFalse(suggested, "an accepted Start must reset the rolling counter")
    }

    // MARK: - Lock / sleep disarm

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

    func testEvictingUnconsumedEpisodeInvalidatesAndConsumedDoesNot() throws {
        let h = DetectorHarness()
        let unconsumed = try XCTUnwrap(h.confirmZoom(pid: 1))
        let consumed = try XCTUnwrap(h.confirmZoom(pid: 2))
        XCTAssertTrue(h.detector.startTapped(episodeID: consumed))

        h.detector.handleWindowSnapshot([], at: h.clock.now())
        h.advance(70)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.invalidated, [unconsumed])
    }

    func testDisarmInvalidatesUnconsumedEpisodesOnly() throws {
        let h = DetectorHarness()
        let unconsumed = try XCTUnwrap(h.confirmZoom(pid: 1))
        let consumed = try XCTUnwrap(h.confirmZoom(pid: 2))
        XCTAssertTrue(h.detector.startTapped(episodeID: consumed))

        h.detector.disarmAndClearTransientState()
        XCTAssertEqual(h.invalidated, [unconsumed])
    }

    // MARK: - Still-recording nudge

    func testStillRecordingNudgeFiresOnceAfterWindowGoneSixtySeconds() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmZoom())
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))

        h.detector.handleWindowSnapshot([], at: h.clock.now())
        h.advance(65)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)

        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1, "the nudge fires once per session")
    }

    func testTeamsAsksOnceItsAudioStopsEvenThoughItsWindowStaysOpen() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmTeams())
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))
        h.detector.handleAudioProcessActivity(true, pid: 300, at: h.clock.now())
        h.advance(600)
        h.detector.handleAudioProcessActivity(true, pid: 300, at: h.clock.now())
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 0, "a call that is still using audio is not over")

        h.detector.handleAudioProcessActivity(false, pid: 300, at: h.clock.now())
        h.advance(MeetingAutoDetector.endSignalGraceSeconds - 2)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 0, "a short gap in the app's audio is not the end of the call")

        h.advance(4)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)

        h.advance(120)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1, "the episode retiring must not ask a second time")
    }

    func testAudioThatComesBackBeforeTheGraceEndsNeverAsks() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmTeams())
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))
        h.detector.handleAudioProcessActivity(true, pid: 300, at: h.clock.now())

        h.detector.handleAudioProcessActivity(false, pid: 300, at: h.clock.now())
        h.advance(10)
        h.detector.handleAudioProcessActivity(true, pid: 300, at: h.clock.now())
        h.advance(60)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 0)
    }

    func testAnAppWhoseAudioWasNeverSeenRunningDoesNotAskWhenItReadsAsIdle() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmTeams())
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))

        // The per-app audio query never showed this app running, so "not running" tells us nothing.
        h.detector.handleAudioProcessActivity(false, pid: 300, at: h.clock.now())
        h.advance(300)
        h.detector.handleAudioProcessActivity(false, pid: 300, at: h.clock.now())
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 0)
    }

    func testAnUnreadableAudioQueryIsNotTakenAsTheCallEnding() async throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmTeams())
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))
        h.detector.handleAudioProcessActivity(true, pid: 300, at: h.clock.now())
        h.detector.handleAudioProcessActivity(false, pid: 300, at: h.clock.now())

        h.audioProcessActivity.snapshotOverride = AudioProcessActivitySnapshot(processes: [], owners: [], queryState: .unknown)
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        h.advance(120)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 0)
    }

    func testQuittingTheMeetingAppAsksAfterTheGrace() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmZoom())
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))

        h.detector.handleWorkspaceEvent(.init(kind: .terminated, bundleIdentifier: "us.zoom.xos", processID: 100), at: h.clock.now())
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 0)

        h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)

        // Another app that happens to get the same process ID is not our meeting coming back.
        h.detector.handleWorkspaceEvent(.init(kind: .launched, bundleIdentifier: "com.microsoft.teams2", processID: 100), at: h.clock.now())
        h.advance(60)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)
    }

    func testTheQuestionWaitsWhilePeopleAreStillTalking() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmTeams())
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))
        h.detector.handleAudioProcessActivity(true, pid: 300, at: h.clock.now())
        h.detector.handleAudioProcessActivity(false, pid: 300, at: h.clock.now())

        // The call dropped but the people in the room carry on.
        for _ in 0..<10 {
            h.advance(30)
            h.flags.lastSpeechAt = h.clock.now().addingTimeInterval(-5)
            h.detector.tick(at: h.clock.now())
        }
        XCTAssertEqual(h.nudges, 0)

        h.advance(MeetingAutoDetector.speechQuietSeconds - 10)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 0, "45 seconds of quiet are not up yet")

        h.advance(10)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)
    }

    func testTalkingAloneNeverAsksAndQuietAloneNeverAsks() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmTeams())
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))
        h.detector.handleAudioProcessActivity(true, pid: 300, at: h.clock.now())

        // A long silence in a call that is still connected is just a quiet meeting.
        h.flags.lastSpeechAt = h.clock.now()
        h.advance(1800)
        h.detector.handleAudioProcessActivity(true, pid: 300, at: h.clock.now())
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 0)
    }

    /// Starts a Teams recording, lets the call drop, and waits until the question is asked.
    private func teamsRecordingThatAsked() throws -> DetectorHarness {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmTeams())
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))
        h.detector.handleAudioProcessActivity(true, pid: 300, at: h.clock.now())
        h.detector.handleAudioProcessActivity(false, pid: 300, at: h.clock.now())
        h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)
        return h
    }

    func testTheQuestionIsTakenBackWhenTheCallResumesAndAskedAgainAtTheNextEnd() throws {
        let h = try self.teamsRecordingThatAsked()
        h.advance(30)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.withdrawals, 0, "the call is still down, so the question stays")

        h.detector.handleAudioProcessActivity(true, pid: 300, at: h.clock.now())
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.withdrawals, 1)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.withdrawals, 1)

        h.advance(600)
        h.detector.handleAudioProcessActivity(false, pid: 300, at: h.clock.now())
        h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 2)
    }

    func testAZoomWindowComingBackTakesTheQuestionBack() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmZoom())
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))
        h.detector.handleWindowSnapshot([], at: h.clock.now())
        h.advance(65)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)

        h.detector.handleWindowSnapshot([.init(processID: 100, windowID: 900, title: "Zoom Meeting", layer: 0)], at: h.clock.now())
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.withdrawals, 1)
    }

    func testADismissedQuestionStaysAwayForTheRestOfThatRecordingOnly() throws {
        let h = try self.teamsRecordingThatAsked()
        h.detector.stillRecordingNudgeDismissed()

        h.detector.handleAudioProcessActivity(true, pid: 300, at: h.clock.now())
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.withdrawals, 0, "there is nothing on screen to take back")
        h.detector.handleAudioProcessActivity(false, pid: 300, at: h.clock.now())
        h.advance(MeetingAutoDetector.endSignalGraceSeconds + 10)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)

        // The next recording of the same call starts fresh.
        h.detector.recordingStopped()
        try h.detector.adoptStartedEpisode(episodeID: XCTUnwrap(h.prompts.last?.episodeID))
        h.detector.handleAudioProcessActivity(true, pid: 300, at: h.clock.now())
        h.detector.handleAudioProcessActivity(false, pid: 300, at: h.clock.now())
        h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 2)
    }

    func testAnUnreadableAudioQueryDoesNotTakeTheQuestionBack() async throws {
        let h = try self.teamsRecordingThatAsked()
        h.audioProcessActivity.snapshotOverride = AudioProcessActivitySnapshot(processes: [], owners: [], queryState: .unknown)
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.withdrawals, 0)
    }

    func testAQuitAppIsNotBroughtBackByAnotherAppWithItsProcessID() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmZoom())
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))
        h.detector.handleWorkspaceEvent(.init(kind: .terminated, bundleIdentifier: "us.zoom.xos", processID: 100), at: h.clock.now())
        h.detector.tick(at: h.clock.now())
        h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)

        h.detector.handleWorkspaceEvent(.init(kind: .launched, bundleIdentifier: "com.microsoft.teams2", processID: 100), at: h.clock.now())
        h.advance(60)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.withdrawals, 0)
        XCTAssertEqual(h.nudges, 1)
    }

    func testScreenLockLeavesAQuestionAlreadyAskedOnScreen() throws {
        let h = try self.teamsRecordingThatAsked()
        h.detector.disarmAndClearTransientState()
        h.advance(120)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.withdrawals, 0)
        XCTAssertEqual(h.nudges, 1)
    }

    func testTheQuestionSitsCenteredAboveThePillAndStaysOnScreen() {
        let size = MeetingStillRecordingNudgeController.panelSize
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

        let middle = MeetingStillRecordingNudgeController.frame(abovePill: NSRect(x: 678, y: 64, width: 84, height: 32), within: screen)
        XCTAssertEqual(middle.midX, 720)
        XCTAssertEqual(middle.minY, 104)
        XCTAssertEqual(middle.size, size)

        let leftEdge = MeetingStillRecordingNudgeController.frame(abovePill: NSRect(x: 4, y: 64, width: 84, height: 32), within: screen)
        XCTAssertEqual(leftEdge.minX, 0)
        let rightEdge = MeetingStillRecordingNudgeController.frame(abovePill: NSRect(x: 1350, y: 64, width: 84, height: 32), within: screen)
        XCTAssertEqual(rightEdge.maxX, 1440)

        let unknownScreen = MeetingStillRecordingNudgeController.frame(abovePill: NSRect(x: 4, y: 64, width: 84, height: 32), within: nil)
        XCTAssertEqual(unknownScreen.midX, 46)
    }

    func testADismissedQuestionTellsTheDetectorAndStopDoesNot() {
        let controller = MeetingStillRecordingNudgeController.shared
        let earlierDismiss = controller.onDismiss
        defer { controller.onDismiss = earlierDismiss }
        var dismissals = 0
        controller.onDismiss = { dismissals += 1 }

        controller.hide()
        XCTAssertEqual(dismissals, 0, "taking the question down is not the user closing it")
        controller.dismiss()
        XCTAssertEqual(dismissals, 1)
        XCTAssertFalse(controller.isPresented)
    }

    // MARK: - Web meetings end with the browser's microphone, not with the front tab

    func testSwitchingTabsDuringAWebMeetingNeverAsks() async throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmChromeMeet())
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))
        await h.pollChrome(microphoneInUse: true)

        // The user reads a doc in another tab for ten minutes while the call goes on.
        h.detector.handleBrowserTabURL(.init(host: "docs.google.com", path: "/document/d/1"), pid: 8, bundleIdentifier: "com.google.Chrome", at: h.clock.now())
        for _ in 0..<10 {
            h.advance(60)
            await h.pollChrome(microphoneInUse: true)
            h.detector.tick(at: h.clock.now())
        }
        XCTAssertEqual(h.nudges, 0)
    }

    func testAWebMeetingAsksOnceTheBrowserLetsGoOfTheMicrophone() async throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmChromeMeet())
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))
        await h.pollChrome(microphoneInUse: true)

        // Left the call. The Meet tab still shows the same address, so the tab says nothing.
        await h.pollChrome(microphoneInUse: false)
        h.advance(MeetingAutoDetector.endSignalGraceSeconds - 2)
        await h.pollChrome(microphoneInUse: false)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 0)

        h.advance(4)
        await h.pollChrome(microphoneInUse: false)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)

        // Rejoined: the question goes away.
        await h.pollChrome(microphoneInUse: true)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.withdrawals, 1)
    }

    func testABrowserWhoseMicrophoneWeNeverSawNeverAsks() async throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmChromeMeet())
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))

        // Safari records through a system process we cannot tie to it, so its microphone always reads as off.
        h.detector.handleBrowserTabURL(nil, pid: 8, bundleIdentifier: "com.google.Chrome", at: h.clock.now())
        for _ in 0..<5 {
            h.advance(60)
            await h.pollChrome(microphoneInUse: false)
            h.detector.tick(at: h.clock.now())
        }
        XCTAssertEqual(h.nudges, 0)
    }

    func testAnUnreadableMicrophoneQueryNeitherAsksNorTakesTheQuestionBackForAWebMeeting() async throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmChromeMeet())
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))
        await h.pollChrome(microphoneInUse: true)

        for _ in 0..<5 {
            h.advance(30)
            await h.pollChrome(microphoneInUse: false, readable: false)
            h.detector.tick(at: h.clock.now())
        }
        XCTAssertEqual(h.nudges, 0, "not readable is not a release")

        await h.pollChrome(microphoneInUse: false)
        h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
        await h.pollChrome(microphoneInUse: false)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)

        await h.pollChrome(microphoneInUse: false, readable: false)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.withdrawals, 0)
    }

    func testQuittingTheBrowserStillAsks() async throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmChromeMeet())
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))

        h.detector.handleWorkspaceEvent(.init(kind: .terminated, bundleIdentifier: "com.google.Chrome", processID: 8), at: h.clock.now())
        h.detector.tick(at: h.clock.now())
        h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)
    }

    func testBrowserMicrophoneIsReadOnlyWhenAskedForAndNeverCountsAsANativeMeeting() {
        let chrome = MeetingProcessOwner(processID: 8, bundleIdentifier: "com.google.Chrome", bundlePath: "/Applications/Google Chrome.app")
        let zoom = MeetingProcessOwner(processID: 100, bundleIdentifier: "us.zoom.xos", bundlePath: "/Applications/zoom.us.app")
        let helper = AudioProcessDescriptor(
            processID: 4242,
            bundleIdentifier: nil,
            executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Helpers/Google Chrome Helper",
            isInputRunning: true,
            isOutputRunning: true
        )
        let snapshot = AudioProcessActivitySnapshot(processes: [helper], owners: [chrome, zoom], queryState: .valid)
        XCTAssertEqual(MeetingAudioProcessResolver.activeOwnerInputByPID(snapshot: snapshot), [:])
        XCTAssertEqual(
            MeetingAudioProcessResolver.activeOwnerInputByPID(snapshot: snapshot, owning: MeetingAppRegistry.isBrowserApp(bundleIdentifier:)),
            [8: true]
        )
    }

    // MARK: - The call comes back in ways the first version missed

    func testAMutedTeamsCallThatResumesAfterALongGapTakesTheQuestionBack() async throws {
        let h = try self.teamsRecordingThatAsked()
        // Long enough for the start-prompt episode to retire.
        h.advance(120)
        h.detector.tick(at: h.clock.now())

        // Rejoined on mute: Teams plays the call but is not using the microphone.
        let teams = MeetingProcessOwner(processID: 300, bundleIdentifier: "com.microsoft.teams2", bundlePath: "/Applications/Microsoft Teams.app")
        let helper = AudioProcessDescriptor(
            processID: 301,
            bundleIdentifier: nil,
            executablePath: "/Applications/Microsoft Teams.app/Contents/Helpers/Teams Helper",
            isInputRunning: false,
            isOutputRunning: true
        )
        h.audioProcessActivity.snapshotOverride = AudioProcessActivitySnapshot(processes: [helper], owners: [teams], queryState: .valid)
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.withdrawals, 1)
        XCTAssertEqual(h.prompts.count, 1, "sound without a microphone still never raises a new start prompt")
    }

    func testAMeetingAppThatRestartsAndRejoinsIsFollowed() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmZoom())
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))
        h.detector.handleWorkspaceEvent(.init(kind: .terminated, bundleIdentifier: "us.zoom.xos", processID: 100), at: h.clock.now())
        h.detector.tick(at: h.clock.now())
        h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)

        // Zoom is back under a new process but not in a call yet: nothing changes.
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "us.zoom.xos", processID: 101), at: h.clock.now())
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.withdrawals, 0)

        h.detector.handleWindowSnapshot([.init(processID: 101, windowID: 901, title: "Zoom Meeting", layer: 0)], at: h.clock.now())
        h.detector.handleAudioProcessActivity(true, pid: 101, at: h.clock.now())
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.withdrawals, 1)

        // From here the new process is the one that is watched.
        h.advance(300)
        h.detector.handleAudioProcessActivity(false, pid: 101, at: h.clock.now())
        h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 2)
    }

    func testADifferentMeetingAppInACallIsNeverTakenForTheOneThatQuit() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmZoom())
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))
        h.detector.handleWorkspaceEvent(.init(kind: .terminated, bundleIdentifier: "us.zoom.xos", processID: 100), at: h.clock.now())
        h.detector.tick(at: h.clock.now())
        h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)

        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.microsoft.teams2", processID: 300), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 300, windowID: 950, title: nil, layer: 0)], at: h.clock.now())
        h.detector.handleAudioProcessActivity(true, pid: 300, at: h.clock.now())
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.withdrawals, 0)
    }

    func testABrowserThatRestartsAndRejoinsIsFollowed() async throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmChromeMeet())
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))
        await h.pollChrome(microphoneInUse: true)
        h.detector.handleWorkspaceEvent(.init(kind: .terminated, bundleIdentifier: "com.google.Chrome", processID: 8), at: h.clock.now())
        h.detector.tick(at: h.clock.now())
        h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)

        h.detector.handleWorkspaceEvent(.init(kind: .launched, bundleIdentifier: "com.google.Chrome", processID: 9), at: h.clock.now())
        await h.pollChrome(microphoneInUse: false, pid: 9)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.withdrawals, 0, "the browser is open again but not in a call")

        // A voice recorder page uses the microphone too. That is not the meeting coming back.
        h.detector.handleBrowserTabURL(.init(host: "voicerecorder.example", path: "/"), pid: 9, bundleIdentifier: "com.google.Chrome", at: h.clock.now())
        await h.pollChrome(microphoneInUse: true, pid: 9)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.withdrawals, 0)

        h.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: "/abc-defg-hij"), pid: 9, bundleIdentifier: "com.google.Chrome", at: h.clock.now())
        await h.pollChrome(microphoneInUse: true, pid: 9)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.withdrawals, 1)
    }

    func testARelaunchedTeamsPlayingASoundIsNotTakenForTheCallComingBack() async throws {
        let h = try self.teamsRecordingThatAsked()
        h.detector.handleWorkspaceEvent(.init(kind: .terminated, bundleIdentifier: "com.microsoft.teams2", processID: 300), at: h.clock.now())
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.microsoft.teams2", processID: 302), at: h.clock.now())
        h.detector.handleWindowSnapshot([.init(processID: 302, windowID: 951, title: nil, layer: 0)], at: h.clock.now())

        func poll(microphoneInUse: Bool) async {
            let teams = MeetingProcessOwner(processID: 302, bundleIdentifier: "com.microsoft.teams2", bundlePath: "/Applications/Microsoft Teams.app")
            let helper = AudioProcessDescriptor(
                processID: 303,
                bundleIdentifier: nil,
                executablePath: "/Applications/Microsoft Teams.app/Contents/Helpers/Teams Helper",
                isInputRunning: microphoneInUse,
                isOutputRunning: true
            )
            h.audioProcessActivity.snapshotOverride = AudioProcessActivitySnapshot(processes: [helper], owners: [teams], queryState: .valid)
            await h.detector.pollAudioProcessActivity(at: h.clock.now())
            h.detector.tick(at: h.clock.now())
        }

        // A notification chime: sound, no microphone.
        await poll(microphoneInUse: false)
        XCTAssertEqual(h.withdrawals, 0)

        // Back in the call with the microphone on.
        await poll(microphoneInUse: true)
        XCTAssertEqual(h.withdrawals, 1)
    }

    func testAGoogleMeetWebAppEndsOnItsBrowsersMicrophone() async throws {
        let h = DetectorHarness()
        let webApp = "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"
        XCTAssertEqual(MeetingAppRegistry.parentBrowser(ofWebApp: webApp), "com.google.Chrome")
        XCTAssertEqual(MeetingAppRegistry.parentBrowser(ofWebApp: "com.microsoft.edgemac.app.abc"), "com.microsoft.edgemac")
        XCTAssertNil(MeetingAppRegistry.parentBrowser(ofWebApp: "com.google.Chrome"))

        h.workspace.frontmostProcessID = 20
        h.detector.handleBackfill([.init(kind: .launched, bundleIdentifier: webApp, processID: 20)])
        h.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: "/abc-defg-hij"), pid: 20, bundleIdentifier: webApp, at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        let episodeID = try XCTUnwrap(h.prompts.last?.episodeID)
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))

        // The web app has its own process, but Chrome (pid 8) is what holds the microphone.
        await h.pollChrome(microphoneInUse: true, pid: 8)
        await h.pollChrome(microphoneInUse: false, pid: 8)
        h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
        await h.pollChrome(microphoneInUse: false, pid: 8)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)

        await h.pollChrome(microphoneInUse: true, pid: 8)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.withdrawals, 1)
    }

    /// Starts a recording of Google Meet's web app (pid 20), which records through Chrome (pid 8).
    private func meetWebAppRecording(_ h: DetectorHarness, pid: Int32 = 20) throws {
        let webApp = "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"
        h.workspace.frontmostProcessID = pid
        h.detector.handleBackfill([.init(kind: .launched, bundleIdentifier: webApp, processID: pid)])
        h.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: "/abc-defg-hij"), pid: pid, bundleIdentifier: webApp, at: h.clock.now())
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertTrue(try h.detector.startTapped(episodeID: XCTUnwrap(h.prompts.last?.episodeID)))
    }

    func testTwoCopiesOfTheBrowserLeaveAWebAppsMicrophoneUnknownNotReleased() async throws {
        let h = DetectorHarness()
        try self.meetWebAppRecording(h)
        await h.pollChrome(microphoneInUse: true, pid: 8)

        // A second Chrome from another folder opens. Which one the web app runs in can no longer be told.
        let stable = MeetingProcessOwner(processID: 8, bundleIdentifier: "com.google.Chrome", bundlePath: "/Applications/Google Chrome.app")
        let other = MeetingProcessOwner(processID: 18, bundleIdentifier: "com.google.Chrome", bundlePath: "/Users/me/Apps/Google Chrome.app")
        let helper = AudioProcessDescriptor(
            processID: 4242,
            bundleIdentifier: nil,
            executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Helpers/Google Chrome Helper",
            isInputRunning: true,
            isOutputRunning: true
        )
        h.audioProcessActivity.snapshotOverride = AudioProcessActivitySnapshot(processes: [helper], owners: [stable, other], queryState: .valid)
        for _ in 0..<5 {
            h.advance(30)
            await h.detector.pollAudioProcessActivity(at: h.clock.now())
            h.detector.tick(at: h.clock.now())
        }
        XCTAssertEqual(h.nudges, 0, "the call is still on")
    }

    func testARelaunchedMeetWebAppIsFollowedThroughItsBrowser() async throws {
        let h = DetectorHarness()
        let webApp = "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"
        try self.meetWebAppRecording(h)
        await h.pollChrome(microphoneInUse: true, pid: 8)
        h.detector.handleWorkspaceEvent(.init(kind: .terminated, bundleIdentifier: webApp, processID: 20), at: h.clock.now())
        h.detector.tick(at: h.clock.now())
        h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
        await h.pollChrome(microphoneInUse: false, pid: 8)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)

        // The web app is opened again, on the meeting, and Chrome has the microphone.
        h.detector.handleWorkspaceEvent(.init(kind: .launched, bundleIdentifier: webApp, processID: 21), at: h.clock.now())
        await h.pollChrome(microphoneInUse: true, pid: 8)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.withdrawals, 0, "open again, but not on a meeting yet")

        h.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: "/abc-defg-hij"), pid: 21, bundleIdentifier: webApp, at: h.clock.now())
        await h.pollChrome(microphoneInUse: true, pid: 8)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.withdrawals, 1)
    }

    func testNothingIsAskedOnceOurRecordingHasStopped() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmZoom())
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))

        // The user stopped our recording mid-call. The call ending later is no longer our business.
        h.detector.recordingStopped()
        h.detector.handleWindowSnapshot([], at: h.clock.now())
        h.detector.handleWorkspaceEvent(.init(kind: .terminated, bundleIdentifier: "us.zoom.xos", processID: 100), at: h.clock.now())
        h.advance(120)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 0)
    }

    func testAMeetingNobodyRecordedNeverAsks() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmZoom())
        h.detector.timeoutDismissed(episodeID: episodeID)

        h.detector.handleWindowSnapshot([], at: h.clock.now())
        h.detector.handleWorkspaceEvent(.init(kind: .terminated, bundleIdentifier: "us.zoom.xos", processID: 100), at: h.clock.now())
        h.advance(120)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 0)
    }

    func testScreenLockStopsTheWatchInsteadOfReadingItAsTheAppQuitting() throws {
        let h = DetectorHarness()
        let episodeID = try XCTUnwrap(h.confirmZoom())
        XCTAssertTrue(h.detector.startTapped(episodeID: episodeID))

        h.detector.disarmAndClearTransientState()
        h.advance(120)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 0)
    }

    // MARK: - Registry / URL matcher sanity

    func testSourcePickerPutsTheUsualMeetingAppsFirstAndBackgroundHelpersLast() {
        struct App: Equatable {
            var bundle: String
            var name: String
            var background = false
        }
        let apps = [
            App(bundle: "com.apple.controlcenter", name: "Control Center", background: true),
            App(bundle: "com.apple.Safari", name: "Safari"),
            App(bundle: "com.apple.Music", name: "Music"),
            App(bundle: "com.tinyspeck.slackmacgap", name: "Slack"),
            App(bundle: "com.apple.AirPlayUIAgent", name: "AirPlayUIAgent", background: true),
            App(bundle: "com.google.Chrome", name: "Google Chrome"),
            App(bundle: "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan", name: "Google Meet"),
            App(bundle: "com.apple.finder", name: "Finder"),
            App(bundle: "com.microsoft.teams2", name: "Microsoft Teams"),
            App(bundle: "us.zoom.xos", name: "zoom.us"),
            App(bundle: "com.apple.FaceTime", name: "FaceTime"),
        ]
        let sections = MeetingAppRegistry.pickerSections(apps, bundleIdentifier: \.bundle, name: \.name, isBackgroundItem: \.background)
        XCTAssertEqual(
            sections.usual.map(\.name),
            ["zoom.us", "Microsoft Teams", "FaceTime", "Slack", "Google Meet", "Google Chrome", "Safari"]
        )
        XCTAssertEqual(sections.others.map(\.name), ["Finder", "Music", "AirPlayUIAgent", "Control Center"])
        XCTAssertEqual(sections.usual.count + sections.others.count, apps.count, "nothing is dropped from the list")
    }

    func testAppsThatOnlyShapeThePickerAreNeverDetected() {
        for bundle in MeetingAppRegistry.otherCallAppBundleIdentifiers {
            XCTAssertNil(MeetingAppRegistry.tier(forBundleIdentifier: bundle), bundle)
            XCTAssertNotNil(MeetingAppRegistry.pickerRank(forBundleIdentifier: bundle), bundle)
        }
        XCTAssertNil(MeetingAppRegistry.pickerRank(forBundleIdentifier: "com.apple.Music"))
    }

    func testBrowserMeetingsAreDetectedUntilTheUserTurnsThatOff() {
        let key = "MeetingAutoDetectBrowserEnabled"
        let defaults = UserDefaults.standard
        let earlier = defaults.object(forKey: key)
        defer {
            if let earlier { defaults.set(earlier, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        defaults.removeObject(forKey: key)
        XCTAssertTrue(SettingsStore.shared.meetingAutoDetectBrowserEnabled, "never chosen means on")
        SettingsStore.shared.meetingAutoDetectBrowserEnabled = false
        XCTAssertFalse(SettingsStore.shared.meetingAutoDetectBrowserEnabled, "a stored off stays off")
        SettingsStore.shared.meetingAutoDetectBrowserEnabled = true
        XCTAssertTrue(SettingsStore.shared.meetingAutoDetectBrowserEnabled)
    }

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

    // MARK: - windowID preference in MeetingWindowSelector

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

@MainActor
final class MeetingManualRecordingEndTests: XCTestCase {
    private func session(bundle: String? = "us.zoom.xos", pid: Int32? = 100) -> MeetingSession {
        var session = MeetingSession(
            configuration: MeetingCaptureConfiguration(
                mode: bundle == nil ? .inRoom : .onlineCall,
                title: "End detection fixture",
                application: bundle.map { MeetingApplicationIdentity(bundleIdentifier: $0, processID: pid, displayName: "Call") },
                microphone: MeetingMicrophoneIdentity(captureDeviceID: "fixture-mic", displayName: "Microphone")
            ),
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1)
        )
        session.state = .recording
        return session
    }

    private func synchronize(_ h: DetectorHarness, _ session: MeetingSession, state: MeetingCoordinatorState? = nil) {
        AppServices.synchronizeMeetingEndWatch(state: state ?? .recording(session.id), session: session, detector: h.detector)
    }

    func testManualNativeRecordingAsksWithoutAnyStartPromptOrWindowEvidence() {
        for bundle in ["us.zoom.xos", "com.microsoft.teams2", "com.cisco.webexmeetingsapp"] {
            let h = DetectorHarness()
            let session = self.session(bundle: bundle)
            h.gate.isIdle = false
            self.synchronize(h, session)
            h.detector.handleAudioProcessActivity(true, pid: 100, at: h.clock.now())
            h.detector.handleAudioProcessActivity(false, pid: 100, at: h.clock.now())
            h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
            h.detector.tick(at: h.clock.now())
            XCTAssertEqual(h.nudges, 1, bundle)
            XCTAssertTrue(h.prompts.isEmpty, "observing a manually selected app must not create a start prompt")
            XCTAssertNil(h.detector.automaticTarget, "end monitoring must not select a source")
            XCTAssertFalse(h.gate.isIdle, "observing an end must not stop capture")
            XCTAssertEqual(session.state, .recording)
        }
    }

    func testManualBrowserRecordingAsksAfterObservedMicrophoneRelease() async {
        let h = DetectorHarness()
        let session = self.session(bundle: "com.google.Chrome", pid: 8)
        h.gate.isIdle = false
        self.synchronize(h, session)
        await h.pollChrome(microphoneInUse: true)
        await h.pollChrome(microphoneInUse: false)
        h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)
        XCTAssertTrue(h.prompts.isEmpty)
        XCTAssertNil(h.detector.automaticTarget)
        XCTAssertFalse(h.gate.isIdle)
    }

    func testManualRecordingAsksAfterCapturedAppQuits() {
        let h = DetectorHarness()
        let session = self.session()
        self.synchronize(h, session)
        h.detector.handleWorkspaceEvent(.init(kind: .terminated, bundleIdentifier: "us.zoom.xos", processID: 100), at: h.clock.now())
        h.detector.tick(at: h.clock.now())
        h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)
    }

    func testRepeatedHealthStatesPreserveAudioEvidenceQuestionAndDismissal() {
        let h = DetectorHarness()
        let session = self.session()
        self.synchronize(h, session)
        h.detector.handleAudioProcessActivity(true, pid: 100, at: h.clock.now())
        h.detector.handleAudioProcessActivity(false, pid: 100, at: h.clock.now())
        h.advance(10)
        self.synchronize(h, session, state: .recordingDegraded(session.id))
        h.advance(11)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)
        self.synchronize(h, session)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1, "a health-state notification must not repeat the question")
        h.detector.stillRecordingNudgeDismissed()
        self.synchronize(h, session, state: .recordingDegraded(session.id))
        h.detector.handleAudioProcessActivity(true, pid: 100, at: h.clock.now())
        h.detector.handleAudioProcessActivity(false, pid: 100, at: h.clock.now())
        h.advance(120)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1, "the user's dismissal survives subsequent health states")
    }

    func testCommonObserverDoesNotResetAnAdoptedAutomaticRecording() throws {
        let h = DetectorHarness()
        let episode = try XCTUnwrap(h.confirmZoom())
        XCTAssertTrue(h.detector.startTapped(episodeID: episode))
        h.detector.handleAudioProcessActivity(true, pid: 100, at: h.clock.now())
        h.detector.handleAudioProcessActivity(false, pid: 100, at: h.clock.now())
        let session = self.session()
        self.synchronize(h, session)
        h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1, "binding the real session preserves previously observed audio")
        h.detector.stillRecordingNudgeDismissed()
        h.detector.adoptStartedEpisode(episodeID: episode)
        self.synchronize(h, session, state: .recordingDegraded(session.id))
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)
    }

    func testManualObserverBeforeAutomaticAdoptionKeepsItsSessionIdentity() throws {
        let h = DetectorHarness()
        let episode = try XCTUnwrap(h.confirmZoom())
        let session = self.session()
        self.synchronize(h, session)
        h.detector.handleAudioProcessActivity(true, pid: 100, at: h.clock.now())
        h.detector.adoptStartedEpisode(episodeID: episode)
        h.detector.handleAudioProcessActivity(false, pid: 100, at: h.clock.now())
        self.synchronize(h, session, state: .recordingDegraded(session.id))
        h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)
        XCTAssertEqual(h.prompts.count, 1)
    }

    func testPreparingAndMismatchedSnapshotsNeverArmAnEndWatch() {
        for state in [MeetingCoordinatorState.preparing(UUID()), .recording(UUID())] {
            let h = DetectorHarness()
            self.synchronize(h, self.session(), state: state)
            h.detector.handleAudioProcessActivity(true, pid: 100, at: h.clock.now())
            h.detector.handleAudioProcessActivity(false, pid: 100, at: h.clock.now())
            h.advance(120)
            h.detector.tick(at: h.clock.now())
            XCTAssertEqual(h.nudges, 0)
            XCTAssertTrue(h.prompts.isEmpty)
        }
    }

    func testInRoomUnsupportedAndMissingProcessRecordingsNeverGuessAnApp() {
        let sessions = [self.session(bundle: nil), self.session(bundle: "com.example.recorder"), self.session(pid: nil)]
        for session in sessions {
            let h = DetectorHarness()
            self.synchronize(h, session)
            h.detector.handleWorkspaceEvent(.init(kind: .terminated, bundleIdentifier: "us.zoom.xos", processID: 100), at: h.clock.now())
            h.detector.tick(at: h.clock.now())
            h.advance(120)
            h.detector.tick(at: h.clock.now())
            XCTAssertEqual(h.nudges, 0)
            XCTAssertNil(h.detector.automaticTarget)
            XCTAssertTrue(h.prompts.isEmpty)
        }
    }

    func testStoppingOrFinishingRecordingClearsItsWatch() {
        let session = self.session()
        let failure = MeetingSessionFailure(id: UUID(), occurredAt: Date(), domain: .capture, code: "fixture", message: "fixture", recoverable: true)
        for state in [MeetingCoordinatorState.stopping(session.id), .processing(session.id, .transcribing), .completed(session.id), .interrupted(session.id), .failed(session.id, failure), .idle] {
            let h = DetectorHarness()
            self.synchronize(h, session)
            self.synchronize(h, session, state: state)
            h.detector.handleAudioProcessActivity(true, pid: 100, at: h.clock.now())
            h.detector.handleAudioProcessActivity(false, pid: 100, at: h.clock.now())
            h.advance(120)
            h.detector.tick(at: h.clock.now())
            XCTAssertEqual(h.nudges, 0)
        }
    }

    func testEndWatchRejectsAProcessIDThatNowBelongsToAnotherApp() {
        let h = DetectorHarness()
        h.detector.handleBackfill([.init(kind: .launched, bundleIdentifier: "com.microsoft.teams2", processID: 100)])
        self.synchronize(h, self.session())
        h.detector.handleAudioProcessActivity(true, pid: 100, at: h.clock.now())
        h.detector.handleAudioProcessActivity(false, pid: 100, at: h.clock.now())
        h.advance(120)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 0)
        XCTAssertTrue(h.prompts.isEmpty)
    }

    func testNewRecordingGetsItsOwnQuestionAfterEarlierDismissal() {
        let h = DetectorHarness()
        let first = self.session()
        self.synchronize(h, first)
        h.detector.stillRecordingNudgeDismissed()
        self.synchronize(h, first, state: .stopping(first.id))
        let second = self.session()
        self.synchronize(h, second)
        h.detector.handleAudioProcessActivity(true, pid: 100, at: h.clock.now())
        h.detector.handleAudioProcessActivity(false, pid: 100, at: h.clock.now())
        h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)
    }

    func testNeverObservedOrUnreadableBrowserMicrophoneDoesNotInventAnEnd() async {
        let h = DetectorHarness()
        self.synchronize(h, self.session(bundle: "com.google.Chrome", pid: 8))
        await h.pollChrome(microphoneInUse: false)
        h.advance(120)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 0)
        await h.pollChrome(microphoneInUse: true)
        await h.pollChrome(microphoneInUse: false, readable: false)
        h.advance(120)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 0)
    }
}

@MainActor
final class MeetingBrowserPostCallTests: XCTestCase {
    private let safariPID: Int32 = 42
    private let room = "/abc-defg-hij"

    private func report(_ h: DetectorHarness, state: MeetingBrowserCallState = .unknown, path: String? = nil) {
        h.detector.handleBrowserTabURL(
            BrowserTabURL(host: "meet.google.com", path: path ?? self.room, callState: state),
            pid: self.safariPID,
            bundleIdentifier: "com.apple.Safari",
            at: h.clock.now()
        )
    }

    private func safariRecording() throws -> DetectorHarness {
        let h = DetectorHarness()
        h.workspace.frontmostProcessID = self.safariPID
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.apple.Safari", processID: self.safariPID), at: h.clock.now())
        self.report(h)
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        let episode = try XCTUnwrap(h.prompts.last?.episodeID)
        XCTAssertTrue(h.detector.startTapped(episodeID: episode))
        h.gate.isIdle = false
        return h
    }

    func testPostCallPageAsksWhenSafarisMicrophoneBelongsToASystemHelper() async throws {
        let h = try self.safariRecording()
        let safari = MeetingProcessOwner(processID: self.safariPID, bundleIdentifier: "com.apple.Safari", bundlePath: "/Applications/Safari.app")
        h.audioProcessActivity.snapshotOverride = .init(
            processes: [.init(
                processID: 4242,
                bundleIdentifier: "com.apple.WebKit.GPU",
                executablePath: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU",
                isInputRunning: true,
                isOutputRunning: true
            )],
            owners: [safari],
            queryState: .valid
        )
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        h.advance(120)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 0)
        self.report(h, state: .ended)
        h.advance(1)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 0, "one brief rejoin opportunity remains")
        h.advance(1.1)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1, "an explicit post-call page is evidence independent of WebKit microphone ownership")
        XCTAssertFalse(h.gate.isIdle, "the end question must not stop or trim capture")
        XCTAssertEqual(h.prompts.count, 1)
    }

    func testPostCallPageNeverOffersAStartAndInvalidatesAnUnacceptedStart() throws {
        let h = DetectorHarness()
        h.workspace.frontmostProcessID = self.safariPID
        h.detector.handleWorkspaceEvent(.init(kind: .activated, bundleIdentifier: "com.apple.Safari", processID: self.safariPID), at: h.clock.now())
        self.report(h, state: .ended)
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertTrue(h.prompts.isEmpty)
        self.report(h, state: .inCall)
        let episode = try XCTUnwrap(h.prompts.last?.episodeID)
        self.report(h, state: .ended)
        XCTAssertEqual(h.invalidated, [episode])
        XCTAssertFalse(h.detector.canStart(episodeID: episode))
        h.detector.handleMicEdge(.init(isActive: true), at: h.clock.now())
        XCTAssertEqual(h.prompts.count, 1)
    }

    func testTabSwitchAndMuteAloneDoNotCountAsAnEnd() throws {
        let h = try self.safariRecording()
        self.report(h, state: .inCall)
        h.detector.handleBrowserTabURL(.init(host: "docs.google.com", path: "/document"), pid: self.safariPID, bundleIdentifier: "com.apple.Safari", at: h.clock.now())
        h.advance(300)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 0)
        self.report(h, state: .inCall)
        h.detector.handleMicEdge(.init(isActive: false), at: h.clock.now())
        h.advance(120)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 0)
    }

    func testDifferentRoomAndDifferentProcessCannotEndOurCall() throws {
        let h = try self.safariRecording()
        self.report(h, state: .ended, path: "/xyz-abcd-uvw")
        h.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: self.room, callState: .ended), pid: 99, bundleIdentifier: "com.apple.Safari", at: h.clock.now())
        h.advance(120)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 0)
    }

    func testUnknownReadsAndTabChangesPreserveAPositiveEndWithoutRestartingItsTimer() throws {
        let h = try self.safariRecording()
        self.report(h, state: .ended)
        h.advance(1)
        self.report(h, state: .ended)
        self.report(h)
        h.detector.handleBrowserTabURL(nil, pid: self.safariPID, bundleIdentifier: "com.apple.Safari", at: h.clock.now())
        self.report(h, state: .inCall, path: "/xyz-abcd-uvw")
        h.advance(1.1)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)
    }

    func testExplicitRejoinCancelsThePendingEndAndWithdrawsAnAskedQuestion() throws {
        let h = try self.safariRecording()
        self.report(h, state: .ended)
        h.advance(1)
        self.report(h, state: .inCall)
        h.advance(5)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 0)
        self.report(h, state: .ended)
        h.advance(2.1)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)
        self.report(h, state: .inCall)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.withdrawals, 1)
    }

    func testPostCallPageDoesNotWaitForCaptionQuietAndStillHonorsDismissal() throws {
        let h = try self.safariRecording()
        self.report(h, state: .ended)
        h.flags.lastSpeechAt = h.clock.now()
        h.advance(2.1)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)
        h.detector.stillRecordingNudgeDismissed()
        self.report(h, state: .inCall)
        self.report(h, state: .ended)
        h.advance(120)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)
    }

    func testMicrophoneReleaseWithoutPostCallProofKeepsTheGraceAndSpeechQuietRules() async throws {
        let h = DetectorHarness()
        let episode = try XCTUnwrap(h.confirmChromeMeet())
        XCTAssertTrue(h.detector.startTapped(episodeID: episode))
        await h.pollChrome(microphoneInUse: true)
        await h.pollChrome(microphoneInUse: false)
        h.advance(3)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 0, "the short post-call grace must not apply to microphone release")
        h.flags.lastSpeechAt = h.clock.now()
        h.advance(MeetingAutoDetector.endSignalGraceSeconds)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 0, "fresh speech still defers an ambiguous disconnect")
        h.advance(MeetingAutoDetector.speechQuietSeconds)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)
    }

    func testMeetEvidenceRequiresMatchingControlsAndIgnoresOrdinaryPageText() {
        var evidence = MeetingBrowserCallEvidence()
        evidence.observe(role: "AXStaticText", label: "You left the meeting")
        evidence.observe(role: "AXStaticText", label: "Rejoin")
        XCTAssertEqual(evidence.state, .unknown)
        evidence.observe(role: "AXHeading", label: "You left the meeting")
        XCTAssertEqual(evidence.state, .unknown)
        evidence.observe(role: "AXButton", label: " Rejoin ")
        XCTAssertEqual(evidence.state, .ended)
        evidence.observe(role: "AXButton", label: "Leave call")
        XCTAssertEqual(evidence.state, .unknown, "contradictory transitional controls are not proof")
        XCTAssertTrue(MeetingBrowserCallEvidence.supports(.init(host: "meet.google.com", path: self.room)))
        XCTAssertFalse(MeetingBrowserCallEvidence.supports(.init(host: "meet.google.com", path: "/home")))
        XCTAssertFalse(MeetingBrowserCallEvidence.supports(.init(host: "example.com", path: self.room)))
        var unknownLanguage = MeetingBrowserCallEvidence()
        unknownLanguage.observe(role: "AXHeading", label: "Unrecognised post-call copy")
        unknownLanguage.observe(role: "AXButton", label: "Unrecognised action")
        XCTAssertEqual(unknownLanguage.state, .unknown)
    }
}

@MainActor
extension MeetingManualRecordingEndTests {
    func testCapturedAppQuitIsObservedWithAutomaticDetectionDisabled() {
        let h = DetectorHarness()
        h.nativeEnabled = false
        h.browserEnabled = false
        h.gate.isIdle = false
        self.synchronize(h, self.session())
        h.detector.handleWorkspaceEvent(.init(kind: .terminated, bundleIdentifier: "us.zoom.xos", processID: 100), at: h.clock.now())
        h.detector.tick(at: h.clock.now())
        h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)
        XCTAssertTrue(h.prompts.isEmpty)
        XCTAssertNil(h.detector.automaticTarget)
    }

    func testPollingWatchesOnlyTheCapturedNativeAppWhenStartDetectionIsOff() async {
        let h = DetectorHarness()
        h.nativeEnabled = false
        h.browserEnabled = false
        h.gate.isIdle = false
        h.detector.start()
        defer { h.detector.stop() }
        await h.detector.pollTick()
        XCTAssertEqual(h.audioProcessActivity.snapshotCount, 0)
        self.synchronize(h, self.session())
        h.detector.handleBackfill([.init(kind: .launched, bundleIdentifier: "com.microsoft.teams2", processID: 300)])
        let owner = MeetingProcessOwner(processID: 100, bundleIdentifier: "us.zoom.xos", bundlePath: "/Applications/zoom.us.app")
        h.audioProcessActivity.snapshotOverride = .init(
            processes: [.init(processID: 100, bundleIdentifier: "us.zoom.xos", executablePath: "/Applications/zoom.us.app/Contents/MacOS/zoom.us", isInputRunning: true, isOutputRunning: true)],
            owners: [owner],
            queryState: .valid
        )
        await h.detector.pollTick()
        XCTAssertEqual(h.audioProcessActivity.snapshotCount, 1)
        XCTAssertEqual(h.windowProvider.lastInterestPIDs, [100])
        h.audioProcessActivity.snapshotOverride = .init(processes: [], owners: [owner], queryState: .valid)
        await h.detector.pollTick()
        h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 1)
        XCTAssertTrue(h.prompts.isEmpty)
        XCTAssertNil(h.detector.automaticTarget)
        h.detector.recordingStopped()
        let count = h.audioProcessActivity.snapshotCount
        await h.detector.pollTick()
        XCTAssertEqual(h.audioProcessActivity.snapshotCount, count)
    }

    func testManualBrowserPostCallIsPolledWithBothStartDetectionOptionsOff() async {
        let h = DetectorHarness()
        h.nativeEnabled = false
        h.browserEnabled = false
        h.gate.isIdle = false
        h.detector.start()
        defer { h.detector.stop() }
        self.synchronize(h, self.session(bundle: "com.apple.Safari", pid: 42))
        h.detector.handleBackfill([.init(kind: .launched, bundleIdentifier: "com.google.Chrome", processID: 8)])
        h.browserReader.result = .init(host: "meet.google.com", path: "/abc-defg-hij", callState: .inCall)
        await h.detector.pollTick()
        h.advance(2)
        h.browserReader.result?.callState = .ended
        await h.detector.pollTick()
        h.advance(2.1)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.browserReader.readPIDs, [42, 42])
        XCTAssertEqual(h.nudges, 1)
        XCTAssertTrue(h.prompts.isEmpty)
        XCTAssertNil(h.detector.automaticTarget)
    }
}

@MainActor
extension MeetingManualRecordingEndTests {
    func testStoppedManualWatchIgnoresAnAudioSnapshotAlreadyInFlight() async {
        let h = DetectorHarness()
        h.nativeEnabled = false
        h.browserEnabled = false
        h.gate.isIdle = false
        h.detector.start()
        defer { h.detector.stop() }
        self.synchronize(h, self.session())
        h.audioProcessActivity.beforeSnapshot = { h.detector.recordingStopped() }
        await h.detector.pollTick()
        h.audioProcessActivity.beforeSnapshot = nil
        self.synchronize(h, self.session())
        h.advance(120)
        h.detector.tick(at: h.clock.now())
        XCTAssertEqual(h.nudges, 0)
        XCTAssertTrue(h.prompts.isEmpty)
        XCTAssertNil(h.detector.automaticTarget)
    }
}
