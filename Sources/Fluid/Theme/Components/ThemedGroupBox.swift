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
        ThemedCard(style: self.style, padding: 0, hoverEffect: self.hoverEffect) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                self.label
                    .font(.headline)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .padding(.top, self.theme.metrics.spacing.md)
                    .padding(.horizontal, self.theme.metrics.spacing.md)

                Divider()
                    .background(self.theme.palette.separator)
                    .opacity(0.6)
                    .padding(.horizontal, self.theme.metrics.spacing.md)

                self.content
                    .padding(.bottom, self.theme.metrics.spacing.md)
                    .padding(.horizontal, self.theme.metrics.spacing.md)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
