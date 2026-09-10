import SwiftUI

/// Presentation only: model browsing is injected by the carousel.
struct FluidModelShowcaseCard: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovered = false
    @State private var showsInfo = false
    let model: PrivateAIRegisteredModel
    let isPreview: Bool
    let isSelected: Bool
    let compact: Bool
    var isRecommended = false
    let browse: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AppTheme.Metrics.Showcase.cardRadius, style: .continuous)
    }

    var body: some View {
        let presentation = PrivateAIModelPresentation.forModel(id: self.model.id)
        Button(action: self.browse) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                Color.clear.frame(height: 20)
                    .overlay(alignment: .leading) {
                        if self.isRecommended {
                            Text(self.compact ? "Recommended" : "Recommended for your Mac")
                                .font(self.theme.typography.captionStrong)
                                .foregroundStyle(FluidBrandColors.blue)
                                .lineLimit(1).minimumScaleFactor(0.8)
                                .padding(.trailing, 24)
                                .help("Based on your Mac’s RAM. You can choose either model.")
                        }
                    }
                HStack(spacing: 8) {
                    Text(self.model.displayName.replacingOccurrences(of: "Fluid-1", with: "Fluid 1"))
                        .font(self.compact ? self.theme.typography.sectionTitle : self.theme.typography.title)
                        .foregroundStyle(self.theme.palette.primaryText)
                        .lineLimit(2).minimumScaleFactor(0.85)
                    if self.isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(FluidBrandColors.blue)
                            .accessibilityLabel("Selected")
                    }
                }
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                        Text(presentation.summary)
                            .font(self.theme.typography.bodyStrong)
                            .foregroundStyle(self.theme.palette.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(presentation.useCase)
                            .font(self.theme.typography.body)
                            .foregroundStyle(self.theme.palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(3)
                    }
                    .opacity(self.showsInfo ? 0 : 1)
                    .accessibilityHidden(self.showsInfo)
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                        self.infoRow("Languages", value: presentation.language)
                        if let bytes = self.model.artifact.byteCount, bytes > 0 {
                            self.infoRow("Download size", value: "≈\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(self.showsInfo ? 1 : 0)
                    .accessibilityHidden(!self.showsInfo)
                }
                .animation(self.reduceMotion ? nil : .easeInOut(duration: 0.16), value: self.showsInfo)
                Spacer(minLength: self.theme.metrics.spacing.sm)
                // Separate sibling controls are overlaid by the carousel; never nest buttons.
                Color.clear.frame(height: 64)
            }
            .padding(self.theme.metrics.spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                self.shape.fill(self.colorScheme == .dark ? Color(red: 0.025, green: 0.04, blue: 0.095) : self.theme.palette.elevatedCardBackground)
                if !self.reduceTransparency {
                    self.shape.fill(LinearGradient(
                        colors: [FluidBrandColors.blue.opacity(self.isPreview ? 0.16 : 0.08), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                }
            }
            .overlay {
                self.shape.strokeBorder(
                    self.isPreview ? FluidBrandColors.blue.opacity(self.contrast == .increased ? 1 : 0.5) : self.theme.palette.cardBorder,
                    lineWidth: self.contrast == .increased ? 2 : 1
                )
            }
            .shadow(color: .black.opacity(self.colorScheme == .dark ? 0.28 : 0.08), radius: self.isPreview ? 12 : 4, y: self.isPreview ? 8 : 2)
            .brightness(self.hovered ? 0.01 : 0)
            .contentShape(self.shape)
        }
        .buttonStyle(.plain)
        .onHover { self.hovered = $0 }
        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.12), value: self.hovered)
        .accessibilityLabel("Preview \(self.model.displayName.replacingOccurrences(of: "Fluid-1", with: "Fluid 1"))")
        .accessibilityValue([self.isPreview ? "Previewed" : "", self.isRecommended ? "Recommended for your Mac" : ""].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityHint(self.showsInfo ? self.infoAccessibilityDescription : "\(presentation.summary). \(presentation.useCase) Browse without changing the selected model.")
        .overlay(alignment: .topTrailing) {
            // Sibling to the browse button: opening details never selects or activates a model.
            Button { self.showsInfo.toggle() } label: {
                Image(systemName: self.showsInfo ? "xmark.circle" : "info.circle")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(self.showsInfo ? "Close model information" : "About \(self.model.displayName)")
            .accessibilityLabel(self.showsInfo ? "Close information for \(self.model.displayName)" : "About \(self.model.displayName)")
            .accessibilityValue(self.showsInfo ? "Expanded" : "Collapsed")
            .padding(14)
        }
    }

    private func infoRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: self.theme.metrics.spacing.sm) {
            Text(title).foregroundStyle(self.theme.palette.secondaryText)
            Spacer(minLength: 0)
            Text(value).foregroundStyle(self.theme.palette.primaryText)
                .multilineTextAlignment(.trailing)
        }
        .font(self.theme.typography.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var infoAccessibilityDescription: String {
        let language = PrivateAIModelPresentation.forModel(id: self.model.id).language
        guard let bytes = self.model.artifact.byteCount, bytes > 0 else { return "Languages: \(language)" }
        return "Languages: \(language). Download size: approximately \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))."
    }
}

struct FluidModelMetrics: View {
    @Environment(\.theme) private var theme
    let modelID: String

    var body: some View {
        let presentation = PrivateAIModelPresentation.forModel(id: self.modelID)
        if let intelligence = presentation.intelligence, let speed = presentation.speed {
            VStack(spacing: self.theme.metrics.spacing.xs) {
                FluidModelMetric(label: "Intelligence", value: intelligence, tint: FluidBrandColors.blue, compact: true)
                FluidModelMetric(label: "Speed", value: speed, tint: .teal, compact: true)
            }
            .frame(width: AppTheme.Metrics.Showcase.compactMetricWidth)
            .help("Illustrative design preview — not benchmark scores")
        }
    }
}

/// Five bounded static segments: no work beyond rendering immutable preview values.
private struct FluidModelMetric: View {
    @Environment(\.theme) private var theme
    let label: String
    let value: Int
    let tint: Color
    let compact: Bool

    var body: some View {
        HStack(spacing: self.theme.metrics.spacing.xs) {
            Text(self.label)
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: self.compact ? 58 : 64, alignment: .leading)
            HStack(spacing: 3) {
                ForEach(1...5, id: \.self) { step in
                    Capsule()
                        .fill(step <= self.value ? self.tint : self.theme.palette.secondaryText.opacity(0.25))
                        .frame(maxWidth: .infinity)
                        .frame(height: 3)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(self.label): illustrative level \(self.value) of 5, not a benchmark score")
    }
}
