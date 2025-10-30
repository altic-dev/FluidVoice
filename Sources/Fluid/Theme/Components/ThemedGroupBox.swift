import SwiftUI

struct ThemedGroupBox<Label: View, Content: View>: View {
    @Environment(\.theme) private var theme

    private let style: ThemedCardStyle
    private let hoverEffect: Bool
    private let label: Label
    private let content: Content

    init(
        style: ThemedCardStyle = .standard,
        hoverEffect: Bool = false,
        @ViewBuilder label: () -> Label,
        @ViewBuilder content: () -> Content
    ) {
        self.style = style
        self.hoverEffect = hoverEffect
        self.label = label()
        self.content = content()
    }

    var body: some View {
        ThemedCard(style: style, padding: 0, hoverEffect: hoverEffect) {
            VStack(alignment: .leading, spacing: theme.metrics.spacing.md) {
                label
                    .font(.headline)
                    .foregroundStyle(theme.palette.secondaryText)
                    .padding(.top, theme.metrics.spacing.md)
                    .padding(.horizontal, theme.metrics.spacing.md)

                Divider()
                    .background(theme.palette.separator)
                    .opacity(0.6)
                    .padding(.horizontal, theme.metrics.spacing.md)

                content
                    .padding(.bottom, theme.metrics.spacing.md)
                    .padding(.horizontal, theme.metrics.spacing.md)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}




