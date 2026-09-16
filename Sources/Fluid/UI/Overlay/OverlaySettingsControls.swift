//
//  OverlaySettingsControls.swift
//  Fluid
//
//  Self-contained controls for the Overlay settings section.
//

import SwiftUI

/// One selectable style card with a live miniature of the style.
struct OverlayStyleCard: View {
    let style: OverlayVisualStyle
    let theme: OverlayColorTheme
    let glow: OverlayGlowIntensity
    let surface: OverlaySurfaceAppearance
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: self.action) {
            VStack(alignment: .leading, spacing: 8) {
                OverlayStyleThumbnail(
                    style: self.style,
                    palette: self.theme.palette,
                    glow: self.glow,
                    surface: OverlaySurfaceStyle.resolve(
                        isLight: self.surface.resolvesToLight(systemIsDark: self.colorScheme == .dark)
                    )
                )

                VStack(alignment: .leading, spacing: 1) {
                    Text(self.style.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(self.style.summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(self.fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(self.borderColor, lineWidth: self.isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
        .accessibilityLabel(self.style.displayName)
        .accessibilityAddTraits(self.isSelected ? [.isSelected] : [])
    }

    private var fillColor: Color {
        if self.isSelected {
            return Color.accentColor.opacity(0.14)
        }
        return Color.primary.opacity(self.isHovered ? 0.06 : 0.03)
    }

    private var borderColor: Color {
        self.isSelected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.10)
    }
}

/// One color theme chip with a gradient swatch.
struct OverlayThemeChip: View {
    let theme: OverlayColorTheme
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: self.action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: self.theme.swatchColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 20, height: 20)

                    if self.isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.55), radius: 1)
                    }
                }
                .padding(3)
                .overlay(
                    Circle()
                        .strokeBorder(self.borderColor, lineWidth: self.isSelected ? 2 : 1)
                )

                Text(self.theme.displayName)
                    .font(.system(size: 10, weight: self.isSelected ? .semibold : .regular))
                    .foregroundStyle(self.isSelected ? Color.primary : Color.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(self.isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(self.isHovered ? 0.05 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
        .accessibilityLabel(self.theme.displayName)
        .accessibilityAddTraits(self.isSelected ? [.isSelected] : [])
    }

    private var borderColor: Color {
        self.isSelected ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.12)
    }
}

/// Segmented Subtle / Normal / Vivid control.
struct OverlayGlowPicker: View {
    @Binding var selection: OverlayGlowIntensity

    var body: some View {
        HStack(spacing: 4) {
            ForEach(OverlayGlowIntensity.allCases, id: \.self) { intensity in
                OverlayGlowChip(intensity: intensity, isSelected: self.selection == intensity) {
                    self.selection = intensity
                }
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

private struct OverlayGlowChip: View {
    let intensity: OverlayGlowIntensity
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            Text(self.intensity.displayName)
                .font(.system(size: 11, weight: self.isSelected ? .semibold : .regular))
                .foregroundStyle(self.isSelected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(self.isSelected ? Color.primary.opacity(0.14) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(self.intensity.displayName)
        .accessibilityAddTraits(self.isSelected ? [.isSelected] : [])
    }
}

/// 2 x 3 anchor grid drawn as miniature screens.
struct OverlayAnchorGrid: View {
    @Binding var selection: SettingsStore.OverlayPosition

    private static let rows: [[SettingsStore.OverlayPosition]] = [
        [.topLeft, .topCenter, .topRight],
        [.bottomLeft, .bottomCenter, .bottomRight],
    ]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Self.rows.indices, id: \.self) { rowIndex in
                HStack(spacing: 6) {
                    ForEach(Self.rows[rowIndex], id: \.self) { anchor in
                        OverlayAnchorButton(anchor: anchor, isSelected: self.selection == anchor) {
                            self.selection = anchor
                        }
                    }
                }
            }
        }
    }
}

/// One anchor button, drawn as a tiny screen with the pill at that corner.
private struct OverlayAnchorButton: View {
    let anchor: SettingsStore.OverlayPosition
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.05))

                Capsule()
                    .fill(self.isSelected ? Color.accentColor : Color.primary.opacity(0.35))
                    .frame(width: 20, height: 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: self.alignment)
                    .padding(4)

                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        self.isSelected ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.14),
                        lineWidth: self.isSelected ? 1.6 : 1
                    )
            }
            .frame(height: 34)
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(self.anchor.displayName)
        .accessibilityLabel(self.anchor.displayName)
        .accessibilityAddTraits(self.isSelected ? [.isSelected] : [])
    }

    private var alignment: Alignment {
        switch self.anchor {
        case .topLeft: return .topLeading
        case .topCenter: return .top
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomCenter: return .bottom
        case .bottomRight: return .bottomTrailing
        }
    }
}
