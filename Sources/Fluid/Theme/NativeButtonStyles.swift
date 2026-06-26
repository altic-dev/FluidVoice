import SwiftUI

enum FluidInteractionVisuals {
    static let hoverScale: CGFloat = 1.01
    static let pressedScale: CGFloat = 0.97
    static let hoverAnimation: Animation = .spring(response: 0.18, dampingFraction: 0.78)
    static let pressedAnimation: Animation = .spring(response: 0.2, dampingFraction: 0.8)

    static func scale(isPressed: Bool, isHovered: Bool) -> CGFloat {
        if isPressed { return self.pressedScale }
        return isHovered ? self.hoverScale : 1
    }
}

enum FluidButtonRole {
    case primary
    case secondary
    case glass
    case compact
    case accent
    case inline
}

enum FluidButtonSize: Equatable {
    case compact
    case small
    case medium
    case large

    var controlHeight: CGFloat {
        switch self {
        case .compact:
            return 34
        case .small:
            return 32
        case .medium:
            return 36
        case .large:
            return 44
        }
    }

    var accentCompact: Bool {
        self == .small || self == .compact
    }
}

extension View {
    func fluidControlSurface(
        isSelected: Bool,
        isHovered: Bool,
        tone: Color,
        cornerRadius: CGFloat
    ) -> some View {
        self.modifier(FluidControlSurfaceModifier(
            isSelected: isSelected,
            isHovered: isHovered,
            tone: tone,
            cornerRadius: cornerRadius
        ))
    }

    @ViewBuilder
    func fluidButton(
        _ role: FluidButtonRole,
        size: FluidButtonSize = .medium,
        isRecording: Bool = false
    ) -> some View {
        switch role {
        case .primary:
            self.buttonStyle(PremiumButtonStyle(isRecording: isRecording, height: size.controlHeight))
        case .secondary:
            self.buttonStyle(SecondaryButtonStyle(height: size.controlHeight))
        case .glass:
            self.buttonStyle(GlassButtonStyle(height: size.controlHeight))
        case .compact:
            self.buttonStyle(CompactButtonStyle(height: size.controlHeight))
        case .accent:
            self.buttonStyle(AccentButtonStyle(compact: size.accentCompact))
        case .inline:
            self.buttonStyle(InlineButtonStyle())
        }
    }

    func fluidCompactButton(
        size: FluidButtonSize = .compact,
        isReady: Bool = false,
        foreground: Color? = nil,
        borderColor: Color? = nil
    ) -> some View {
        self.buttonStyle(CompactButtonStyle(
            isReady: isReady,
            foreground: foreground,
            borderColor: borderColor,
            height: size.controlHeight
        ))
    }
}

private struct FluidControlSurfaceModifier: ViewModifier {
    @Environment(\.theme) private var theme
    let isSelected: Bool
    let isHovered: Bool
    let tone: Color
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
        let fillOpacity = self.isSelected ? 0.96 : (self.isHovered ? 0.42 : 0)
        let shineOpacity = self.isSelected ? 0.14 : (self.isHovered ? 0.07 : 0)
        let strokeColor = self.isSelected
            ? self.tone.opacity(0.24)
            : (self.isHovered ? self.theme.palette.cardBorder.opacity(0.28) : .clear)

        content
            .background(
                shape
                    .fill(self.theme.palette.cardBackground.opacity(fillOpacity))
                    .overlay(
                        LinearGradient(
                            colors: [.white.opacity(shineOpacity), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .clipShape(shape)
                    )
                    .overlay(shape.stroke(strokeColor, lineWidth: 1))
                    .shadow(
                        color: .black.opacity(self.isSelected ? 0.16 : (self.isHovered ? 0.08 : 0)),
                        radius: self.isSelected || self.isHovered ? 5 : 0,
                        y: self.isSelected || self.isHovered ? 1 : 0
                    )
            )
            .scaleEffect(self.isHovered && !self.isSelected ? FluidInteractionVisuals.hoverScale : 1)
            .animation(FluidInteractionVisuals.hoverAnimation, value: self.isSelected)
            .animation(FluidInteractionVisuals.hoverAnimation, value: self.isHovered)
    }
}

// MARK: - Primary (Prominent) Button

struct GlassButtonStyle: ButtonStyle {
    var height: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        GlassButton(configuration: configuration, height: self.height)
    }

    private struct GlassButton: View {
        @Environment(\.theme) private var theme
        @State private var isHovered = false
        let configuration: ButtonStyle.Configuration
        let height: CGFloat?

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
        }

        var body: some View {
            self.configuration.label
                .fontWeight(.semibold)
                .padding(.horizontal, self.theme.metrics.spacing.lg)
                .padding(.vertical, self.theme.metrics.spacing.sm)
                .frame(height: self.height ?? 36)
                .foregroundStyle(self.theme.palette.primaryText)
                .background(self.theme.materials.card, in: self.shape)
                .background(
                    self.shape
                        .fill(self.theme.palette.cardBackground)
                        .overlay(
                            self.shape.stroke(
                                self.theme.palette.cardBorder.opacity(self.isHovered ? 0.45 : 0.25),
                                lineWidth: 1
                            )
                        )
                )
                .overlay(
                    self.shape
                        .stroke(self.theme.palette.accent.opacity(self.isHovered ? 0.25 : 0.1), lineWidth: 1)
                        .blendMode(.plusLighter)
                )
                .shadow(
                    color: self.theme.palette.cardBorder.opacity(self.isHovered ? 0.45 : 0.22),
                    radius: self.isHovered ? self.theme.metrics.cardShadow.radius : max(self.theme.metrics.cardShadow.radius - 3, 2),
                    x: 0,
                    y: self.isHovered ? self.theme.metrics.cardShadow.y : self.theme.metrics.cardShadow.y - 2
                )
                .scaleEffect(FluidInteractionVisuals.scale(isPressed: self.configuration.isPressed, isHovered: self.isHovered))
                .animation(FluidInteractionVisuals.hoverAnimation, value: self.isHovered)
                .animation(FluidInteractionVisuals.pressedAnimation, value: self.configuration.isPressed)
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
                .background(
                    self.shape
                        .fill(self.baseGradient)
                        .overlay(
                            self.shape.stroke(
                                Color.white.opacity(self.isHovered ? 0.35 : 0.2),
                                lineWidth: 1
                            )
                        )
                )
                .shadow(
                    color: (self.isRecording ? Color(nsColor: .systemRed) : self.theme.palette.accent)
                        .opacity(self.isHovered ? 0.45 : 0.25),
                    radius: self.isHovered ? self.theme.metrics.elevatedCardShadow.radius : max(self.theme.metrics.cardShadow.radius - 2, 2),
                    x: 0,
                    y: self.isHovered ? self.theme.metrics.elevatedCardShadow.y : self.theme.metrics.cardShadow.y
                )
                .scaleEffect(FluidInteractionVisuals.scale(isPressed: self.configuration.isPressed, isHovered: self.isHovered))
                .animation(FluidInteractionVisuals.hoverAnimation, value: self.isHovered)
                .animation(FluidInteractionVisuals.pressedAnimation, value: self.configuration.isPressed)
                .onHover { self.isHovered = $0 }
        }
    }
}

// MARK: - Secondary Button

struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 42

    func makeBody(configuration: Configuration) -> some View {
        SecondaryButton(configuration: configuration, height: self.height)
    }

    private struct SecondaryButton: View {
        @Environment(\.theme) private var theme
        @State private var isHovered = false
        let configuration: ButtonStyle.Configuration
        let height: CGFloat

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
        }

        var body: some View {
            self.configuration.label
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .frame(height: self.height)
                .foregroundStyle(self.theme.palette.primaryText)
                .background(self.theme.materials.card, in: self.shape)
                .background(
                    self.shape
                        .fill(self.theme.palette.cardBackground)
                        .overlay(
                            self.shape.stroke(
                                self.theme.palette.cardBorder.opacity(self.isHovered ? 0.45 : 0.25),
                                lineWidth: 1
                            )
                        )
                )
                .shadow(
                    color: self.theme.palette.cardBorder.opacity(self.isHovered ? 0.35 : 0.15),
                    radius: self.isHovered ? self.theme.metrics.cardShadow.radius : max(self.theme.metrics.cardShadow.radius - 4, 1),
                    x: 0,
                    y: self.isHovered ? self.theme.metrics.cardShadow.y : self.theme.metrics.cardShadow.y - 2
                )
                .scaleEffect(FluidInteractionVisuals.scale(isPressed: self.configuration.isPressed, isHovered: self.isHovered))
                .animation(FluidInteractionVisuals.hoverAnimation, value: self.isHovered)
                .animation(FluidInteractionVisuals.pressedAnimation, value: self.configuration.isPressed)
                .onHover { self.isHovered = $0 }
        }
    }
}

// MARK: - Compact Button

struct CompactButtonStyle: ButtonStyle {
    var isReady: Bool = false
    var foreground: Color? = nil
    var borderColor: Color? = nil
    var height: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        CompactButton(
            configuration: configuration,
            isReady: self.isReady,
            foreground: self.foreground,
            borderColor: self.borderColor,
            height: self.height
        )
    }

    private struct CompactButton: View {
        @Environment(\.theme) private var theme
        @State private var isHovered = false
        let configuration: ButtonStyle.Configuration
        let isReady: Bool
        let foreground: Color?
        let borderColor: Color?
        let height: CGFloat

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
        }

        var body: some View {
            let border = self.borderColor ?? (self.isReady ? self.theme.palette.accent : self.theme.palette.cardBorder)
            let foregroundColor = self.foreground ?? self.theme.palette.primaryText
            let borderOpacity = self.borderColor == nil
                ? (self.isHovered ? 0.56 : 0.38)
                : (self.isHovered ? 0.64 : 0.48)

            self.configuration.label
                .fontWeight(.medium)
                .padding(.horizontal, self.theme.metrics.spacing.md)
                .frame(height: self.height)
                .foregroundStyle(foregroundColor)
                .background(self.theme.materials.card, in: self.shape)
                .background(
                    self.shape
                        .fill(self.theme.palette.cardBackground)
                        .overlay(
                            self.shape.stroke(
                                border.opacity(borderOpacity),
                                lineWidth: 1
                            )
                        )
                )
                .shadow(
                    color: border.opacity(self.isHovered ? 0.18 : 0.06),
                    radius: self.isHovered ? 4 : 1.5,
                    x: 0,
                    y: self.isHovered ? 1 : 0.5
                )
                .scaleEffect(FluidInteractionVisuals.scale(isPressed: self.configuration.isPressed, isHovered: self.isHovered))
                .animation(FluidInteractionVisuals.hoverAnimation, value: self.isHovered)
                .animation(FluidInteractionVisuals.pressedAnimation, value: self.configuration.isPressed)
                .onHover { self.isHovered = $0 }
        }
    }
}

// MARK: - Accent Filled Button (Solid accent background)

struct AccentButtonStyle: ButtonStyle {
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        AccentButton(configuration: configuration, compact: self.compact)
    }

    private struct AccentButton: View {
        @Environment(\.theme) private var theme
        @State private var isHovered = false
        let configuration: ButtonStyle.Configuration
        let compact: Bool

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: self.compact ? 8 : self.theme.metrics.corners.md, style: .continuous)
        }

        var body: some View {
            self.configuration.label
                .fontWeight(.semibold)
                .padding(.horizontal, self.compact ? 12 : self.theme.metrics.spacing.lg)
                .padding(.vertical, self.compact ? 8 : self.theme.metrics.spacing.md)
                .frame(minHeight: self.compact ? 32 : 36)
                .foregroundStyle(Color.white)
                .background(
                    self.shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    self.theme.palette.accent,
                                    self.theme.palette.accent.opacity(0.85),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    self.shape
                        .stroke(Color.white.opacity(self.isHovered ? 0.3 : 0.15), lineWidth: 1)
                )
                .shadow(
                    color: self.theme.palette.accent.opacity(self.isHovered ? 0.5 : 0.3),
                    radius: self.isHovered ? 6 : 4,
                    x: 0,
                    y: self.isHovered ? 3 : 2
                )
                .scaleEffect(FluidInteractionVisuals.scale(isPressed: self.configuration.isPressed, isHovered: self.isHovered))
                .animation(FluidInteractionVisuals.hoverAnimation, value: self.isHovered)
                .animation(FluidInteractionVisuals.pressedAnimation, value: self.configuration.isPressed)
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
                .background(
                    self.shape
                        .fill(self.theme.palette.accent.opacity(self.isHovered ? 0.9 : 0.8))
                )
                .shadow(
                    color: self.theme.palette.accent.opacity(self.isHovered ? 0.45 : 0.25),
                    radius: self.isHovered ? 6 : 3,
                    x: 0,
                    y: self.isHovered ? 3 : 1
                )
                .scaleEffect(FluidInteractionVisuals.scale(isPressed: self.configuration.isPressed, isHovered: self.isHovered))
                .animation(FluidInteractionVisuals.hoverAnimation, value: self.isHovered)
                .animation(FluidInteractionVisuals.pressedAnimation, value: self.configuration.isPressed)
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
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let row = self.theme.metrics.formRow
        let shape = RoundedRectangle(cornerRadius: row.cornerRadius, style: .continuous)

        content
            .padding(.horizontal, row.horizontalPadding)
            .padding(.vertical, row.verticalPadding)
            .background(
                shape
                    .fill(self.theme.materials.formRow.opacity(row.materialOpacity))
                    .overlay(
                        shape.stroke(self.theme.palette.cardBorder.opacity(row.borderOpacity), lineWidth: 1)
                    )
            )
    }
}

// MARK: - Searchable Picker Chrome

struct FluidPickerDisclosureIcon: View {
    @Environment(\.theme) private var theme
    var backgroundOpacity: Double

    var body: some View {
        let picker = self.theme.metrics.pickerControl

        Image(systemName: "chevron.down")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(width: picker.disclosureSize, height: picker.disclosureSize)
            .background(
                Circle()
                    .fill(self.theme.palette.cardBackground.opacity(self.backgroundOpacity))
                    .overlay(
                        Circle()
                            .stroke(self.theme.palette.cardBorder.opacity(picker.disclosureBorderOpacity), lineWidth: 1)
                    )
            )
    }
}

struct SearchablePickerControlChrome: ViewModifier {
    @Environment(\.theme) private var theme
    let width: CGFloat?
    let height: CGFloat?
    let usesMaterial: Bool
    let showsShadow: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let picker = self.theme.metrics.pickerControl
        let shape = RoundedRectangle(cornerRadius: picker.cornerRadius, style: .continuous)
        let control = content
            .frame(width: self.width, alignment: .leading)
            .frame(maxWidth: self.width == nil ? .infinity : nil, alignment: .leading)
            .padding(.horizontal, picker.horizontalPadding)
            .padding(.vertical, picker.verticalPadding)
            .frame(height: self.height)
            .contentShape(Rectangle())

        if self.usesMaterial {
            control
                .background(self.theme.materials.card, in: shape)
                .background(self.pickerSurface(shape, picker: picker))
                .shadow(
                    color: self.theme.palette.cardBorder.opacity(self.showsShadow ? 0.18 : 0),
                    radius: self.showsShadow ? 3 : 0,
                    x: 0,
                    y: self.showsShadow ? 1 : 0
                )
        } else {
            control
                .background(self.pickerSurface(shape, picker: picker))
        }
    }

    private func pickerSurface(
        _ shape: RoundedRectangle,
        picker: AppTheme.Metrics.PickerControl
    ) -> some View {
        shape
            .fill(self.theme.palette.cardBackground)
            .overlay(
                shape.stroke(self.theme.palette.cardBorder.opacity(picker.borderOpacity), lineWidth: 1)
            )
    }
}

struct SearchablePickerSearchFieldChrome: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let picker = self.theme.metrics.pickerControl
        let shape = RoundedRectangle(cornerRadius: picker.cornerRadius, style: .continuous)

        content
            .padding(self.theme.metrics.spacing.sm)
            .background(
                shape
                    .fill(self.theme.palette.contentBackground)
                    .overlay(
                        shape.stroke(self.theme.palette.cardBorder.opacity(picker.searchBorderOpacity), lineWidth: 1)
                    )
            )
    }
}

extension View {
    func formRowStyle() -> some View {
        modifier(FormRowStyle())
    }

    func searchablePickerControlChrome(
        width: CGFloat? = nil,
        height: CGFloat? = nil,
        usesMaterial: Bool = false,
        showsShadow: Bool = false
    ) -> some View {
        modifier(SearchablePickerControlChrome(
            width: width,
            height: height,
            usesMaterial: usesMaterial,
            showsShadow: showsShadow
        ))
    }

    func searchablePickerSearchFieldChrome() -> some View {
        modifier(SearchablePickerSearchFieldChrome())
    }

    func searchablePickerSelectedRowBackground(isSelected: Bool) -> some View {
        modifier(SearchablePickerSelectedRowBackground(isSelected: isSelected))
    }
}

private struct SearchablePickerSelectedRowBackground: ViewModifier {
    @Environment(\.theme) private var theme
    let isSelected: Bool

    func body(content: Content) -> some View {
        content.background(
            self.isSelected
                ? self.theme.palette.accent.opacity(self.theme.metrics.pickerControl.selectedRowOpacity)
                : Color.clear
        )
    }
}

// MARK: - Square Icon Button Style (no horizontal padding, fixed square)

struct SquareIconButtonStyle: ButtonStyle {
    var foreground: Color? = nil
    var borderColor: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        SquareIconButton(
            configuration: configuration,
            foreground: self.foreground,
            borderColor: self.borderColor
        )
    }

    private struct SquareIconButton: View {
        @Environment(\.theme) private var theme
        @State private var isHovered = false
        let configuration: ButtonStyle.Configuration
        let foreground: Color?
        let borderColor: Color?

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
        }

        var body: some View {
            let border = self.borderColor ?? self.theme.palette.cardBorder
            let borderOpacity = self.borderColor == nil
                ? (self.isHovered ? 0.8 : 0.6)
                : (self.isHovered ? 0.84 : 0.68)
            let foregroundColor = self.foreground ?? self.theme.palette.primaryText

            self.configuration.label
                .foregroundStyle(foregroundColor)
                .background(self.theme.materials.card, in: self.shape)
                .background(
                    self.shape
                        .fill(self.theme.palette.cardBackground)
                        .overlay(
                            self.shape.stroke(
                                border.opacity(borderOpacity),
                                lineWidth: 1
                            )
                        )
                )
                .shadow(
                    color: border.opacity(self.isHovered ? 0.18 : 0.06),
                    radius: self.isHovered ? 4 : 1.5,
                    x: 0,
                    y: self.isHovered ? 1 : 0.5
                )
                .scaleEffect(FluidInteractionVisuals.scale(isPressed: self.configuration.isPressed, isHovered: self.isHovered))
                .animation(FluidInteractionVisuals.hoverAnimation, value: self.isHovered)
                .animation(FluidInteractionVisuals.pressedAnimation, value: self.configuration.isPressed)
                .onHover { self.isHovered = $0 }
        }
    }
}
