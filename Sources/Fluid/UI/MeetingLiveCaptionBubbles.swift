import SwiftUI

/// Shared bubble look for final transcript and live captions; callers own alignment, labels, and insets.
struct MeetingBubbleStyle {
    var font: Font
    var lineSpacing: CGFloat
    var horizontalPadding: CGFloat
    var verticalPadding: CGFloat
    var cornerRadius: CGFloat
    var fill: Color
    var foreground: Color

    static func final(fill: Color, foreground: Color) -> MeetingBubbleStyle {
        MeetingBubbleStyle(
            font: .system(size: 15, design: .monospaced), lineSpacing: 5,
            horizontalPadding: 18, verticalPadding: 12, cornerRadius: 18,
            fill: fill, foreground: foreground
        )
    }
}

extension View {
    func meetingBubbleStyle(_ style: MeetingBubbleStyle) -> some View {
        self
            .font(style.font)
            .lineSpacing(style.lineSpacing)
            .foregroundStyle(style.foreground)
            .padding(.horizontal, style.horizontalPadding)
            .padding(.vertical, style.verticalPadding)
            .background(style.fill, in: RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
    }
}

/// Auto-follows the newest row only while the user is pinned to the bottom; scrolling up suspends
/// following and shows a jump-to-bottom button.
struct MeetingLiveBubbleScrollList: View {
    let rows: [MeetingLiveBubbleComposer.Row]
    var hidesPartialFromAccessibility = true

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPinnedToBottom = true

    private var trailingPartialLength: Int {
        guard let last = self.rows.last, last.isPartial else { return 0 }
        return last.text.count
    }

    var body: some View {
        let rowIDs = self.rows.map(\.id)
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                        ForEach(self.rows) { row in
                            MeetingLiveBubbleRow(row: row, hidesPartialFromAccessibility: self.hidesPartialFromAccessibility)
                                .equatable()
                                .id(row.id)
                                .transition(.opacity)
                        }
                    }
                }
                .animation(self.reduceMotion ? nil : .easeInOut(duration: 0.2), value: rowIDs)
                // Wide threshold so a growing partial (one wrapped line ≈ 20pt) can't out-race the
                // follow-up scrollTo and read as the user scrolling away; only a deliberate
                // scroll-up (> 80pt) disengages following.
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    let bottomOffset = geometry.contentSize.height - geometry.containerSize.height
                    return geometry.contentOffset.y >= bottomOffset - 80
                } action: { _, isPinned in
                    self.isPinnedToBottom = isPinned
                }
                .onChange(of: self.rows.count) {
                    self.scrollToBottomIfPinned(proxy: proxy)
                }
                .onChange(of: self.trailingPartialLength) {
                    self.scrollToBottomIfPinned(proxy: proxy)
                }

                if !self.isPinnedToBottom {
                    Button {
                        self.isPinnedToBottom = true
                        self.scrollToBottom(proxy: proxy, animated: true)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(self.theme.palette.primaryText)
                            .frame(width: 28, height: 28)
                            .background(self.theme.palette.contentBackground, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }
            }
        }
    }

    private func scrollToBottomIfPinned(proxy: ScrollViewProxy) {
        guard self.isPinnedToBottom else { return }
        self.scrollToBottom(proxy: proxy, animated: false)
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard let lastID = self.rows.last?.id else { return }
        guard animated, !self.reduceMotion else {
            proxy.scrollTo(lastID, anchor: .bottom)
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }
}

struct MeetingLiveBubbleRow: View, Equatable {
    let row: MeetingLiveBubbleComposer.Row
    var hidesPartialFromAccessibility: Bool = true

    @Environment(\.theme) private var theme

    static func == (lhs: MeetingLiveBubbleRow, rhs: MeetingLiveBubbleRow) -> Bool {
        lhs.row == rhs.row && lhs.hidesPartialFromAccessibility == rhs.hidesPartialFromAccessibility
    }

    private var isYou: Bool { self.row.speaker == .you }

    /// Same washes as the final transcript: accent for You, the first speaker-palette pastel for Them.
    private var fill: Color {
        let base = self.isYou ? self.theme.palette.accent : MeetingSpeakerPalette.tint(forSpeakerIndex: 0)
        return base.opacity(self.row.isPartial ? 0.05 : 0.10)
    }

    var body: some View {
        VStack(alignment: self.isYou ? .trailing : .leading, spacing: 4) {
            if self.row.showsLabel {
                Text(self.isYou ? "You" : "Them")
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.isYou ? self.theme.palette.accent : self.theme.palette.secondaryText)
            }
            Text(self.row.text)
                // The partial→final color swap solidifies in place; it must never animate.
                .transaction { $0.animation = nil }
                .meetingBubbleStyle(.final(fill: self.fill, foreground: self.row.isPartial ? self.theme.palette.secondaryText : self.theme.palette.primaryText))
        }
        .frame(maxWidth: .infinity, alignment: self.isYou ? .trailing : .leading)
        .padding(self.isYou ? .leading : .trailing, 32)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(self.isYou ? "You" : "Them"), \(self.row.text)")
        .accessibilityHidden(self.hidesPartialFromAccessibility && self.row.isPartial)
    }
}
