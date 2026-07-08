import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TranscriptionHistoryView: View {
    @ObservedObject private var historyStore = TranscriptionHistoryStore.shared
    @Environment(\.theme) private var theme

    @State private var searchQuery: String = ""
    @State private var showClearConfirmation: Bool = false
    @State private var showReportConfirmation: Bool = false
    @State private var selectedReportEntry: TranscriptionHistoryEntry?
    @State private var selectedEntryID: UUID?

    private var filteredEntries: [TranscriptionHistoryEntry] {
        self.historyStore.search(query: self.searchQuery)
    }

    private var selectedEntry: TranscriptionHistoryEntry? {
        guard let id = selectedEntryID else { return self.filteredEntries.first }
        return self.filteredEntries.first(where: { $0.id == id })
    }

    var body: some View {
        HSplitView {
            // MARK: - Left Panel: Entry List

            VStack(spacing: 0) {
                // Search Bar
                self.searchBar
                    .padding(12)

                Divider()
                    .opacity(0.3)

                // Entry List
                if self.filteredEntries.isEmpty {
                    self.emptyStateView
                } else {
                    self.entryListView
                }

                // Footer with stats and clear button
                self.footerView
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
            .background(self.theme.palette.contentBackground)

            // MARK: - Right Panel: Entry Detail

            if let entry = selectedEntry {
                self.entryDetailView(entry)
                    .frame(minWidth: 400)
            } else {
                self.noSelectionView
                    .frame(minWidth: 400)
            }
        }
        .onAppear {
            if self.selectedEntryID == nil {
                self.selectedEntryID = self.filteredEntries.first?.id
            }
        }
        .alert("Clear All History", isPresented: self.$showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.historyStore.clearAllHistory()
                    self.selectedEntryID = nil
                }
            }
        } message: {
            Text("This will permanently delete all \(self.historyStore.entries.count) transcription entries. This action cannot be undone.")
        }
        .alert("Report Sent", isPresented: self.$showReportConfirmation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Thank you for helping improve FluidVoice dictation.")
        }
        .sheet(item: self.$selectedReportEntry) { entry in
            TranscriptionFeedbackReportSheet(entry: entry) {
                self.selectedReportEntry = nil
                self.showReportConfirmation = true
            }
            .environment(\.theme, self.theme)
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search transcriptions...", text: self.$searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))

            if !self.searchQuery.isEmpty {
                Button {
                    self.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(self.theme.palette.cardBackground)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(self.theme.palette.cardBorder.opacity(0.6), lineWidth: 1)))
    }

    // MARK: - Entry List

    private var entryListView: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(self.filteredEntries) { entry in
                    self.entryRow(entry)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func entryRow(_ entry: TranscriptionHistoryEntry) -> some View {
        let isSelected = self.selectedEntryID == entry.id

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                self.selectedEntryID = entry.id
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                // Top row: App name and time
                HStack(spacing: 6) {
                    Text(entry.appName.isEmpty ? "Unknown App" : entry.appName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : .secondary)
                        .lineLimit(1)

                    if entry.wasAIProcessed {
                        Text("AI")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(isSelected ? .white.opacity(0.8) : self.theme.palette.accent)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(isSelected ? .white.opacity(0.2) : self.theme.palette.accent.opacity(0.15))
                            )
                    }

                    if self.hasAudio(entry) {
                        Image(systemName: "waveform")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isSelected ? .white.opacity(0.8) : self.theme.palette.accent)
                            .help("Saved local dictation audio")
                    }

                    if entry.aiProcessingError != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(isSelected ? .white : Color.orange)
                            .help(entry.aiProcessingError ?? "")
                    }

                    Spacer()

                    Text(entry.relativeTimeString)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : Color.secondary.opacity(0.6))
                }

                // Preview text
                Text(entry.previewText)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? .white.opacity(0.9) : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? self.theme.palette.accent : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                self.copyToClipboard(entry.processedText)
            } label: {
                Label(entry.wasAIProcessed ? "Copy AI Text" : "Copy Text", systemImage: "doc.on.doc")
            }

            if entry.wasAIProcessed {
                Button {
                    self.copyToClipboard(entry.rawText)
                } label: {
                    Label("Copy Raw Text", systemImage: "doc.on.doc.fill")
                }

                Button {
                    self.copyToClipboard(self.combinedText(for: entry))
                } label: {
                    Label("Copy Both", systemImage: "doc.on.doc")
                }
            }

            if self.hasAudio(entry) {
                Divider()

                Button {
                    self.exportPair(entry)
                } label: {
                    Label("Export Pair...", systemImage: "square.and.arrow.up")
                }

                Button {
                    self.revealAudio(entry)
                } label: {
                    Label("Reveal Audio", systemImage: "waveform")
                }
            }

            Divider()

            Button {
                self.openFeedbackReport(for: entry)
            } label: {
                Label("Report Bad Result...", systemImage: "hand.thumbsup.slash")
            }

            Divider()

            Button(role: .destructive) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.historyStore.deleteEntry(id: entry.id)
                    if self.selectedEntryID == entry.id {
                        self.selectedEntryID = self.filteredEntries.first(where: { $0.id != entry.id })?.id
                    }
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: self.searchQuery.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)

            VStack(spacing: 4) {
                Text(self.searchQuery.isEmpty ? "No History Yet" : "No Results")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(self.searchQuery.isEmpty
                    ? "Your transcriptions will appear here"
                    : "Try a different search term")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    // MARK: - Footer

    private var footerView: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.3)

            HStack {
                // Stats
                Text("\(self.historyStore.entries.count) entries")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)

                Spacer()

                // Clear All Button
                if !self.historyStore.entries.isEmpty {
                    Button {
                        self.showClearConfirmation = true
                    } label: {
                        Text("Clear All")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .opacity(0.8)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Entry Detail View

    private func entryDetailView(_ entry: TranscriptionHistoryEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Transcription Details")
                            .font(.system(size: 18, weight: .semibold))

                        Spacer()

                        Button {
                            self.copyToClipboard(entry.processedText)
                        } label: {
                            Label(entry.wasAIProcessed ? "Copy AI" : "Copy", systemImage: "doc.on.doc")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        if self.hasAudio(entry) {
                            Button {
                                self.exportPair(entry)
                            } label: {
                                Label("Export Pair", systemImage: "square.and.arrow.up")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button {
                                self.revealAudio(entry)
                            } label: {
                                Label("Audio", systemImage: "waveform")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Button {
                            self.openFeedbackReport(for: entry)
                        } label: {
                            Label("Report", systemImage: "hand.thumbsup.slash")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Review and send this example to FluidVoice")

                        if entry.wasAIProcessed {
                            Button {
                                self.copyToClipboard(entry.rawText)
                            } label: {
                                Label("Raw", systemImage: "doc.on.doc.fill")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button {
                                self.copyToClipboard(self.combinedText(for: entry))
                            } label: {
                                Label("Both", systemImage: "doc.on.doc")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    Text(entry.fullDateString)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Divider()
                    .opacity(0.3)

                if let aiError = entry.aiProcessingError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AI Enhancement failed - raw transcription was typed instead")
                                .font(.system(size: 12, weight: .semibold))
                            Text(aiError)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.orange.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                            )
                    )
                }

                // Final Text Section
                self.detailSection(
                    title: "Final Text",
                    content: entry.processedText,
                    badge: entry.wasAIProcessed ? "AI Enhanced" : nil
                )

                // Raw Text Section (only if different)
                if entry.wasAIProcessed {
                    self.detailSection(
                        title: "Original Transcription",
                        content: entry.rawText,
                        badge: nil,
                        isSecondary: true
                    )
                }

                Divider()
                    .opacity(0.3)

                // Metadata Grid
                self.metadataGrid(entry)

                Spacer(minLength: 20)

                // Delete Button
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            let nextEntry = self.filteredEntries.first(where: { $0.id != entry.id })
                            self.historyStore.deleteEntry(id: entry.id)
                            self.selectedEntryID = nextEntry?.id
                        }
                    } label: {
                        Label("Delete Entry", systemImage: "trash")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                }
            }
            .padding(24)
        }
        .background(self.theme.palette.contentBackground)
    }

    private func detailSection(
        title: String,
        content: String,
        badge: String?,
        isSecondary: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                if let badge = badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(self.theme.palette.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(self.theme.palette.accent.opacity(0.15))
                        )
                }
            }

            Text(content)
                .font(.system(size: 14, design: .default))
                .foregroundStyle(isSecondary ? .secondary : .primary)
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(self.theme.palette.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(self.theme.palette.cardBorder.opacity(isSecondary ? 0.35 : 0.5), lineWidth: 1)))
        }
    }

    private func metadataGrid(_ entry: TranscriptionHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 16),
                GridItem(.flexible(), spacing: 16),
            ], spacing: 12) {
                self.metadataItem(icon: "app.fill", label: "Application", value: entry.appName.isEmpty ? "Unknown" : entry.appName)
                self.metadataItem(icon: "macwindow", label: "Window", value: entry.windowTitle.isEmpty ? "Unknown" : entry.windowTitle)
                self.metadataItem(icon: "character.cursor.ibeam", label: "Characters", value: "\(entry.characterCount)")
                self.metadataItem(icon: "sparkles", label: "AI Processed", value: entry.wasAIProcessed ? "Yes" : "No")
                self.metadataItem(icon: "waveform", label: "Audio", value: self.audioMetadataText(for: entry))
            }
        }
    }

    private func metadataItem(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)

                Text(value)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(self.theme.palette.cardBackground.opacity(0.9)))
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func openFeedbackReport(for entry: TranscriptionHistoryEntry) {
        self.selectedReportEntry = entry
    }

    private func combinedText(for entry: TranscriptionHistoryEntry) -> String {
        "\(entry.rawText)\n\n\(entry.processedText)"
    }

    private func hasAudio(_ entry: TranscriptionHistoryEntry) -> Bool {
        DictationAudioHistoryStore.shared.audioFileExists(for: entry)
    }

    private func audioMetadataText(for entry: TranscriptionHistoryEntry) -> String {
        guard let audio = entry.audio, self.hasAudio(entry) else { return "No" }
        let seconds = Double(audio.durationMilliseconds) / 1000.0
        let size = ByteCountFormatter.string(fromByteCount: Int64(audio.byteCount), countStyle: .file)
        return "\(String(format: "%.1f", seconds))s, \(size)"
    }

    private func revealAudio(_ entry: TranscriptionHistoryEntry) {
        guard let url = DictationAudioHistoryStore.shared.audioFileURL(for: entry),
              FileManager.default.fileExists(atPath: url.path)
        else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func exportPair(_ entry: TranscriptionHistoryEntry) {
        do {
            guard self.hasAudio(entry) else { throw DictationAudioHistoryError.audioMissing }
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [.zip]
            panel.nameFieldStringValue = DictationAudioHistoryStore.shared.suggestedPairExportFilename(for: entry)

            guard panel.runModal() == .OK, let url = panel.url else { return }
            try DictationAudioHistoryStore.shared.exportPair(entry: entry, to: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Pair Export Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - No Selection View

    private var noSelectionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.quote")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)

            Text("Select a transcription")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(self.theme.palette.contentBackground)
    }
}

private struct TranscriptionFeedbackReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var inputText: String
    @State private var outputText: String
    @State private var processingModel: String
    @State private var comment: String
    @State private var isSending: Bool = false
    @State private var errorMessage: String?

    let onSent: () -> Void

    init(entry: TranscriptionHistoryEntry, onSent: @escaping () -> Void) {
        _inputText = State(initialValue: entry.rawText)
        _outputText = State(initialValue: entry.processedText)
        _processingModel = State(initialValue: Self.reportModel(for: entry))
        _comment = State(initialValue: "")
        self.onSent = onSent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Share anonymous datapoint")
                    .font(.system(size: 18, weight: .semibold))
                Text("Help improve our model. Only the example shown below will be sent.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            self.feedbackField(title: "Raw Text", text: self.$inputText, height: 88)
            self.feedbackField(title: "Processed Text", text: self.$outputText, height: 88)
            self.feedbackField(title: "Processing Model", text: self.$processingModel, height: 40)
            self.feedbackField(title: "Comment optional", text: self.$comment, height: 72)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    self.dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(self.isSending)

                Button {
                    Task {
                        await self.sendReport()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if self.isSending {
                            ProgressView()
                                .controlSize(.small)
                                .fixedSize()
                        }
                        Text(self.isSending ? "Sending..." : "Send Example")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(self.isSendDisabled)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(self.theme.palette.contentBackground)
    }

    private var isSendDisabled: Bool {
        self.isSending ||
            (self.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                self.outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ||
            self.processingModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendReport() async {
        let payload = TranscriptionFeedbackReporter.Payload(
            rawText: self.inputText.trimmingCharacters(in: .whitespacesAndNewlines),
            processedText: self.outputText.trimmingCharacters(in: .whitespacesAndNewlines),
            processingModel: self.processingModel.trimmingCharacters(in: .whitespacesAndNewlines),
            comments: self.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        self.isSending = true
        self.errorMessage = nil
        do {
            try await TranscriptionFeedbackReporter.submit(payload)
            self.isSending = false
            self.onSent()
        } catch {
            self.errorMessage = error.localizedDescription
            self.isSending = false
        }
    }

    private func feedbackField(title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            TextEditor(text: text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(self.theme.palette.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(self.theme.palette.cardBorder.opacity(0.55), lineWidth: 1)
                        )
                )
        }
    }

    private static func reportModel(for entry: TranscriptionHistoryEntry) -> String {
        let model = entry.processingModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return model.isEmpty ? "unknown" : model
    }
}

#Preview {
    TranscriptionHistoryView()
        .frame(width: 800, height: 600)
        .environment(\.theme, AppTheme.dark)
}
