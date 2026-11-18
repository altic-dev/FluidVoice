import SwiftUI

// Shared list pieces: selectable rows, chips, status labels, metric tiles and fact rows.
// Screens pass content only; every color, fill and size lives here or in AppTheme, so a
// redesign changes this file instead of each screen.

extension FluidInteractionVisuals {
    /// One source for hover, press and selection fills on rows and soft controls.
    static func fill(_ palette: AppTheme.Palette, isSelected: Bool = false, isHovered: Bool = false, isPressed: Bool = false) -> Color {
        if isPressed { return palette.primaryText.opacity(0.10) }
        if isSelected { return palette.primaryText.opacity(0.08) }
        return palette.primaryText.opacity(isHovered ? 0.045 : 0)
    }
}

/// A selectable row, tile or segment: hover, press and selected fills over the whole hit area.
struct FluidSelectableRowStyle: ButtonStyle {
    let isSelected: Bool
    /// Rounds the fill for tiles and segments; list rows keep square edges.
    var cornerRadius: CGFloat = 0
    /// Rows span their container; tiles and segments keep their own width.
    var fillsWidth = true

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, isSelected: self.isSelected, cornerRadius: self.cornerRadius, fillsWidth: self.fillsWidth)
    }

    private struct RowBody: View {
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false
        let configuration: Configuration
        let isSelected: Bool
        let cornerRadius: CGFloat
        let fillsWidth: Bool

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
            self.configuration.label
                .frame(maxWidth: self.fillsWidth ? .infinity : nil, alignment: .leading)
                .background(FluidInteractionVisuals.fill(
                    self.theme.palette,
                    isSelected: self.isSelected,
                    isHovered: self.isHovered && self.isEnabled,
                    isPressed: self.configuration.isPressed
                ), in: shape)
                .contentShape(shape)
                .contentShape(
                    .focusEffect,
                    self.cornerRadius > 0 ? AnyShape(shape) : AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous).inset(by: 3))
                )
                .onHover { self.isHovered = $0 }
                .animation(self.reduceMotion ? nil : .easeOut(duration: 0.12), value: self.isHovered)
        }
    }
}

extension View {
    /// A selectable row. The whole row takes clicks; the keyboard-focus ring is rounded and inset
    /// instead of square. Tiles and segments pass a corner radius and keep their own width.
    func fluidSelectableRow(isSelected: Bool, cornerRadius: CGFloat = 0, fillsWidth: Bool = true) -> some View {
        self.buttonStyle(FluidSelectableRowStyle(isSelected: isSelected, cornerRadius: cornerRadius, fillsWidth: fillsWidth))
    }
}

/// The hover and selected fill for a list row that holds buttons of its own, so it cannot be one
/// button itself. A row that is one button uses `fluidSelectableRow` instead.
private struct FluidListRowFill: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    let isSelected: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                FluidInteractionVisuals.fill(self.theme.palette, isSelected: self.isSelected, isHovered: self.isHovered),
                in: RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
            )
            .onHover { self.isHovered = $0 }
            .animation(self.reduceMotion ? nil : .easeOut(duration: 0.12), value: self.isHovered)
    }
}

extension View {
    func fluidListRowFill(isSelected: Bool, cornerRadius: CGFloat = FluidSettingsLayout.cornerRadius) -> some View {
        self.modifier(FluidListRowFill(isSelected: isSelected, cornerRadius: cornerRadius))
    }
}

enum FluidChipStyle {
    /// Positive mark, e.g. a supported language.
    case highlight
    /// Plain label.
    case neutral
    /// Outlined tag, e.g. "Recommended".
    case outlined
    /// Dashed outline for a softer suggestion, e.g. "Try first".
    case dashed
}

struct FluidChip: View {
    @Environment(\.theme) private var theme
    let text: String
    var systemImage: String?
    var style: FluidChipStyle = .neutral

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).font(.fluidSystem(size: 9, weight: .bold))
            }
            Text(self.text)
        }
        .font(.fluidSystem(size: 11.5, weight: self.style == .outlined || self.style == .dashed ? .medium : .regular))
        .tracking(-0.1)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .foregroundStyle(self.foreground)
        .background(self.fill, in: Capsule())
        .overlay {
            if self.style == .outlined || self.style == .dashed {
                Capsule().strokeBorder(
                    self.theme.look.text.opacity(0.28),
                    style: StrokeStyle(lineWidth: 1, dash: self.style == .dashed ? [3, 2] : [])
                )
            }
        }
    }

    private var foreground: Color {
        switch self.style {
        case .highlight: self.theme.look.highlightText
        case .neutral: self.theme.look.secondaryText
        case .outlined, .dashed: self.theme.look.text
        }
    }

    private var fill: Color {
        switch self.style {
        case .highlight: self.theme.look.highlightFill
        case .neutral: self.theme.look.quietFill
        case .outlined, .dashed: .clear
        }
    }
}

/// A short status that tells one item apart from its neighbours, e.g. "In use" on one row of a list.
struct FluidStatusLabel: View {
    @Environment(\.theme) private var theme
    let text: String

    var body: some View {
        Text(self.text)
            .fluidText(.label)
            .foregroundStyle(self.theme.look.highlightText)
            .lineLimit(1)
    }
}

/// "Label ……… value" with a hairline above, for detail panels.
struct FluidFactRow<Value: View>: View {
    @Environment(\.theme) private var theme
    let label: String
    @ViewBuilder let value: () -> Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: self.theme.metrics.spacing.md) {
            Text(self.label).foregroundStyle(self.theme.look.secondaryText)
            Spacer(minLength: self.theme.metrics.spacing.sm)
            self.value().multilineTextAlignment(.trailing).foregroundStyle(self.theme.look.text)
        }
        .fluidText(.body)
        .padding(.vertical, self.theme.metrics.spacing.sm)
        .overlay(alignment: .top) { FluidHairline() }
    }
}

extension FluidFactRow where Value == Text {
    init(label: String, value: String) {
        self.label = label
        self.value = { Text(value) }
    }
}

/// A full-width information band with an optional trailing action, placed under a header.
struct FluidNoticeBanner<Accessory: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    let message: String
    var systemImage = "info.circle"
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) {
            Image(systemName: self.systemImage)
                .foregroundStyle(self.theme.look.secondaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(self.title).fluidText(.rowTitle).foregroundStyle(self.theme.look.text)
                Text(self.message)
                    .fluidText(.body)
                    .foregroundStyle(self.theme.look.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: self.theme.metrics.spacing.sm)
            self.accessory()
        }
        .padding(.horizontal, self.theme.metrics.spacing.xl)
        .padding(.vertical, self.theme.metrics.spacing.sm + 2)
        .background(self.theme.look.surface)
        .overlay(alignment: .bottom) { FluidHairline() }
    }
}

/// Wraps chips onto as many lines as they need.
struct FluidChipFlow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + self.spacing
                lineHeight = 0
            }
            x += size.width + self.spacing
            maxX = max(maxX, x - self.spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + self.spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + self.spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
