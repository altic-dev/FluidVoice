import Combine
import SwiftUI

/// Passive text in unused preview space. Captions and actual errors always take priority.
struct LowMemoryCleanupNotice: View {
    @ObservedObject var monitor: LowMemorySlowdownMonitor = .shared
    @ObservedObject private var contentState = NotchContentState.shared
    let fontSize: CGFloat

    private var canShow: Bool {
        self.monitor.isNoticeVisible && self.contentState.mode == .dictation && self.contentState.isProcessing &&
            !self.contentState.isAIProcessingFailureVisible && !self.contentState.isTextDeliveryFailureVisible &&
            (NotchOverlayManager.shared.isOverlayVisible || NotchOverlayManager.shared.isBottomOverlayVisible)
    }

    var body: some View {
        Group {
            if self.canShow {
                Text("Low memory may slow cleanup")
                    .font(.fluidSystem(size: self.fontSize, weight: .medium))
                    .foregroundStyle(.orange.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .accessibilityLabel("Memory pressure may be slowing cleanup")
                    .background(CleanupNoticeVisibilityProbe { self.monitor.noticeDidAppear() })
                    .allowsHitTesting(false)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CleanupNoticeVisibilityProbe: NSViewRepresentable {
    let didShow: () -> Void

    func makeNSView(context _: Context) -> CleanupNoticeVisibilityView {
        let view = CleanupNoticeVisibilityView()
        view.didShow = self.didShow
        return view
    }

    func updateNSView(_ view: CleanupNoticeVisibilityView, context _: Context) {
        view.didShow = self.didShow
        view.reportVisibility()
    }
}

private final class CleanupNoticeVisibilityView: NSView {
    var didShow: (() -> Void)?
    private var subscriptions = Set<AnyCancellable>()

    nonisolated deinit {}

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.subscriptions.removeAll()
        if let window {
            NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
                .filter { [weak window] in $0.object as? NSWindow === window }
                .sink { [weak self] _ in self?.reportVisibility() }
                .store(in: &self.subscriptions)
            window.publisher(for: \.alphaValue, options: [.new])
                .sink { [weak self] _ in self?.reportVisibility() }
                .store(in: &self.subscriptions)
            window.publisher(for: \.isVisible, options: [.new])
                .sink { [weak self] _ in self?.reportVisibility() }
                .store(in: &self.subscriptions)
        }
        self.reportVisibility()
    }

    override func layout() {
        super.layout()
        self.reportVisibility()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        self.reportVisibility()
    }

    func reportVisibility() {
        guard !self.isHiddenOrHasHiddenAncestor, self.bounds.width > 0, self.bounds.height > 0,
              let window = self.window, window.isVisible, window.alphaValue > 0,
              window.occlusionState.contains(.visible) else { return }
        self.didShow?()
    }
}
