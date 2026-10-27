import SwiftUI

/// A bounded, static glass surface for onboarding, with an opaque accessibility fallback.
struct OnboardingGlassSurface: ViewModifier {
    let selected: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AppTheme.Metrics.Showcase.cardRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        self.material(content: content)
            .overlay {
                if !self.reduceTransparency {
                    self.shape.fill(LinearGradient(
                        colors: [.white.opacity(self.selected ? 0.08 : 0.025), .clear, FluidBrandColors.blue.opacity(self.selected ? 0.055 : 0.015)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .allowsHitTesting(false)
                }
            }
            .overlay {
                self.shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(self.edgeOpacity), .white.opacity(0.06), .white.opacity(self.edgeOpacity * 0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: self.contrast == .increased ? 2 : 1
                )
                .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(self.selected ? 0.22 : 0.1), radius: self.selected ? 12 : 4, y: self.selected ? 8 : 2)
    }

    private var edgeOpacity: Double {
        self.contrast == .increased ? 0.8 : (self.selected ? 0.30 : 0.10)
    }

    @ViewBuilder private func material(content: Content) -> some View {
        if self.reduceTransparency {
            content.background(self.shape.fill(Color(red: 0.065, green: 0.075, blue: 0.11)))
        } else if #available(macOS 26, *) {
            content
                .glassEffect(.regular.tint(FluidBrandColors.blue.opacity(self.selected ? 0.08 : 0.025)), in: self.shape)
        } else {
            content.background(.ultraThinMaterial, in: self.shape)
        }
    }
}
