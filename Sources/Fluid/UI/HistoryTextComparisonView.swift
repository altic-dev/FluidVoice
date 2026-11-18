import SwiftUI

struct HistoryTextComparisonView: View {
    @Environment(\.theme) private var theme
    let entry: TranscriptionHistoryEntry
    let copy: (String) -> Void
    @State private var showChanges = true
    @State private var comparison: HistoryTextDiff?
    @State private var comparisonMessage: String?
    @State private var hasCompared = false

    var body: some View {
        VStack(alignment: .leading, spacing: FluidSettingsLayout.groupSpacing) {
            if self.entry.wasAIProcessed {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    if self.showChanges, let message = self.comparisonMessage {
                        Text(message)
                            .lineLimit(1).help(message)
                    }
                    Spacer()
                    Text("Show changes")
                        .accessibilityHidden(true)
                    Toggle("Show changes", isOn: self.$showChanges)
                        .fluidSwitch()
                }
                .fluidText(.label)
                .foregroundStyle(self.theme.look.secondaryText)
                .frame(height: 24)
            }
            self.section(title: "Final text", content: self.entry.clipboardText ?? "", isOriginal: false)
            if self.entry.wasAIProcessed {
                self.section(title: "Original transcription", content: self.entry.rawText, isOriginal: true)
            }
        }
        .task(id: self.showChanges) {
            // Keep the result while toggling; only this selected entry is compared, once.
            guard self.entry.wasAIProcessed, self.showChanges, !self.hasCompared else { return }
            let original = self.entry.rawText
            let final = self.entry.clipboardText ?? ""
            let result = await Task.detached(priority: .utility) {
                HistoryTextDiff.compare(original: original, final: final)
            }.value
            guard !Task.isCancelled else { return }
            self.comparison = result
            self.hasCompared = true
            self.comparisonMessage = result == nil
                ? "This entry is too long for inline comparison. Both texts remain available below."
                : nil
        }
    }

    private func section(title: String, content: String, isOriginal: Bool) -> some View {
        let look = self.theme.look
        return VStack(alignment: .leading, spacing: 0) {
            FluidGroupHeader(title: title) {
                if !isOriginal, self.entry.wasAIProcessed {
                    FluidChip(text: "AI enhanced")
                }
                Button { self.copy(content) } label: { Image(systemName: "doc.on.doc") }
                    .fluidGlassAction(circular: true, quiet: true)
                    .help(isOriginal ? "Copy raw text" : "Copy final text")
                    .accessibilityLabel(isOriginal ? "Copy raw text" : "Copy final text")
            }
            FluidSettingsGroup {
                FluidSettingsBlock {
                    self.text(content, isOriginal: isOriginal)
                        .fluidText(.body).lineSpacing(5)
                        .foregroundStyle(isOriginal ? look.secondaryText : look.text)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func text(_ content: String, isOriginal: Bool) -> Text {
        guard self.showChanges, let comparison else { return Text(AttributedString(content)) }
        let runs = isOriginal ? comparison.original : comparison.final
        var text = AttributedString()
        for run in runs {
            var part = AttributedString(run.text)
            // Changes stand out by weight of ink, not hue: removed words are struck through,
            // added words are underlined, both on the look's highlight fill.
            if run.changed {
                part.foregroundColor = isOriginal ? self.theme.look.tertiaryText : self.theme.look.text
                part.backgroundColor = self.theme.look.highlightFill
                if isOriginal {
                    part.strikethroughStyle = .single
                } else {
                    part.underlineStyle = .single
                }
            }
            text.append(part)
        }
        return Text(text)
    }
}
