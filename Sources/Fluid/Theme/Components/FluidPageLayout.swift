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

private struct FluidToolbarTrailingInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 80
}

extension EnvironmentValues {
    var fluidToolbarTrailingInset: CGFloat {
        get { self[FluidToolbarTrailingInsetKey.self] }
        set { self[FluidToolbarTrailingInsetKey.self] = newValue }
    }

    /// Hidden app content remains mounted behind Settings, but must not contribute actions.
    var fluidPageToolbarVisible: Bool {
        get { self[FluidPageToolbarVisibleKey.self] }
        set { self[FluidPageToolbarVisibleKey.self] = newValue }
    }
}

private struct FluidPageActions<Actions: View>: ViewModifier {
    @Environment(\.fluidPageToolbarVisible) private var isVisible
    @Environment(\.fluidToolbarTrailingInset) private var trailingInset
    let enabled: Bool
    let actions: Actions

    func body(content: Content) -> some View {
        content.toolbar {
            if self.isVisible, self.enabled {
                // Keep page actions separate from the shared trailing controls.
                if #available(macOS 26, *) {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    self.actions
                        .buttonStyle(.automatic)
                        .labelStyle(FluidToolbarLabelStyle())
                }
                FluidToolbarEdgeSpace(width: self.trailingInset)
            }
        }
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

/// A separate invisible item leaves the native glass and button hit areas intact.
struct FluidToolbarEdgeSpace: ToolbarContent {
    let width: CGFloat

    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .primaryAction) { self.space }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { self.space }
        }
    }

    private var space: some View {
        Color.clear
            .frame(width: max(0, self.width - 8), height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
