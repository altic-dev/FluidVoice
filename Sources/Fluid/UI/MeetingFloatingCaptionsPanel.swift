import AppKit
import Combine
import SwiftUI

/// Borderless, non-activating panel that mirrors the live captions card while FluidVoice is buried
/// under a meeting app. `canBecomeKey` stays false and `title` stays unset so MenuBarManager's
/// main-window heuristics (level == .normal, styleMask.contains(.titled), canBecomeKey) never treat
/// it as the app's main window — see MenuBarManager.isFluidMainWindow.
final class MeetingFloatingCaptionsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

/// Swallows first-mouse so clicks and drags work while FluidVoice is inactive — this panel's
/// normal state, since it exists precisely so captions stay visible while another app has focus.
final class MeetingFloatingHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

enum MeetingFloatingPanelFactory {
    @MainActor
    static func make(size: NSSize, resizable: Bool, content: AnyView) -> MeetingFloatingCaptionsPanel {
        var styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        if resizable { styleMask.insert(.resizable) }
        let panel = MeetingFloatingCaptionsPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Default true would hide the panel the instant the user clicks into Zoom — these panels
        // exist precisely to stay visible while FluidVoice is not the active app.
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        // Must never appear in the user's own screen share.
        panel.sharingType = .none

        let hostingView = MeetingFloatingHostingView(rootView: content)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        panel.contentView = hostingView
        return panel
    }
}

@MainActor
final class MeetingFloatingCaptionsController: ObservableObject {
    static let shared = MeetingFloatingCaptionsController()

    private static let panelSize = NSSize(width: 400, height: 480)
    private static let minimumSize = NSSize(width: 320, height: 240)
    private static let autosaveName = "MeetingFloatingCaptions"
    private static let defaultEdgeInset: CGFloat = 24

    private var panel: MeetingFloatingCaptionsPanel?
    private var stateSubscription: AnyCancellable?
    private var screenParametersObserver: NSObjectProtocol?

    private init() {}

    static func isVisible(for state: MeetingCoordinatorState) -> Bool {
        switch state {
        case .recording, .recordingDegraded:
            return true
        case .idle, .preparing, .stopping, .processing, .completed, .interrupted, .failed:
            return false
        }
    }

    func show() {
        let coordinator = AppServices.shared.meetingSessionCoordinator
        let panel = self.panelOrCreate(coordinator: coordinator)
        self.subscribeIfNeeded(coordinator: coordinator)

        let sourceFrame = MeetingRecordingPillController.shared.expandedPanelFrame
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let sourceFrame, !panel.isVisible, !reduceMotion {
            let targetFrame = panel.frame
            panel.setFrame(sourceFrame, display: false)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.55
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                panel.animator().setFrame(targetFrame, display: true)
            }
        } else {
            panel.orderFrontRegardless()
        }
        MeetingRecordingPillController.shared.collapse()
    }

    func hide() {
        self.panel?.orderOut(nil)
    }

    private func panelOrCreate(coordinator: MeetingSessionCoordinator) -> MeetingFloatingCaptionsPanel {
        if let panel { return panel }

        let content = AnyView(
            AdaptiveAppTheme(accent: SettingsStore.shared.accentColor) {
                MeetingFloatingCaptionsContent(coordinator: coordinator)
            }
        )
        let panel = MeetingFloatingPanelFactory.make(size: Self.panelSize, resizable: true, content: content)
        panel.minSize = Self.minimumSize

        panel.setFrameAutosaveName(Self.autosaveName)
        // setFrameAutosaveName alone does not restore a saved frame; it only enables saving on move.
        if !panel.setFrameUsingName(Self.autosaveName) {
            self.placeAtDefaultPosition(panel)
        }
        self.clampIntoVisibleFrame(panel)

        self.panel = panel
        self.installScreenParametersObserverIfNeeded()
        return panel
    }

    private func subscribeIfNeeded(coordinator: MeetingSessionCoordinator) {
        guard self.stateSubscription == nil else { return }
        self.stateSubscription = coordinator.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard Self.isVisible(for: state) else {
                    self?.hide()
                    return
                }
            }
    }

    private func placeAtDefaultPosition(_ panel: NSPanel) {
        let screen = OverlayScreenResolver.screenForCurrentPointer() ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.maxX - Self.panelSize.width - Self.defaultEdgeInset,
            y: visible.midY - Self.panelSize.height / 2
        )
        panel.setFrame(NSRect(origin: origin, size: Self.panelSize), display: false)
    }

    private func clampIntoVisibleFrame(_ panel: NSPanel) {
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame
        guard let visible else { return }
        var frame = panel.frame
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        panel.setFrame(frame, display: false)
    }

    private func installScreenParametersObserverIfNeeded() {
        guard self.screenParametersObserver == nil else { return }
        self.screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.repositionIfOffscreen()
            }
        }
    }

    private func repositionIfOffscreen() {
        guard let panel else { return }
        let stillOnScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) }
        guard !stillOnScreen else { return }
        self.placeAtDefaultPosition(panel)
        self.clampIntoVisibleFrame(panel)
    }
}

struct MeetingFloatingCaptionsContent: View {
    @ObservedObject var coordinator: MeetingSessionCoordinator

    @Environment(\.theme) private var theme

    private var rows: [MeetingLiveBubbleComposer.Row] {
        MeetingLiveBubbleComposer.rows(for: self.coordinator.liveTranscript)
    }

    var body: some View {
        let rows = self.rows

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Live captions")
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.theme.palette.secondaryText)
                Spacer()
                Button {
                    MeetingFloatingCaptionsController.shared.hide()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close floating captions")
            }

            if rows.isEmpty {
                Text("Listening…")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                MeetingLiveBubbleScrollList(rows: rows, hidesPartialFromAccessibility: false)
            }
        }
        .padding(14)
        .frame(minWidth: 320, maxWidth: .infinity, minHeight: 240, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(self.theme.palette.separator.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 6)
    }
}
