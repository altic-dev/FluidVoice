import SwiftUI

/// Shared typography and layout for every spoken-text / cleanup comparison.
struct OnboardingCleanupExampleCarousel: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let autoplay: OnboardingCarouselAutoplay
    @State private var selectedID = "correction"

    private struct Example: Identifiable {
        let id: String
        let title: String
        let spoken: String
        let cleaned: String
    }

    private static let examples = [
        Example(
            id: "correction",
            title: "Understand when you change your mind",
            spoken: "I'm free at 7:30 tomorrow morning. Would you be available for a quick call? Sorry, I meant 9:30 am.",
            cleaned: "I'm free at 9:30 am tomorrow morning. Would you be available for a quick call?"
        ),
        Example(
            id: "list",
            title: "Turn your rambling into lists",
            spoken: "Grocery list. First one is apples, second one is milk, third one is egg.",
            cleaned: "Grocery list\n\n1. Apples\n2. Milk\n3. Egg"
        ),
        Example(
            id: "paragraphs",
            title: "Start a new paragraph based on context",
            spoken: "I think I'm gonna meet you tomorrow at 3 p.m. Let me know if the time works. If not, we can figure out some other time. Also, I think you need to fix the bug. Please let me know if you need some help there.",
            cleaned: "I think I'm gonna meet you tomorrow at 3 p.m. Let me know if the time works. If not, we can figure out some other time.\n\nAlso, I think you need to fix the bug. Please let me know if you need some help there."
        ),
    ]
    private var ids: [String] { Self.examples.map(\.id) }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                let width = min(640, geometry.size.width * 0.76)
                let sideWidth = max(48, (geometry.size.width - width - 48) / 2)
                let stride = width / 2 + sideWidth / 2 + 16
                FluidGlassControlGroup {
                    ZStack {
                        ForEach(Self.examples) { example in
                            let position = PrivateAIModelCarouselNavigation.position(of: example.id, in: self.ids, current: self.selectedID)
                            if abs(position) <= 1 {
                                self.card(example, compact: position != 0, contentWidth: width, visibleWidth: position == 0 ? width : sideWidth)
                                    .opacity(position == 0 ? 1 : 0.65)
                                    .scaleEffect(position == 0 ? 1 : 0.90)
                                    .offset(x: CGFloat(position) * stride)
                                    .zIndex(position == 0 ? 1 : 0)
                                    .transition(.opacity)
                            }
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                }
                .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    self.advance(forward: value.translation.width < 0)
                })
            }
            .frame(height: 380)
            FluidGlassControlGroup {
                HStack(spacing: 24) {
                    self.arrow(forward: false)
                    HStack(spacing: 4) {
                        ForEach(Self.examples) { example in
                            Button { self.browse(example.id) } label: {
                                Circle()
                                    .fill(self.selectedID == example.id ? FluidBrandColors.blue : self.theme.palette.secondaryText.opacity(0.4))
                                    .frame(width: self.selectedID == example.id ? 10 : 7, height: self.selectedID == example.id ? 10 : 7)
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Show \(example.title)")
                            .accessibilityValue(self.selectedID == example.id ? "Current page" : "")
                        }
                    }
                    self.arrow(forward: true)
                }
            }
        }
        .onReceive(self.autoplay.advance) { self.advance(forward: true) }
    }

    private func card(_ example: Example, compact: Bool, contentWidth: CGFloat, visibleWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                Text(example.title)
                    .font(.fluidSystem(size: 25, weight: .regular, design: .serif))
                    .tracking(-0.5)
                    .foregroundStyle(Color(red: 0.96, green: 0.95, blue: 0.91))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .accessibilityAddTraits(.isHeader)
                self.mode(title: "Basic · Without Fluid Intelligence", text: example.spoken, enhanced: false)
                    .frame(minHeight: 76, alignment: .topLeading)
                Rectangle()
                    .fill(.white.opacity(0.12))
                    .frame(height: 1)
                self.mode(title: "Smart · With Fluid Intelligence", text: example.cleaned, enhanced: true)
            }
        }
        // Keep text at its final reading width while the glass surface slides and narrows.
        .frame(width: contentWidth - 48, alignment: .leading)
        .opacity(compact ? 0 : 1)
        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.18), value: compact)
        .padding(24)
        .frame(width: visibleWidth, height: 360, alignment: .top)
        .clipped()
        .accessibilityHidden(compact)
        .modifier(OnboardingGlassSurface(selected: !compact))
        .overlay {
            if compact {
                Button { self.browse(example.id) } label: {
                    Color.clear.contentShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.Showcase.cardRadius))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(example.title)")
            }
        }
    }

    private func mode(title: String, text: String, enhanced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.fluidSystem(size: 18, weight: .regular, design: .serif))
                .tracking(-0.5)
                .foregroundStyle(enhanced ? Color(red: 0.48, green: 0.72, blue: 1) : .white.opacity(0.62))
            Text(text)
                .font(.fluidSystem(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(0.9))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    private func browse(_ id: String) {
        self.autoplay.interact()
        withAnimation(self.reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.94)) { self.selectedID = id }
    }

    private func advance(forward: Bool) {
        guard let id = PrivateAIModelCarouselNavigation.next(in: self.ids, current: self.selectedID, forward: forward) else { return }
        self.browse(id)
    }

    private func arrow(forward: Bool) -> some View {
        Button { self.advance(forward: forward) } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(self.theme.typography.sectionTitle)
                .foregroundStyle(self.theme.palette.primaryText)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .fluidGlassAction(circular: true)
        .accessibilityLabel(forward ? "Next example" : "Previous example")
    }
}
