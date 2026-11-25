import SwiftUI

enum MainSidebarLayout {
    static let expandedWidth: CGFloat = 264
    static let collapsedWidth: CGFloat = 56
    static let transition: Animation = .timingCurve(0.23, 1, 0.32, 1, duration: 0.1)
}

/// The icon column keeps the same position in both sidebar states.
struct MainSidebarLabel: View {
    @Environment(\.theme) private var theme
    let title: String
    let systemImage: String
    let isCollapsed: Bool
    var isSelected = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: self.systemImage)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 20, height: 20)
                .foregroundStyle(self.isSelected ? Color.white : Color.secondary)
                .accessibilityHidden(true)

            if !self.isCollapsed {
                Text(self.title)
                    .foregroundStyle(self.isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .font(self.theme.typography.sidebarItem)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct MainSidebarButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        MainSidebarButtonSurface(
            label: configuration.label,
            isSelected: self.isSelected,
            isPressed: configuration.isPressed,
            accent: self.theme.palette.accent
        )
    }
}

private struct MainSidebarButtonSurface<Label: View>: View {
    let label: Label
    let isSelected: Bool
    let isPressed: Bool
    let accent: Color
    @State private var isHovered = false

    var body: some View {
        self.label
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(self.backgroundColor)
            )
            .onHover { self.isHovered = $0 }
    }

    private var backgroundColor: Color {
        if self.isSelected { return self.accent }
        if self.isPressed { return Color.primary.opacity(0.12) }
        return Color.primary.opacity(self.isHovered ? 0.07 : 0)
    }
}
