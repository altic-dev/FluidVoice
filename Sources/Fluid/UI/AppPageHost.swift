import AppKit
import SwiftUI

/// Values a cached page reads from `ContentView`. Unchanged inputs leave its graph untouched on a switch.
struct AppPageInputs: Equatable {
    let colorScheme: ColorScheme
    let accentColor: SettingsStore.AccentColorOption
    let accessibilityEnabled: Bool
    let isSettingsPresented: Bool
}

/// Keeps visited pages outside the window, so a page switch reattaches a built SwiftUI graph.
struct AppPageHost: NSViewRepresentable {
    let page: SidebarItem
    let inputs: AppPageInputs
    let prewarmPages: [SidebarItem]
    let canPrewarm: () -> Bool
    let content: (_ page: SidebarItem, _ prewarmState: FluidPagePrewarmState) -> AnyView

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context _: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.update(self, container: container)
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.stopPrewarming()
    }

    @MainActor
    final class Coordinator {
        private var pages: [SidebarItem: NSHostingView<AnyView>] = [:]
        private var prewarmStates: [SidebarItem: FluidPagePrewarmState] = [:]
        private var appliedInputs: [SidebarItem: AppPageInputs] = [:]
        private var visiblePage: SidebarItem?
        private var host: AppPageHost?
        private weak var container: NSView?
        private var prewarmTask: Task<Void, Never>?

        func update(_ host: AppPageHost, container: NSView) {
            self.host = host
            self.container = container
            container.isHidden = host.inputs.isSettingsPresented

            let page = host.page
            let view = self.pages[page] ?? self.makePage(page)
            let prewarmState = self.prewarmState(for: page)
            prewarmState.end(presented: true)
            if self.appliedInputs[page] != host.inputs {
                view.rootView = host.content(page, prewarmState)
                self.appliedInputs[page] = host.inputs
            }
            for subview in container.subviews where subview !== view {
                // Otherwise AppKit hands focus to the sidebar search, which redraws the whole window.
                if let window = container.window,
                   let responder = window.firstResponder as? NSView,
                   responder.isDescendant(of: subview)
                {
                    window.makeFirstResponder(nil)
                }
                subview.removeFromSuperview()
            }
            view.alphaValue = 1
            if view.superview !== container {
                view.frame = container.bounds
                container.addSubview(view)
            }
            self.visiblePage = page
            self.startPrewarmingIfNeeded()
        }

        func stopPrewarming() {
            self.prewarmTask?.cancel()
        }

        private func prewarmState(for page: SidebarItem) -> FluidPagePrewarmState {
            if let state = self.prewarmStates[page] { return state }
            let state = FluidPagePrewarmState()
            self.prewarmStates[page] = state
            return state
        }

        private func makePage(_ page: SidebarItem) -> NSHostingView<AnyView> {
            let root = self.host?.content(page, self.prewarmState(for: page)) ?? AnyView(EmptyView())
            let view = NSHostingView(rootView: root)
            // The page fills its container; measuring it would walk all of its content.
            view.sizingOptions = []
            view.autoresizingMask = [.width, .height]
            self.pages[page] = view
            self.appliedInputs[page] = self.host?.inputs
            return view
        }

        private var isReadyToPrewarm: Bool {
            guard let host, let container else { return false }
            return !container.isHidden && host.canPrewarm()
        }

        private func startPrewarmingIfNeeded() {
            guard self.prewarmTask == nil else { return }
            self.prewarmTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                for page in self?.host?.prewarmPages ?? [] {
                    try? await Task.sleep(for: .milliseconds(400))
                    while !Task.isCancelled, self?.isReadyToPrewarm == false {
                        try? await Task.sleep(for: .seconds(1))
                    }
                    guard !Task.isCancelled else { return }
                    await self?.prewarm(page)
                }
            }
        }

        /// Pages finish building only inside a window, so this one attaches briefly and invisibly.
        private func prewarm(_ page: SidebarItem) async {
            guard self.pages[page] == nil, let container else { return }
            let prewarmState = self.prewarmState(for: page)
            prewarmState.begin()
            let view = self.makePage(page)
            view.alphaValue = 0
            view.frame = container.bounds
            container.addSubview(view, positioned: .below, relativeTo: nil)
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
            guard self.visiblePage != page else { return }
            view.removeFromSuperview()
            // `onDisappear` runs after removal and must still see the prewarm.
            try? await Task.sleep(for: .milliseconds(50))
            if self.visiblePage != page { prewarmState.end(presented: false) }
        }
    }
}
