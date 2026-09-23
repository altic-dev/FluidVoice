import SwiftUI

struct ReleaseHighlightsView: View {
    let canExplore: Bool
    let content: ReleaseHighlightsContent
    let onClose: (ReleaseHighlightsContent.Destination?) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("FLUIDVOICE \(self.content.release)")
                        .font(self.theme.typography.captionStrong)
                        .tracking(2)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    Text(self.content.title)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(self.theme.palette.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    Text(self.content.subtitle)
                        .font(self.theme.typography.body)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                Spacer()
                Button { self.onClose(nil) } label: {
                    Image(systemName: "xmark")
                }
                .fluidGlassAction(circular: true, quiet: true)
                .accessibilityLabel("Close what’s new")
                .help("Close (Esc)")
            }
            HStack(alignment: .top, spacing: 18) {
                ForEach(self.content.features) { feature in
                    self.feature(feature)
                }
            }
            Text("Always here in Help → What’s new.")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.tertiaryText)
                .frame(maxWidth: .infinity)
        }
        .padding(30)
        .frame(width: 800)
        .background(self.theme.palette.contentBackground)
        .onExitCommand { self.onClose(nil) }
    }

    private func feature(_ feature: ReleaseHighlightsContent.Feature) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ReleaseFeaturePreview(kind: feature.preview)
                .frame(height: 156)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
                .padding(.bottom, 20)
            Text(feature.eyebrow)
                .font(.system(size: 9, weight: .semibold))
                .tracking(1)
                .foregroundStyle(self.theme.palette.secondaryText)
                .padding(.bottom, 8)
            Text(feature.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(self.theme.palette.primaryText)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 10)
            Text(feature.detail)
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.theme.palette.secondaryText)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 68, alignment: .topLeading)
            FluidGlassControlGroup {
                Button(feature.action, systemImage: "arrow.up.right") { self.onClose(feature.destination) }
                    .fluidGlassAction()
                    .disabled(!self.canExplore)
            }
            .padding(.top, 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
