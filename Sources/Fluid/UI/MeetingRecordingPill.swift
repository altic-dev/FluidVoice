import AppKit
import Combine
import SwiftUI

/// Small always-on-top pill shown automatically while a meeting is recording: live mic level and a
/// stop button, visible even when FluidVoice is buried under the meeting app.
@MainActor
final class MeetingRecordingPillController: ObservableObject {
    static let shared = MeetingRecordingPillController()

    @Published private(set) var isExpanded = false

    private static let pillSize = NSSize(width: 84, height: 32)
    private static let subtitleSize = NSSize(width: 480, height: 132)
    private static let autosaveName = "MeetingRecordingPill"
    private static let defaultBottomInset: CGFloat = 64

    private var panel: MeetingFloatingCaptionsPanel?
    private var stateSubscription: AnyCancellable?
    private var screenParametersObserver: NSObjectProtocol?

    private init() {}

    func activate(coordinator: MeetingSessionCoordinator) {
        guard self.stateSubscription == nil else { return }
        self.stateSubscription = coordinator.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak coordinator] state in
                guard let self, let coordinator else { return }
                if MeetingFloatingCaptionsController.isVisible(for: state) {
                    self.show(coordinator: coordinator)
                } else {
                    self.setExpanded(false)
                    self.panel?.orderOut(nil)
                }
            }
    }

    private func show(coordinator: MeetingSessionCoordinator) {
        let panel = self.panelOrCreate(coordinator: coordinator)
        panel.orderFrontRegardless()
    }

    func toggleExpanded() {
        self.setExpanded(!self.isExpanded)
    }

    /// Collapses back to the smallest pill — also called when the full captions window opens.
    func collapse() {
        self.setExpanded(false)
    }

    /// Where the subtitle strip currently sits, if expanded — the captions window slides out from here.
    var expandedPanelFrame: NSRect? {
        guard self.isExpanded, let panel, panel.isVisible else { return nil }
        return panel.frame
    }

    private func setExpanded(_ expanded: Bool) {
        guard self.isExpanded != expanded, let panel else {
            self.isExpanded = expanded
            return
        }
        self.isExpanded = expanded
        let size = expanded ? Self.subtitleSize : Self.pillSize
        var frame = panel.frame
        let centerX = frame.midX
        frame.origin.x = centerX - size.width / 2
        frame.size = size

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard panel.isVisible, !reduceMotion else {
            panel.setFrame(frame, display: true)
            self.clampIntoVisibleFrame(panel)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.55
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel else { return }
                self.clampIntoVisibleFrame(panel)
            }
        }
    }

    private func panelOrCreate(coordinator: MeetingSessionCoordinator) -> MeetingFloatingCaptionsPanel {
        if let panel { return panel }

        let content = AnyView(
            AdaptiveAppTheme(accent: SettingsStore.shared.accentColor) {
                MeetingRecordingPillContent(coordinator: coordinator)
            }
        )
        let panel = MeetingFloatingPanelFactory.make(size: Self.pillSize, resizable: false, content: content)

        panel.setFrameAutosaveName(Self.autosaveName)
        if panel.setFrameUsingName(Self.autosaveName) {
            // Only the position is user-controlled; the size must track the current design.
            var frame = panel.frame
            frame.size = Self.pillSize
            panel.setFrame(frame, display: false)
        } else {
            self.placeAtDefaultPosition(panel)
        }
        self.clampIntoVisibleFrame(panel)

        self.panel = panel
        self.installScreenParametersObserverIfNeeded()
        return panel
    }

    private func placeAtDefaultPosition(_ panel: NSPanel) {
        let screen = OverlayScreenResolver.screenForCurrentPointer() ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - Self.pillSize.width / 2,
            y: visible.minY + Self.defaultBottomInset
        )
        panel.setFrame(NSRect(origin: origin, size: Self.pillSize), display: false)
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

struct MeetingRecordingPillContent: View {
    @ObservedObject var coordinator: MeetingSessionCoordinator

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isStopping = false

    private var microphoneLevel: Float {
        self.coordinator.trackHealth[.microphone]?.level ?? 0
    }

    private var isRecordingActive: Bool {
        MeetingFloatingCaptionsController.isVisible(for: self.coordinator.state)
    }

    @ObservedObject private var pill = MeetingRecordingPillController.shared
    @Namespace private var morph

    private var morphAnimation: Animation? {
        self.reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.88)
    }

    var body: some View {
        Group {
            if self.pill.isExpanded {
                self.subtitleStrip
            } else {
                self.compactPill
            }
        }
        // The panel and its view persist across meetings; re-arm the stop button per recording.
        .onChange(of: self.isRecordingActive) { _, active in
            if active { self.isStopping = false }
        }
        .animation(self.morphAnimation, value: self.pill.isExpanded)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting recording in progress")
    }

    private var morphSurface: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(self.theme.palette.contentBackground.opacity(0.96))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(self.theme.palette.accent.opacity(0.7), lineWidth: 1.2)
            )
            .shadow(color: .black.opacity(0.3), radius: 11, x: 0, y: 4)
            .matchedGeometryEffect(id: "surface", in: self.morph)
    }

    private var compactPill: some View {
        HStack(spacing: 7) {
            MeetingRecordingLevelBars(level: self.microphoneLevel, animated: !self.reduceMotion)
                .frame(width: 20, height: 11)
                .matchedGeometryEffect(id: "wave", in: self.morph)

            self.stopButton
                .matchedGeometryEffect(id: "stop", in: self.morph)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .contentShape(Capsule())
        // The whole capsule expands; only the stop button opts out (inner Button wins its hits).
        .onTapGesture { self.pill.toggleExpanded() }
        .background(self.morphSurface)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Show live captions")
    }

    @State private var isHoveringStrip = false

    private var subtitleStrip: some View {
        let rows = MeetingLiveBubbleComposer.rows(for: self.coordinator.liveTranscript)
        return Group {
            if rows.isEmpty {
                Text("Listening…")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                Text(self.rollingSubtitle(rows: rows))
                    .font(.system(size: 14, design: .monospaced))
                    .lineSpacing(4)
                    .foregroundStyle(self.theme.palette.primaryText)
                    // fixedSize is load-bearing — a height-constrained Text truncates its END,
                    // freezing the display on the oldest words instead of clipping the top.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .clipped()
            }
        }
        .transition(.opacity)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(self.morphSurface)
        // Pure text island; controls surface only on hover so it reads as subtitles, not a widget.
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
                            .foregroundStyle(self.theme.palette.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open captions window")
                    Button {
                        self.pill.collapse()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(self.theme.palette.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Collapse captions")
                    self.stopButton
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(self.theme.palette.contentBackground.opacity(0.92)))
                .padding(6)
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { self.isHoveringStrip = hovering }
        }
    }

    /// One rolling word stream across all turns — no bubbles, no speaker structure, just the last
    /// words spoken. Oldest words fall off the front; "—" marks a speaker change, subtitle-style.
    private func rollingSubtitle(rows: [MeetingLiveBubbleComposer.Row], maxWords: Int = 42) -> String {
        var words: [String] = []
        var previousSpeaker: MeetingLiveSpeaker?
        for row in rows.suffix(8) {
            if previousSpeaker != nil, row.speaker != previousSpeaker {
                words.append("—")
            }
            previousSpeaker = row.speaker
            words.append(contentsOf: row.text.split(separator: " ").map(String.init))
        }
        return words.suffix(maxWords).joined(separator: " ")
    }

    private var stopButton: some View {
        Button {
            guard !self.isStopping else { return }
            self.isStopping = true
            let coordinator = self.coordinator
            Task {
                _ = try? await coordinator.stopAndTranscribe()
            }
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(self.theme.palette.primaryText)
                .frame(width: 18, height: 18)
                .background(self.theme.palette.contentBackground, in: Circle())
                .overlay(Circle().stroke(self.theme.palette.separator.opacity(0.5), lineWidth: 1))
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
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(Self.weights.enumerated()), id: \.offset) { _, weight in
                Capsule()
                    .fill(self.theme.palette.accent)
                    .frame(width: 2, height: max(2.5, CGFloat(self.level) * 11 * weight))
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .animation(self.animated ? .easeOut(duration: 0.12) : nil, value: self.level)
        .accessibilityHidden(true)
    }
}
