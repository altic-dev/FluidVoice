import AppKit
import SwiftUI

struct FluidWindowSizing: Equatable {
    let minWidth: CGFloat
    let minHeight: CGFloat

    var minSize: NSSize {
        NSSize(width: self.minWidth, height: self.minHeight)
    }

    static func minimum(width: CGFloat, height: CGFloat) -> FluidWindowSizing {
        FluidWindowSizing(minWidth: width, minHeight: height)
    }
}

private struct FluidWindowSizingModifier: ViewModifier {
    let sizing: FluidWindowSizing

    func body(content: Content) -> some View {
        content.background(FluidWindowSizingBridge(sizing: self.sizing))
    }
}

private struct FluidWindowSizingBridge: NSViewRepresentable {
    let sizing: FluidWindowSizing

    func makeNSView(context _: Context) -> NSView {
        FluidWindowSizingNSView(sizing: self.sizing)
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        guard let sizingView = nsView as? FluidWindowSizingNSView else { return }
        sizingView.sizing = self.sizing
    }
}

private final class FluidWindowSizingNSView: NSView {
    var sizing: FluidWindowSizing {
        didSet {
            self.applySizing()
        }
    }

    private weak var observedWindow: NSWindow?
    private var resizeObserver: NSObjectProtocol?
    private var isApplyingSizing = false

    init(sizing: FluidWindowSizing) {
        self.sizing = sizing
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    deinit {
        self.removeResizeObserver()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.observeWindowIfNeeded()
        self.applySizing()
    }

    private func observeWindowIfNeeded() {
        guard self.observedWindow !== self.window else { return }

        self.removeResizeObserver()
        self.observedWindow = self.window

        guard let window else { return }
        self.resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.applySizing()
        }
    }

    private func removeResizeObserver() {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
        self.resizeObserver = nil
    }

    private func applySizing() {
        guard !self.isApplyingSizing, let window else { return }

        self.isApplyingSizing = true
        defer { self.isApplyingSizing = false }

        let minSize = self.sizing.minSize
        window.minSize = minSize

        let frame = window.frame
        guard frame.width < minSize.width || frame.height < minSize.height else { return }

        let targetWidth = max(frame.width, minSize.width)
        let targetHeight = max(frame.height, minSize.height)
        let targetFrame = NSRect(
            x: frame.midX - targetWidth / 2,
            y: frame.midY - targetHeight / 2,
            width: targetWidth,
            height: targetHeight
        )
        window.setFrame(targetFrame, display: true, animate: false)
    }
}

extension View {
    func fluidWindowSizing(_ sizing: FluidWindowSizing) -> some View {
        self.modifier(FluidWindowSizingModifier(sizing: sizing))
    }
}
