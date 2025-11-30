import SwiftUI

// MARK: - Primary (Prominent) Button
struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GlassButton(configuration: configuration)
    }

    private struct GlassButton: View {
        @Environment(\.theme) private var theme
        @State private var isHovered = false
        let configuration: ButtonStyle.Configuration

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: theme.metrics.corners.md, style: .continuous)
        }

        var body: some View {
            configuration.label
                .fontWeight(.semibold)
                .padding(.horizontal, theme.metrics.spacing.lg)
                .padding(.vertical, theme.metrics.spacing.md)
                .frame(minHeight: 36)
                .foregroundStyle(theme.palette.primaryText)
                .background(theme.materials.card, in: shape)
                .background(
                    shape
                        .fill(theme.palette.cardBackground)
                        .overlay(
                            shape.stroke(
                                theme.palette.cardBorder.opacity(isHovered ? 0.45 : 0.25),
                                lineWidth: 1
                            )
                        )
                )
                .overlay(
                    shape
                        .stroke(theme.palette.accent.opacity(isHovered ? 0.25 : 0.1), lineWidth: 1)
                        .blendMode(.plusLighter)
                )
                .shadow(
                    color: theme.palette.cardBorder.opacity(isHovered ? 0.45 : 0.22),
                    radius: isHovered ? theme.metrics.cardShadow.radius : max(theme.metrics.cardShadow.radius - 3, 2),
                    x: 0,
                    y: isHovered ? theme.metrics.cardShadow.y : theme.metrics.cardShadow.y - 2
                )
                .scaleEffect(configuration.isPressed ? 0.97 : (isHovered ? 1.01 : 1.0))
                .animation(.spring(response: 0.18, dampingFraction: 0.78), value: isHovered)
                .animation(.spring(response: 0.2, dampingFraction: 0.8), value: configuration.isPressed)
                .onHover { isHovered = $0 }
        }
    }
}

// MARK: - Primary Accent Button
struct PremiumButtonStyle: ButtonStyle {
    var isRecording: Bool = false
    var height: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButton(configuration: configuration, isRecording: isRecording, height: height)
    }

    private struct PrimaryButton: View {
        @Environment(\.theme) private var theme
        @State private var isHovered = false
        let configuration: ButtonStyle.Configuration
        let isRecording: Bool
        let height: CGFloat

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: theme.metrics.corners.lg, style: .continuous)
        }

        private var baseGradient: LinearGradient {
            if isRecording {
                return LinearGradient(
                    colors: [
                        Color(nsColor: .systemRed),
                        Color(nsColor: .systemRed).opacity(0.8)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            return LinearGradient(
                colors: [
                    theme.palette.accent.opacity(0.95),
                    theme.palette.accent.opacity(0.75)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        var body: some View {
            configuration.label
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .foregroundStyle(isRecording ? Color.white : theme.palette.primaryText)
                .background(
                    shape
                        .fill(baseGradient)
                        .overlay(
                            shape.stroke(
                                Color.white.opacity(isHovered ? 0.35 : 0.2),
                                lineWidth: 1
                            )
                        )
                )
                .shadow(
                    color: (isRecording ? Color(nsColor: .systemRed) : theme.palette.accent)
                        .opacity(isHovered ? 0.45 : 0.25),
                    radius: isHovered ? theme.metrics.elevatedCardShadow.radius : max(theme.metrics.cardShadow.radius - 2, 2),
                    x: 0,
                    y: isHovered ? theme.metrics.elevatedCardShadow.y : theme.metrics.cardShadow.y
                )
                .scaleEffect(configuration.isPressed ? 0.98 : (isHovered ? 1.01 : 1.0))
                .animation(.spring(response: 0.18, dampingFraction: 0.75), value: isHovered)
                .animation(.spring(response: 0.18, dampingFraction: 0.75), value: configuration.isPressed)
                .onHover { isHovered = $0 }
        }
    }
}

// MARK: - Secondary Button
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SecondaryButton(configuration: configuration)
    }

    private struct SecondaryButton: View {
        @Environment(\.theme) private var theme
        @State private var isHovered = false
        let configuration: ButtonStyle.Configuration

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: theme.metrics.corners.lg, style: .continuous)
        }

        var body: some View {
            configuration.label
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .foregroundStyle(theme.palette.primaryText)
                .background(theme.materials.card, in: shape)
                .background(
                    shape
                        .fill(theme.palette.cardBackground)
                        .overlay(
                            shape.stroke(
                                theme.palette.cardBorder.opacity(isHovered ? 0.45 : 0.25),
                                lineWidth: 1
                            )
                        )
                )
                .shadow(
                    color: theme.palette.cardBorder.opacity(isHovered ? 0.35 : 0.15),
                    radius: isHovered ? theme.metrics.cardShadow.radius : max(theme.metrics.cardShadow.radius - 4, 1),
                    x: 0,
                    y: isHovered ? theme.metrics.cardShadow.y : theme.metrics.cardShadow.y - 2
                )
                .scaleEffect(configuration.isPressed ? 0.98 : (isHovered ? 1.01 : 1.0))
                .animation(.spring(response: 0.18, dampingFraction: 0.78), value: isHovered)
                .animation(.spring(response: 0.2, dampingFraction: 0.8), value: configuration.isPressed)
                .onHover { isHovered = $0 }
        }
    }
}

// MARK: - Compact Button
struct CompactButtonStyle: ButtonStyle {
    var isReady: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        CompactButton(configuration: configuration, isReady: isReady)
    }

    private struct CompactButton: View {
        @Environment(\.theme) private var theme
        @State private var isHovered = false
        let configuration: ButtonStyle.Configuration
        let isReady: Bool

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: theme.metrics.corners.sm, style: .continuous)
        }

        var body: some View {
            configuration.label
                .fontWeight(.medium)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .foregroundStyle(theme.palette.primaryText)
                .background(theme.materials.card, in: shape)
                .background(
                    shape
                        .fill(theme.palette.cardBackground)
                        .overlay(
                            shape.stroke(
                                (isReady ? theme.palette.accent : theme.palette.cardBorder)
                                    .opacity(isHovered ? 0.45 : 0.25),
                                lineWidth: 1
                            )
                        )
                )
                .shadow(
                    color: (isReady ? theme.palette.accent : theme.palette.cardBorder)
                        .opacity(isHovered ? 0.3 : 0.12),
                    radius: isHovered ? theme.metrics.cardShadow.radius - 2 : 2,
                    x: 0,
                    y: isHovered ? theme.metrics.cardShadow.y - 1 : 1
                )
                .scaleEffect(configuration.isPressed ? 0.97 : (isHovered ? 1.01 : 1.0))
                .animation(.spring(response: 0.18, dampingFraction: 0.78), value: isHovered)
                .animation(.spring(response: 0.2, dampingFraction: 0.8), value: configuration.isPressed)
                .onHover { isHovered = $0 }
        }
    }
}

// MARK: - Inline Button
struct InlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        InlineButton(configuration: configuration)
    }

    private struct InlineButton: View {
        @Environment(\.theme) private var theme
        @State private var isHovered = false
        let configuration: ButtonStyle.Configuration

        private var shape: Capsule {
            Capsule()
        }

        var body: some View {
            configuration.label
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, theme.metrics.spacing.md)
                .padding(.vertical, theme.metrics.spacing.xs)
                .foregroundStyle(Color.white)
                .background(
                    shape
                        .fill(theme.palette.accent.opacity(isHovered ? 0.9 : 0.8))
                )
                .shadow(
                    color: theme.palette.accent.opacity(isHovered ? 0.45 : 0.25),
                    radius: isHovered ? 6 : 3,
                    x: 0,
                    y: isHovered ? 3 : 1
                )
                .scaleEffect(configuration.isPressed ? 0.96 : (isHovered ? 1.03 : 1.0))
                .animation(.easeOut(duration: 0.15), value: isHovered)
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
                .onHover { isHovered = $0 }
        }
    }
}

// MARK: - Glass Toggle Style (now uses native switch for consistency)
struct GlassToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        ToggleBody(configuration: configuration)
    }

    private struct ToggleBody: View {
        @Environment(\.theme) private var theme
        let configuration: ToggleStyle.Configuration

        var body: some View {
            HStack {
                configuration.label
                    .foregroundStyle(theme.palette.primaryText)

                Spacer()

                Toggle("", isOn: configuration.$isOn)
                    .toggleStyle(.switch)
                    .tint(theme.palette.accent)
                    .labelsHidden()
            }
        }
    }
}

// MARK: - Native Form Row Style
struct FormRowStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.ultraThinMaterial.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    )
            )
    }
}

extension View {
    func formRowStyle() -> some View {
        modifier(FormRowStyle())
    }
}










