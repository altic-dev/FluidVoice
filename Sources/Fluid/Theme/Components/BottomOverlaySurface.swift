import SwiftUI

/// Visual-only styling for the bottom overlay and its attached menus.
/// Add another preset here to retry the material without touching overlay behavior or layout.
struct BottomOverlayAppearance {
    let usesGlass: Bool
    let legacyMaterial: Material
    let glassTint: Color
    let fallbackFill: Color
    let tintTop: Color
    let tintBottom: Color
    var sheen: Color
    var edgeTop: Color
    var edgeBottom: Color
    let shadowColor: Color
    let shadowRadius: CGFloat
    let shadowY: CGFloat

    static let smokedGlass = Self.smokedGlass(opacity: SettingsStore.defaultOverlayGlassOpacity)

    static func resolve(
        material: SettingsStore.OverlayMaterial,
        opacity: Double,
        tint: SettingsStore.OverlayTint = .ocean,
        highlight: Double = 0.5
    ) -> Self {
        var result = self.base(material: material, opacity: self.normalizedOpacity(opacity), tint: tint)
        if material != .original {
            let strength = highlight.isFinite ? min(max(highlight, 0), 1) : 0.5
            result.sheen = Color.white.opacity(strength * (material == .velvet ? 0.05 : 0.18))
            result.edgeTop = Color.white.opacity(strength * 0.52)
            result.edgeBottom = Color.white.opacity(strength * 0.12)
        }
        return result
    }

    private static func base(material: SettingsStore.OverlayMaterial, opacity: Double, tint: SettingsStore.OverlayTint) -> Self {
        switch material {
        case .original:
            return .original
        case .smokedGlass:
            return self.smokedGlass(opacity: opacity)
        case .clearGlass:
            return self.clearGlass(opacity: opacity)
        case .velvet, .aurora:
            return BottomOverlayAppearance(
                usesGlass: material == .aurora,
                legacyMaterial: .ultraThinMaterial,
                glassTint: tint.color.opacity(0.25),
                fallbackFill: Color(red: 0.025, green: 0.03, blue: 0.045),
                tintTop: tint.color.opacity(material == .velvet ? 0.25 : 0.16 + opacity * 0.25),
                tintBottom: material == .velvet ? Color.black.opacity(0.45) : tint.companion.opacity(0.12 + opacity * 0.3),
                sheen: .white.opacity(material == .velvet ? 0.025 : 0.09),
                edgeTop: tint.color.opacity(0.45),
                edgeBottom: .white.opacity(0.06),
                shadowColor: .black.opacity(0.32),
                shadowRadius: 14,
                shadowY: 7
            )
        }
    }

    private static let original = BottomOverlayAppearance(
        usesGlass: false,
        legacyMaterial: .ultraThinMaterial,
        glassTint: .clear,
        fallbackFill: .black,
        tintTop: .clear,
        tintBottom: .clear,
        sheen: .clear,
        edgeTop: .white.opacity(0.15),
        edgeBottom: .white.opacity(0.08),
        shadowColor: Color.black.opacity(0.32),
        shadowRadius: 14,
        shadowY: 7
    )

    private static func smokedGlass(opacity: Double) -> BottomOverlayAppearance {
        let opacity = self.normalizedOpacity(opacity)
        return BottomOverlayAppearance(
            usesGlass: true,
            legacyMaterial: .ultraThinMaterial,
            glassTint: Color(red: 0.045, green: 0.075, blue: 0.13).opacity(0.20 + (0.35 * opacity)),
            fallbackFill: Color(red: 0.035, green: 0.045, blue: 0.065),
            tintTop: Color(red: 0.065, green: 0.095, blue: 0.15).opacity(0.08 + (0.30 * opacity)),
            tintBottom: Color.black.opacity(0.22 + (0.45 * opacity)),
            sheen: Color.white.opacity(0.09),
            edgeTop: Color.white.opacity(0.26),
            edgeBottom: Color.white.opacity(0.06),
            shadowColor: Color.black.opacity(0.34),
            shadowRadius: 14,
            shadowY: 7
        )
    }

    private static func clearGlass(opacity: Double) -> BottomOverlayAppearance {
        let opacity = self.normalizedOpacity(opacity)
        return BottomOverlayAppearance(
            usesGlass: true,
            legacyMaterial: .ultraThinMaterial,
            glassTint: Color(red: 0.06, green: 0.085, blue: 0.13).opacity(0.10 + (0.24 * opacity)),
            fallbackFill: Color(red: 0.055, green: 0.065, blue: 0.085),
            tintTop: Color(red: 0.10, green: 0.13, blue: 0.18).opacity(0.04 + (0.16 * opacity)),
            tintBottom: Color.black.opacity(0.10 + (0.28 * opacity)),
            sheen: Color.white.opacity(0.11),
            edgeTop: Color.white.opacity(0.32),
            edgeBottom: Color.white.opacity(0.09),
            shadowColor: Color.black.opacity(0.28),
            shadowRadius: 14,
            shadowY: 7
        )
    }

    private static func normalizedOpacity(_ opacity: Double) -> Double {
        guard opacity.isFinite else { return SettingsStore.defaultOverlayGlassOpacity }
        return min(max(opacity, SettingsStore.overlayGlassOpacityRange.lowerBound), SettingsStore.overlayGlassOpacityRange.upperBound)
    }
}

private struct BottomOverlaySurfaceModifier: ViewModifier {
    let appearance: BottomOverlayAppearance
    let cornerRadius: CGFloat
    let castsShadow: Bool
    let showsBorder: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background {
                self.materialSurface
                    .overlay {
                        // Color over the opaque fallback is still opaque; preserve personalization.
                        self.shape
                            .fill(
                                LinearGradient(
                                    colors: [self.appearance.tintTop, self.appearance.tintBottom],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .allowsHitTesting(false)
                    }
                    .overlay {
                        if !self.reduceTransparency {
                            self.shape
                                .fill(
                                    LinearGradient(
                                        stops: [
                                            .init(color: self.appearance.sheen, location: 0),
                                            .init(color: self.appearance.sheen.opacity(0.22), location: 0.12),
                                            .init(color: .clear, location: 0.28),
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .allowsHitTesting(false)
                        }
                    }
                    .shadow(
                        color: self.castsShadow ? self.appearance.shadowColor : .clear,
                        radius: self.castsShadow ? self.appearance.shadowRadius : 0,
                        x: 0,
                        y: self.castsShadow ? self.appearance.shadowY : 0
                    )
            }
            .overlay {
                if self.showsBorder {
                    self.shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    self.appearance.edgeTop.opacity(self.contrast == .increased ? 1 : 0.72),
                                    self.appearance.edgeBottom,
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: self.contrast == .increased ? 1.5 : 1
                        )
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private var materialSurface: some View {
        if self.reduceTransparency || !self.appearance.usesGlass {
            self.shape.fill(self.appearance.fallbackFill)
        } else if #available(macOS 26, *) {
            self.shape
                .fill(.clear)
                .glassEffect(.regular.tint(self.appearance.glassTint), in: self.shape)
        } else {
            self.shape.fill(self.appearance.legacyMaterial)
        }
    }
}

extension View {
    func bottomOverlaySurface(
        _ appearance: BottomOverlayAppearance = .smokedGlass,
        cornerRadius: CGFloat,
        castsShadow: Bool = false,
        showsBorder: Bool = true
    ) -> some View {
        self.modifier(
            BottomOverlaySurfaceModifier(
                appearance: appearance,
                cornerRadius: cornerRadius,
                castsShadow: castsShadow,
                showsBorder: showsBorder
            )
        )
    }
}

extension SettingsStore {
    var bottomOverlayAppearance: BottomOverlayAppearance {
        .resolve(material: self.overlayMaterial, opacity: self.overlayGlassOpacity, tint: self.overlayTint, highlight: self.overlayHighlight)
    }
}

extension SettingsStore.OverlayTint {
    var color: Color {
        switch self {
        case .ocean: return Color(red: 0.15, green: 0.48, blue: 0.85)
        case .violet: return Color(red: 0.57, green: 0.32, blue: 0.85)
        case .rose: return Color(red: 0.85, green: 0.3, blue: 0.5)
        case .mint: return Color(red: 0.15, green: 0.68, blue: 0.5)
        case .amber: return Color(red: 0.85, green: 0.52, blue: 0.17)
        }
    }

    var companion: Color {
        switch self {
        case .ocean, .mint: return .indigo
        case .violet, .rose: return .blue
        case .amber: return .purple
        }
    }
}
