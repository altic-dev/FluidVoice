import AppKit
import Foundation

/// Standalone meeting-detection state machine. Zero dependency on `MeetingSessionCoordinator` —
/// it reads activity state through `DetectionActivityGate` and never materializes the lazy
/// coordinator. Prompt-only: it never starts or stops a recording itself.
///
/// Every ambiguity resolves to no prompt: a false negative here is free, a false positive is not.
@MainActor
final class MeetingAutoDetector {
    // MARK: - Tunables (Phase A plan v2)

    static let coincidenceWindowSeconds: TimeInterval = 30
    static let confirmDeadlineSeconds: TimeInterval = 30
    static let frontmostLeadSeconds: TimeInterval = 15
    static let windowLossGraceSeconds: TimeInterval = 5
    static let micReleaseEpisodeEndSeconds: TimeInterval = 60
    /// How long the meeting app must have let go of its audio, or been gone, before we ask whether
    /// the meeting ended. Short blips (a device switch, a crash and relaunch) stay under it.
    static let endSignalGraceSeconds: TimeInterval = 20
    /// People still talking means the meeting is not over for them, whatever the app did. The
    /// question waits until nobody has said anything for this long.
    static let speechQuietSeconds: TimeInterval = 45
    static let dismissalSuppressionSeconds: TimeInterval = 30 * 60
    static let rollingDismissalWindowSeconds: TimeInterval = 14 * 24 * 3600
    static let dismissalCountThreshold = 3

    struct PromptRequest: Equatable {
        var episodeID: UUID
        var bundleIdentifier: String
        var pid: Int32
        var tier: MeetingDetectionTier
        var cta: PromptCTA = .record
        /// Browser tier only: the meeting service behind the tab, e.g. "Google Meet".
        var serviceName: String? = nil
    }

    static func serviceName(forEvidenceKey key: String) -> String? {
        guard key.hasPrefix("url:") else { return nil }
        let host = key.dropFirst(4).split(separator: "/").first.map(String.init)?.lowercased() ?? ""
        if host == "meet.google.com" { return "Google Meet" }
        if host.hasSuffix("zoom.us") { return "Zoom" }
        if host.hasPrefix("teams.") { return "Microsoft Teams" }
        if host.contains("whereby.com") { return "Whereby" }
        if host == "meet.jit.si" { return "Jitsi" }
        return nil
    }

    enum PromptCTA: String, Equatable, Sendable { case record, setup }

    enum Health: String, Equatable, Sendable {
        case ready
        case zoomWindowTitleUnreadable
    }

    struct ResolvedTarget: Equatable {
        var bundleIdentifier: String
        var pid: Int32
        /// Set only for Tier 1 native evidence — the window auto-detection actually found.
        var windowID: UInt32?
    }

    var onPromptRequested: ((PromptRequest) -> Void)?
    var onStillRecordingNudge: (() -> Void)?
    /// The call came back after we asked whether it ended. Take the question down.
    var onStillRecordingNudgeWithdrawn: (() -> Void)?
    var onSuggestDisablingAutoDetect: (() -> Void)?
    var onEpisodeInvalidated: ((UUID) -> Void)?
    var onHealthChanged: ((Health) -> Void)?
    /// Independent of prompt presentation/consumption; selecting a source never starts capture.
    var onAutomaticTargetChanged: ((ResolvedTarget?) -> Void)?
    private(set) var automaticTarget: ResolvedTarget?

    private struct CandidateRecord {
        var incarnation: UInt64
        var pid: Int32
        var bundleIdentifier: String
        var tier: MeetingDetectionTier
        var lastFrontmostAt: Date?
        var audioEvidenceAt: Date?
        var audioEvidenceSource: AudioEvidenceSource?
        var processAudioWasActive = false
        var processAudioObserved = false
        var processAudioInactiveAt: Date?
        var windowEvidenceAt: Date?
        var windowEvidenceKey: String?
        var windowEvidenceWindowID: UInt32?
        var hasLiveWindow = false
        var windowLostAt: Date?
    }

    private enum AudioEvidenceSource: Equatable {
        case device
        case process
    }

    private struct Episode {
        var id: UUID
        var pid: Int32
        var bundleIdentifier: String
        var tier: MeetingDetectionTier
        var key: String
        var windowID: UInt32?
        var confirmedAt: Date
        var consumed = false
        var duplicateEpisodeRejectionLogged = false
    }

    /// The meeting app behind our own live recording. Kept apart from the episode, which is
    /// retired by rules written for the next start prompt and can go while we still record.
    private struct WatchedRecording {
        var pid: Int32
        var bundleIdentifier: String
        var tier: MeetingDetectionTier
        var incarnation: UInt64?
        /// The app's own audio was seen running during this recording, so seeing it stop means something.
        var sawProcessAudio = false
        var appGoneAt: Date?
        /// Browser meetings only: when the browser was first seen without the microphone.
        var browserMicReleasedAt: Date?
        var browserMicUnknown = false
        var asked = false
        /// The user waved the question away. It stays away for the rest of this recording.
        var silenced = false
    }

    private let workspaceEvents: any WorkspaceEventsProviding
    private let micActivity: any MicActivitySignalProviding
    private let audioProcessActivity: any AudioProcessActivityProviding
    private let windowSnapshotProvider: any WindowSnapshotProviding
    private let browserTabReader: any BrowserTabReading
    private let activityGate: any DetectionActivityGate
    private let clock: any MeetingClockProviding
    private let isNativeDetectionEnabled: () -> Bool
    private let isBrowserDetectionEnabled: () -> Bool
    private let lastSpeechAt: () -> Date?
    private let rejectionLogger: (String) -> Void
    private var lastLoggedRejectionByPID: [Int32: String] = [:]

    private var records: [Int32: CandidateRecord] = [:] {
        didSet { self.publishAutomaticTarget() }
    }

    private var lastMicReleaseAt: Date?
    private var episodesByKey: [String: Episode] = [:] {
        didSet { self.publishAutomaticTarget() }
    }

    private var activeConsumedEpisodeKey: String?
    private var watchedRecording: WatchedRecording?
    private var dismissedBundleUntil: [String: Date] = [:]
    private var dismissalTimestamps: [Date] = []
    private var pollTask: Task<Void, Never>?
    private var runGeneration: UInt64 = 0
    private var candidateIncarnation: UInt64 = 0
    private var lastBrowserPollAt: [Int32: Date] = [:]
    private var titleEnrichmentGeneration: [Int32: UInt64] = [:]
    private var titleEnrichmentInFlight: Set<Int32> = []
    private var lastHealth: Health?
    private var audioQueryUnknown = false

    init(
        workspaceEvents: any WorkspaceEventsProviding,
        micActivity: any MicActivitySignalProviding,
        audioProcessActivity: any AudioProcessActivityProviding,
        windowSnapshotProvider: any WindowSnapshotProviding,
        browserTabReader: any BrowserTabReading,
        activityGate: any DetectionActivityGate,
        clock: any MeetingClockProviding,
        isNativeDetectionEnabled: @escaping () -> Bool,
        isBrowserDetectionEnabled: @escaping () -> Bool,
        lastSpeechAt: @escaping () -> Date? = { nil },
        rejectionLogger: @escaping (String) -> Void = { DebugLogger.shared.log($0, source: "MeetingAutoDetector") }
    ) {
        self.workspaceEvents = workspaceEvents
        self.micActivity = micActivity
        self.audioProcessActivity = audioProcessActivity
        self.windowSnapshotProvider = windowSnapshotProvider
        self.browserTabReader = browserTabReader
        self.activityGate = activityGate
        self.clock = clock
        self.isNativeDetectionEnabled = isNativeDetectionEnabled
        self.isBrowserDetectionEnabled = isBrowserDetectionEnabled
        self.lastSpeechAt = lastSpeechAt
        self.rejectionLogger = rejectionLogger
    }

    // MARK: - Lifecycle

    func start() {
        guard self.pollTask == nil else { return }
        self.runGeneration &+= 1
        let runGeneration = self.runGeneration
        self.workspaceEvents.onEvent = { [weak self] event in self?.handleWorkspaceEvent(event, at: self?.clock.now() ?? Date()) }
        self.workspaceEvents.start(isRegistryApp: { MeetingAppRegistry.tier(forBundleIdentifier: $0) != nil }) { [weak self] backfill in
            self?.handleBackfill(backfill)
        }
        self.micActivity.onEdge = { [weak self] edge in self?.handleMicEdge(edge, at: self?.clock.now() ?? Date()) }
        self.micActivity.start()
        self.installTransientDisarmObservers()

        self.pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                await self.pollTick(runGeneration: runGeneration)
            }
        }
    }

    func stop() {
        self.automaticTarget = nil
        self.onAutomaticTargetChanged?(nil)
        self.runGeneration &+= 1
        self.pollTask?.cancel()
        self.pollTask = nil
        self.workspaceEvents.stop()
        self.micActivity.stop()
        self.titleEnrichmentInFlight.removeAll()
        self.titleEnrichmentGeneration.removeAll()
        self.removeTransientDisarmObservers()
        self.lastLoggedRejectionByPID.removeAll()
    }

    private func pollTick(runGeneration: UInt64) async {
        guard self.isCurrentRun(runGeneration) else { return }
        let now = self.clock.now()
        if self.isNativeDetectionEnabled() {
            await self.pollAudioProcessActivity(at: now, expectedRunGeneration: runGeneration)
            guard self.isCurrentRun(runGeneration) else { return }
        }
        if self.shouldCollectEvidence(at: now) {
            if self.isNativeDetectionEnabled() {
                let nativePIDs = Set(self.records.filter { $0.value.tier == .nativeTier1 }.keys)
                if !nativePIDs.isEmpty {
                    self.handleWindowSnapshot(self.windowSnapshotProvider.snapshot(interestPIDs: nativePIDs), at: now)
                }
            }
            if self.isBrowserDetectionEnabled() {
                await self.pollBrowserTabsIfDue(at: now, runGeneration: runGeneration)
                guard self.isCurrentRun(runGeneration) else { return }
            }
        }
        guard self.isCurrentRun(runGeneration) else { return }
        self.tick(at: self.clock.now())
    }

    private func isCurrentRun(_ generation: UInt64) -> Bool {
        !Task.isCancelled && self.runGeneration == generation && self.pollTask != nil
    }

    private func shouldCollectEvidence(at now: Date) -> Bool {
        if !self.episodesByKey.isEmpty { return true }
        // A browser we were recording is gone. Keep reading tabs so a relaunched one that is back
        // on the meeting can be recognised.
        if let watched = self.watchedRecording, watched.tier == .browserTier2, !self.isStillRunning(watched) { return true }
        return self.records.values.contains { record in
            record.hasLiveWindow || record.windowLostAt != nil
                || record.audioEvidenceAt.map { now.timeIntervalSince($0) <= Self.confirmDeadlineSeconds } == true
        }
    }

    private func pollBrowserTabsIfDue(at now: Date, runGeneration: UInt64) async {
        for (pid, record) in self.records where record.tier == .browserTier2 {
            guard self.isCurrentRun(runGeneration), self.isBrowserDetectionEnabled() else { return }
            let lastPoll = self.lastBrowserPollAt[pid]
            guard lastPoll.map { now.timeIntervalSince($0) >= 2 } ?? true else { continue }
            let url = await self.browserTabReader.frontmostTabURL(bundleIdentifier: record.bundleIdentifier, processID: pid)
            guard self.isCurrentRun(runGeneration), self.isBrowserDetectionEnabled(),
                  self.records[pid]?.incarnation == record.incarnation
            else { continue }
            self.lastBrowserPollAt[pid] = now
            self.handleBrowserTabURL(url, pid: pid, bundleIdentifier: record.bundleIdentifier, at: self.clock.now())
        }
    }

    // MARK: - Workspace events

    func handleWorkspaceEvent(_ event: WorkspaceEvent, at now: Date) {
        guard let tier = MeetingAppRegistry.tier(forBundleIdentifier: event.bundleIdentifier) else { return }
        guard tier == .nativeTier1 ? self.isNativeDetectionEnabled() : self.isBrowserDetectionEnabled() else { return }

        switch event.kind {
        case .launched:
            self.armIfNeeded(pid: event.processID, bundleIdentifier: event.bundleIdentifier, tier: tier)
        case .activated:
            self.armIfNeeded(pid: event.processID, bundleIdentifier: event.bundleIdentifier, tier: tier)
            self.records[event.processID]?.lastFrontmostAt = now
            DebugLogger.shared.log("app-activated bundle=\(event.bundleIdentifier)", source: "MeetingAutoDetector")
        case .terminated:
            self.records[event.processID] = nil
            self.lastLoggedRejectionByPID[event.processID] = nil
            self.lastBrowserPollAt[event.processID] = nil
            self.titleEnrichmentInFlight.remove(event.processID)
            self.titleEnrichmentGeneration[event.processID] = nil
        }
    }

    /// Backfill only arms known-running apps; it never seeds mic/frontmost timestamps. A backfilled
    /// app is only stamped frontmost later, at a mic edge while it is actually in front.
    func handleBackfill(_ events: [WorkspaceEvent]) {
        for event in events {
            guard let tier = MeetingAppRegistry.tier(forBundleIdentifier: event.bundleIdentifier) else { continue }
            self.armIfNeeded(pid: event.processID, bundleIdentifier: event.bundleIdentifier, tier: tier)
        }
    }

    private func armIfNeeded(pid: Int32, bundleIdentifier: String, tier: MeetingDetectionTier) {
        guard self.records[pid] == nil else { return }
        self.candidateIncarnation &+= 1
        self.records[pid] = CandidateRecord(
            incarnation: self.candidateIncarnation,
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            tier: tier
        )
        DebugLogger.shared.log("record-armed bundle=\(bundleIdentifier)", source: "MeetingAutoDetector")
    }

    // MARK: - Mic activity

    func handleMicEdge(_ edge: MicActivityEdge, at now: Date) {
        guard edge.isActive else {
            self.lastMicReleaseAt = now
            for pid in self.records.keys where self.records[pid]?.audioEvidenceSource == .device {
                self.records[pid]?.audioEvidenceAt = nil
                self.records[pid]?.audioEvidenceSource = nil
                if let bundleIdentifier = self.records[pid]?.bundleIdentifier {
                    DebugLogger.shared.log("audio-evidence-end path=device bundle=\(bundleIdentifier)", source: "MeetingAutoDetector")
                }
            }
            return
        }
        self.lastMicReleaseAt = nil
        let frontmostPID = self.workspaceEvents.frontmostProcessID
        for pid in self.records.keys {
            guard var record = self.records[pid] else { continue }
            // A browser the user has been sitting in for minutes (Calendar → Meet) never re-activates;
            // being in front at the moment the mic opens is equally strong evidence because the tab
            // URL still gates confirmation. Native apps keep the activation rule: Teams and Webex
            // windows persist all day and would otherwise confirm on any unrelated mic edge.
            if record.tier == .browserTier2, frontmostPID == pid, !self.isFrontmostNearEdge(record, edge: now) {
                record.lastFrontmostAt = now
                self.records[pid] = record
            }
            guard self.isFrontmostNearEdge(record, edge: now) else { continue }
            self.records[pid]?.audioEvidenceAt = now
            self.records[pid]?.audioEvidenceSource = .device
            DebugLogger.shared.log("audio-evidence-begin path=device bundle=\(record.bundleIdentifier)", source: "MeetingAutoDetector")
            self.attemptConfirm(pid: pid, at: now)
        }
    }

    func pollAudioProcessActivity(at now: Date) async {
        await self.pollAudioProcessActivity(at: now, expectedRunGeneration: nil)
    }

    private func pollAudioProcessActivity(at now: Date, expectedRunGeneration: UInt64?) async {
        guard !Task.isCancelled,
              expectedRunGeneration.map({ self.runGeneration == $0 && self.pollTask != nil && self.isNativeDetectionEnabled() }) ?? true
        else { return }
        let candidates = self.records.filter { $0.value.tier == .nativeTier1 }
        let snapshot = await self.audioProcessActivity.snapshot()
        guard !Task.isCancelled,
              expectedRunGeneration.map({ self.runGeneration == $0 && self.pollTask != nil && self.isNativeDetectionEnabled() }) ?? true
        else { return }
        self.noteWatchedBrowserMicrophone(snapshot, at: now)
        guard let activeInputByPID = MeetingAudioProcessResolver.activeOwnerInputByPID(snapshot: snapshot) else {
            if !self.audioQueryUnknown {
                DebugLogger.shared.warning("audio-query-unavailable native confirmation paused", source: "MeetingAutoDetector")
            }
            self.audioQueryUnknown = true
            for (pid, record) in candidates where self.records[pid]?.incarnation == record.incarnation {
                self.records[pid]?.processAudioInactiveAt = nil
            }
            return
        }
        if self.audioQueryUnknown {
            DebugLogger.shared.info("audio-query-recovered native activity reconciliation resumed", source: "MeetingAutoDetector")
        }
        self.audioQueryUnknown = false
        for (pid, record) in candidates {
            guard !Task.isCancelled,
                  expectedRunGeneration.map({ self.runGeneration == $0 && self.pollTask != nil && self.isNativeDetectionEnabled() }) ?? true,
                  self.records[pid]?.incarnation == record.incarnation
            else { continue }
            let isActive = activeInputByPID[pid] != nil
            let hasInput = activeInputByPID[pid] == true
            guard !isActive || snapshot.owners.contains(where: { $0.processID == pid && $0.bundleIdentifier == record.bundleIdentifier }) else { continue }
            // Generic helpers often expose output-only media while the app is idle. Require
            // input for a new generic episode; an already-established episode is enough
            // to make output-only activity meaningful. Zoom's muted output-only path remains
            // supported because Zoom also requires an explicit meeting-window title.
            let hasEstablishedEpisode = self.episodesByKey.values.contains { $0.pid == pid }
            // The process behind our own recording stays established after its episode retires, so
            // a muted call that resumes still reads as audio. Only that process: a relaunched copy
            // playing a notification sound is not a call. We are busy recording, so this cannot
            // raise a start prompt.
            let isBehindOurRecording = self.watchedRecording.map { $0.pid == pid && $0.incarnation == record.incarnation } == true
            if isActive, !hasInput, record.bundleIdentifier != "us.zoom.xos", !hasEstablishedEpisode, !isBehindOurRecording {
                self.handleAudioProcessActivity(false, pid: pid, at: now)
                continue
            }
            self.handleAudioProcessActivity(isActive, pid: pid, at: now)
        }
    }

    /// A web meeting is over when the browser lets go of the microphone, whichever tab is in front.
    /// Only a browser we saw holding the microphone during this recording can be read this way.
    private func noteWatchedBrowserMicrophone(_ snapshot: AudioProcessActivitySnapshot, at now: Date) {
        guard var watched = self.watchedRecording, watched.tier == .browserTier2 else { return }
        let inputByPID = MeetingAudioProcessResolver.activeOwnerInputByPID(
            snapshot: snapshot,
            owning: MeetingAppRegistry.isBrowserApp(bundleIdentifier:)
        )
        var inUse: Bool?
        if let inputByPID {
            func holdsMicrophone(_ bundleIdentifier: String, _ pid: Int32) -> Bool? {
                Self.browserHoldsMicrophone(bundleIdentifier: bundleIdentifier, pid: pid, owners: snapshot.owners, inputByPID: inputByPID)
            }
            if !self.isStillRunning(watched) {
                // The microphone alone could be a voice recorder page. It has to be on a meeting tab.
                self.follow(&watched, to: self.records.values.filter {
                    $0.bundleIdentifier == watched.bundleIdentifier && $0.tier == .browserTier2
                        && $0.hasLiveWindow && holdsMicrophone($0.bundleIdentifier, $0.pid) == true
                })
            }
            inUse = holdsMicrophone(watched.bundleIdentifier, watched.pid)
        }
        switch inUse {
        case true?:
            watched.browserMicUnknown = false
            watched.sawProcessAudio = true
            watched.browserMicReleasedAt = nil
        case false?:
            watched.browserMicUnknown = false
            if watched.sawProcessAudio, watched.browserMicReleasedAt == nil { watched.browserMicReleasedAt = now }
        case nil:
            // Not readable is not a release. The quiet has to be seen again from the start.
            watched.browserMicUnknown = true
            watched.browserMicReleasedAt = nil
        }
        self.watchedRecording = watched
    }

    /// Whether a browser holds the microphone, or nil when that cannot be told. A web app records
    /// through the browser it runs in, and with two copies of that browser open there is no
    /// telling which one it is.
    private static func browserHoldsMicrophone(
        bundleIdentifier: String,
        pid: Int32,
        owners: [MeetingProcessOwner],
        inputByPID: [Int32: Bool]
    ) -> Bool? {
        guard let browser = MeetingAppRegistry.parentBrowser(ofWebApp: bundleIdentifier) else { return inputByPID[pid] == true }
        let browsers = owners.filter { $0.bundleIdentifier == browser }
        guard browsers.count == 1, let owner = browsers.first else { return nil }
        return inputByPID[owner.processID] == true
    }

    private func isStillRunning(_ watched: WatchedRecording) -> Bool {
        guard let record = self.records[watched.pid] else { return false }
        return watched.incarnation == nil || record.incarnation == watched.incarnation
    }

    /// The app behind the recording crashed or was restarted and is in a call again under a new
    /// process. Follow it, so the question can be taken back. Only one clear match of the same
    /// app is ever adopted.
    private func follow(_ watched: inout WatchedRecording, to relaunched: [CandidateRecord]) {
        guard relaunched.count == 1, let record = relaunched.first else { return }
        watched.pid = record.pid
        watched.incarnation = record.incarnation
        watched.sawProcessAudio = true
        watched.appGoneAt = nil
        DebugLogger.shared.log("end-of-meeting-watch-followed bundle=\(record.bundleIdentifier)", source: "MeetingAutoDetector")
    }

    func handleAudioProcessActivity(_ isActive: Bool, pid: Int32, at now: Date) {
        guard var record = self.records[pid], record.tier == .nativeTier1 else { return }
        record.processAudioObserved = true
        if isActive, self.watchedRecording?.pid == pid, self.watchedRecording?.incarnation == record.incarnation {
            self.watchedRecording?.sawProcessAudio = true
        }
        if isActive, record.processAudioWasActive {
            // A continuous stream is still fresh evidence. Refreshing here allows a late window
            // snapshot/activation to confirm without synthesizing duplicate episodes.
            record.audioEvidenceAt = now
            record.audioEvidenceSource = .process
            record.processAudioInactiveAt = nil
            self.records[pid] = record
            self.attemptConfirm(pid: pid, at: now)
            return
        }
        if !isActive, !record.processAudioWasActive {
            // Inactivity must be continuously observed; an unknown snapshot resets this timer.
            if record.processAudioInactiveAt == nil { record.processAudioInactiveAt = now }
            self.records[pid] = record
            return
        }
        record.processAudioWasActive = isActive
        if isActive {
            record.processAudioInactiveAt = nil
            record.audioEvidenceAt = now
            record.audioEvidenceSource = .process
            self.records[pid] = record
            DebugLogger.shared.log("audio-evidence-begin path=process bundle=\(record.bundleIdentifier)", source: "MeetingAutoDetector")
            self.attemptConfirm(pid: pid, at: now)
        } else {
            record.processAudioInactiveAt = now
            if record.audioEvidenceSource == .process {
                record.audioEvidenceAt = nil
                record.audioEvidenceSource = nil
            }
            self.records[pid] = record
            DebugLogger.shared.log("audio-evidence-end path=process bundle=\(record.bundleIdentifier)", source: "MeetingAutoDetector")
        }
    }

    private func isFrontmostNearEdge(_ record: CandidateRecord, edge: Date) -> Bool {
        guard let frontmostAt = record.lastFrontmostAt else { return false }
        let delta = edge.timeIntervalSince(frontmostAt)
        return delta >= -5 && delta <= Self.frontmostLeadSeconds
    }

    // MARK: - Window evidence (Tier 1)

    func handleWindowSnapshot(_ snapshots: [WindowSnapshot], at now: Date) {
        for pid in self.records.keys where self.records[pid]?.tier == .nativeTier1 {
            guard let bundleIdentifier = self.records[pid]?.bundleIdentifier else { continue }
            let ownedWindows = snapshots.filter { $0.processID == pid && $0.layer == 0 }
            let matched = self.matchingNativeWindow(ownedWindows, bundleIdentifier: bundleIdentifier)

            if matched == nil, bundleIdentifier == "us.zoom.xos",
               let unreadableWindow = ownedWindows.first(where: { $0.title == nil })
            {
                guard !self.titleEnrichmentInFlight.contains(pid) else { continue }
                self.titleEnrichmentInFlight.insert(pid)
                let generation = (self.titleEnrichmentGeneration[pid] ?? 0) &+ 1
                self.titleEnrichmentGeneration[pid] = generation
                let provider = self.windowSnapshotProvider
                Task { [weak self] in
                    let titles = await provider.titles(processID: pid)
                    guard let self else { return }
                    guard self.titleEnrichmentGeneration[pid] == generation else {
                        self.titleEnrichmentInFlight.remove(pid)
                        return
                    }
                    self.titleEnrichmentInFlight.remove(pid)
                    guard self.titleEnrichmentGeneration[pid] == generation,
                          let current = self.records[pid], current.bundleIdentifier == bundleIdentifier
                    else { return }
                    guard let title = titles.first(where: MeetingAppRegistry.isZoomMeetingWindowTitle) else {
                        self.publishHealth(titles.isEmpty ? .zoomWindowTitleUnreadable : .ready)
                        return
                    }
                    self.publishHealth(.ready)
                    self.handleWindowSnapshot(
                        ownedWindows.map { snapshot in
                            snapshot.windowID == unreadableWindow.windowID
                                ? WindowSnapshot(processID: snapshot.processID, windowID: snapshot.windowID, title: title, layer: snapshot.layer)
                                : snapshot
                        }, at: self.clock.now()
                    )
                }
            }

            if let matched {
                if bundleIdentifier == "us.zoom.xos" { self.publishHealth(.ready) }
                let wasLiveWindow = self.records[pid]?.hasLiveWindow == true
                self.records[pid]?.hasLiveWindow = true
                self.records[pid]?.windowLostAt = nil
                self.records[pid]?.windowEvidenceAt = now
                self.records[pid]?.windowEvidenceKey = "win:\(matched.windowID)"
                self.records[pid]?.windowEvidenceWindowID = matched.windowID
                if !wasLiveWindow {
                    DebugLogger.shared.log("window-evidence-found bundle=\(bundleIdentifier)", source: "MeetingAutoDetector")
                }
                self.attemptConfirm(pid: pid, at: now)
            } else if self.records[pid]?.hasLiveWindow == true {
                self.records[pid]?.hasLiveWindow = false
                if self.records[pid]?.windowLostAt == nil {
                    self.records[pid]?.windowLostAt = now
                    DebugLogger.shared.log("window-evidence-lost bundle=\(bundleIdentifier)", source: "MeetingAutoDetector")
                }
            }
        }
    }

    /// Zoom requires a meeting/webinar-titled window (the home window never qualifies); Teams and
    /// Webex have no generically nameable meeting window, so presence + frontmost-at-edge is the
    /// whole attribution for them.
    private func matchingNativeWindow(_ windows: [WindowSnapshot], bundleIdentifier: String) -> WindowSnapshot? {
        if bundleIdentifier == "us.zoom.xos" {
            return windows.first { MeetingAppRegistry.isZoomMeetingWindowTitle($0.title ?? "") }
        }
        return windows.first
    }

    private func publishHealth(_ health: Health) {
        guard self.lastHealth != health else { return }
        self.lastHealth = health
        DebugLogger.shared.log("detector-health=\(health.rawValue)", source: "MeetingAutoDetector")
        self.onHealthChanged?(health)
    }

    // MARK: - Browser evidence (Tier 2)

    func handleBrowserTabURL(_ url: BrowserTabURL?, pid: Int32, bundleIdentifier: String, at now: Date) {
        guard let url, MeetingInCallURLMatcher.isInCallURL(host: url.host, path: url.path) else {
            // Unreadable AXURL (nil) or the tab navigated off an in-call URL: fail closed and,
            // if this record had live evidence, start the loss clock so the episode can end.
            if self.records[pid]?.hasLiveWindow == true {
                self.records[pid]?.hasLiveWindow = false
                if self.records[pid]?.windowLostAt == nil {
                    self.records[pid]?.windowLostAt = now
                    DebugLogger.shared.log("window-evidence-lost bundle=\(bundleIdentifier)", source: "MeetingAutoDetector")
                }
            }
            return
        }
        let wasLiveWindow = self.records[pid]?.hasLiveWindow == true
        self.records[pid]?.windowEvidenceAt = now
        self.records[pid]?.windowEvidenceKey = "url:\(url.host)\(url.path)"
        self.records[pid]?.hasLiveWindow = true
        self.records[pid]?.windowLostAt = nil
        if !wasLiveWindow {
            DebugLogger.shared.log("window-evidence-found bundle=\(bundleIdentifier)", source: "MeetingAutoDetector")
        }
        self.attemptConfirm(pid: pid, at: now)
    }

    // MARK: - Confirm + episode lifecycle

    private func attemptConfirm(pid: Int32, at now: Date) {
        guard let record = self.records[pid],
              record.tier == .nativeTier1 ? self.isNativeDetectionEnabled() : self.isBrowserDetectionEnabled(),
              let audioEvidenceAt = record.audioEvidenceAt,
              let audioEvidenceSource = record.audioEvidenceSource,
              let windowEvidenceAt = record.windowEvidenceAt,
              let evidenceKey = record.windowEvidenceKey
        else { return }
        if record.tier == .nativeTier1, self.audioQueryUnknown {
            return // a transient HAL failure is not an inactive edge, but cannot confirm anew
        }
        guard now.timeIntervalSince(audioEvidenceAt) <= Self.confirmDeadlineSeconds else {
            self.logConfirmRejected("deadline", record: record)
            return
        }
        guard abs(windowEvidenceAt.timeIntervalSince(audioEvidenceAt)) <= Self.coincidenceWindowSeconds else {
            self.logConfirmRejected("coincidence", record: record)
            return
        }
        let frontmostPasses = audioEvidenceSource == .process ? record.lastFrontmostAt != nil : self.isFrontmostNearEdge(record, edge: audioEvidenceAt)
        guard frontmostPasses else {
            self.logConfirmRejected("frontmost", record: record)
            return
        }

        let readiness = self.activityGate.preflightState()
        guard readiness != .busy else {
            self.logConfirmRejected("busy", record: record)
            return
        }

        let episodeKey = "pid:\(pid)|\(evidenceKey)"
        if var existingEpisode = self.episodesByKey[episodeKey] {
            if !existingEpisode.duplicateEpisodeRejectionLogged {
                self.logConfirmRejected("duplicate-episode", record: record)
                existingEpisode.duplicateEpisodeRejectionLogged = true
                self.episodesByKey[episodeKey] = existingEpisode
            }
            return
        }
        guard (self.dismissedBundleUntil[record.bundleIdentifier].map { $0 > now }) != true else {
            self.logConfirmRejected("bundle-suppressed", record: record)
            return
        }

        let episode = Episode(
            id: UUID(),
            pid: pid,
            bundleIdentifier: record.bundleIdentifier,
            tier: record.tier,
            key: episodeKey,
            windowID: record.tier == .nativeTier1 ? record.windowEvidenceWindowID : nil,
            confirmedAt: now
        )
        self.episodesByKey[episodeKey] = episode
        self.lastLoggedRejectionByPID[pid] = nil

        DebugLogger.shared.log("preflight-state=\(Self.readinessToken(readiness)) bundle=\(record.bundleIdentifier)", source: "MeetingAutoDetector")
        guard readiness != .busy else {
            return
        }
        DebugLogger.shared.log("confirm-accepted bundle=\(record.bundleIdentifier)", source: "MeetingAutoDetector")
        DebugLogger.shared.log("prompt-requested bundle=\(record.bundleIdentifier)", source: "MeetingAutoDetector")
        let cta: PromptCTA = readiness == .ready ? .record : .setup
        self.onPromptRequested?(PromptRequest(
            episodeID: episode.id,
            bundleIdentifier: episode.bundleIdentifier,
            pid: pid,
            tier: episode.tier,
            cta: cta,
            serviceName: Self.serviceName(forEvidenceKey: evidenceKey)
        ))
    }

    private func logConfirmRejected(_ reason: String, record: CandidateRecord) {
        // Diagnostics follow reason changes; prompt admission still runs on every event.
        // These slots share the candidate lifetime and never mutate source-selection state.
        guard self.lastLoggedRejectionByPID[record.pid] != reason else { return }
        self.lastLoggedRejectionByPID[record.pid] = reason
        self.rejectionLogger("confirm-rejected reason=\(reason) bundle=\(record.bundleIdentifier)")
    }

    private static func readinessToken(_ state: DetectionPreflightState) -> String {
        switch state {
        case .ready: return "ready"
        case .busy: return "busy"
        case let .needsSetup(reason): return "setup-\(reason.rawValue)"
        }
    }

    // MARK: - Prompt outcomes

    enum StartError: LocalizedError, Equatable {
        case cannotStart

        var errorDescription: String? {
            "Can't start recording right now."
        }
    }

    func canStart(episodeID: UUID) -> Bool {
        guard let episode = self.episodesByKey.values.first(where: { $0.id == episodeID }),
              !episode.consumed
        else { return false }
        return self.activityGate.preflightState() == .ready
    }

    /// Adopt after recording has actually started. Skips preflight because the live
    /// recording itself would fail the idle gate. Re-adopts timeout-consumed episodes so
    /// the live session still owns the key and clears the dismissal counter.
    func adoptStartedEpisode(episodeID: UUID) {
        guard let key = self.episodesByKey.first(where: { $0.value.id == episodeID })?.key,
              var episode = self.episodesByKey[key]
        else { return }
        episode.consumed = true
        self.episodesByKey[key] = episode
        self.activeConsumedEpisodeKey = key
        self.dismissalTimestamps.removeAll()
        let record = self.records[episode.pid]
        self.watchedRecording = WatchedRecording(
            pid: episode.pid,
            bundleIdentifier: episode.bundleIdentifier,
            tier: episode.tier,
            incarnation: record?.incarnation,
            sawProcessAudio: record?.processAudioWasActive == true
        )
    }

    /// Our recording is over, however it ended. Nothing is left to ask about.
    func recordingStopped() {
        self.watchedRecording = nil
    }

    /// The user closed the "Meeting ended?" question without stopping.
    func stillRecordingNudgeDismissed() {
        self.watchedRecording?.silenced = true
    }

    /// Atomic gate re-check + single-shot consume. Returns false if the episode is unknown,
    /// already consumed, or the gate no longer passes — callers must not proceed with Start.
    @discardableResult
    func startTapped(episodeID: UUID) -> Bool {
        guard self.canStart(episodeID: episodeID) else { return false }
        self.adoptStartedEpisode(episodeID: episodeID)
        return true
    }

    func resolvedTarget(for episodeID: UUID) -> ResolvedTarget? {
        guard let episode = self.episodesByKey.values.first(where: { $0.id == episodeID }) else { return nil }
        return ResolvedTarget(bundleIdentifier: episode.bundleIdentifier, pid: episode.pid, windowID: episode.windowID)
    }

    private func publishAutomaticTarget() {
        let eligible = self.episodesByKey.values.filter { episode in
            guard self.isNativeDetectionEnabled(),
                  episode.tier == .nativeTier1 || self.isBrowserDetectionEnabled(),
                  let record = self.records[episode.pid],
                  record.bundleIdentifier == episode.bundleIdentifier,
                  episode.key == "pid:\(episode.pid)|\(record.windowEvidenceKey ?? "")",
                  record.hasLiveWindow,
                  record.processAudioInactiveAt == nil
            else { return false }
            return true
        }
        // Ambiguity requires an explicit source, never arbitrary dictionary order.
        let target = eligible.count == 1 ? eligible.first.map {
            ResolvedTarget(bundleIdentifier: $0.bundleIdentifier, pid: $0.pid, windowID: $0.windowID)
        } : nil
        guard target != self.automaticTarget else { return }
        self.automaticTarget = target
        self.onAutomaticTargetChanged?(target)
    }

    /// Explicit "X" dismiss: suppresses the bundle for 30 minutes and counts toward the rolling
    /// 14-day counter. A 20s auto-dismiss timeout must call `timeoutDismissed` instead.
    func dismissTapped(episodeID: UUID, at now: Date) {
        guard let key = self.episodesByKey.first(where: { $0.value.id == episodeID })?.key,
              var episode = self.episodesByKey[key], !episode.consumed
        else { return }
        episode.consumed = true
        self.episodesByKey[key] = episode

        self.dismissedBundleUntil[episode.bundleIdentifier] = now.addingTimeInterval(Self.dismissalSuppressionSeconds)
        self.dismissalTimestamps.append(now)
        self.dismissalTimestamps.removeAll { now.timeIntervalSince($0) > Self.rollingDismissalWindowSeconds }
        if self.dismissalTimestamps.count >= Self.dismissalCountThreshold {
            self.onSuggestDisablingAutoDetect?()
        }
    }

    /// 20s auto-dismiss: consumes the episode (no re-prompt into the same meeting) but does NOT
    /// suppress the bundle and does NOT count toward the dismissal counter.
    func timeoutDismissed(episodeID: UUID) {
        guard let key = self.episodesByKey.first(where: { $0.value.id == episodeID })?.key,
              var episode = self.episodesByKey[key], !episode.consumed
        else { return }
        episode.consumed = true
        self.episodesByKey[key] = episode
    }

    // MARK: - Tick — grace, release, episode teardown, still-recording nudge

    func tick(at now: Date) {
        defer { self.publishAutomaticTarget() }
        for pid in self.records.keys {
            guard var record = self.records[pid] else { continue }
            if let windowLostAt = record.windowLostAt, now.timeIntervalSince(windowLostAt) > Self.windowLossGraceSeconds {
                record.windowEvidenceAt = nil
                record.windowEvidenceKey = nil
                record.windowEvidenceWindowID = nil
            }
            self.records[pid] = record
        }

        self.evaluateEndOfMeeting(at: now)

        // Uniform episode-end eviction (window/URL evidence gone ≥60s, or the app quit) applies
        // even to a consumed episode still backing our own live recording — that IS episode end,
        // e.g. the "stop mid-call, keep talking" rule: the episode stays consumed for as long as
        // the meeting's own evidence persists, never merely because our recording stopped.
        // Mic release ≥60s ends episodes too — Teams/Webex main windows persist after a call, so
        // window loss alone would keep their episodes alive (and back-to-back meetings silent) forever.
        for (key, episode) in self.episodesByKey {
            let ended: Bool
            if let record = self.records[episode.pid] {
                let windowGone = record.windowLostAt.map { now.timeIntervalSince($0) >= Self.micReleaseEpisodeEndSeconds } == true
                let processAudioInactiveLongEnough = !self.audioQueryUnknown &&
                    (record.processAudioInactiveAt.map { now.timeIntervalSince($0) >= Self.micReleaseEpisodeEndSeconds } == true)
                // A global mic release can belong to another app/device transition. Process
                // audio is app-specific and therefore wins over that global signal.
                let micReleasedLongEnough = (record.processAudioObserved || (record.tier == .nativeTier1 && self.audioQueryUnknown)) ? false :
                    (self.lastMicReleaseAt.map { now.timeIntervalSince($0) >= Self.micReleaseEpisodeEndSeconds } == true)
                ended = windowGone || micReleasedLongEnough || processAudioInactiveLongEnough
            } else {
                ended = true // the app quit
            }
            guard ended else { continue }
            self.episodesByKey[key] = nil
            if key == self.activeConsumedEpisodeKey { self.activeConsumedEpisodeKey = nil }
            if !episode.consumed {
                self.onEpisodeInvalidated?(episode.id)
            }
            DebugLogger.shared.log("episode-ended bundle=\(episode.bundleIdentifier)", source: "MeetingAutoDetector")
        }
    }

    /// Asks "Meeting ended?" once the app behind our recording looks done: it quit, it let go of
    /// its audio, or its meeting window has been gone for a while. It only ever asks.
    private func evaluateEndOfMeeting(at now: Date) {
        guard var watched = self.watchedRecording, !watched.silenced else { return }
        if watched.tier == .nativeTier1, !self.isStillRunning(watched) {
            self.follow(&watched, to: self.records.values.filter {
                $0.bundleIdentifier == watched.bundleIdentifier && $0.tier == .nativeTier1 && $0.processAudioWasActive && $0.hasLiveWindow
            })
        }
        let askAt: Date?
        var audioUnknown = false
        if let record = self.records[watched.pid], self.isStillRunning(watched) {
            watched.appGoneAt = nil
            var moments: [Date] = []
            if record.tier == .browserTier2 {
                // We only ever read the front tab, so a meeting tab that is no longer in front says
                // nothing: the call may be running behind another tab. The microphone decides.
                audioUnknown = watched.browserMicUnknown
                if let releasedAt = watched.browserMicReleasedAt {
                    moments.append(releasedAt.addingTimeInterval(Self.endSignalGraceSeconds))
                }
            } else {
                audioUnknown = self.audioQueryUnknown
                if record.windowEvidenceAt == nil, let windowLostAt = record.windowLostAt {
                    moments.append(windowLostAt.addingTimeInterval(Self.micReleaseEpisodeEndSeconds))
                }
                // An unknown audio query is not a release, and an app whose audio we never saw running
                // gives no release to read. Teams and Webex keep a window open all day, so for them
                // this is the only sign the call is over.
                if watched.sawProcessAudio, !self.audioQueryUnknown, let inactiveAt = record.processAudioInactiveAt {
                    moments.append(inactiveAt.addingTimeInterval(Self.endSignalGraceSeconds))
                }
            }
            askAt = moments.min()
        } else {
            let goneAt = watched.appGoneAt ?? now
            watched.appGoneAt = goneAt
            askAt = goneAt.addingTimeInterval(Self.endSignalGraceSeconds)
        }
        // Without live captions there is no speech to wait for, and the app's own signal decides.
        let stillTalking = self.lastSpeechAt().map { now.timeIntervalSince($0) < Self.speechQuietSeconds } == true
        let shouldAsk = askAt.map { now >= $0 } == true && !stillTalking && !watched.asked
        // Every sign of the end is gone again: the call resumed. An audio query we cannot read is
        // not that, so it changes nothing. The question can then come back at the next real end.
        let shouldWithdraw = askAt == nil && watched.asked && !(audioUnknown && watched.sawProcessAudio)
        if shouldAsk { watched.asked = true }
        if shouldWithdraw { watched.asked = false }
        self.watchedRecording = watched
        if shouldAsk {
            DebugLogger.shared.log("end-of-meeting-asked", source: "MeetingAutoDetector")
            self.onStillRecordingNudge?()
        } else if shouldWithdraw {
            DebugLogger.shared.log("end-of-meeting-withdrawn", source: "MeetingAutoDetector")
            self.onStillRecordingNudgeWithdrawn?()
        }
    }

    // MARK: - Disarm on lock / sleep / fast-user-switch — mic bits are unreliable across these.

    func disarmAndClearTransientState() {
        self.audioQueryUnknown = false
        let unconsumedIDs = self.episodesByKey.values.compactMap { episode in
            episode.consumed ? nil : episode.id
        }
        self.records = [:]
        self.lastLoggedRejectionByPID.removeAll()
        self.titleEnrichmentInFlight.removeAll()
        self.titleEnrichmentGeneration.removeAll()
        self.lastMicReleaseAt = nil
        self.episodesByKey = [:]
        self.activeConsumedEpisodeKey = nil
        // With the records gone the app would look like it quit. Stop watching instead of guessing.
        // A question already on screen stays there for the user to answer.
        self.watchedRecording = nil
        self.lastBrowserPollAt = [:]
        for episodeID in unconsumedIDs {
            self.onEpisodeInvalidated?(episodeID)
        }
    }

    private var transientDisarmObservers: [NSObjectProtocol] = []

    private func installTransientDisarmObservers() {
        let center = NSWorkspace.shared.notificationCenter
        self.transientDisarmObservers = [
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.disarmAndClearTransientState()
            },
            center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.disarmAndClearTransientState()
            },
        ]
        self.transientDisarmObservers.append(
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
            ) { [weak self] _ in self?.disarmAndClearTransientState() }
        )
    }

    private func removeTransientDisarmObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in self.transientDisarmObservers {
            center.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        self.transientDisarmObservers = []
    }
}
