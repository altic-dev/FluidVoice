import AppKit
import Combine
import SwiftUI

/// Small always-on-top overlay shown automatically while a meeting is recording: live mic level and a
/// stop button, visible even when FluidVoice is buried under the meeting app.
@MainActor
final class MeetingRecordingPillController: ObservableObject {
    static let shared = MeetingRecordingPillController()

    @Published private(set) var presentation: MeetingOverlayPresentation = .pill

    // Shared only by cooperating types in this file.

    // swiftlint:disable:next strict_fileprivate
    fileprivate static let overlayPadding = MeetingOverlayPadding.uniform(24)
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

    /// Collapses back to the smallest pill.
    func collapse() {
        guard self.reducer.presentation == .captions else { return }
        self.reducer.apply(.toggleRequested)
        self.setPresentation(self.reducer.presentation ?? .pill)
    }

    /// Grows the pill into the captions box; a no-op when already expanded or not recording.
    func expand() {
        guard self.reducer.presentation == .pill else { return }
        self.reducer.apply(.toggleRequested)
        self.setPresentation(self.reducer.presentation ?? .captions)
    }

    /// Visible surface of the current overlay, excluding transparent shadow padding.
    var currentOverlayFrame: NSRect? {
        guard let panel, panel.isVisible else { return nil }
        return Self.visibleSurfaceFrame(from: panel.frame)
    }

    private func handleCoordinatorState(_ state: MeetingCoordinatorState, coordinator: MeetingSessionCoordinator) {
        switch state {
        case let .recording(sessionID), let .recordingDegraded(sessionID):
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

    /// `.pill` is the small capsule; `.captions` is the separate scrollable, resizable window.
    /// Exactly one of them is on screen while recording.
    private func show(coordinator: MeetingSessionCoordinator, resetFrameToPresentation: Bool) {
        // Resolve the first frame before showing the cached panel. A drag belongs to this
        // meeting only; an old panel frame or saved position must not pick the next screen.
        if resetFrameToPresentation {
            self.visibleAnchor = self.defaultAnchor()
        }
        let panel = self.panelOrCreate(coordinator: coordinator)
        if resetFrameToPresentation {
            self.applyFrame(for: .pill, animated: false)
        }
        switch self.presentation {
        case .pill:
            MeetingFloatingCaptionsController.shared.hide()
            panel.orderFrontRegardless()
        case .captions:
            panel.orderOut(nil)
            MeetingFloatingCaptionsController.shared.show(from: nil)
        }
    }

    private func hideOverlay() {
        self.invalidateTransition()
        self.reducer.apply(.recordingStopped)
        self.presentation = .pill
        self.panel?.orderOut(nil)
        MeetingFloatingCaptionsController.shared.hide()
    }

    private func setPresentation(_ presentation: MeetingOverlayPresentation) {
        guard self.presentation != presentation, let panel else {
            self.presentation = presentation
            return
        }
        self.presentation = presentation
        switch presentation {
        case .captions:
            let source = self.currentOverlayFrame
            panel.orderOut(nil)
            MeetingFloatingCaptionsController.shared.show(from: source)
        case .pill:
            MeetingFloatingCaptionsController.shared.hide()
            self.applyFrame(for: .pill, animated: false)
            panel.orderFrontRegardless()
        }
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
            self.visibleAnchor = self.defaultAnchor()
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

        self.panel = panel
        self.applyFrame(for: presentation, animated: false)
        self.installWindowMoveObserverIfNeeded(for: panel)
        self.installScreenParametersObserverIfNeeded()
        return panel
    }

    private func defaultAnchor() -> MeetingOverlayVisibleAnchor {
        let screen = OverlayScreenResolver.screenForCurrentPointer() ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return MeetingOverlayGeometry.initialPillAnchor(
            screenFrame: screen?.frame ?? visible,
            screenVisible: visible,
            bottomOffset: CGFloat(SettingsStore.shared.overlayBottomOffset)
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
        let point = NSPoint(x: anchor.centerX, y: anchor.bottomY)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) || $0.visibleFrame.contains(point) }) {
            return screen.visibleFrame
        }
        return (OverlayScreenResolver.screenForCurrentPointer() ?? panel?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
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

    private var microphoneLevel: Float {
        self.coordinator.trackHealth[.microphone]?.level ?? 0
    }

    private var isRecordingActive: Bool {
        MeetingOverlayVisibility.isVisible(for: self.coordinator.state)
    }

    @ObservedObject private var pill = MeetingRecordingPillController.shared

    var body: some View {
        self.compactPill
            // The panel and its view persist across meetings; re-arm the stop button per recording.
            .onChange(of: self.isRecordingActive) { _, active in
                if active { self.isStopping = false }
            }
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
        // The whole capsule opens the captions window; only the stop button opts out.
        .onTapGesture { self.pill.expand() }
        .background(self.compactSurface)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Show live captions")
        .accessibilityAction(named: "Show Captions") {
            self.pill.expand()
        }
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
                .font(.fluidSystem(size: 8, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 20, height: 20)
                .background(Color(red: 0.93, green: 0.23, blue: 0.23), in: Circle())
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
