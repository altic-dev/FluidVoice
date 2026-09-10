import SwiftUI

/// Pure presentation: the only emitted action is browsing, never activation or persistence.
struct FluidIntelligenceModelCarousel<Controls: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    let models: [PrivateAIRegisteredModel]
    let previewID: String
    let selectedID: String
    var recommendedModelID: String? = nil
    let onBrowse: (String) -> Void
    @ViewBuilder let controls: (PrivateAIRegisteredModel) -> Controls
    @State private var upcomingPreviewID: String?

    private var spacing: AppTheme.Metrics.Spacing { self.theme.metrics.spacing }
    private var itemIDs: [String] { self.models.map(\.id) + PrivateAIUpcomingModel.allCases.map(\.id) }
    private var displayedPreviewID: String { self.upcomingPreviewID ?? self.previewID }

    var body: some View {
        VStack(spacing: self.spacing.sm) {
            GeometryReader { geometry in
                let cardWidth = min(AppTheme.Metrics.Showcase.cardMaxWidth, geometry.size.width * 0.44)
                let sideWidth = min(AppTheme.Metrics.Showcase.sideCardMaxWidth, max(60, (geometry.size.width - cardWidth - self.spacing.md * 2 - 80) / 2))
                let stride = cardWidth / 2 + sideWidth / 2 + self.spacing.md
                ZStack {
                    ForEach(self.itemIDs.filter { abs(self.carouselPosition($0)) <= 1 }, id: \.self) { id in
                        let position = self.carouselPosition(id)
                        Group {
                            if let model = self.models.first(where: { $0.id == id }) {
                                FluidModelShowcaseCard(
                                    model: model,
                                    isPreview: position == 0,
                                    isSelected: self.selectedID == model.id,
                                    compact: position != 0,
                                    isRecommended: self.recommendedModelID == model.id,
                                    browse: { self.browse(id) }
                                )
                            } else if let upcoming = PrivateAIUpcomingModel(rawValue: id) {
                                self.upcomingCard(upcoming, compact: position != 0)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if position == 0, let model = self.models.first(where: { $0.id == id }) {
                                self.controls(model).padding(.horizontal, 16).padding(.bottom, 16)
                            }
                        }
                        .frame(width: position == 0 ? cardWidth : sideWidth, height: AppTheme.Metrics.Showcase.cardHeight)
                        .saturation(position == 0 ? 1 : 0.12)
                        .opacity(position == 0 || self.contrast == .increased ? 1 : 0.65)
                        .scaleEffect(position == 0 ? 1 : 0.90)
                        .offset(x: CGFloat(position) * stride)
                        .zIndex(position == 0 ? 1 : 0)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .overlay(alignment: .leading) { self.carouselArrow(forward: false) }
                .overlay(alignment: .trailing) { self.carouselArrow(forward: true) }
                .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    self.advanceCarousel(forward: value.translation.width < 0)
                })
            }
            .frame(height: AppTheme.Metrics.Showcase.stageHeight)

            HStack(spacing: self.spacing.xs) {
                ForEach(self.itemIDs, id: \.self) { id in
                    Button { self.browse(id) } label: {
                        Circle()
                            .fill(self.displayedPreviewID == id ? FluidBrandColors.blue : self.theme.palette.secondaryText.opacity(0.4))
                            .frame(width: self.displayedPreviewID == id ? 10 : 7, height: self.displayedPreviewID == id ? 10 : 7)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show \(self.title(for: id))")
                    .accessibilityValue(self.displayedPreviewID == id ? "Current page" : "")
                }
            }
        }
        .onChange(of: self.previewID) { _, _ in self.upcomingPreviewID = nil }
    }

    private func carouselPosition(_ id: String) -> Int {
        PrivateAIModelCarouselNavigation.position(of: id, in: self.itemIDs, current: self.displayedPreviewID)
    }

    private func browse(_ id: String) {
        withAnimation(self.reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            if PrivateAIUpcomingModel(rawValue: id) != nil {
                self.upcomingPreviewID = id
            } else if self.models.contains(where: { $0.id == id }) {
                self.upcomingPreviewID = nil
                self.onBrowse(id)
            }
        }
    }

    private func advanceCarousel(forward: Bool) {
        guard let id = PrivateAIModelCarouselNavigation.next(in: self.itemIDs, current: self.displayedPreviewID, forward: forward) else { return }
        self.browse(id)
    }

    private func carouselArrow(forward: Bool) -> some View {
        Button { self.advanceCarousel(forward: forward) } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(self.theme.typography.sectionTitle)
                .foregroundStyle(self.theme.palette.primaryText)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .fluidGlassAction(circular: true)
        .accessibilityLabel(forward ? "Next model" : "Previous model")
        .disabled(self.itemIDs.count < 2)
    }

    private func title(for id: String) -> String {
        PrivateAIUpcomingModel(rawValue: id)?.title
            ?? self.models.first(where: { $0.id == id })?.displayName.replacingOccurrences(of: "Fluid-1", with: "Fluid 1")
            ?? id
    }

    private func upcomingCard(_ model: PrivateAIUpcomingModel, compact: Bool) -> some View {
        Button { self.browse(model.id) } label: {
            VStack(alignment: .leading, spacing: self.spacing.md) {
                Text("Coming soon")
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.theme.palette.secondaryText)
                Text(model.title)
                    .font(compact ? self.theme.typography.sectionTitle : self.theme.typography.title)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Not available yet")
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.tertiaryText)
                Spacer(minLength: 0)
                Divider()
                Label("Coming soon", systemImage: "clock")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            .padding(self.spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: AppTheme.Metrics.Showcase.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Metrics.Showcase.cardRadius)
                    .strokeBorder(self.theme.palette.cardBorder, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.Showcase.cardRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Preview \(model.title), coming soon")
        .accessibilityHint("Preview only. This model cannot be activated or downloaded.")
    }
}
