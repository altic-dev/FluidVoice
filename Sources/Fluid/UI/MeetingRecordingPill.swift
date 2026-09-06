import AppKit
import Combine
import SwiftUI

/// Small always-on-top overlay shown automatically while a meeting is recording: live mic level and a
/// stop button, visible even when FluidVoice is buried under the meeting app.
@MainActor
final class MeetingRecordingPillController: ObservableObject {
    static let shared = MeetingRecordingPillController()

    @Published private(set) var presentation: MeetingOverlayPresentation = .pill

    fileprivate static let overlayPadding = MeetingOverlayPadding.uniform(24)
    private static let legacyAutosaveName = "MeetingRecordingPill"
    private static let anchorCenterXKey = "MeetingRecordingOverlay.visibleAnchor.centerX"
    private static let anchorBottomYKey = "MeetingRecordingOverlay.visibleAnchor.bottomY"
    private static let defaultBottomInset: CGFloat = 64
    private static let morphDuration: TimeInterval = 0.55

    private var panel: MeetingFloatingCaptionsPanel?
    private var reducer = MeetingOverlayPresentationReducer()
    private var visibleAnchor: MeetingOverlayVisibleAnchor?
    private var stateSubscription: AnyCancellable?
    private var screenParametersObserver: NSObjectProtocol?
    private var windowMoveObserver: NSObjectProtocol?
    private var transitionGeneration = 0
    private var inFlightTransitionGeneration: Int?
    private var isApplyingProgrammaticFrame = false

    private init() {}

    func activate(coordinator: MeetingSessionCoordinator) {
        guard self.stateSubscription == nil else { return }
        self.stateSubscription = coordinator.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak coordinator] state in
                guard let self, let coordinator else { return }
                self.handleCoordinatorState(state, coordinator: coordinator)
            }
    }

    func toggleExpanded() {
        self.reducer.apply(.toggleRequested)
        guard let presentation = self.reducer.presentation else { return }
        self.setPresentation(presentation)
    }

    /// Collapses back to the smallest pill — also called when the full captions window opens.
    func collapse() {
        guard self.reducer.presentation == .captions else { return }
        self.reducer.apply(.toggleRequested)
        self.setPresentation(self.reducer.presentation ?? .pill)
    }

    /// Visible surface of the current overlay, excluding transparent shadow padding.
    var currentOverlayFrame: NSRect? {
        guard let panel, panel.isVisible else { return nil }
        return Self.visibleSurfaceFrame(from: panel.frame)
    }

    /// Source frame for the full captions window: a completed Captions surface only.
    func resolveCaptionsSourceFrame() -> NSRect? {
        guard self.presentation == .captions, self.panel?.isVisible == true else { return nil }
        if self.inFlightTransitionGeneration != nil {
            self.applyFrame(for: .captions, animated: false)
        }
        return self.currentOverlayFrame
    }

    private func handleCoordinatorState(_ state: MeetingCoordinatorState, coordinator: MeetingSessionCoordinator) {
        switch state {
        case .recording(let sessionID), .recordingDegraded(let sessionID):
            if self.reducer.sessionID != sessionID {
                self.invalidateTransition()
                self.reducer.apply(.preferenceChanged(SettingsStore.shared.meetingOverlayPreference))
                self.reducer.apply(.recordingStarted(sessionID: sessionID))
                self.presentation = self.reducer.presentation ?? .pill
                self.show(coordinator: coordinator, resetFrameToPresentation: true)
            } else {
                self.show(coordinator: coordinator, resetFrameToPresentation: false)
            }
        case .idle, .preparing, .stopping, .processing, .completed, .interrupted, .failed:
            self.hideOverlay()
        }
    }

    private func show(coordinator: MeetingSessionCoordinator, resetFrameToPresentation: Bool) {
        let panel = self.panelOrCreate(coordinator: coordinator)
        if resetFrameToPresentation {
            self.applyFrame(for: self.presentation, animated: false)
        }
        panel.orderFrontRegardless()
    }

    private func hideOverlay() {
        self.invalidateTransition()
        self.reducer.apply(.recordingStopped)
        self.presentation = .pill
        self.panel?.orderOut(nil)
    }

    private func setPresentation(_ presentation: MeetingOverlayPresentation) {
        guard self.presentation != presentation, self.panel != nil else {
            self.presentation = presentation
            return
        }
        self.presentation = presentation
        self.applyFrame(for: presentation, animated: true)
    }

    private func applyFrame(for presentation: MeetingOverlayPresentation, animated: Bool) {
        guard let panel else { return }
        let anchor = self.resolvedAnchor(for: panel)
        let screenVisible = self.screenVisibleFrame(for: anchor, panel: panel)
        guard screenVisible.width > 0, screenVisible.height > 0 else { return }
        let layout = MeetingOverlayGeometry.layout(
            anchor: anchor,
            visibleSize: presentation.visibleSize,
            padding: Self.overlayPadding,
            screenVisible: screenVisible
        )
        self.visibleAnchor = MeetingOverlayVisibleAnchor(
            centerX: layout.visibleSurfaceFrame.midX,
            bottomY: layout.visibleSurfaceFrame.minY
        )

        self.transitionGeneration += 1
        let generation = self.transitionGeneration
        self.inFlightTransitionGeneration = nil

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let canAnimate = animated
            && panel.isVisible
            && !reduceMotion
            && !panel.frame.equalTo(layout.panelFrame)

        self.isApplyingProgrammaticFrame = true
        if !canAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().setFrame(layout.panelFrame, display: true)
            }
            self.isApplyingProgrammaticFrame = false
            self.persistAnchor()
            return
        }

        self.inFlightTransitionGeneration = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.morphDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            panel.animator().setFrame(layout.panelFrame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.transitionGeneration else { return }
                self.isApplyingProgrammaticFrame = false
                self.inFlightTransitionGeneration = nil
                if let panel = self.panel {
                    self.captureAnchor(from: panel)
                    self.persistAnchor()
                }
            }
        }
    }

    private func invalidateTransition() {
        self.transitionGeneration += 1
        self.inFlightTransitionGeneration = nil
        self.isApplyingProgrammaticFrame = false
    }

    private func panelOrCreate(coordinator: MeetingSessionCoordinator) -> MeetingFloatingCaptionsPanel {
        if let panel { return panel }

        let presentation = self.presentation
        if self.visibleAnchor == nil {
            self.visibleAnchor = self.loadPersistedAnchor() ?? self.defaultAnchor()
        }
        let anchor = self.resolvedAnchor(for: nil)
        let screenVisible = self.screenVisibleFrame(for: anchor, panel: nil)
        let layout = MeetingOverlayGeometry.layout(
            anchor: anchor,
            visibleSize: presentation.visibleSize,
            padding: Self.overlayPadding,
            screenVisible: screenVisible.width > 0 ? screenVisible : CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        let content = AnyView(
            AdaptiveAppTheme(accent: SettingsStore.shared.accentColor) {
                MeetingRecordingPillContent(coordinator: coordinator)
            }
        )
        let panel = MeetingFloatingPanelFactory.make(
            size: layout.panelFrame.size,
            resizable: false,
            content: content,
            overlayHitPadding: Self.overlayPadding
        )

        if self.loadPersistedAnchor() == nil, panel.setFrameUsingName(Self.legacyAutosaveName) {
            let restored = panel.frame
            self.visibleAnchor = MeetingOverlayVisibleAnchor(centerX: restored.midX, bottomY: restored.minY)
            self.persistAnchor()
        }

        self.panel = panel
        self.applyFrame(for: presentation, animated: false)
        self.installWindowMoveObserverIfNeeded(for: panel)
        self.installScreenParametersObserverIfNeeded()
        return panel
    }

    private func defaultAnchor() -> MeetingOverlayVisibleAnchor {
        let screen = OverlayScreenResolver.screenForCurrentPointer() ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return MeetingOverlayVisibleAnchor(
            centerX: visible.midX,
            bottomY: visible.minY + Self.defaultBottomInset
        )
    }

    private func resolvedAnchor(for panel: NSPanel?) -> MeetingOverlayVisibleAnchor {
        if let visibleAnchor { return visibleAnchor }
        if let panel {
            return self.anchor(from: Self.visibleSurfaceFrame(from: panel.frame))
        }
        return self.defaultAnchor()
    }

    private func screenVisibleFrame(for anchor: MeetingOverlayVisibleAnchor, panel: NSPanel?) -> CGRect {
        if let panel, let screen = panel.screen {
            return screen.visibleFrame
        }
        let point = NSPoint(x: anchor.centerX, y: anchor.bottomY)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) || $0.visibleFrame.contains(point) }) {
            return screen.visibleFrame
        }
        return (OverlayScreenResolver.screenForCurrentPointer() ?? NSScreen.main)?.visibleFrame ?? .zero
    }

    private static func visibleSurfaceFrame(from panelFrame: CGRect) -> CGRect {
        let padding = Self.overlayPadding
        return CGRect(
            x: panelFrame.minX + padding.left,
            y: panelFrame.minY + padding.bottom,
            width: max(0, panelFrame.width - padding.left - padding.right),
            height: max(0, panelFrame.height - padding.top - padding.bottom)
        )
    }

    private func anchor(from visible: CGRect) -> MeetingOverlayVisibleAnchor {
        MeetingOverlayVisibleAnchor(centerX: visible.midX, bottomY: visible.minY)
    }

    private func captureAnchor(from panel: NSPanel) {
        self.visibleAnchor = self.anchor(from: Self.visibleSurfaceFrame(from: panel.frame))
    }

    private func loadPersistedAnchor() -> MeetingOverlayVisibleAnchor? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.anchorCenterXKey) != nil,
              defaults.object(forKey: Self.anchorBottomYKey) != nil
        else { return nil }
        return MeetingOverlayVisibleAnchor(
            centerX: CGFloat(defaults.double(forKey: Self.anchorCenterXKey)),
            bottomY: CGFloat(defaults.double(forKey: Self.anchorBottomYKey))
        )
    }

    private func persistAnchor() {
        guard let visibleAnchor else { return }
        let defaults = UserDefaults.standard
        defaults.set(Double(visibleAnchor.centerX), forKey: Self.anchorCenterXKey)
        defaults.set(Double(visibleAnchor.bottomY), forKey: Self.anchorBottomYKey)
    }

    private func installWindowMoveObserverIfNeeded(for panel: NSPanel) {
        guard self.windowMoveObserver == nil else { return }
        self.windowMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isApplyingProgrammaticFrame, let panel = self.panel else { return }
                self.captureAnchor(from: panel)
                self.persistAnchor()
            }
        }
    }

    private func installScreenParametersObserverIfNeeded() {
        guard self.screenParametersObserver == nil else { return }
        self.screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.repositionForDisplayChange()
            }
        }
    }

    private func repositionForDisplayChange() {
        guard let panel, panel.isVisible else { return }
        self.applyFrame(for: self.presentation, animated: false)
    }
}

struct MeetingRecordingPillContent: View {
    @ObservedObject var coordinator: MeetingSessionCoordinator

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isStopping = false
    @State private var meetingAppIcon: NSImage? = NSApplication.shared.applicationIconImage

    private var microphoneLevel: Float {
        self.coordinator.trackHealth[.microphone]?.level ?? 0
    }

    private var isRecordingActive: Bool {
        MeetingFloatingCaptionsController.isVisible(for: self.coordinator.state)
    }

    @ObservedObject private var pill = MeetingRecordingPillController.shared

    var body: some View {
        Group {
            switch self.pill.presentation {
            case .captions:
                self.subtitleStrip
            case .pill:
                self.compactPill
            }
        }
        // The panel and its view persist across meetings; re-arm the stop button per recording.
        .onChange(of: self.isRecordingActive) { _, active in
            if active { self.isStopping = false }
        }
        .onChange(of: self.coordinator.activeSession?.capturedApplication) { _, application in
            self.meetingAppIcon = Self.resolveMeetingAppIcon(for: application)
        }
        .onAppear {
            self.meetingAppIcon = Self.resolveMeetingAppIcon(
                for: self.coordinator.activeSession?.capturedApplication
            )
        }
        .animation(nil, value: self.pill.presentation)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.top, MeetingRecordingPillController.overlayPadding.top)
        .padding(.leading, MeetingRecordingPillController.overlayPadding.left)
        .padding(.bottom, MeetingRecordingPillController.overlayPadding.bottom)
        .padding(.trailing, MeetingRecordingPillController.overlayPadding.right)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting recording in progress")
        .accessibilityAction(named: "Stop Meeting Recording") {
            self.stopRecording()
        }
    }

    private var compactSurface: some View {
        FluidOverlaySurface(
            cornerRadius: 16,
            border: .staticAngular(angle: .degrees(0), lineWidth: 1.2),
            shadow: .init(opacity: 0.32, radius: 10, y: 4)
        )
    }

    private var captionsSurface: some View {
        FluidOverlaySurface(
            cornerRadius: 16,
            border: .linear(topOpacity: 0.15, bottomOpacity: 0.08, lineWidth: 1),
            shadow: .init(opacity: 0.35, radius: 16, y: 6)
        )
    }

    private var compactPill: some View {
        HStack(spacing: 7) {
            MeetingRecordingLevelBars(level: self.microphoneLevel, animated: !self.reduceMotion)
                .frame(width: 20, height: 11)

            self.stopButton
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(
            width: MeetingOverlayPresentation.pill.visibleSize.width,
            height: MeetingOverlayPresentation.pill.visibleSize.height
        )
        .contentShape(Capsule())
        // The whole capsule expands; only the stop button opts out (inner Button wins its hits).
        .onTapGesture { self.pill.toggleExpanded() }
        .background(self.compactSurface)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Show live captions")
        .accessibilityAction(named: "Show Captions") {
            self.pill.toggleExpanded()
        }
    }

    @State private var isHoveringStrip = false

    private var subtitleStrip: some View {
        let rows = MeetingLiveBubbleComposer.rows(for: self.coordinator.liveTranscript)
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: MeetingOverlayPresentation.captionsControlsHeight)

                Color.clear
                    .frame(height: MeetingOverlayPresentation.captionsTopInset)

                Group {
                    if rows.isEmpty {
                        Text(self.emptyCaptionStatusText)
                            .font(.system(size: 13, design: .monospaced))
                            // The overlay surface is intentionally always dark, independent of the
                            // app theme. System label colors can resolve dark in light mode and made
                            // this text indistinguishable from the black surface.
                            .foregroundStyle(Color.white.opacity(0.62))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            .accessibilityHidden(true)
                    } else {
                        MeetingRollingCaptionView(
                            text: self.rollingSubtitle(rows: rows),
                            foregroundColor: NSColor.white.withAlphaComponent(0.94)
                        )
                        .frame(
                            width: MeetingOverlayPresentation.captionsContentWidth,
                            height: MeetingOverlayPresentation.captionsContentHeight,
                            alignment: .bottomLeading
                        )
                        .accessibilityHidden(true)
                    }
                }
                .frame(
                    width: MeetingOverlayPresentation.captionsContentWidth,
                    height: MeetingOverlayPresentation.captionsContentHeight
                )
                // Clip strictly to the content rectangle; the TextKit view itself also draws only
                // the selected suffix inside this frame.
                .clipped()

                Color.clear
                    .frame(height: MeetingOverlayPresentation.captionsBottomInset)
            }
            .frame(
                width: MeetingOverlayPresentation.captions.visibleSize.width,
                height: MeetingOverlayPresentation.captionsViewportHeight
            )
            .clipped()

            self.meetingStatusFooter
                .frame(
                    width: MeetingOverlayPresentation.captions.visibleSize.width,
                    height: MeetingOverlayPresentation.captionsFooterHeight
                )
        }
        .frame(
            width: MeetingOverlayPresentation.captions.visibleSize.width,
            height: MeetingOverlayPresentation.captions.visibleSize.height
        )
        .background(self.captionsSurface)
        // Hover controls stay inside their permanently reserved top strip, never over text.
        .overlay(alignment: .topTrailing) {
            if self.isHoveringStrip {
                HStack(spacing: 8) {
                    MeetingRecordingLevelBars(level: self.microphoneLevel, animated: !self.reduceMotion)
                        .frame(width: 18, height: 10)
                    Button {
                        MeetingFloatingCaptionsController.shared.show()
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.68))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open captions window")
                    Button {
                        self.pill.collapse()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.68))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Collapse captions")
                    self.stopButton
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.82)))
                .padding(6)
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { self.isHoveringStrip = hovering }
        }
        .accessibilityAction(named: "Hide Captions") {
            self.pill.collapse()
        }
        .accessibilityAction(named: "Open Captions Window") {
            MeetingFloatingCaptionsController.shared.show()
        }
    }

    private var emptyCaptionStatusText: String {
        switch self.coordinator.liveTranscript.availability {
        case .available:
            return "Listening…"
        case .unavailable(let reason), .degraded(let reason):
            return reason
        }
    }

    /// Mirrors the dictation overlay's persistent status row without coupling meeting state to the
    /// dictation overlay. The ZStack keeps the waveform geometrically centered even when the app
    /// icon and label have different widths.
    private var meetingStatusFooter: some View {
        ZStack {
            MeetingCaptionWaveform(level: self.microphoneLevel, animated: !self.reduceMotion)
                .frame(width: 90, height: 20)

            HStack {
                if let meetingAppIcon = self.meetingAppIcon {
                    Image(nsImage: meetingAppIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Circle()
                        .fill(self.theme.palette.accent.opacity(0.9))
                        .frame(width: 9, height: 9)
                        .frame(width: 18, height: 18)
                }

                Spacer()

                Text("Meeting")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(self.theme.palette.accent)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(height: 28)
        .padding(.horizontal, 14)
        .padding(.bottom, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Meeting microphone activity")
    }

    private static func resolveMeetingAppIcon(for application: MeetingApplicationIdentity?) -> NSImage? {
        if let processID = application?.processID,
           let icon = NSRunningApplication(processIdentifier: processID)?.icon
        {
            return icon
        }
        if let bundleIdentifier = application?.bundleIdentifier,
           let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        {
            return NSWorkspace.shared.icon(forFile: applicationURL.path)
        }
        return NSApplication.shared.applicationIconImage
    }

    /// One rolling stream across the most recent rows. TextKit selects complete wrapped lines;
    /// this input bound prevents an ever-growing live transcript from retaining excess storage.
    private func rollingSubtitle(rows: [MeetingLiveBubbleComposer.Row]) -> String {
        var words: [String] = []
        var previousSpeaker: MeetingLiveSpeaker?
        for row in rows.suffix(8) {
            if previousSpeaker != nil, row.speaker != previousSpeaker {
                words.append("—")
            }
            previousSpeaker = row.speaker
            words.append(row.text)
        }
        return String(words.joined(separator: " ").suffix(MeetingRollingCaptionLayout.maximumInputCharacters))
    }

    private func stopRecording() {
        guard !self.isStopping, self.isRecordingActive else { return }
        self.isStopping = true
        let coordinator = self.coordinator
        Task {
            _ = try? await coordinator.stopAndTranscribe()
        }
    }

    private var stopButton: some View {
        Button {
            self.stopRecording()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.92))
                .frame(width: 18, height: 18)
                .background(Color.white.opacity(0.12), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(self.isStopping || !self.isRecordingActive)
        .accessibilityLabel("Stop meeting recording and transcribe")
    }
}

/// Five bars scaled by the published mic level; center-weighted so it reads as a waveform.
private struct MeetingRecordingLevelBars: View {
    let level: Float
    let animated: Bool

    @Environment(\.theme) private var theme

    private static let weights: [CGFloat] = [0.45, 0.75, 1.0, 0.75, 0.45]

    var body: some View {
        FluidOverlayLevelBars(
            heights: Self.weights.map { max(2.5, CGFloat(self.level) * 11 * $0) },
            width: 2,
            spacing: 2.5,
            cornerRadius: 1,
            color: self.theme.palette.accent,
            glowColor: self.theme.palette.accent,
            glowRadius: 0
        )
        .frame(maxHeight: .infinity, alignment: .center)
        .animation(self.animated ? .easeOut(duration: 0.12) : nil, value: self.level)
        .accessibilityHidden(true)
    }
}

/// Wider center-weighted meter for the captions footer, matching the visual rhythm of the
/// dictation overlay while remaining driven by the meeting microphone track.
private struct MeetingCaptionWaveform: View {
    let level: Float
    let animated: Bool

    @Environment(\.theme) private var theme

    private static let weights: [CGFloat] = [0.30, 0.46, 0.66, 0.86, 1.0, 0.86, 0.66, 0.46, 0.30]

    var body: some View {
        FluidOverlayLevelBars(
            heights: Self.weights.map { max(4, CGFloat(self.level) * 19 * $0) },
            width: 3,
            spacing: 4,
            cornerRadius: 1.5,
            color: self.theme.palette.accent,
            glowColor: self.theme.palette.accent.opacity(0.42),
            glowRadius: 2
        )
        .frame(maxHeight: .infinity, alignment: .center)
        .animation(self.animated ? .easeOut(duration: 0.12) : nil, value: self.level)
        .accessibilityHidden(true)
    }
}
