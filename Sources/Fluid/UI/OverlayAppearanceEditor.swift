import SwiftUI

/// The overlay's look, as rows for a Settings group: a live preview, the styles, the knobs the
/// chosen style has, and a reset. Samples use the production surface and sizing, without microphone
/// activity, and the swatches show real overlay colors, since those are the values.
struct OverlayAppearanceEditor: View {
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var backdrop = 0

    private var isGlass: Bool {
        [.smokedGlass, .clearGlass, .aurora].contains(self.settings.overlayMaterial)
    }

    var body: some View {
        FluidSettingsBlock {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                HStack {
                    Text("Preview on a")
                        .fluidText(.label)
                        .foregroundStyle(self.theme.look.tertiaryText)
                    HStack(spacing: 2) {
                        self.backdropOption("Light", symbol: "sun.max", value: 1)
                        self.backdropOption("Dark", symbol: "moon", value: 0)
                    }
                    Text("backdrop")
                        .fluidText(.label)
                        .foregroundStyle(self.theme.look.tertiaryText)
                    Spacer()
                }
                self.sample
            }
        }

        FluidSettingsBlock {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 60), spacing: 8), count: 5), spacing: 8) {
                    ForEach(SettingsStore.OverlayMaterial.allCases, id: \.self) { material in
                        self.materialTile(material)
                    }
                }
                Text(self.settings.overlayMaterial.detail)
                    .fluidText(.body)
                    .foregroundStyle(self.theme.look.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if self.isGlass {
            self.knob(
                "Transparency",
                value: Binding(
                    get: { 1 - self.settings.overlayGlassOpacity },
                    set: { self.settings.overlayGlassOpacity = 1 - $0 }
                ),
                range: 0...0.75,
                low: "Smoky",
                high: "Airy"
            )
            .disabled(self.reduceTransparency)
        }

        if [.velvet, .aurora].contains(self.settings.overlayMaterial) {
            FluidSettingsRow(title: "Color") {
                HStack(spacing: 2) {
                    ForEach(SettingsStore.OverlayTint.allCases, id: \.self) { tint in
                        Button {
                            self.settings.overlayTint = tint
                        } label: {
                            Circle().fill(tint.color)
                                .frame(width: 22, height: 22)
                                .overlay {
                                    if self.settings.overlayTint == tint {
                                        Image(systemName: "checkmark")
                                            .font(.fluidSystem(size: 10, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(FluidHoverIconButtonStyle())
                        .accessibilityLabel(tint.rawValue.capitalized)
                        .accessibilityAddTraits(self.settings.overlayTint == tint ? .isSelected : [])
                    }
                }
            }
        }

        if self.settings.overlaySize == .pill {
            FluidSettingsRow(title: "Show edge light") {
                Toggle("Show edge light", isOn: self.$settings.overlayEdgeLightEnabled)
                    .fluidSwitch()
            }
        }
        if self.settings.overlayMaterial != .original, self.settings.overlaySize != .pill || self.settings.overlayEdgeLightEnabled {
            self.knob(
                "Edge light",
                value: self.$settings.overlayHighlight,
                range: 0...1,
                low: "Soft",
                high: "Defined"
            )
        }

        FluidSettingsRow(
            title: "Reset look",
            description: "Go back to Smoked Glass with its default settings.",
            footnote: self.reduceTransparency ? "Reduce Transparency is on in macOS. Glass uses a solid finish." : nil
        ) {
            Button("Reset") {
                self.settings.overlayMaterial = .smokedGlass
                self.settings.overlayGlassOpacity = SettingsStore.defaultOverlayGlassOpacity
                self.settings.overlayTint = .ocean
                self.settings.overlayHighlight = 0.5
                self.settings.overlayEdgeLightEnabled = true
            }
            .fluidAction()
        }
    }

    /// A style tile: a small swatch of the real material, its name, and a tick on the chosen one.
    private func materialTile(_ material: SettingsStore.OverlayMaterial) -> some View {
        let isSelected = self.settings.overlayMaterial == material
        return Button {
            self.settings.overlayMaterial = material
        } label: {
            VStack(spacing: 8) {
                Image(systemName: material.symbol)
                    .font(.fluidSystem(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .bottomOverlaySurface(
                        .resolve(
                            material: material,
                            opacity: self.settings.overlayGlassOpacity,
                            tint: self.settings.overlayTint,
                            highlight: self.settings.overlayHighlight
                        ),
                        cornerRadius: 12
                    )
                HStack(spacing: 4) {
                    Text(material.displayName)
                        .fluidText(.label)
                        .multilineTextAlignment(.center)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.fluidSystem(size: 9, weight: .bold))
                    }
                }
                .foregroundStyle(self.theme.look.text)
                .frame(minHeight: 30)
            }
            .padding(8)
        }
        .fluidSelectableRow(isSelected: isSelected, cornerRadius: 14)
        .accessibilityLabel(material.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var sample: some View {
        GeometryReader { proxy in
            let layout = BottomOverlayView.LayoutConstants.get(for: self.settings.overlaySize)
            let scale = min(1, max(0.1, (proxy.size.width - 40) / layout.containerWidth))
            OverlayAppearanceSample(size: self.settings.overlaySize, appearance: self.settings.bottomOverlayAppearance)
                .scaleEffect(scale)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: self.settings.overlaySize == .large ? 210 : 145)
        .background {
            // Neutral backdrops, so the overlay's own material is the only color in the preview.
            LinearGradient(
                colors: self.backdrop == 0
                    ? [Color(white: 0.16), Color(white: 0.34)]
                    : [Color(white: 0.78), Color(white: 0.96)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func backdropOption(_ title: String, symbol: String, value: Int) -> some View {
        let selected = self.backdrop == value
        return Button {
            self.backdrop = value
        } label: {
            Label(title, systemImage: symbol)
                .fluidText(.label)
                .foregroundStyle(selected ? self.theme.look.text : self.theme.look.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .fluidSelectableRow(isSelected: selected, cornerRadius: 8, fillsWidth: false)
        .accessibilityLabel("\(title) sample backdrop")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A titled slider with its value, and words for each end.
    private func knob(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, low: String, high: String) -> some View {
        FluidSettingsBlock {
            VStack(spacing: 6) {
                HStack {
                    Text(title)
                        .fluidText(.rowTitle)
                        .foregroundStyle(self.theme.look.text)
                    Spacer()
                    Text("\(Int((value.wrappedValue * 100).rounded()))%")
                        .fluidText(.label)
                        .monospacedDigit()
                        .foregroundStyle(self.theme.look.secondaryText)
                }
                HStack {
                    Text(low).fluidText(.label).foregroundStyle(self.theme.look.secondaryText).frame(width: 48, alignment: .leading)
                    Slider(value: value, in: range, step: 0.05)
                        .tint(self.theme.look.switchOn)
                        .accessibilityLabel(title)
                    Text(high).fluidText(.label).foregroundStyle(self.theme.look.secondaryText).frame(width: 48, alignment: .trailing)
                }
            }
        }
    }
}

private struct OverlayAppearanceSample: View {
    private static let appIcon = NSImage(named: "AppIcon") ?? NSApplication.shared.applicationIconImage ?? NSImage(size: NSSize(width: 32, height: 32))
    let size: SettingsStore.OverlaySize
    let appearance: BottomOverlayAppearance

    private var layout: BottomOverlayView.LayoutConstants { .get(for: self.size) }

    var body: some View {
        VStack(alignment: .leading, spacing: self.layout.vPadding / 2) {
            if self.layout.showsPreview {
                Text(self.size == .large ? "A little space for your next big idea.\nMake every word feel like you." : "Make every word feel like you.")
                    .font(.fluidSystem(size: self.layout.transFontSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.96))
                    .lineLimit(self.size == .small ? 1 : 3)
                    .frame(maxWidth: .infinity, minHeight: self.size == .large ? self.layout.previewBoxHeight : 20, alignment: .topLeading)
            }
            HStack {
                Image(nsImage: Self.appIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: self.layout.iconSize, height: self.layout.iconSize)
                    .accessibilityLabel("FluidVoice")
                Spacer(minLength: 4)
                HStack(spacing: self.layout.barSpacing) {
                    ForEach(0..<self.layout.barCount, id: \.self) { index in
                        Capsule()
                            .fill(.white.opacity(0.88))
                            .frame(
                                width: self.layout.barWidth,
                                height: self.layout.minBarHeight + CGFloat([0.1, 0.4, 0.7, 0.25, 0.55, 0.9, 0.45, 0.2, 0.6, 0.4, 0.1][index]) * (self.layout.maxBarHeight - self.layout.minBarHeight)
                            )
                    }
                }
                .frame(height: self.layout.waveformHeight)
                if self.layout.showsModeLabel {
                    Spacer(minLength: 4)
                    Label("Basic", systemImage: "bolt.fill")
                        .font(.fluidSystem(size: self.layout.modeFontSize, weight: .semibold))
                }
                if self.layout.showsTopControls {
                    Image(systemName: "chevron.down").font(.fluidSystem(size: 9))
                    Image(systemName: "ellipsis").padding(.leading, 10)
                }
            }
            .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, self.layout.hPadding)
        .padding(.vertical, self.layout.vPadding)
        .frame(width: self.layout.containerWidth)
        .bottomOverlaySurface(self.appearance, cornerRadius: self.layout.cornerRadius, castsShadow: true)
        // Only the sample is dark; preferredColorScheme would turn the whole Settings window dark.
        .environment(\.colorScheme, .dark)
    }
}

private extension SettingsStore.OverlayMaterial {
    var symbol: String {
        switch self {
        case .original: return "circle.fill"
        case .smokedGlass: return "moon"
        case .clearGlass: return "drop"
        case .velvet: return "square.fill"
        case .aurora: return "sparkles"
        }
    }

    var detail: String {
        switch self {
        case .original: return "The classic. Solid black, quietly out of the way."
        case .smokedGlass: return "Dark glass with a soft edge. Familiar, with a little depth."
        case .clearGlass: return "Light-catching glass that lets your desktop show through."
        case .velvet: return "A matte, tinted finish. Rich color without transparency."
        case .aurora: return "Two tones of glass, softly blended. Choose your color."
        }
    }
}
