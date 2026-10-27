import SwiftUI

/// Fits the page above its fixed navigation footer, without a page-level scroll view.
struct OnboardingFittedContent<Content: View>: View {
    let width: CGFloat
    var heightAnimation: Animation? = nil
    @ViewBuilder let content: () -> Content
    @State private var measuredHeight: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            let scale = min(1, geometry.size.width / self.width, geometry.size.height / max(1, self.measuredHeight))
            self.content()
                .frame(width: self.width)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { contentGeometry in
                        Color.clear.preference(key: OnboardingContentHeightKey.self, value: contentGeometry.size.height)
                    }
                }
                .onPreferenceChange(OnboardingContentHeightKey.self) { height in
                    guard abs(height - self.measuredHeight) > 0.5 else { return }
                    withAnimation(self.measuredHeight > 1 ? self.heightAnimation : nil) {
                        self.measuredHeight = height
                    }
                }
                .scaleEffect(max(0, scale))
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

private struct OnboardingContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
