import SwiftUI

enum ThemedCardStyle {
    case standard
    case prominent
    case subtle
}

/// Page sections used to be filled, bordered cards. The window's inset panel is
/// the only container now, so this keeps the call sites' padding and nothing else.
struct ThemedCard<Content: View>: View {
    @Environment(\.theme) private var theme

    private let padding: CGFloat?
    private let content: Content

    init(
        style: ThemedCardStyle = .standard,
        padding: CGFloat? = nil,
        hoverEffect: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        _ = style
        _ = hoverEffect
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        self.content
            .padding(self.padding ?? self.theme.metrics.cardSurface.defaultPadding)
    }
}
