import AppKit
import Combine
import SwiftUI

@MainActor
final class MiniNotchIndicatorController: ObservableObject {
    static let shared = MiniNotchIndicatorController()
    @Published private(set) var isRecording = false
    @Published private(set) var level: CGFloat = 0
    @Published private(set) var isHovered = false
    @Published private(set) var isFocused = false
    private var hoverExitTask: Task<Void, Never>?
    private var panel: NSPanel?
    private var keyboardFocused = false
    private var accessibilityFocused = false
    private var resignKeySubscription: AnyCancellable?
    private var audioSubscription: AnyCancellable?
    private var preferencesSubscription: AnyCancellable?
    private var screenSubscription: AnyCancellable?
    private var targetScreen: NSScreen?
    @Published private(set) var isExpanded = false
    var expand: (() -> Void)?
    private let panelSize = NSSize(width: 164, height: 36)

    private init() {
        self.preferencesSubscription = NotificationCenter.default.publisher(for: .init("MiniNotchIndicatorChanged"))
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshVisibility() }
        self.screenSubscription = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                self?.targetScreen = nil
                self?.refreshVisibility()
            }
    }

    var isPresented: Bool { self.panel?.isVisible == true }
    var showsControls: Bool { self.isRecording || self.isHovered || self.isFocused }

    func start(_ publisher: AnyPublisher<CGFloat, Never>, screen: NSScreen?) {
        self.targetScreen = screen
        self.level = 0
        self.isRecording = true
        self.isExpanded = false
        self.audioSubscription = publisher.receive(on: RunLoop.main).sink { [weak self] level in self?.level = level }
        self.refreshVisibility()
    }

    func finish() {
        self.audioSubscription = nil
        self.isRecording = false
        self.isExpanded = false
        self.level = 0
        self.keyboardFocused = false
        self.isFocused = self.accessibilityFocused
        self.isHovered = self.isPresented && self.pointerIsInsideIndicator
        self.refreshVisibility()
    }

    func hoverChanged(_ hovered: Bool) {
        self.hoverExitTask?.cancel()
        if hovered {
            self.isHovered = true
            self.refreshVisibility()
        } else {
            self.hoverExitTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                guard let self, !Task.isCancelled, !self.pointerIsInsideIndicator, !self.isFocused else { return }
                self.isHovered = false
                self.refreshVisibility()
            }
        }
    }

    func keyboardFocusChanged(_ focused: Bool) {
        // SwiftUI can assign focus to a nonactivating panel before it becomes key.
        self.keyboardFocused = focused && self.panel?.isKeyWindow == true
        self.updateFocus()
    }

    func accessibilityFocusChanged(_ focused: Bool) {
        self.accessibilityFocused = focused
        self.updateFocus()
    }

    private func updateFocus() {
        self.isFocused = self.keyboardFocused || self.accessibilityFocused
        if !self.isFocused, !self.pointerIsInsideIndicator { self.isHovered = false }
        self.refreshVisibility()
    }

    private var pointerIsInsideIndicator: Bool {
        guard let panel, let hosting = panel.contentView as? MiniIndicatorHostingView else { return false }
        let rectInWindow = hosting.convert(hosting.interactiveRect, to: nil)
        return panel.convertToScreen(rectInWindow).contains(NSEvent.mouseLocation)
    }

    func expandOverlay() {
        guard self.isRecording else { return }
        self.hoverExitTask?.cancel()
        self.isHovered = false
        self.isExpanded = true
        self.panel?.orderOut(nil)
        self.expand?()
    }

    func refreshVisibility() {
        // Disabling mini must not remove the active recording's only indicator.
        guard SettingsStore.shared.miniNotchIndicatorEnabled || self.isRecording, !self.isExpanded,
              self.isRecording || !SettingsStore.shared.miniNotchHideWhenIdle,
              let screen = self.targetScreen ?? NSScreen.main else {
            self.hoverExitTask?.cancel()
            self.isHovered = false
            self.keyboardFocused = false
            self.accessibilityFocused = false
            self.isFocused = false
            self.panel?.orderOut(nil)
            return
        }
        self.ensurePanel()
        let size = self.panelSize
        let notchHeight = screen.safeAreaInsets.top
        let frame = NSRect(x: screen.frame.midX - size.width / 2,
                           y: screen.frame.maxY - notchHeight - size.height - 6,
                           width: size.width,
                           height: size.height)
        if let panel = self.panel, panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
        if let hosting = self.panel?.contentView as? MiniIndicatorHostingView {
            hosting.interactiveSize = self.showsControls ? self.panelSize : NSSize(width: 58, height: 10)
        }
        if !self.isPresented { self.panel?.orderFrontRegardless() }
    }

    private func ensurePanel() {
        guard self.panel == nil else { return }
        let panel = MiniIndicatorPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let hosting = MiniIndicatorHostingView(rootView: MiniNotchIndicatorView(controller: self))
        hosting.onHoverChanged = { [weak self] in self?.hoverChanged($0) }
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        self.resignKeySubscription = NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.keyboardFocusChanged(false) }
    }
}

private final class MiniIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class MiniIndicatorHostingView: NSHostingView<MiniNotchIndicatorView> {
    var onHoverChanged: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?
    var interactiveSize = NSSize(width: 58, height: 10) {
        didSet { if oldValue != self.interactiveSize { self.updateTrackingAreas() } }
    }

    var interactiveRect: NSRect {
        NSRect(x: self.bounds.midX - self.interactiveSize.width / 2,
               y: self.isFlipped ? self.bounds.minY : self.bounds.maxY - self.interactiveSize.height,
               width: self.interactiveSize.width,
               height: self.interactiveSize.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { self.removeTrackingArea(hoverTrackingArea) }
        let trackingArea = NSTrackingArea(rect: self.interactiveRect,
                                         options: [.mouseEnteredAndExited, .activeAlways],
                                         owner: self,
                                         userInfo: nil)
        self.addTrackingArea(trackingArea)
        self.hoverTrackingArea = trackingArea
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard self.interactiveRect.contains(point) else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { self.onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { self.onHoverChanged?(false) }
}

private struct MiniNotchIndicatorView: View {
    @ObservedObject var controller: MiniNotchIndicatorController
    @ObservedObject private var content = NotchContentState.shared
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @FocusState private var keyboardFocused: Bool
    @AccessibilityFocusState private var accessibilityFocused: Bool

    private var showsControls: Bool { self.controller.showsControls }

    var body: some View {
        Group {
            if self.showsControls {
                HStack(spacing: 8) {
                    if self.controller.isRecording {
                        Image(systemName: self.content.isProcessing ? "sparkles" : "mic.fill")
                            .foregroundStyle(self.content.isProcessing ? Color.white : .red)
                            .frame(width: 24, height: 24)
                    } else {
                        MiniIndicatorButton(symbol: "mic.fill", label: "Start dictation") {
                            self.content.onMiniDictationStartRequested?()
                        }
                    }
                    VoiceAnimationView(style: self.settings.voiceAnimation,
                    level: self.controller.level,
                                       isProcessing: self.controller.isRecording && self.content.isProcessing,
                                       isActive: !self.controller.isExpanded && self.showsControls,
                                       size: CGSize(width: 72, height: 22),
                                       previewLevel: self.controller.isRecording ? nil : 0.08)
                    if self.controller.isRecording {
                        MiniIndicatorButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Expand overlay") {
                            self.controller.expandOverlay()
                        }
                    } else {
                        MiniIndicatorButton(symbol: "gearshape", label: "Open Overlay settings") {
                            self.content.onOpenOverlayPreferencesRequested?()
                        }
                    }
                }
                .font(.system(size: 12)).padding(.horizontal, 12)
                .transition(.opacity)
            } else {
                Color.clear
            }
        }
        .frame(width: self.showsControls ? 164 : 58, height: self.showsControls ? 36 : 8)
        .background(Color.black.opacity(self.controller.isHovered ? 0.98 : 0.92), in: Capsule())
        .foregroundStyle(.white)
        .contentShape(Capsule())
        .focusable()
        .focused(self.$keyboardFocused)
        .focusEffectDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voice dictation indicator")
        .accessibilityFocused(self.$accessibilityFocused)
        .accessibilityAction(named: Text("Start dictation")) {
            guard !self.controller.isRecording else { return }
            self.content.onMiniDictationStartRequested?()
        }
        .accessibilityAction(named: Text("Open Overlay settings")) {
            self.content.onOpenOverlayPreferencesRequested?()
        }
        .onChange(of: self.keyboardFocused) { _, focused in self.controller.keyboardFocusChanged(focused) }
        .onChange(of: self.accessibilityFocused) { _, focused in self.controller.accessibilityFocusChanged(focused) }
        .animation(self.reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.9), value: self.showsControls)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

    }
}

private struct MiniIndicatorButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: self.action) {
            Image(systemName: self.symbol)
                .frame(width: 24, height: 24)
                .background(.white.opacity(self.isHovered ? 0.12 : 0), in: Circle())
                .scaleEffect(self.isHovered && !self.reduceMotion ? 1.06 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.12), value: self.isHovered)
        .help(self.label)
        .accessibilityLabel(self.label)
    }
}

struct MiniNotchIndicatorPreview: View {
    var body: some View {
        VStack(spacing: 6) {
            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
                .fill(.black).frame(width: 140, height: 22)
            HStack(spacing: 12) {
                Image(systemName: "mic.fill").foregroundStyle(.red)
                Image(systemName: "waveform")
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .font(.system(size: 11)).foregroundStyle(.white)
            .padding(8).background(.black.opacity(0.9), in: Capsule())
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity).frame(height: 85)
        .background(LinearGradient(colors: [.blue.opacity(0.25), .purple.opacity(0.25)], startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Preview of a compact voice indicator below the notch")
    }
}
