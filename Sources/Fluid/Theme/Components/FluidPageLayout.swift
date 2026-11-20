import AppKit
import Combine
import SwiftUI

/// Shared page geometry. Pane interiors and readable document columns retain their own layouts.
enum FluidPageLayout {
    static let inset: CGFloat = 20
    static let sectionSpacing: CGFloat = 20

    enum Width {
        case overview, standard, reading, form, expanding

        var maximum: CGFloat {
            switch self {
            case .expanding: .infinity
            case .overview: 1440
            case .standard: 1080
            case .reading: 880
            case .form: 720
            }
        }
    }
}

private struct FluidPageToolbarVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

/// A reference, so ending a prewarm doesn't invalidate the page that was just built.
@MainActor
final class FluidPagePrewarmState {
    var isPrewarming = false
}

private struct FluidPagePrewarmStateKey: EnvironmentKey {
    static let defaultValue: FluidPagePrewarmState? = nil
}

private struct FluidPageToolbarPageKey: EnvironmentKey {
    static let defaultValue: SidebarItem? = nil
}

private struct FluidPageToolbarStoreKey: EnvironmentKey {
    static let defaultValue: FluidPageToolbarStore? = nil
}

extension EnvironmentValues {
    /// Set while a page is built ahead of its first visit; it must not start user-visible work.
    var fluidPagePrewarmState: FluidPagePrewarmState? {
        get { self[FluidPagePrewarmStateKey.self] }
        set { self[FluidPagePrewarmStateKey.self] = newValue }
    }

    var fluidPageToolbarPage: SidebarItem? {
        get { self[FluidPageToolbarPageKey.self] }
        set { self[FluidPageToolbarPageKey.self] = newValue }
    }

    var fluidPageToolbarStore: FluidPageToolbarStore? {
        get { self[FluidPageToolbarStoreKey.self] }
        set { self[FluidPageToolbarStoreKey.self] = newValue }
    }

    /// Hidden app content remains mounted behind Settings, but must not contribute actions.
    var fluidPageToolbarVisible: Bool {
        get { self[FluidPageToolbarVisibleKey.self] }
        set { self[FluidPageToolbarVisibleKey.self] = newValue }
    }
}

/// Cached pages sit in their own hosting views, whose `.toolbar` content can't reach the window.
/// Actions stay stored per page so the toolbar has them in the same update as a page switch.
@MainActor
final class FluidPageToolbarStore: ObservableObject {
    @Published private(set) var actions: [SidebarItem: AnyView] = [:]

    func publish(_ actions: AnyView?, for page: SidebarItem) {
        self.actions[page] = actions
    }
}

struct FluidPageToolbarActions: View {
    @ObservedObject var store: FluidPageToolbarStore
    let page: SidebarItem

    var body: some View {
        self.store.actions[self.page]
    }
}

private final class FluidPageToolbarAnchorView: NSView {
    weak var store: FluidPageToolbarStore?
    var page: SidebarItem?
    var actions: AnyView?
    private var isSyncScheduled = false

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    /// Publishing during a SwiftUI update would mutate state that the toolbar is reading.
    func scheduleSync() {
        guard !self.isSyncScheduled else { return }
        self.isSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isSyncScheduled = false
            guard let page = self.page else { return }
            self.store?.publish(self.actions, for: page)
        }
    }
}

private struct FluidPageToolbarAnchor: NSViewRepresentable {
    let store: FluidPageToolbarStore?
    let page: SidebarItem?
    let actions: AnyView?

    func makeNSView(context _: Context) -> FluidPageToolbarAnchorView {
        FluidPageToolbarAnchorView()
    }

    func updateNSView(_ view: FluidPageToolbarAnchorView, context _: Context) {
        view.store = self.store
        view.page = self.page
        view.actions = self.actions
        view.scheduleSync()
    }

    static func dismantleNSView(_ view: FluidPageToolbarAnchorView, coordinator _: ()) {
        guard let page = view.page else { return }
        view.store?.publish(nil, for: page)
    }
}

private struct FluidPageActions<Actions: View>: ViewModifier {
    @Environment(\.fluidPageToolbarStore) private var store
    @Environment(\.fluidPageToolbarPage) private var page
    let enabled: Bool
    let actions: Actions

    func body(content: Content) -> some View {
        content.background(FluidPageToolbarAnchor(
            store: self.store,
            page: self.page,
            actions: self.enabled ? AnyView(
                self.actions
                    .buttonStyle(.automatic)
                    .labelStyle(FluidToolbarLabelStyle())
            ) : nil
        ))
    }
}

/// Match symbol geometry without replacing native macOS toolbar chrome or interaction.
private struct FluidToolbarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.icon.fluidToolbarIcon()
    }
}

extension View {
    func fluidToolbarIcon() -> some View {
        self.font(.system(size: 17, weight: .medium))
            .imageScale(.medium)
            .frame(width: 22, height: 22)
    }

    func fluidPageContent(width: FluidPageLayout.Width = .standard, alignment: Alignment = .leading) -> some View {
        self.padding(FluidPageLayout.inset)
            .frame(maxWidth: width.maximum, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    func fluidPageActions<Actions: View>(enabled: Bool = true, @ViewBuilder actions: () -> Actions) -> some View {
        self.modifier(FluidPageActions(enabled: enabled, actions: actions()))
    }
}
