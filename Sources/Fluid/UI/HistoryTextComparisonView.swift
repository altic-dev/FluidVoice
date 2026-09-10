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
        VStack(alignment: .leading, spacing: 20) {
            if self.entry.wasAIProcessed {
                HStack {
                    if self.showChanges, let message = self.comparisonMessage {
                        Text(message).foregroundStyle(.secondary)
                            .lineLimit(1).help(message)
                    }
                    Spacer()
                    Toggle("Show changes", isOn: self.$showChanges).toggleStyle(.switch).controlSize(.small)
                        .fixedSize()
                }
                .font(self.theme.typography.caption)
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(title).font(self.theme.typography.bodyStrong)
                if !isOriginal, self.entry.wasAIProcessed {
                    Text("AI enhanced").font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.accent)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(self.theme.palette.accent.opacity(0.1), in: Capsule())
                }
                Spacer()
                Button { self.copy(content) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(isOriginal ? "Copy raw text" : "Copy final text")
                    .accessibilityLabel(isOriginal ? "Copy raw text" : "Copy final text")
            }
            self.text(content, isOriginal: isOriginal)
                .font(self.theme.typography.body).lineSpacing(5)
                .foregroundStyle(isOriginal ? self.theme.palette.secondaryText : self.theme.palette.primaryText)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .background(self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(self.theme.palette.cardBorder.opacity(0.5)))
    }

    private func text(_ content: String, isOriginal: Bool) -> Text {
        guard self.showChanges, let comparison else { return Text(AttributedString(content)) }
        let runs = isOriginal ? comparison.original : comparison.final
        var text = AttributedString()
        for run in runs {
            var part = AttributedString(run.text)
            if run.changed {
                part.foregroundColor = isOriginal ? .red : .green
                part.backgroundColor = (isOriginal ? Color.red : Color.green).opacity(0.1)
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
