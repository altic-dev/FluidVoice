import AppKit
import SwiftUI

/// Transient bottom-center panel for a transcript that could not be
/// delivered. Same panel, motion and styling as the microphone change
/// notice, so it reads as one system rather than a state of the
/// dictation overlay.
@MainActor
final class DeliveryFailureOverlayController {
    static let shared = DeliveryFailureOverlayController()

    enum Kind: Equatable {
        case noEditableTarget
        case pasteNotLanded
        case accessibilityNotTrusted
        case deliveryFailed
        case insertionUnconfirmed

        /// Every failure the user can act on maps to a card; only an empty
        /// transcript has nothing to show.
        init?(failure: TextDeliveryFailure) {
            switch failure {
            case .noEditableTarget: self = .noEditableTarget
            case .pasteNotLanded: self = .pasteNotLanded
            case .insertionUnconfirmed: self = .insertionUnconfirmed
            case .accessibilityNotTrusted: self = .accessibilityNotTrusted
            case .clipboardSnapshotFailed, .clipboardWriteFailed, .pasteCommandFailed,
                 .targetUnavailable, .targetRestoreFailed: self = .deliveryFailed
            case .emptyText: return nil
            }
        }

        var title: String {
            switch self {
            case .noEditableTarget: "No text field focused"
            case .pasteNotLanded, .deliveryFailed: "Text wasn't inserted"
            case .accessibilityNotTrusted: "Enable Accessibility to insert text"
            case .insertionUnconfirmed: "Couldn't confirm insertion — Enter skipped"
            }
        }

        var recoveryHint: String {
            self == .insertionUnconfirmed ? "Check the field. Your transcript is saved." : "Your transcript is saved."
        }

        var offersAccessibilitySettings: Bool { self == .accessibilityNotTrusted }
    }

    static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

    private static let displayDuration: TimeInterval = 10
    private var panel: NSPanel?
    private var hostingView: NSHostingView<DeliveryFailureOverlayView>?
    private var dismissTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    private init() {}

    func show(kind: Kind, transcript: String) {
        self.generation &+= 1
        let currentGeneration = self.generation
        self.dismissTask?.cancel()

        let rootView = DeliveryFailureOverlayView(
            kind: kind,
            transcript: transcript,
            displayDuration: Self.displayDuration,
            startedAt: Date(),
            onCopied: { [weak self] in
                self?.hide(after: 0.9)
            },
            onDismiss: { [weak self] in self?.hide() }
        )
        if let hostingView = self.hostingView {
            hostingView.rootView = rootView
        } else {
            self.createPanel(rootView: rootView)
        }
        guard let panel = self.panel else { return }
        self.resizeAndPositionPanel()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        self.animate(duration: 0.12) {
            panel.animator().alphaValue = 1
        }
        DebugLogger.shared.info("Delivery failure card shown kind=\(kind)", source: "DeliveryFailureOverlay")

        self.dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.displayDuration * 1_000_000_000))
            guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
            self.hide()
        }
    }

    func hide(after delay: TimeInterval = 0) {
        self.generation &+= 1
        let hideGeneration = self.generation
        self.dismissTask?.cancel()
        self.dismissTask = nil
        guard let panel, panel.isVisible else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == hideGeneration else { return }
            self.animate(duration: 0.1) {
                panel.animator().alphaValue = 0
            } completion: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == hideGeneration else { return }
                    self.panel?.orderOut(nil)
                    self.panel?.alphaValue = 1
                }
            }
        }
    }

    private func createPanel(rootView: DeliveryFailureOverlayView) {
        let panel = NSPanel(
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

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        panel.contentView = hostingView
        self.panel = panel
        self.hostingView = hostingView
    }

    private func resizeAndPositionPanel() {
        guard let panel, let hostingView,
              let screen = OverlayScreenResolver.screenForCurrentPointer() ?? NSScreen.main
        else { return }
        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let size = NSSize(width: ceil(fittingSize.width), height: ceil(fittingSize.height))
        guard size.width > 0, size.height > 0 else { return }
        hostingView.frame = NSRect(origin: .zero, size: size)
        let visibleFrame = screen.visibleFrame
        panel.setFrame(
            NSRect(x: screen.frame.midX - size.width / 2, y: visibleFrame.minY + 10, width: size.width, height: size.height),
            display: true
        )
    }

    private func animate(duration: TimeInterval, changes: () -> Void, completion: (() -> Void)? = nil) {
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false else {
            changes()
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            changes()
        } completionHandler: {
            completion?()
        }
    }
}

private struct DeliveryFailureOverlayView: View {
    let kind: DeliveryFailureOverlayController.Kind
    let transcript: String
    let displayDuration: TimeInterval
    let startedAt: Date
    let onCopied: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var didCopy = false
    @State private var isCloseHovered = false
    @State private var isCopyHovered = false
    @State private var isSettingsHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "text.cursor")
                    .font(.fluidSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Color.orange.opacity(0.95))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.orange.opacity(0.14)))

                Text(self.kind.title)
                    .font(.fluidSystem(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))

                Spacer(minLength: 8)

                Button(action: self.onDismiss) {
                    Image(systemName: "xmark")
                        .font(.fluidSystem(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(self.isCloseHovered ? 0.95 : 0.68))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(self.isCloseHovered ? 0.13 : 0.06)))
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .onHover { self.isCloseHovered = $0 }
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }

            Text(self.transcriptPreview)
                .font(.fluidSystem(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Text(self.kind.recoveryHint)
                    .font(.fluidSystem(size: 11))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if self.kind.offersAccessibilitySettings {
                    Button(action: self.openAccessibilitySettings) {
                        HStack(spacing: 5) {
                            Image(systemName: "gear")
                                .font(.fluidSystem(size: 10, weight: .semibold))
                            Text("Open Settings")
                        }
                    }
                    .buttonStyle(TransientOverlaySettingsButtonStyle(isHovered: self.isSettingsHovered))
                    .onHover { self.isSettingsHovered = $0 }
                    .help("Open Accessibility settings")
                }

                Button(action: self.copy) {
                    HStack(spacing: 5) {
                        Image(systemName: self.didCopy ? "checkmark" : "doc.on.doc")
                            .font(.fluidSystem(size: 10, weight: .semibold))
                        Text(self.didCopy ? "Copied" : "Copy transcript")
                    }
                }
                .buttonStyle(TransientOverlaySettingsButtonStyle(isHovered: self.isCopyHovered))
                .onHover { self.isCopyHovered = $0 }
                .help("Copy transcript")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 440)
        .background(TransientOverlayBackground())
        .overlay(alignment: .bottomLeading) {
            TransientOverlayCountdownBar(
                startedAt: self.startedAt,
                duration: self.displayDuration,
                reduceMotion: self.reduceMotion
            )
        }
        .scaleEffect(self.appeared || self.reduceMotion ? 1 : 0.96)
        .offset(y: self.appeared || self.reduceMotion ? 0 : 10)
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { self.appeared = true }
        }
        .preferredColorScheme(.dark)
    }

    private var transcriptPreview: String {
        let trimmed = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Nothing was captured" : "\u{201C}\(trimmed)\u{201D}"
    }

    private func openAccessibilitySettings() {
        guard let url = DeliveryFailureOverlayController.accessibilitySettingsURL else { return }
        NSWorkspace.shared.open(url)
        self.onDismiss()
    }

    private func copy() {
        guard !self.didCopy else { return }
        _ = ClipboardService.copyToClipboard(self.transcript)
        withAnimation(.easeOut(duration: 0.15)) { self.didCopy = true }
        self.onCopied()
    }
}
