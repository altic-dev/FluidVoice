import AppKit
import SwiftUI

/// A small, transient "Copied" confirmation that appears next to the mouse
/// cursor and fades away — the pattern people expect for a copy action, so the
/// feedback shows up where the user is already looking instead of docked to a
/// row. Presented in a borderless, non-activating floating panel so it never
/// steals focus (a subsequent ⌘V still pastes into the user's target app).
///
/// Shared by every copy action in the Transcription History view (double-click,
/// ⌘C, the Copy button, and the right-click menu).
@MainActor
final class CursorCopyToast {
    static let shared = CursorCopyToast()

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var generation = 0

    private init() {}

    /// Show the toast at the current cursor location. Safe to call repeatedly;
    /// each call resets the auto-dismiss timer.
    func show(_ text: String = "Copied") {
        let panel = self.panel ?? self.makePanel()
        self.panel = panel
        self.generation &+= 1

        let host = NSHostingView(rootView: CursorCopyToastView(text: text))
        host.layout()
        let size = host.fittingSize
        panel.contentView = host
        panel.setContentSize(size)

        // Position just above-right of the cursor, clamped to its screen.
        let mouse = NSEvent.mouseLocation
        var origin = CGPoint(x: mouse.x + 14, y: mouse.y + 14)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        self.dismissTask?.cancel()
        self.dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.9))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func dismiss() {
        guard let panel = self.panel else { return }
        let dismissGeneration = self.generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // Skip hiding if a newer show() re-displayed the toast during the fade.
            guard let self, self.generation == dismissGeneration else { return }
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return panel
    }
}

private struct CursorCopyToastView: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
            Text(self.text)
                .font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.primary.opacity(0.08))
        )
        .fixedSize()
        .padding(4)
    }
}
