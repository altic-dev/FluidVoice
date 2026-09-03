import AppKit
import Foundation

/// Standalone meeting-detection state machine. Zero dependency on `MeetingSessionCoordinator` —
/// it reads activity state through `DetectionActivityGate` and never materializes the lazy
/// coordinator. Prompt-only: it never starts or stops a recording itself.
///
/// Every ambiguity resolves to no prompt: a false negative here is free, a false positive is not.
@MainActor
final class MeetingAutoDetector {
    // MARK: Tunables (Phase A plan v2)

    static let coincidenceWindowSeconds: TimeInterval = 30
    static let confirmDeadlineSeconds: TimeInterval = 30
    static let frontmostLeadSeconds: TimeInterval = 15
    static let windowLossGraceSeconds: TimeInterval = 5
    static let micReleaseEpisodeEndSeconds: TimeInterval = 60
    static let dismissalSuppressionSeconds: TimeInterval = 30 * 60
    static let rollingDismissalWindowSeconds: TimeInterval = 14 * 24 * 3600
    static let dismissalCountThreshold = 3

    struct PromptRequest: Equatable {
        var episodeID: UUID
        var bundleIdentifier: String
        var pid: Int32
        var tier: MeetingDetectionTier
        var cta: PromptCTA = .record
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
    var onSuggestDisablingAutoDetect: (() -> Void)?
    var onEpisodeInvalidated: ((UUID) -> Void)?
    var onHealthChanged: ((Health) -> Void)?

    private struct CandidateRecord {
        var incarnation: UInt64
        var pid: Int32
        var bundleIdentifier: String
        var tier: MeetingDetectionTier
        var lastFrontmostAt: Date?
        var audioEvidenceAt: Date?
        var audioEvidenceSource: AudioEvidenceSource?
        var processAudioWasActive = false
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
        var stillRecordingNudgeShown = false
        var duplicateEpisodeRejectionLogged = false
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

    private var records: [Int32: CandidateRecord] = [:]
    private var lastMicReleaseAt: Date?
    private var episodesByKey: [String: Episode] = [:]
    private var activeConsumedEpisodeKey: String?
    private var dismissedBundleUntil: [String: Date] = [:]
    private var dismissalTimestamps: [Date] = []
    private var pollTask: Task<Void, Never>?
    private var runGeneration: UInt64 = 0
    private var candidateIncarnation: UInt64 = 0
    private var lastBrowserPollAt: [Int32: Date] = [:]
    private var titleEnrichmentGeneration: [Int32: UInt64] = [:]
    private var titleEnrichmentInFlight: Set<Int32> = []
    private var lastHealth: Health?

    init(
        workspaceEvents: any WorkspaceEventsProviding,
        micActivity: any MicActivitySignalProviding,
        audioProcessActivity: any AudioProcessActivityProviding,
        windowSnapshotProvider: any WindowSnapshotProviding,
        browserTabReader: any BrowserTabReading,
        activityGate: any DetectionActivityGate,
        clock: any MeetingClockProviding,
        isNativeDetectionEnabled: @escaping () -> Bool,
        isBrowserDetectionEnabled: @escaping () -> Bool
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
    }

    // MARK: Lifecycle

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
        self.runGeneration &+= 1
        self.pollTask?.cancel()
        self.pollTask = nil
        self.workspaceEvents.stop()
        self.micActivity.stop()
        self.titleEnrichmentInFlight.removeAll()
        self.titleEnrichmentGeneration.removeAll()
        self.removeTransientDisarmObservers()
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
        return self.records.values.contains { record in
            record.hasLiveWindow || record.windowLostAt != nil
                || record.audioEvidenceAt.map { now.timeIntervalSince($0) <= Self.confirmDeadlineSeconds } == true
        }
    }

    private func pollBrowserTabsIfDue(at now: Date, runGeneration: UInt64) async {
        for (pid, record) in self.records where record.tier == .browserTier2 {
            guard self.isCurrentRun(runGeneration), self.isBrowserDetectionEnabled() else { return }
            let lastPoll = self.lastBrowserPollAt[pid]
            guard lastPoll == nil || now.timeIntervalSince(lastPoll!) >= 2 else { continue }
            let url = await self.browserTabReader.frontmostTabURL(bundleIdentifier: record.bundleIdentifier, processID: pid)
            guard self.isCurrentRun(runGeneration), self.isBrowserDetectionEnabled(),
                  self.records[pid]?.incarnation == record.incarnation
            else { continue }
            self.lastBrowserPollAt[pid] = now
            self.handleBrowserTabURL(url, pid: pid, bundleIdentifier: record.bundleIdentifier, at: self.clock.now())
        }
    }

    // MARK: Workspace events

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
            self.lastBrowserPollAt[event.processID] = nil
            self.titleEnrichmentInFlight.remove(event.processID)
            self.titleEnrichmentGeneration[event.processID] = nil
        }
    }

    /// Backfill only arms known-running apps; it never seeds mic/frontmost timestamps, so an
    /// already-in-progress meeting can never be retroactively confirmed from this alone.
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

    // MARK: Mic activity

    func handleMicEdge(_ edge: MicActivityEdge, at now: Date) {
        guard edge.isActive else {
            self.lastMicReleaseAt = now
            for pid in self.records.keys {
                if self.records[pid]?.audioEvidenceSource == .device {
                    self.records[pid]?.audioEvidenceAt = nil
                    self.records[pid]?.audioEvidenceSource = nil
                    if let bundleIdentifier = self.records[pid]?.bundleIdentifier {
                        DebugLogger.shared.log("audio-evidence-end path=device bundle=\(bundleIdentifier)", source: "MeetingAutoDetector")
                    }
                }
            }
            return
        }
        self.lastMicReleaseAt = nil
        for pid in self.records.keys {
            guard let record = self.records[pid], self.isFrontmostNearEdge(record, edge: now) else { continue }
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
        for (pid, record) in self.records where record.tier == .nativeTier1 {
            let isActive = await self.audioProcessActivity.isAudioActive(forBundleIdentifiers: MeetingAppRegistry.audioProcessBundleIdentifiers(for: record.bundleIdentifier))
            guard !Task.isCancelled,
                  expectedRunGeneration.map({ self.runGeneration == $0 && self.pollTask != nil && self.isNativeDetectionEnabled() }) ?? true,
                  self.records[pid]?.incarnation == record.incarnation
            else { continue }
            self.handleAudioProcessActivity(isActive, pid: pid, at: now)
        }
    }

    func handleAudioProcessActivity(_ isActive: Bool, pid: Int32, at now: Date) {
        guard var record = self.records[pid], record.tier == .nativeTier1 else { return }
        guard isActive != record.processAudioWasActive else { return }
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

    // MARK: Window evidence (Tier 1)

    func handleWindowSnapshot(_ snapshots: [WindowSnapshot], at now: Date) {
        for pid in self.records.keys where self.records[pid]?.tier == .nativeTier1 {
            guard let bundleIdentifier = self.records[pid]?.bundleIdentifier else { continue }
            let ownedWindows = snapshots.filter { $0.processID == pid && $0.layer == 0 }
            let matched = self.matchingNativeWindow(ownedWindows, bundleIdentifier: bundleIdentifier)

            if matched == nil, bundleIdentifier == "us.zoom.xos",
               let unreadableWindow = ownedWindows.first(where: { $0.title == nil }) {
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

    // MARK: Browser evidence (Tier 2)

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

    // MARK: Confirm + episode lifecycle

    private func attemptConfirm(pid: Int32, at now: Date) {
        guard let record = self.records[pid],
              let audioEvidenceAt = record.audioEvidenceAt,
              let audioEvidenceSource = record.audioEvidenceSource,
              let windowEvidenceAt = record.windowEvidenceAt,
              let evidenceKey = record.windowEvidenceKey
        else { return }
        guard now.timeIntervalSince(audioEvidenceAt) <= Self.confirmDeadlineSeconds else {
            self.logConfirmRejected("deadline", bundleIdentifier: record.bundleIdentifier)
            return
        }
        guard abs(windowEvidenceAt.timeIntervalSince(audioEvidenceAt)) <= Self.coincidenceWindowSeconds else {
            self.logConfirmRejected("coincidence", bundleIdentifier: record.bundleIdentifier)
            return
        }
        let frontmostPasses = audioEvidenceSource == .process ? record.lastFrontmostAt != nil : self.isFrontmostNearEdge(record, edge: audioEvidenceAt)
        guard frontmostPasses else {
            self.logConfirmRejected("frontmost", bundleIdentifier: record.bundleIdentifier)
            return
        }

        let readiness = self.activityGate.preflightState()
        guard readiness != .busy else {
            self.logConfirmRejected("busy", bundleIdentifier: record.bundleIdentifier)
            return
        }

        let episodeKey = "pid:\(pid)|\(evidenceKey)"
        if var existingEpisode = self.episodesByKey[episodeKey] {
            if !existingEpisode.duplicateEpisodeRejectionLogged {
                self.logConfirmRejected("duplicate-episode", bundleIdentifier: record.bundleIdentifier)
                existingEpisode.duplicateEpisodeRejectionLogged = true
                self.episodesByKey[episodeKey] = existingEpisode
            }
            return
        }
        guard (self.dismissedBundleUntil[record.bundleIdentifier].map { $0 > now }) != true else {
            self.logConfirmRejected("bundle-suppressed", bundleIdentifier: record.bundleIdentifier)
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

        DebugLogger.shared.log("preflight-state=\(Self.readinessToken(readiness)) bundle=\(record.bundleIdentifier)", source: "MeetingAutoDetector")
        guard readiness != .busy else {
            return
        }
        DebugLogger.shared.log("confirm-accepted bundle=\(record.bundleIdentifier)", source: "MeetingAutoDetector")
        DebugLogger.shared.log("prompt-requested bundle=\(record.bundleIdentifier)", source: "MeetingAutoDetector")
        let cta: PromptCTA = readiness == .ready ? .record : .setup
        self.onPromptRequested?(PromptRequest(episodeID: episode.id, bundleIdentifier: episode.bundleIdentifier, pid: pid, tier: episode.tier, cta: cta))
    }

    private func logConfirmRejected(_ reason: String, bundleIdentifier: String) {
        DebugLogger.shared.log("confirm-rejected reason=\(reason) bundle=\(bundleIdentifier)", source: "MeetingAutoDetector")
    }

    private static func readinessToken(_ state: DetectionPreflightState) -> String {
        switch state {
        case .ready: return "ready"
        case .busy: return "busy"
        case let .needsSetup(reason): return "setup-\(reason.rawValue)"
        }
    }

    // MARK: Prompt outcomes

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

    // MARK: Tick — grace, release, episode teardown, still-recording nudge

    func tick(at now: Date) {
        for pid in self.records.keys {
            guard var record = self.records[pid] else { continue }
            if let windowLostAt = record.windowLostAt, now.timeIntervalSince(windowLostAt) > Self.windowLossGraceSeconds {
                record.windowEvidenceAt = nil
                record.windowEvidenceKey = nil
                record.windowEvidenceWindowID = nil
            }
            self.records[pid] = record
        }

        // Evaluated before eviction below: the active episode must still be present to nudge on
        // the same tick its window-gone-60s threshold is crossed.
        if let activeKey = self.activeConsumedEpisodeKey, let activeEpisode = self.episodesByKey[activeKey] {
            self.evaluateStillRecordingNudge(key: activeKey, episode: activeEpisode, at: now)
        }

        // Uniform episode-end eviction (window/URL evidence gone ≥60s, or the app quit) applies
        // even to a consumed episode still backing our own live recording — that IS episode end,
        // e.g. the "stop mid-call, keep talking" rule: the episode stays consumed for as long as
        // the meeting's own evidence persists, never merely because our recording stopped.
        // Mic release ≥60s ends episodes too — Teams/Webex main windows persist after a call, so
        // window loss alone would keep their episodes alive (and back-to-back meetings silent) forever.
        let micReleasedLongEnough = self.lastMicReleaseAt.map { now.timeIntervalSince($0) >= Self.micReleaseEpisodeEndSeconds } == true
        for (key, episode) in self.episodesByKey {
            let ended: Bool
            if let record = self.records[episode.pid] {
                let windowGone = record.windowLostAt.map { now.timeIntervalSince($0) >= Self.micReleaseEpisodeEndSeconds } == true
                let processAudioInactiveLongEnough = record.processAudioInactiveAt.map { now.timeIntervalSince($0) >= Self.micReleaseEpisodeEndSeconds } == true
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

    private func evaluateStillRecordingNudge(key: String, episode: Episode, at now: Date) {
        guard !episode.stillRecordingNudgeShown else { return }
        guard let record = self.records[episode.pid] else { return }
        guard record.windowEvidenceAt == nil, let windowLostAt = record.windowLostAt else { return }
        guard now.timeIntervalSince(windowLostAt) >= Self.micReleaseEpisodeEndSeconds else { return }
        var updated = episode
        updated.stillRecordingNudgeShown = true
        self.episodesByKey[key] = updated
        self.onStillRecordingNudge?()
    }

    // MARK: Disarm on lock / sleep / fast-user-switch — mic bits are unreliable across these.

    func disarmAndClearTransientState() {
        let unconsumedIDs = self.episodesByKey.values.compactMap { episode in
            episode.consumed ? nil : episode.id
        }
        self.records = [:]
        self.titleEnrichmentInFlight.removeAll()
        self.titleEnrichmentGeneration.removeAll()
        self.lastMicReleaseAt = nil
        self.episodesByKey = [:]
        self.activeConsumedEpisodeKey = nil
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
