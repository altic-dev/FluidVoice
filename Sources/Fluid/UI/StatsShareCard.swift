import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The numbers available to the shareable stats image. Totals only: no transcript text,
/// app names or times of day ever leave the Mac through this card.
struct StatsShareContent {
    let totalWords: Int
    let timeSaved: String
    let currentStreak: Int
    let totalTranscriptions: Int
    let keystrokesSaved: Int
    let aiPolishRate: Int
    let talkingWordsPerMinute: Int?
    let biggestDayWords: Int
    let longestDictationWords: Int
    let activity: [Int]

    /// A paperback page holds roughly 275 words.
    var pagesEquivalent: Int { self.totalWords / 275 }

    var headline: String {
        if self.pagesEquivalent >= 300 {
            let novels = Double(self.pagesEquivalent) / 300
            return String(format: "That's about %.1f novels, spoken instead of typed.", novels)
        }
        if self.pagesEquivalent >= 2 {
            return "That's about \(self.pagesEquivalent) book pages, spoken instead of typed."
        }
        return "Spoken instead of typed."
    }
}

/// A stat the user can switch on or off for their card.
enum StatsShareStat: String, CaseIterable, Identifiable {
    case keystrokes, timeSaved, streak, dictations, aiPolish, talkingSpeed, biggestDay, longestDictation

    static let maxSelected = 4
    static let defaults: [StatsShareStat] = [.keystrokes, .timeSaved, .streak, .dictations]

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .keystrokes: return "Keystrokes saved"
        case .timeSaved: return "Time saved"
        case .streak: return "Streak"
        case .dictations: return "Dictations"
        case .aiPolish: return "AI polish"
        case .talkingSpeed: return "Talking speed"
        case .biggestDay: return "Biggest day"
        case .longestDictation: return "Longest dictation"
        }
    }

    /// Talking speed needs measured audio; everything else is always available.
    func isAvailable(in content: StatsShareContent) -> Bool {
        self != .talkingSpeed || content.talkingWordsPerMinute != nil
    }

    func value(in content: StatsShareContent) -> String {
        switch self {
        case .keystrokes: return Self.compact(content.keystrokesSaved)
        case .timeSaved:
            // Once it is hours, the minutes are noise on a share card.
            return content.timeSaved.split(separator: " ").first { $0.hasSuffix("h") }.map(String.init) ?? content.timeSaved
        case .streak: return "\(content.currentStreak)"
        case .dictations: return content.totalTranscriptions.formatted()
        case .aiPolish: return "\(content.aiPolishRate)%"
        case .talkingSpeed: return "\(content.talkingWordsPerMinute ?? 0)"
        case .biggestDay: return content.biggestDayWords.formatted()
        case .longestDictation: return content.longestDictationWords.formatted()
        }
    }

    var label: String {
        switch self {
        case .keystrokes: return "keys never pressed"
        case .timeSaved: return "time saved"
        case .streak: return "day streak"
        case .dictations: return "dictations"
        case .aiPolish: return "polished by AI"
        case .talkingSpeed: return "words a minute"
        case .biggestDay: return "words in one day"
        case .longestDictation: return "words in one go"
        }
    }

    private static func compact(_ number: Int) -> String {
        number.formatted(.number.notation(.compactName).precision(.fractionLength(0...2)))
    }
}

/// Fixed-size artwork rendered to an image; sized for a 1200×675 social preview at 2×.
struct StatsShareCard: View {
    static let size = CGSize(width: 600, height: 337.5)

    let content: StatsShareContent
    let stats: [StatsShareStat]
    let showsActivity: Bool
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text("FluidVoice")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(Date.now.formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer(minLength: 0)

            Text(self.content.totalWords.formatted())
                .font(.system(size: 76, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(
                    LinearGradient(colors: [.white, self.accent.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            Text("words dictated")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.top, -6)
            Text(self.content.headline)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.top, 6)

            Spacer(minLength: 0)

            // Four long stats leave less room; the graph steps down to fewer days before it is dropped.
            ViewThatFits(in: .horizontal) {
                self.statsRow(activityDays: 30)
                self.statsRow(activityDays: 21)
                self.statsRow(activityDays: 14)
                self.statsRow(activityDays: 0)
            }
        }
        .foregroundStyle(.white)
        .padding(28)
        .frame(width: Self.size.width, height: Self.size.height)
        .background {
            ZStack {
                Color(red: 0.045, green: 0.055, blue: 0.085)
                RadialGradient(colors: [self.accent.opacity(0.55), .clear], center: .init(x: 0.95, y: 0.0), startRadius: 0, endRadius: 380)
                RadialGradient(colors: [Color.purple.opacity(0.28), .clear], center: .init(x: 0.0, y: 1.0), startRadius: 0, endRadius: 320)
            }
        }
    }

    private func statsRow(activityDays: Int) -> some View {
        HStack(alignment: .bottom, spacing: 18) {
            ForEach(self.stats) { stat in
                self.metric(stat)
            }
            Spacer(minLength: 14)
            if self.showsActivity, activityDays > 0 {
                self.sparkline(days: activityDays)
            }
        }
    }

    private func metric(_ stat: StatsShareStat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(stat.value(in: self.content))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                if stat == .streak, let flame = self.streakFlame {
                    Image(systemName: "flame.fill")
                        .font(.system(size: flame.size, weight: .semibold))
                        .foregroundStyle(flame.color)
                }
            }
            Text(stat.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .fixedSize()
    }

    /// The flame grows and heats up at a week, a month and a hundred days.
    private var streakFlame: (size: CGFloat, color: Color)? {
        switch self.content.currentStreak {
        case 100...: return (20, Color(red: 1.0, green: 0.35, blue: 0.3))
        case 30...: return (17, .orange)
        case 7...: return (14, .yellow)
        default: return nil
        }
    }

    private func sparkline(days: Int) -> some View {
        let activity = Array(self.content.activity.suffix(days))
        let peak = max(activity.max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(activity.enumerated()), id: \.offset) { _, words in
                Capsule()
                    .fill(.white.opacity(words == 0 ? 0.14 : 0.85))
                    .frame(width: 4, height: max(4, 46 * CGFloat(words) / CGFloat(peak)))
            }
        }
        .frame(height: 46, alignment: .bottom)
        .fixedSize()
    }
}

/// Live preview, the on/off chips that shape it, and the three ways out: share, copy, save.
struct StatsShareSheet: View {
    let content: StatsShareContent
    let close: () -> Void
    @Environment(\.theme) private var theme
    @AppStorage("StatsShareSelectedStats") private var storedSelection = ""
    @AppStorage("StatsShareShowsActivity") private var showsActivity = true
    @State private var copied = false

    /// Kept in the enum's order so the card layout is stable however chips were tapped.
    private var selection: [StatsShareStat] {
        let stored = self.storedSelection.split(separator: ",").compactMap { StatsShareStat(rawValue: String($0)) }
        let chosen = self.storedSelection.isEmpty ? StatsShareStat.defaults : stored
        return StatsShareStat.allCases.filter { chosen.contains($0) && $0.isAvailable(in: self.content) }
    }

    private var card: StatsShareCard {
        StatsShareCard(content: self.content, stats: self.selection, showsActivity: self.showsActivity, accent: self.theme.palette.accent)
    }

    private var image: NSImage? {
        let renderer = ImageRenderer(content: self.card)
        renderer.scale = 2
        return renderer.nsImage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Flex your FluidVoice stats").font(self.theme.typography.sectionTitle)
                    Text("Post it, send it to a friend, start a streak war.")
                        .font(self.theme.typography.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: self.close).fluidGlassAction()
            }

            self.card
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(self.theme.palette.cardBorder, lineWidth: 1))

            VStack(alignment: .leading, spacing: 8) {
                Text("Show on card · up to \(StatsShareStat.maxSelected)")
                    .font(self.theme.typography.caption).foregroundStyle(.secondary)
                FlowChips(spacing: 6) {
                    ForEach(StatsShareStat.allCases.filter { $0.isAvailable(in: self.content) }) { stat in
                        let isOn = self.selection.contains(stat)
                        self.chip(stat.title, isOn: isOn, isEnabled: isOn || self.selection.count < StatsShareStat.maxSelected) {
                            self.toggle(stat)
                        }
                    }
                    self.chip("Activity graph", isOn: self.showsActivity, isEnabled: true) {
                        self.showsActivity.toggle()
                    }
                }
            }

            HStack(spacing: 8) {
                if let image {
                    ShareLink(
                        item: Image(nsImage: image),
                        preview: SharePreview("My FluidVoice stats", image: Image(nsImage: image))
                    ) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                    .fluidGlassAction(prominent: true)
                }
                Button(self.copied ? "Copied" : "Copy image", systemImage: self.copied ? "checkmark" : "doc.on.doc", action: self.copy)
                    .fluidGlassAction()
                Button("Save…", systemImage: "arrow.down.to.line", action: self.save)
                    .fluidGlassAction()
                Spacer()
            }
        }
        .padding(20)
        .frame(width: StatsShareCard.size.width + 40)
        .onChange(of: self.storedSelection) { _, _ in self.copied = false }
        .onChange(of: self.showsActivity) { _, _ in self.copied = false }
    }

    private func chip(_ title: String, isOn: Bool, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark" : "plus")
                    .font(.fluidSystem(size: 9, weight: .bold))
                Text(title).font(self.theme.typography.captionStrong)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(isOn ? self.theme.palette.accent : .secondary)
            .background(
                isOn ? self.theme.palette.accent.opacity(0.14) : self.theme.palette.cardBackground,
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(isOn ? self.theme.palette.accent.opacity(0.4) : self.theme.palette.cardBorder, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func toggle(_ stat: StatsShareStat) {
        var chosen = self.selection
        if let index = chosen.firstIndex(of: stat) {
            chosen.remove(at: index)
        } else if chosen.count < StatsShareStat.maxSelected {
            chosen.append(stat)
        }
        // An empty string means "defaults", so keep an explicit marker when everything is off.
        self.storedSelection = chosen.isEmpty ? "none" : chosen.map(\.rawValue).joined(separator: ",")
    }

    private func copy() {
        guard let image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        self.copied = true
    }

    private func save() {
        guard let image,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "FluidVoice stats.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? png.write(to: url)
    }
}

/// Wrapping row for the option chips.
private struct FlowChips: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = self.rows(in: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * self.spacing
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        for row in self.rows(in: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + self.spacing
            }
            y += row.height + self.spacing
        }
    }

    private func rows(in width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if var last = rows.last, last.width + self.spacing + size.width <= width {
                last.indices.append(index)
                last.width += self.spacing + size.width
                last.height = max(last.height, size.height)
                rows[rows.count - 1] = last
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}
