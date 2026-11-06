import AppKit
import SwiftUI

/// Floating panel shown when a local coding agent (e.g. OpenCode) asks for a voice reply.
/// The panel can receive Return and Esc without activating FluidVoice.
@MainActor
final class AgentPromptPanelController {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("AgentPrompt")
    private var panel: NSPanel?

    func show(bridge: AgentBridgeService) {
        let panel = self.makePanel(bridge: bridge)
        self.panel = panel
        self.resizeAndPositionPanel(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        // Non-activating panel: makeKey delivers Esc/Return without foregrounding the app.
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        self.panel?.orderOut(nil)
        self.panel = nil
    }

    private func makePanel(bridge: AgentBridgeService) -> NSPanel {
        let panel = AgentPromptPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.identifier = Self.windowIdentifier
        panel.onCancel = { [weak bridge] in bridge?.cancelActivePrompt() }

        let hostingView = AgentPromptHostingView(rootView: AgentPromptView(bridge: bridge))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        panel.contentView = hostingView
        return panel
    }

    private func resizeAndPositionPanel(_ panel: NSPanel) {
        guard let hostingView = panel.contentView,
              let screen = OverlayScreenResolver.screenForCurrentPointer() ?? NSScreen.main
        else { return }
        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let size = NSSize(width: ceil(fittingSize.width), height: ceil(fittingSize.height))
        guard size.width > 0, size.height > 0 else { return }
        hostingView.frame = NSRect(origin: .zero, size: size)
        let visibleFrame = screen.visibleFrame
        panel.setFrame(
            NSRect(
                x: screen.frame.midX - size.width / 2,
                y: visibleFrame.minY + 80,
                width: size.width,
                height: size.height
            ),
            display: true
        )
    }
}

private final class AgentPromptPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool {
        true
    }

    override func cancelOperation(_ sender: Any?) {
        self.onCancel?()
    }
}

private final class AgentPromptHostingView: NSHostingView<AgentPromptView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private struct AgentPromptView: View {
    @ObservedObject var bridge: AgentBridgeService
    @ObservedObject private var settings = SettingsStore.shared

    private var statusStyle: (label: String, color: Color, icon: String) {
        switch self.bridge.agentStatus {
        case .error:
            ("Agent error", .red, "exclamationmark.triangle.fill")
        case .completed:
            ("Turn finished", .green, "checkmark.circle.fill")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            self.header
            self.message
            self.transcriptCard
            self.footer
        }
        .padding(16)
        .frame(width: 520)
        .bottomOverlaySurface(self.settings.bottomOverlayAppearance, cornerRadius: 18)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: self.statusStyle.icon)
                .font(.fluidSystem(size: 11, weight: .semibold))
                .foregroundStyle(self.statusStyle.color)
                .accessibilityHidden(true)

            Text(self.statusStyle.label)
                .font(.fluidSystem(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Button(action: { self.bridge.cancelActivePrompt() }) {
                Image(systemName: "xmark")
                    .font(.fluidSystem(size: 10, weight: .semibold))
            }
            .fluidGlassAction(circular: true, quiet: true)
            .help("Dismiss (Esc)")
            .accessibilityLabel("Dismiss")
        }
    }

    private var message: some View {
        ScrollView {
            Text(self.bridge.agentMessage)
                .font(.fluidSystem(size: 13))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 140)
    }

    private var transcriptCard: some View {
        HStack(spacing: 8) {
            if self.bridge.phase == .starting || self.bridge.phase == .processing {
                ProgressView()
                    .controlSize(.small)
                Text(self.bridge.phase == .starting ? "Starting microphone…" : "Transcribing…")
                    .font(.fluidSystem(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "mic.fill")
                    .font(.fluidSystem(size: 11, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.9))
                if self.bridge.liveTranscript.isEmpty {
                    Text("Listening… speak your reply")
                        .font(.fluidSystem(size: 13))
                        .italic()
                        .foregroundStyle(.secondary)
                } else {
                    Text(self.bridge.liveTranscript)
                        .font(.fluidSystem(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 48)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }

    private var footer: some View {
        FluidGlassControlGroup {
            HStack(spacing: 8) {
                Button("Cancel") {
                    self.bridge.cancelActivePrompt()
                }
                .fluidGlassAction()

                Spacer()

                Button("Send") {
                    self.bridge.finishRecordingAndReply()
                }
                .fluidGlassAction(prominent: true, tone: self.settings.accentColor)
                .disabled(self.bridge.phase != .recording)
                .keyboardShortcut(.return)
            }
        }
    }
}
