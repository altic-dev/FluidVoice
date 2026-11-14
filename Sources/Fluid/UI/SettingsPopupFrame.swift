import AppKit
import SwiftUI

/// Sizes the settings popup from the window it sits on, without making the main screen
/// recalculate while that window is being resized.
///
/// The size lives here, inside the popup, so a resize only updates the popup:
/// - when the window shrinks, the popup follows right away so it never hangs outside the window;
/// - when the window grows, the popup waits until the drag ends and then adjusts once.
struct SettingsPopupFrame<Content: View>: View {
    @State private var layout: SettingsPopupLayout
    private let content: Content

    init(initialWindowContentSize: CGSize, @ViewBuilder content: () -> Content) {
        self._layout = State(initialValue: SettingsPopupLayout(windowContentSize: initialWindowContentSize))
        self.content = content()
    }

    var body: some View {
        self.content
            .frame(width: self.layout.width, height: self.layout.height)
            .background(SettingsPopupParentSizeReader { size, isLiveResize in
                let next = SettingsPopupLayout(windowContentSize: size)
                guard next != self.layout else { return }
                let shrinks = next.width < self.layout.width || next.height < self.layout.height
                if !isLiveResize || shrinks { self.layout = next }
            })
    }
}

private struct SettingsPopupParentSizeReader: NSViewRepresentable {
    let onChange: (CGSize, Bool) -> Void

    func makeNSView(context _: Context) -> SettingsPopupParentSizeView {
        SettingsPopupParentSizeView(onChange: self.onChange)
    }

    func updateNSView(_ nsView: SettingsPopupParentSizeView, context _: Context) {
        nsView.onChange = self.onChange
    }
}

final class SettingsPopupParentSizeView: NSView {
    var onChange: (CGSize, Bool) -> Void
    private weak var observedParent: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var attachAttempts = 0

    init(onChange: @escaping (CGSize, Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    deinit {
        self.removeObservers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.attachAttempts = 0
        self.attachToParent()
    }

    /// The popup's window is attached to its parent a moment after this view enters it,
    /// so look for the parent a few times, then stop.
    private func attachToParent() {
        guard let window else {
            self.removeObservers()
            return
        }
        guard let parent = window.sheetParent else {
            guard self.attachAttempts < 20 else { return }
            self.attachAttempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.attachToParent() }
            return
        }
        guard parent !== self.observedParent else { return }
        self.removeObservers()
        self.observedParent = parent
        let names = [
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
        ]
        self.observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                self?.report()
            }
        }
        self.report()
    }

    private func report() {
        guard let parent = self.observedParent else { return }
        self.onChange(parent.contentLayoutRect.size, parent.inLiveResize)
    }

    private func removeObservers() {
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
        self.observers.removeAll()
        self.observedParent = nil
    }
}
