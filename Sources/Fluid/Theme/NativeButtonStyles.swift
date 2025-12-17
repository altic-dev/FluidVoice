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
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
        }

        var body: some View {
            self.configuration.label
                .fontWeight(.semibold)
                .padding(.horizontal, self.theme.metrics.spacing.lg)
                .padding(.vertical, self.theme.metrics.spacing.md)
                .frame(minHeight: 36)
                .foregroundStyle(self.theme.palette.primaryText)
                .background(self.theme.materials.card, in: self.shape)
                .background(self.shape
                    .fill(self.theme.palette.cardBackground)
                    .overlay(self.shape.stroke(
                        self.theme.palette.cardBorder.opacity(self.isHovered ? 0.45 : 0.25),
                        lineWidth: 1
                    )))
                .overlay(self.shape
                    .stroke(self.theme.palette.accent.opacity(self.isHovered ? 0.25 : 0.1), lineWidth: 1)
                    .blendMode(.plusLighter))
                .shadow(
                    color: self.theme.palette.cardBorder.opacity(self.isHovered ? 0.45 : 0.22),
                    radius: self.isHovered ? self.theme.metrics.cardShadow
                        .radius : max(
                            self.theme.metrics.cardShadow.radius - 3,
                            2
                        ),
                    x: 0,
                    y: self.isHovered ? self.theme.metrics.cardShadow.y : self.theme.metrics.cardShadow.y - 2
                )
                .scaleEffect(self.configuration.isPressed ? 0.97 : (self.isHovered ? 1.01 : 1.0))
                .animation(.spring(response: 0.18, dampingFraction: 0.78), value: self.isHovered)
                .animation(.spring(response: 0.2, dampingFraction: 0.8), value: self.configuration.isPressed)
                .onHover { self.isHovered = $0 }
        }
    }
}

// MARK: - Primary Accent Button

struct PremiumButtonStyle: ButtonStyle {
    var isRecording: Bool = false
    var height: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButton(configuration: configuration, isRecording: self.isRecording, height: self.height)
    }

    private struct PrimaryButton: View {
        @Environment(\.theme) private var theme
        @State private var isHovered = false
        let configuration: ButtonStyle.Configuration
        let isRecording: Bool
        let height: CGFloat

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
        }

        private var baseGradient: LinearGradient {
            if self.isRecording {
                return LinearGradient(
                    colors: [
                        Color(nsColor: .systemRed),
                        Color(nsColor: .systemRed).opacity(0.8),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            return LinearGradient(
                colors: [
                    self.theme.palette.accent.opacity(0.95),
                    self.theme.palette.accent.opacity(0.75),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        var body: some View {
            self.configuration.label
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .frame(height: self.height)
                .foregroundStyle(self.isRecording ? Color.white : self.theme.palette.primaryText)
                .background(self.shape
                    .fill(self.baseGradient)
                    .overlay(self.shape.stroke(
                        Color.white.opacity(self.isHovered ? 0.35 : 0.2),
                        lineWidth: 1
                    )))
                .shadow(
                    color: (self.isRecording ? Color(nsColor: .systemRed) : self.theme.palette.accent)
                        .opacity(self.isHovered ? 0.45 : 0.25),
                    radius: self.isHovered ? self.theme.metrics.elevatedCardShadow
                        .radius : max(
                            self.theme.metrics.cardShadow.radius - 2,
                            2
                        ),
                    x: 0,
                    y: self.isHovered ? self.theme.metrics.elevatedCardShadow.y : self.theme.metrics.cardShadow.y
                )
                .scaleEffect(self.configuration.isPressed ? 0.98 : (self.isHovered ? 1.01 : 1.0))
                .animation(.spring(response: 0.18, dampingFraction: 0.75), value: self.isHovered)
                .animation(.spring(response: 0.18, dampingFraction: 0.75), value: self.configuration.isPressed)
                .onHover { self.isHovered = $0 }
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
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
        }

        var body: some View {
            self.configuration.label
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .foregroundStyle(self.theme.palette.primaryText)
                .background(self.theme.materials.card, in: self.shape)
                .background(self.shape
                    .fill(self.theme.palette.cardBackground)
                    .overlay(self.shape.stroke(
                        self.theme.palette.cardBorder.opacity(self.isHovered ? 0.45 : 0.25),
                        lineWidth: 1
                    )))
                .shadow(
                    color: self.theme.palette.cardBorder.opacity(self.isHovered ? 0.35 : 0.15),
                    radius: self.isHovered ? self.theme.metrics.cardShadow
                        .radius : max(
                            self.theme.metrics.cardShadow.radius - 4,
                            1
                        ),
                    x: 0,
                    y: self.isHovered ? self.theme.metrics.cardShadow.y : self.theme.metrics.cardShadow.y - 2
                )
                .scaleEffect(self.configuration.isPressed ? 0.98 : (self.isHovered ? 1.01 : 1.0))
                .animation(.spring(response: 0.18, dampingFraction: 0.78), value: self.isHovered)
                .animation(.spring(response: 0.2, dampingFraction: 0.8), value: self.configuration.isPressed)
                .onHover { self.isHovered = $0 }
        }
    }
}

// MARK: - Compact Button

struct CompactButtonStyle: ButtonStyle {
    var isReady: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        CompactButton(configuration: configuration, isReady: self.isReady)
    }

    private struct CompactButton: View {
        @Environment(\.theme) private var theme
        @State private var isHovered = false
        let configuration: ButtonStyle.Configuration
        let isReady: Bool

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
        }

        var body: some View {
            self.configuration.label
                .fontWeight(.medium)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .foregroundStyle(self.theme.palette.primaryText)
                .background(self.theme.materials.card, in: self.shape)
                .background(self.shape
                    .fill(self.theme.palette.cardBackground)
                    .overlay(self.shape
                        .stroke(
                            (self.isReady ? self.theme.palette.accent : self.theme.palette.cardBorder)
                                .opacity(self.isHovered ? 0.45 : 0.25),
                            lineWidth: 1
                        )))
                .shadow(
                    color: (self.isReady ? self.theme.palette.accent : self.theme.palette.cardBorder)
                        .opacity(self.isHovered ? 0.3 : 0.12),
                    radius: self.isHovered ? self.theme.metrics.cardShadow.radius - 2 : 2,
                    x: 0,
                    y: self.isHovered ? self.theme.metrics.cardShadow.y - 1 : 1
                )
                .scaleEffect(self.configuration.isPressed ? 0.97 : (self.isHovered ? 1.01 : 1.0))
                .animation(.spring(response: 0.18, dampingFraction: 0.78), value: self.isHovered)
                .animation(.spring(response: 0.2, dampingFraction: 0.8), value: self.configuration.isPressed)
                .onHover { self.isHovered = $0 }
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
            self.configuration.label
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, self.theme.metrics.spacing.md)
                .padding(.vertical, self.theme.metrics.spacing.xs)
                .foregroundStyle(Color.white)
                .background(self.shape
                    .fill(self.theme.palette.accent.opacity(self.isHovered ? 0.9 : 0.8)))
                .shadow(
                    color: self.theme.palette.accent.opacity(self.isHovered ? 0.45 : 0.25),
                    radius: self.isHovered ? 6 : 3,
                    x: 0,
                    y: self.isHovered ? 3 : 1
                )
                .scaleEffect(self.configuration.isPressed ? 0.96 : (self.isHovered ? 1.03 : 1.0))
                .animation(.easeOut(duration: 0.15), value: self.isHovered)
                .animation(.easeOut(duration: 0.15), value: self.configuration.isPressed)
                .onHover { self.isHovered = $0 }
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
                self.configuration.label
                    .foregroundStyle(self.theme.palette.primaryText)

                Spacer()

                Toggle("", isOn: self.configuration.$isOn)
                    .toggleStyle(.switch)
                    .tint(self.theme.palette.accent)
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
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)))
    }
}

extension View {
    func formRowStyle() -> some View {
        modifier(FormRowStyle())
    }
}
