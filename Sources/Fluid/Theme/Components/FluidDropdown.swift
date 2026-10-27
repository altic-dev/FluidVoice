import SwiftUI

enum FluidDropdownAppearance {
    case standard
    case inline
}

/// Shared dropdown surface. Native menus, pickers, and searchable popovers use
/// this appearance while retaining their own selection and presentation logic.
struct FluidDropdownSurface: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    var cornerRadius: CGFloat = 10
    var appearance: FluidDropdownAppearance = .standard

    func body(content: Content) -> some View {
        let highlighted = self.isHovered && self.isEnabled
        content
            .background {
                if self.appearance == .inline {
                    RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
                        .fill(self.theme.palette.primaryText.opacity(highlighted ? 0.055 : 0))
                } else {
                    RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
                        .fill(self.theme.palette.elevatedCardBackground)
                        .overlay {
                            RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
                                .fill(self.theme.palette.accent.opacity(highlighted ? 0.08 : 0))
                        }
                }
            }
            .overlay {
                if self.appearance == .standard {
                    RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
                        .strokeBorder(highlighted ? self.theme.palette.accent.opacity(0.45) : self.theme.palette.cardBorder, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous))
            .onHover { self.isHovered = $0 }
            .animation(self.reduceMotion ? nil : .easeOut(duration: 0.14), value: highlighted)
    }
}

struct FluidDropdownChevron: View {
    @Environment(\.theme) private var theme
    var body: some View {
        Image(systemName: "chevron.down")
            .font(.fluidSystem(size: 10, weight: .semibold))
            .foregroundStyle(self.theme.palette.secondaryText)
            .accessibilityHidden(true)
    }
}

private struct FluidDropdownControlStyle: ViewModifier {
    var fillsWidth = false
    var appearance: FluidDropdownAppearance = .standard
    var tone: Color?

    func body(content: Content) -> some View {
        content
            .menuStyle(.button)
            .buttonStyle(FluidDropdownButtonStyle(fillsWidth: self.fillsWidth, appearance: self.appearance, tone: self.tone))
            .menuIndicator(.hidden)
            .labelsHidden()
    }
}

/// Keep the surface inside the native control's label, so its padding and
/// expanded width participate in hit testing, not just the selected text.
private struct FluidDropdownButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    let fillsWidth: Bool
    let appearance: FluidDropdownAppearance
    let tone: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(self.appearance == .inline ? self.theme.typography.statement : self.theme.typography.bodySmall)
            .foregroundStyle(self.tone ?? self.theme.palette.primaryText)
            .frame(maxWidth: self.fillsWidth ? .infinity : nil, alignment: .leading)
            .padding(.leading, self.appearance == .inline ? 8 : 12)
            .padding(.trailing, self.appearance == .inline ? 24 : 30)
            .padding(.vertical, self.appearance == .inline ? 8 : 9)
            .fluidDropdownSurface(appearance: self.appearance)
            .overlay(alignment: .trailing) {
                FluidDropdownChevron().padding(.trailing, self.appearance == .inline ? 8 : 12).allowsHitTesting(false)
            }
    }
}

extension View {
    /// Apply outside a native menu/picker, rather than inside its label:
    /// macOS may flatten label styling when building the native control.
    /// Use FluidDropdownPicker for selections. Native menu Pickers and
    /// borderless menus ignore custom ButtonStyle hit geometry.
    func fluidDropdownStyle(fillsWidth: Bool = false, appearance: FluidDropdownAppearance = .standard, tone: Color? = nil) -> some View {
        modifier(FluidDropdownControlStyle(fillsWidth: fillsWidth, appearance: appearance, tone: tone))
    }

    /// For custom searchable controls that provide their own label and chevron.
    func fluidDropdownSurface(cornerRadius: CGFloat = 10, appearance: FluidDropdownAppearance = .standard) -> some View {
        modifier(FluidDropdownSurface(cornerRadius: cornerRadius, appearance: appearance))
    }
}

struct FluidDropdown<Content: View>: View {
    let title: String
    var width: CGFloat = 192
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: self.content) { Text(self.title) }
            .fluidDropdownStyle()
            .frame(width: self.width)
    }
}

/// Native menu pickers ignore custom button hit geometry. Keep the native
/// selection/checkmark behavior inside a Menu whose entire label is clickable.
struct FluidDropdownPicker<Selection: Hashable, Options: View>: View {
    let title: String
    let selectedTitle: String
    @Binding var selection: Selection
    @ViewBuilder let options: () -> Options

    init(_ title: String, selectedTitle: String, selection: Binding<Selection>, @ViewBuilder content: @escaping () -> Options) {
        self.title = title
        self.selectedTitle = selectedTitle
        self._selection = selection
        self.options = content
    }

    var body: some View {
        Menu {
            Picker(self.title, selection: self.$selection, content: self.options)
                .pickerStyle(.inline)
        } label: {
            Text(self.selectedTitle)
        }
        .accessibilityLabel(self.title.isEmpty ? self.selectedTitle : self.title)
        .accessibilityValue(self.selectedTitle)
    }
}
