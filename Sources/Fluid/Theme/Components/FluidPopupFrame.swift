import AppKit
import Combine
import SwiftUI

extension View {
    /// Shows `content` as a pop-up at the shared pop-up size (`FluidPopupLayout`). While it is
    /// open the main window keeps itself big enough for it.
    func fluidPopup<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        self.modifier(FluidPopupRegistration(isOpen: item.wrappedValue != nil))
            .sheet(item: item) { value in FluidPopupFrame { content(value) } }
    }

    /// Shows `content` as a pop-up at the shared pop-up size (`FluidPopupLayout`). While it is
    /// open the main window keeps itself big enough for it.
    func fluidPopup<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        self.modifier(FluidPopupRegistration(isOpen: isPresented.wrappedValue))
            .sheet(isPresented: isPresented) { FluidPopupFrame(content: content) }
    }
}

/// Counts the pop-ups that are open, so the main window can keep itself big enough for them.
/// The main window owns one and reads `isAnyOpen` for its minimum size.
@MainActor
final class FluidPopupPresence: ObservableObject {
    @Published private(set) var openCount = 0

    var isAnyOpen: Bool {
        self.openCount > 0
    }

    func opened() {
        self.openCount += 1
    }

    func closed() {
        self.openCount = max(0, self.openCount - 1)
    }
}

private struct FluidPopupPresenceKey: EnvironmentKey {
    static let defaultValue: FluidPopupPresence? = nil
}

extension EnvironmentValues {
    var fluidPopupPresence: FluidPopupPresence? {
        get { self[FluidPopupPresenceKey.self] }
        set { self[FluidPopupPresenceKey.self] = newValue }
    }
}

/// Reports one pop-up as open or closed exactly once per change, including when its presenter
/// leaves the screen while it is open.
private struct FluidPopupRegistration: ViewModifier {
    @Environment(\.fluidPopupPresence) private var presence
    @State private var isRegistered = false
    let isOpen: Bool

    func body(content: Content) -> some View {
        content
            .onAppear { self.sync(self.isOpen) }
            .onChange(of: self.isOpen) { _, isOpen in self.sync(isOpen) }
            .onDisappear { self.sync(false) }
    }

    private func sync(_ isOpen: Bool) {
        guard isOpen != self.isRegistered else { return }
        self.isRegistered = isOpen
        if isOpen { self.presence?.opened() } else { self.presence?.closed() }
    }
}

/// Sizes a pop-up from the window it sits on, without making the main screen recalculate while
/// that window is being resized.
///
/// The size lives here, inside the pop-up, so a resize only updates the pop-up:
/// - when the window shrinks, the pop-up follows right away so it never hangs outside the window;
/// - when the window grows, the pop-up waits until the drag ends and then adjusts once.
struct FluidPopupFrame<Content: View>: View {
    @State private var layout: FluidPopupLayout
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        // Read once when the pop-up opens. After that the pop-up tracks the window itself.
        let windowContentSize = NSApp.windows.first(where: MainWindowIdentity.matches)?.contentLayoutRect.size
            ?? FluidPopupLayout.minimumWindowContentSize
        self._layout = State(initialValue: FluidPopupLayout(windowContentSize: windowContentSize))
        self.content = content()
    }

    var body: some View {
        self.content
            .frame(width: self.layout.width, height: self.layout.height)
            .background(FluidPopupParentSizeReader { size, isLiveResize in
                let next = FluidPopupLayout(windowContentSize: size)
                guard next != self.layout else { return }
                let shrinks = next.width < self.layout.width || next.height < self.layout.height
                if !isLiveResize || shrinks { self.layout = next }
            })
    }
}

private struct FluidPopupParentSizeReader: NSViewRepresentable {
    let onChange: (CGSize, Bool) -> Void

    func makeNSView(context _: Context) -> FluidPopupParentSizeView {
        FluidPopupParentSizeView(onChange: self.onChange)
    }

    func updateNSView(_ nsView: FluidPopupParentSizeView, context _: Context) {
        nsView.onChange = self.onChange
    }
}

final class FluidPopupParentSizeView: NSView {
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

    /// The pop-up's window is attached to its parent a moment after this view enters it,
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
