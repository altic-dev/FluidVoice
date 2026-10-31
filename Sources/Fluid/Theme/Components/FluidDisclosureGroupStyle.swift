import SwiftUI

/// The label, chevron, padding, and blank row space all belong to one native button.
/// Content actions remain outside that button and retain their own bindings.
/// Apply to content disclosures directly; native sidebar sections must keep their system style.
struct FluidDisclosureGroupStyle: DisclosureGroupStyle {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if self.reduceMotion {
                    configuration.isExpanded.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        configuration.isExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    Image(systemName: "chevron.right")
                        .font(.fluidSystem(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 14)
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .padding(.vertical, self.theme.metrics.spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Show or hide details")

            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}
