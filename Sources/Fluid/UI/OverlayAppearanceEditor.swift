import SwiftUI

/// Static samples use the production surface and production sizing, without microphone activity.
struct OverlayAppearanceEditor: View {
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var backdrop = 0

    private var isGlass: Bool {
        [.smokedGlass, .clearGlass, .aurora].contains(self.settings.overlayMaterial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Make it yours")
                        .font(.fluidSystem(size: 26, weight: .bold))
                    Text("A little personality for every thought.")
                        .font(.fluidSystem(size: 13))
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                Spacer()
                Button {
                    self.settings.overlayMaterial = .smokedGlass
                    self.settings.overlayGlassOpacity = SettingsStore.defaultOverlayGlassOpacity
                    self.settings.overlayTint = .ocean
                    self.settings.overlayHighlight = 0.5
                    self.settings.overlayEdgeLightEnabled = true
                } label: {
                    Label("Reset look", systemImage: "arrow.counterclockwise")
                        .font(self.theme.typography.bodyStrong)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                .fluidOutlinedButton()
                .controlSize(.regular)
            }

            HStack {
                Text("Try a backdrop")
                    .font(self.theme.typography.bodyStrong)
                Spacer()
                HStack(spacing: 4) {
                    self.backdropOption("Light", symbol: "sun.max.fill", value: 1)
                    self.backdropOption("Dark", symbol: "moon.fill", value: 0)
                }
                .padding(4)
                .background(self.theme.palette.secondaryText.opacity(0.08), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(self.theme.palette.secondaryText.opacity(0.12), lineWidth: 1)
                }
            }

            self.sample

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 60), spacing: 10), count: 5), spacing: 10) {
                ForEach(SettingsStore.OverlayMaterial.allCases, id: \.self) { material in
                    Button {
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
                                    .font(self.theme.typography.caption)
                                    .multilineTextAlignment(.center)
                                if self.settings.overlayMaterial == material {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                            }
                            .foregroundStyle(.primary)
                            .frame(minHeight: 30)
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity)
                        .background(
                            self.settings.overlayMaterial == material ? self.theme.palette.accent.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 16)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(material.displayName)
                    .accessibilityAddTraits(self.settings.overlayMaterial == material ? .isSelected : [])
                }
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, alignment: .center)

            Text(self.settings.overlayMaterial.detail)
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.theme.palette.secondaryText)

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
                HStack(spacing: 12) {
                    Text("Color").font(self.theme.typography.bodySmall)
                    Spacer()
                    ForEach(SettingsStore.OverlayTint.allCases, id: \.self) { tint in
                        Button {
                            self.settings.overlayTint = tint
                        } label: {
                            Circle().fill(tint.color)
                                .frame(width: 26, height: 26)
                                .overlay {
                                    if self.settings.overlayTint == tint {
                                        Image(systemName: "checkmark")
                                            .font(.fluidSystem(size: 11, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .padding(3)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tint.rawValue.capitalized)
                        .accessibilityAddTraits(self.settings.overlayTint == tint ? .isSelected : [])
                    }
                }
            }

            if self.settings.overlaySize == .pill {
                // Same row shape as "Color" and the knob headers: title left, control right.
                HStack(spacing: 12) {
                    Text("Show edge light").font(self.theme.typography.bodySmall)
                    Spacer()
                    Toggle("Show edge light", isOn: self.$settings.overlayEdgeLightEnabled)
                        .toggleStyle(.switch)
                        .tint(self.theme.palette.accent)
                        .labelsHidden()
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
            if self.reduceTransparency {
                Text("Reduce Transparency is on in macOS. Glass uses a solid finish.")
                    .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
            }
        }
    }

    private var sample: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let layout = BottomOverlayView.LayoutConstants.get(for: self.settings.overlaySize)
                let scale = min(1, max(0.1, (proxy.size.width - 40) / layout.containerWidth))
                OverlayAppearanceSample(size: self.settings.overlaySize, appearance: self.settings.bottomOverlayAppearance)
                    .scaleEffect(scale)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .frame(height: self.settings.overlaySize == .large ? 210 : 145)
            .background {
                LinearGradient(
                    colors: self.backdrop == 0
                        ? [Color(red: 0.12, green: 0.19, blue: 0.28), Color(red: 0.42, green: 0.28, blue: 0.37)]
                        : [.gray.opacity(0.2), .white.opacity(0.8)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .background(self.theme.palette.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func backdropOption(_ title: String, symbol: String, value: Int) -> some View {
        let selected = self.backdrop == value
        return Button {
            self.backdrop = value
        } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.fluidSystem(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? (value == 1 ? Color.orange : Color.indigo) : self.theme.palette.secondaryText)
                Text(title)
                    .font(.fluidSystem(size: 12, weight: .semibold))
            }
            .foregroundStyle(selected ? self.theme.palette.primaryText : self.theme.palette.secondaryText)
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .background {
                if selected {
                    Capsule()
                        .fill(self.theme.palette.cardBackground)
                        .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) sample backdrop")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func knob(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, low: String, high: String) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title).font(self.theme.typography.bodySmall)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .font(self.theme.typography.caption.monospacedDigit()).foregroundStyle(self.theme.palette.secondaryText)
            }
            HStack {
                Text(low).font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText).frame(width: 48, alignment: .leading)
                Slider(value: value, in: range, step: 0.05).accessibilityLabel(title)
                Text(high).font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText).frame(width: 48, alignment: .trailing)
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
        .preferredColorScheme(.dark)
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
