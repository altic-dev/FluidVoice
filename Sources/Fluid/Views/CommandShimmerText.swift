import SwiftUI

struct CommandShimmerText: View {
    let text: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let duration = 1.15
            let progress = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: duration) / duration
            let center = CGFloat(progress)
            let leadingEdge = max(0, center - 0.18)
            let trailingEdge = min(1, center + 0.18)

            Text(self.text)
                .font(.fluidSystem(size: 13, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: Color.secondary.opacity(0.42), location: 0),
                            .init(color: Color.secondary.opacity(0.42), location: leadingEdge),
                            .init(color: Color.primary.opacity(0.98), location: center),
                            .init(color: Color.secondary.opacity(0.42), location: trailingEdge),
                            .init(color: Color.secondary.opacity(0.42), location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
        .accessibilityLabel(Text(self.text))
    }
}
