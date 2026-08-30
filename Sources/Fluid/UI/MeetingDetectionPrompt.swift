import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// Floating "Meeting detected" prompt — a NEW controller, deliberately separate from
/// `MeetingRecordingPillController`. The pill's contract (state-driven order-out, fixed 84×32
/// size, recording a11y label) fights a prompt mode, so this reuses only the shared panel
/// factory, not the pill's controller.
@MainActor
final class MeetingDetectionPromptController: ObservableObject {
    static let shared = MeetingDetectionPromptController()

    enum SuppressionReason: String, Equatable {
        case dictationOverlay = "dictation-overlay"
        case fullscreenOtherApp = "fullscreen-other-app"
    }

    static let panelSize = NSSize(width: 392, height: 120)
    private static let defaultTopInset: CGFloat = 12
    static let autoDismissSeconds: TimeInterval = 20
    static let suppressionRetryInterval: TimeInterval = 0.5

    enum ReminderPresentationDecision: Equatable {
        case present
        case retryAfter(TimeInterval)
        case timeout
    }

    enum IncomingPromptPolicy: Equatable {
        case ignore
        case timeoutIncoming
        case replaceExisting
    }

    enum PrimaryAction: Equatable {
        case startRecording
        case openSetup
    }

    static func primaryAction(for cta: MeetingAutoDetector.PromptCTA) -> PrimaryAction {
        cta == .setup ? .openSetup : .startRecording
    }

    enum CheapSuppressionDecision: Equatable {
        case suppressed(SuppressionReason)
        case presentNow
        case queryFullscreen(pid_t)
    }

    @Published private(set) var request: MeetingAutoDetector.PromptRequest?
    @Published private(set) var appIcon: NSImage?
    @Published private(set) var appDisplayName: String = ""
    @Published private(set) var startErrorMessage: String?
    @Published private(set) var isStarting = false

    var onStart: ((UUID) async throws -> Void)?
    var onSetup: ((UUID) -> Void)?
    var onDismiss: ((UUID) -> Void)?
    var onTimeout: ((UUID) -> Void)?

    private var panel: MeetingFloatingCaptionsPanel?
    private var autoDismissTask: Task<Void, Never>?
    private var suppressionRetryTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var autoDismissLegStartedAt: Date?
    private var remainingAutoDismissSeconds: TimeInterval = 0
    private var isAutoDismissPaused = false
    private var pendingSuppressedRequest: MeetingAutoDetector.PromptRequest?
    private var hasLoggedCurrentSuppression = false

    private init() {}

    func present(_ request: MeetingAutoDetector.PromptRequest) {
        switch Self.incomingPromptPolicy(
            isStarting: self.isStarting,
            currentEpisodeID: self.request?.episodeID,
            pendingEpisodeID: self.pendingSuppressedRequest?.episodeID,
            incomingEpisodeID: request.episodeID
        ) {
        case .ignore:
            return
        case .timeoutIncoming:
            DebugLogger.shared.log(
                "prompt-suppressed reason=start-in-progress bundle=\(request.bundleIdentifier)",
                source: "MeetingAutoDetector"
            )
            self.onTimeout?(request.episodeID)
            return
        case .replaceExisting:
            break
        }
        self.timeoutReplacedEpisodes(incoming: request.episodeID)
        self.startErrorMessage = nil
        self.isStarting = false

        switch self.cheapSuppressionDecision(for: request) {
        case .suppressed, .queryFullscreen:
            self.beginSuppressedRetry(request)
        case .presentNow:
            self.showVisiblePrompt(request, remainingSeconds: Self.autoDismissSeconds)
        }
    }

    func invalidateEpisode(_ episodeID: UUID) {
        guard Self.shouldSilentlyInvalidatePrompt(
            episodeID: episodeID,
            visibleEpisodeID: self.request?.episodeID,
            pendingEpisodeID: self.pendingSuppressedRequest?.episodeID
        ) else { return }
        if self.request?.episodeID == episodeID {
            self.hide()
            return
        }
        self.pendingSuppressedRequest = nil
        self.cancelSuppressionRetry()
        self.clearAutoDismiss()
    }

    func startTapped() {
        guard let request, !self.isStarting else { return }
        guard Self.primaryAction(for: request.cta) == .startRecording else {
            let episodeID = request.episodeID
            self.hide()
            self.onSetup?(episodeID)
            return
        }
        self.isStarting = true
        self.startErrorMessage = nil
        self.pauseAutoDismiss()
        let episodeID = request.episodeID
        self.startTask?.cancel()
        self.startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let onStart = self.onStart else {
                    self.isStarting = false
                    return
                }
                try await onStart(episodeID)
                guard !Task.isCancelled, self.request?.episodeID == episodeID else { return }
                self.hide()
            } catch {
                guard !Task.isCancelled, self.request?.episodeID == episodeID else { return }
                DebugLogger.shared.log("prompt-start-failed error=\(error)", source: "MeetingAutoDetector")
                self.startErrorMessage = Self.startErrorMessage(from: error, appDisplayName: self.appDisplayName)
                self.isStarting = false
                if !self.isPointerInsidePanel() {
                    self.resumeAutoDismiss()
                }
            }
        }
    }

    func dismissTapped() {
        guard let request, !self.isStarting else { return }
        self.hide()
        self.onDismiss?(request.episodeID)
    }

    func pauseAutoDismiss() {
        guard self.request != nil, !self.isAutoDismissPaused, let startedAt = self.autoDismissLegStartedAt else { return }
        self.remainingAutoDismissSeconds = Self.remainingAutoDismissSeconds(
            self.remainingAutoDismissSeconds,
            after: Date().timeIntervalSince(startedAt)
        )
        self.autoDismissTask?.cancel()
        self.autoDismissTask = nil
        self.autoDismissLegStartedAt = nil
        self.isAutoDismissPaused = true
    }

    func resumeAutoDismiss() {
        guard let request = self.request, self.isAutoDismissPaused, !self.isStarting else { return }
        self.isAutoDismissPaused = false
        self.scheduleAutoDismiss(for: request.episodeID)
    }

    private func hide() {
        self.startTask?.cancel()
        self.startTask = nil
        self.isStarting = false
        self.startErrorMessage = nil
        self.cancelSuppressionRetry()
        self.pendingSuppressedRequest = nil
        self.hasLoggedCurrentSuppression = false
        self.clearAutoDismiss()
        self.panel?.orderOut(nil)
        self.request = nil
    }

    private func showVisiblePrompt(_ request: MeetingAutoDetector.PromptRequest, remainingSeconds: TimeInterval) {
        self.pendingSuppressedRequest = nil
        self.cancelSuppressionRetry()
        self.request = request
        let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: request.bundleIdentifier)
        self.appIcon = resolved.map { NSWorkspace.shared.icon(forFile: $0.path) }
        self.appDisplayName = resolved.flatMap {
            FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
        } ?? "Meeting"

        let panel = self.panelOrCreate()
        self.placeAtDefaultPosition(panel)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.orderFrontRegardless()
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        DebugLogger.shared.log("prompt-shown bundle=\(request.bundleIdentifier)", source: "MeetingAutoDetector")
        AccessibilityNotification.Announcement(
            "Meeting detected in \(self.appDisplayName). Nothing is recording yet."
        ).post()

        self.clearAutoDismiss()
        self.remainingAutoDismissSeconds = remainingSeconds
        self.isAutoDismissPaused = self.isPointerInsidePanel(panel)
        self.scheduleAutoDismiss(for: request.episodeID)
    }

    private func beginSuppressedRetry(_ request: MeetingAutoDetector.PromptRequest) {
        self.request = nil
        self.panel?.orderOut(nil)
        self.pendingSuppressedRequest = request
        self.hasLoggedCurrentSuppression = false
        self.autoDismissTask?.cancel()
        self.autoDismissTask = nil
        self.autoDismissLegStartedAt = nil
        self.isAutoDismissPaused = false
        self.remainingAutoDismissSeconds = Self.autoDismissSeconds
        self.scheduleSuppressionRetry()
    }

    private func timeoutReplacedEpisodes(incoming: UUID) {
        if let existing = Self.episodeToTimeoutOnReplacement(existing: self.request?.episodeID, incoming: incoming) {
            self.onTimeout?(existing)
            self.request = nil
        }
        if let pending = Self.episodeToTimeoutOnReplacement(existing: self.pendingSuppressedRequest?.episodeID, incoming: incoming) {
            self.onTimeout?(pending)
            self.pendingSuppressedRequest = nil
        }
        self.startTask?.cancel()
        self.startTask = nil
        self.cancelSuppressionRetry()
        self.clearAutoDismiss()
    }

    private func scheduleSuppressionRetry() {
        self.suppressionRetryTask?.cancel()
        self.suppressionRetryTask = nil
        guard let pending = self.pendingSuppressedRequest else { return }
        switch self.cheapSuppressionDecision(for: pending) {
        case let .suppressed(reason):
            self.finishSuppressionEvaluation(pending: pending, reason: reason)
        case .presentNow:
            self.finishSuppressionEvaluation(pending: pending, reason: nil)
        case let .queryFullscreen(pid):
            let episodeID = pending.episodeID
            self.suppressionRetryTask = Task { [weak self] in
                let isFullScreen = await Task.detached(priority: .userInitiated) {
                    MeetingDetectionPromptController.isProcessFullScreen(processIdentifier: pid)
                }.value
                guard !Task.isCancelled, let self else { return }
                guard self.pendingSuppressedRequest?.episodeID == episodeID else { return }
                self.applyFullscreenQueryResult(pending: pending, queriedPid: pid, isFullScreen: isFullScreen)
            }
        }
    }

    private func applyFullscreenQueryResult(
        pending: MeetingAutoDetector.PromptRequest,
        queriedPid: pid_t,
        isFullScreen: Bool
    ) {
        switch self.cheapSuppressionDecision(for: pending) {
        case let .suppressed(reason):
            self.finishSuppressionEvaluation(pending: pending, reason: reason)
        case .presentNow:
            self.finishSuppressionEvaluation(pending: pending, reason: nil)
        case let .queryFullscreen(currentPid):
            guard currentPid == queriedPid else {
                self.scheduleSuppressionRetry()
                return
            }
            let reason = Self.suppressionReason(
                frontmostBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                isFrontmostFullScreen: isFullScreen,
                isDictationOverlayPresented: false,
                requestBundleIdentifier: pending.bundleIdentifier
            )
            self.finishSuppressionEvaluation(pending: pending, reason: reason)
        }
    }

    private func finishSuppressionEvaluation(
        pending: MeetingAutoDetector.PromptRequest,
        reason: SuppressionReason?
    ) {
        if let reason, !self.hasLoggedCurrentSuppression {
            self.hasLoggedCurrentSuppression = true
            DebugLogger.shared.log(
                "prompt-suppressed reason=\(reason.rawValue) bundle=\(pending.bundleIdentifier)",
                source: "MeetingAutoDetector"
            )
        }
        switch Self.reminderPresentationDecision(
            remainingBudget: self.remainingAutoDismissSeconds,
            isSuppressed: reason != nil
        ) {
        case .timeout:
            self.pendingSuppressedRequest = nil
            self.onTimeout?(pending.episodeID)
        case .present:
            self.showVisiblePrompt(pending, remainingSeconds: self.remainingAutoDismissSeconds)
        case let .retryAfter(delay):
            let delayNanoseconds = UInt64(delay * 1_000_000_000)
            let startedAt = Date()
            let episodeID = pending.episodeID
            self.suppressionRetryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delayNanoseconds)
                guard !Task.isCancelled, let self else { return }
                guard self.pendingSuppressedRequest?.episodeID == episodeID else { return }
                self.remainingAutoDismissSeconds = Self.remainingAutoDismissSeconds(
                    self.remainingAutoDismissSeconds,
                    after: Date().timeIntervalSince(startedAt)
                )
                self.scheduleSuppressionRetry()
            }
        }
    }

    private func cancelSuppressionRetry() {
        self.suppressionRetryTask?.cancel()
        self.suppressionRetryTask = nil
    }

    private func cheapSuppressionDecision(for request: MeetingAutoDetector.PromptRequest) -> CheapSuppressionDecision {
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        return Self.cheapSuppressionDecision(
            frontmostBundleIdentifier: frontmostApplication?.bundleIdentifier,
            frontmostProcessIdentifier: frontmostApplication?.processIdentifier,
            isDictationOverlayPresented: NotchContentState.shared.isBottomOverlayPresented,
            requestBundleIdentifier: request.bundleIdentifier
        )
    }

    private func isPointerInsidePanel(_ panel: NSPanel? = nil) -> Bool {
        let target = panel ?? self.panel
        guard let target else { return false }
        return target.frame.contains(NSEvent.mouseLocation)
    }

    private func clearAutoDismiss() {
        self.autoDismissTask?.cancel()
        self.autoDismissTask = nil
        self.autoDismissLegStartedAt = nil
        self.remainingAutoDismissSeconds = 0
        self.isAutoDismissPaused = false
    }

    private func scheduleAutoDismiss(for episodeID: UUID) {
        guard !self.isAutoDismissPaused else { return }
        guard self.remainingAutoDismissSeconds > 0 else {
            self.onTimeout?(episodeID)
            self.hide()
            return
        }
        let delayNanoseconds = UInt64(self.remainingAutoDismissSeconds * 1_000_000_000)
        self.autoDismissLegStartedAt = Date()
        self.autoDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, let self, self.request?.episodeID == episodeID else { return }
            self.onTimeout?(episodeID)
            self.hide()
        }
    }

    static func remainingAutoDismissSeconds(_ remaining: TimeInterval, after elapsed: TimeInterval) -> TimeInterval {
        max(0, remaining - max(0, elapsed))
    }

    static func reminderPresentationDecision(
        remainingBudget: TimeInterval,
        isSuppressed: Bool,
        retryInterval: TimeInterval = MeetingDetectionPromptController.suppressionRetryInterval
    ) -> ReminderPresentationDecision {
        if remainingBudget <= 0 { return .timeout }
        if !isSuppressed { return .present }
        return .retryAfter(min(retryInterval, remainingBudget))
    }

    static func episodeToTimeoutOnReplacement(existing: UUID?, incoming: UUID) -> UUID? {
        guard let existing, existing != incoming else { return nil }
        return existing
    }

    static func incomingPromptPolicy(
        isStarting: Bool,
        currentEpisodeID: UUID?,
        pendingEpisodeID: UUID?,
        incomingEpisodeID: UUID
    ) -> IncomingPromptPolicy {
        if incomingEpisodeID == currentEpisodeID || incomingEpisodeID == pendingEpisodeID {
            return .ignore
        }
        if isStarting {
            return .timeoutIncoming
        }
        return .replaceExisting
    }

    static func shouldSilentlyInvalidatePrompt(
        episodeID: UUID,
        visibleEpisodeID: UUID?,
        pendingEpisodeID: UUID?
    ) -> Bool {
        episodeID == visibleEpisodeID || episodeID == pendingEpisodeID
    }

    static func cheapSuppressionDecision(
        frontmostBundleIdentifier: String?,
        frontmostProcessIdentifier: pid_t?,
        isDictationOverlayPresented: Bool,
        requestBundleIdentifier: String
    ) -> CheapSuppressionDecision {
        if isDictationOverlayPresented { return .suppressed(.dictationOverlay) }
        if frontmostBundleIdentifier == requestBundleIdentifier { return .presentNow }
        guard let frontmostProcessIdentifier else { return .presentNow }
        return .queryFullscreen(frontmostProcessIdentifier)
    }

    static func startErrorMessage(from error: Error, appDisplayName: String) -> String {
        if case MeetingCaptureError.applicationUnavailable = error {
            return "\(appDisplayName) is no longer available to record."
        }
        return (error as? LocalizedError)?.errorDescription ?? "Can't start recording right now."
    }

    static func suppressionReason(
        frontmostBundleIdentifier: String?,
        isFrontmostFullScreen: Bool,
        isDictationOverlayPresented: Bool,
        requestBundleIdentifier: String
    ) -> SuppressionReason? {
        if isDictationOverlayPresented { return .dictationOverlay }
        if isFrontmostFullScreen, frontmostBundleIdentifier != requestBundleIdentifier {
            return .fullscreenOtherApp
        }
        return nil
    }

    nonisolated static func isProcessFullScreen(processIdentifier: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(processIdentifier)
        _ = AXUIElementSetMessagingTimeout(appElement, 0.3)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let window = windowValue
        else { return false }
        // swiftlint:disable:next force_cast
        let windowElement = window as! AXUIElement
        var fullScreenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement, "AXFullScreen" as CFString, &fullScreenValue) == .success else { return false }
        return (fullScreenValue as? Bool) ?? false
    }

    private func panelOrCreate() -> MeetingFloatingCaptionsPanel {
        if let panel { return panel }
        let content = AnyView(
            AdaptiveAppTheme(accent: SettingsStore.shared.accentColor) {
                MeetingDetectionPromptContent(controller: self)
            }
        )
        let panel = MeetingFloatingPanelFactory.make(size: Self.panelSize, resizable: false, content: content)
        panel.acceptsMouseMovedEvents = true
        self.placeAtDefaultPosition(panel)
        self.panel = panel
        return panel
    }

    private func placeAtDefaultPosition(_ panel: NSPanel) {
        let screen = OverlayScreenResolver.screenForCurrentPointer() ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        panel.setFrame(Self.defaultFrame(panelSize: Self.panelSize, visibleFrame: visible), display: false)
    }

    static func defaultFrame(panelSize: NSSize, visibleFrame: NSRect) -> NSRect {
        NSRect(
            x: visibleFrame.midX - panelSize.width / 2,
            y: visibleFrame.maxY - panelSize.height - Self.defaultTopInset,
            width: panelSize.width,
            height: panelSize.height
        )
    }
}

private struct MeetingDetectionPromptContent: View {
    @ObservedObject var controller: MeetingDetectionPromptController

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let icon = self.controller.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Image(systemName: "person.2.wave.2.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(self.theme.palette.accent)
                        .frame(width: 34, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(self.theme.palette.accent.opacity(0.12))
                        )
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Meeting detected")
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.theme.palette.primaryText)
                    Text("\(self.controller.appDisplayName) appears to be in a call")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                if let startErrorMessage = self.controller.startErrorMessage {
                    Label(startErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.warning)
                        .lineLimit(1)
                } else if self.controller.isStarting {
                    Label("Starting…", systemImage: "waveform")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                } else {
                    Label(
                        self.controller.request?.cta == .setup ? "Recording hasn’t started — setup required" : "Not recording yet",
                        systemImage: "mic.slash.fill"
                    )
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }

                Spacer(minLength: 8)

                Button("Not now") {
                    self.controller.dismissTapped()
                }
                .fluidButton(.compact, size: .small)
                .disabled(self.controller.isStarting)

                Button {
                    self.controller.startTapped()
                } label: {
                    Label(
                        self.controller.request?.cta == .setup ? "Open recording setup" : "Record & transcribe",
                        systemImage: self.controller.request?.cta == .setup ? "gearshape" : "waveform"
                    )
                }
                .fluidButton(.accent, size: .small)
                .disabled(self.controller.isStarting)
            }
        }
        .padding(14)
        .frame(
            width: MeetingDetectionPromptController.panelSize.width,
            height: MeetingDetectionPromptController.panelSize.height,
            alignment: .top
        )
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(self.theme.palette.separator.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 6)
        .onHover { hovering in
            if hovering {
                self.controller.pauseAutoDismiss()
            } else {
                self.controller.resumeAutoDismiss()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting detected in \(self.controller.appDisplayName). Nothing is recording yet. Record and transcribe, or dismiss.")
    }
}

/// "Still recording?" nudge — passive, pill-adjacent, shown once per recording session while our
/// own recording's originating meeting evidence has been gone for a while.
@MainActor
final class MeetingStillRecordingNudgeController: ObservableObject {
    static let shared = MeetingStillRecordingNudgeController()

    private static let panelSize = NSSize(width: 260, height: 64)
    private static let autoDismissSeconds: TimeInterval = 20

    @Published private(set) var isPresented = false
    var onStop: (() -> Void)?

    private var panel: MeetingFloatingCaptionsPanel?
    private var autoDismissTask: Task<Void, Never>?

    private init() {}

    func present() {
        guard !self.isPresented else { return }
        self.isPresented = true
        let panel = self.panelOrCreate()
        if let pillFrame = MeetingRecordingPillController.shared.currentOverlayFrame ?? self.pillFrameFallback() {
            var frame = pillFrame
            frame.origin.y += pillFrame.height + 8
            frame.size = Self.panelSize
            panel.setFrame(frame, display: false)
        }
        panel.orderFrontRegardless()
        self.autoDismissTask?.cancel()
        self.autoDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autoDismissSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        self.autoDismissTask?.cancel()
        self.isPresented = false
        self.panel?.orderOut(nil)
    }

    private func pillFrameFallback() -> NSRect? {
        let screen = OverlayScreenResolver.screenForCurrentPointer() ?? NSScreen.main
        guard let screen else { return nil }
        let visible = screen.visibleFrame
        return NSRect(x: visible.midX - 42, y: visible.minY + 64, width: 84, height: 32)
    }

    private func panelOrCreate() -> MeetingFloatingCaptionsPanel {
        if let panel { return panel }
        let content = AnyView(
            AdaptiveAppTheme(accent: SettingsStore.shared.accentColor) {
                MeetingStillRecordingNudgeContent(controller: self)
            }
        )
        let panel = MeetingFloatingPanelFactory.make(size: Self.panelSize, resizable: false, content: content)
        self.panel = panel
        return panel
    }
}

/// Backs the "Turn off automatic detection?" affordance after 3 explicit dismissals in 14 days.
/// Session-scoped: the settings sheet reads and clears it; it does not persist across launches.
@MainActor
final class MeetingAutoDetectDismissalAdvisor: ObservableObject {
    static let shared = MeetingAutoDetectDismissalAdvisor()

    @Published var shouldSuggest = false

    private init() {}
}

private struct MeetingStillRecordingNudgeContent: View {
    @ObservedObject var controller: MeetingStillRecordingNudgeController

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(self.theme.palette.warning)
            Text("Meeting ended?")
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.theme.palette.primaryText)
            Spacer()
            Button("Stop & Transcribe") {
                self.controller.onStop?()
                self.controller.hide()
            }
            .fluidButton(.compact, size: .small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 260, height: 64)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(self.theme.palette.separator.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting may have ended. Stop and transcribe?")
    }
}
