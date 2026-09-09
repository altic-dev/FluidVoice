import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TranscriptionHistoryView: View {
    @ObservedObject private var historyStore = TranscriptionHistoryStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme

    @State private var searchQuery: String = ""
    @State private var showClearConfirmation: Bool = false
    @State private var showReportConfirmation: Bool = false
    @State private var selectedReportEntry: TranscriptionHistoryEntry?
    @State private var selectedEntryID: UUID?
    @State private var audioEntryID: UUID?
    @State private var copiedEntryID: UUID?
    @State private var copyFeedbackTask: Task<Void, Never>?
    @State private var availableAudioFiles: Set<String> = []
    @State private var audioAvailabilityRevision = UUID()

    private struct AudioAvailabilityRequest: Equatable {
        let fileNames: [String]
        let revision: UUID
        let selectedID: UUID?
    }

    private var audioAvailabilityRequest: AudioAvailabilityRequest {
        AudioAvailabilityRequest(
            fileNames: self.historyStore.entries.compactMap { $0.audio?.fileName },
            revision: self.audioAvailabilityRevision,
            selectedID: self.selectedEntry?.id
        )
    }

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
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(self.theme.palette.accent)
                    Text("History").font(self.theme.typography.sectionTitle)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 20)
                .padding(.bottom, 8)
                self.searchBar
                    .padding(12)

                if self.historyStore.isLoading {
                    ProgressView("Loading history…")
                        .padding(12)
                } else if let error = self.historyStore.persistenceError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error)
                            .font(.caption)
                        Button("Retry saving history") {
                            self.historyStore.retryPersistence()
                        }
                    }
                    .padding(12)
                }

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
                    .disabled(self.historyStore.isLoading)
            }
            .frame(minWidth: 280, idealWidth: 340, maxWidth: 400)
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
        .onChange(of: self.selectedEntry?.id) { _, _ in
            self.audioEntryID = nil
        }
        .onDisappear {
            self.availableAudioFiles = []
            self.audioEntryID = nil
            self.copyFeedbackTask?.cancel()
            self.copiedEntryID = nil
        }
        .onAppear {
            self.audioAvailabilityRevision = UUID()
            if self.selectedEntryID == nil {
                self.selectedEntryID = self.filteredEntries.first?.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            self.audioAvailabilityRevision = UUID()
        }
        .task(id: self.audioAvailabilityRequest) {
            let request = self.audioAvailabilityRequest
            let available = await HistoryAudioAvailability.scan(fileNames: request.fileNames) {
                DictationAudioHistoryStore.shared.audioFileExists(fileName: $0)
            }
            guard !Task.isCancelled, request == self.audioAvailabilityRequest else { return }
            self.availableAudioFiles = available
            if let entry = self.selectedEntry, !self.hasAudio(entry) {
                self.audioEntryID = nil
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
            LazyVStack(spacing: 6) {
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
        return HStack(alignment: .top, spacing: 8) {
            Button {
                self.selectedEntryID = entry.id
            } label: {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        HistoryAppIcon(appName: entry.appName)
                        Spacer(minLength: 4)
                        Text(entry.relativeTimeString)
                            .font(self.theme.typography.caption).foregroundStyle(.secondary)
                    }
                    Text(entry.previewText)
                        .font(self.theme.typography.body)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 10) {
                        if let model = self.recordedModel(entry) {
                            Label(model, systemImage: "sparkles")
                                .lineLimit(1).truncationMode(.middle)
                                .help("Recorded AI model: \(model)")
                        } else if entry.wasAIProcessed {
                            Label("AI enhanced", systemImage: "sparkles")
                        }
                        if self.hasAudio(entry) {
                            Image(systemName: "waveform").accessibilityLabel("Saved audio")
                        }
                        if entry.aiProcessingError != nil {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange).help(entry.aiProcessingError ?? "")
                        }
                        Spacer(minLength: 0)
                        if self.settings.showHistoryPerformanceMetrics, let speed = entry.aiTokensPerSecond {
                            Text(TranscriptionHistoryEntry.formattedTokensPerSecond(speed, compact: true))
                                .font(self.theme.typography.captionStrong)
                                .foregroundStyle(self.theme.palette.accent)
                                .monospacedDigit()
                                .fixedSize()
                                .help("AI generation speed, in tokens per second—not total processing time")
                        }
                    }
                    .font(self.theme.typography.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            VStack(spacing: 10) {
                Button {
                    self.copyFinalText(entry)
                } label: {
                    Image(systemName: self.copiedEntryID == entry.id ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy final text")
                .accessibilityLabel(self.copiedEntryID == entry.id ? "Copied" : "Copy final text")
                Menu { self.entryActions(entry) } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .fixedSize().accessibilityLabel("Dictation actions")
            }
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(self.theme.palette.accent.opacity(isSelected ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(isSelected ? self.theme.palette.accent.opacity(0.6) : self.theme.palette.cardBorder.opacity(0.25)))
        .contextMenu { self.entryActions(entry) }
    }

    @ViewBuilder
    private func entryActions(_ entry: TranscriptionHistoryEntry) -> some View {
        Button {
            self.copyFinalText(entry)
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
            if self.audioEntryID == entry.id { self.audioEntryID = nil }
            self.historyStore.deleteEntry(id: entry.id)
            if self.selectedEntryID == entry.id {
                self.selectedEntryID = self.filteredEntries.first(where: { $0.id != entry.id })?.id
            }
        } label: {
            Label("Delete", systemImage: "trash")
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
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        self.detailHeading(entry)
                        Spacer(minLength: 12)
                        self.detailActions(entry)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        self.detailHeading(entry)
                        self.detailActions(entry)
                    }
                }
                if self.audioEntryID == entry.id {
                    HistoryInlineAudioView(entry: entry)
                        .id(entry.id)
                }
                if let error = entry.aiProcessingError {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("AI enhancement failed—raw transcription was used").font(self.theme.typography.bodyStrong)
                            Text(error).font(self.theme.typography.caption).textSelection(.enabled)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                }
                HistoryTextComparisonView(entry: entry, copy: self.copyToClipboard)
                    .id(entry.id)
                if self.settings.showHistoryPerformanceMetrics {
                    FluidManagementGroup(title: "Processing") {
                        LazyVGrid(columns: self.detailColumns, alignment: .leading, spacing: 16) {
                            if let duration = entry.transcriptionDurationMilliseconds {
                                self.metadataItem(
                                    icon: "waveform",
                                    label: "Transcription",
                                    value: TranscriptionHistoryEntry.formattedDuration(milliseconds: duration)
                                )
                            }
                            if let duration = entry.aiProcessingDurationMilliseconds {
                                self.metadataItem(
                                    icon: "sparkles",
                                    label: "AI cleanup",
                                    value: TranscriptionHistoryEntry.formattedDuration(milliseconds: duration)
                                )
                            }
                            if let speed = entry.aiTokensPerSecond {
                                self.metadataItem(
                                    icon: "speedometer",
                                    label: "AI speed",
                                    value: TranscriptionHistoryEntry.formattedTokensPerSecond(speed, compact: true)
                                )
                            }
                        }
                    }
                }
                FluidManagementGroup(title: "Details") {
                    LazyVGrid(columns: self.detailColumns, alignment: .leading, spacing: 16) {
                        self.metadataItem(icon: "app", label: "Application", value: entry.appName.isEmpty ? "Unknown" : entry.appName)
                        self.metadataItem(icon: "character.cursor.ibeam", label: "Characters", value: "\(entry.characterCount)")
                        self.metadataItem(icon: "waveform", label: "Recording", value: self.audioMetadataText(for: entry))
                    }
                    Divider().opacity(0.4)
                    self.metadataItem(
                        icon: "sparkles",
                        label: entry.aiProcessingError == nil ? "AI model" : "AI model (failed)",
                        value: self.recordedModel(entry) ?? (entry.wasAIProcessed ? "Not recorded" : "No AI cleanup")
                    )
                }
                ViewThatFits(in: .horizontal) {
                    HStack {
                        self.secondaryActions(entry)
                        Spacer()
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        self.secondaryActions(entry)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(self.theme.palette.contentBackground)
    }

    private func detailHeading(_ entry: TranscriptionHistoryEntry) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(self.theme.palette.accent)
                .frame(width: 52, height: 52)
                .background(self.theme.palette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 5) {
                Text("Dictation details").font(self.theme.typography.title)
                Text(entry.fullDateString).font(self.theme.typography.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var detailColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: 16, alignment: .leading), count: 3)
    }

    private func recordedModel(_ entry: TranscriptionHistoryEntry) -> String? {
        guard let model = entry.processingModel?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else { return nil }
        return ModelDisplayName.forID(model)
    }

    private func detailActions(_ entry: TranscriptionHistoryEntry) -> some View {
        FluidGlassControlGroup {
            HStack(spacing: 8) {
                Button { self.copyFinalText(entry) } label: {
                    Label(
                        self.copiedEntryID == entry.id ? "Copied" : "Copy text",
                        systemImage: self.copiedEntryID == entry.id ? "checkmark" : "doc.on.doc"
                    )
                }
                .fluidGlassAction(prominent: true)
                .disabled(entry.clipboardText == nil)
                if self.hasAudio(entry) {
                    Button {
                        self.audioEntryID = self.audioEntryID == entry.id ? nil : entry.id
                    } label: {
                        Label(self.audioEntryID == entry.id ? "Close audio" : "Audio", systemImage: "waveform")
                    }
                    .fluidGlassAction()
                }
                Menu { self.entryActions(entry) } label: { Image(systemName: "ellipsis") }
                    .menuIndicator(.hidden)
                    .fluidGlassAction(circular: true)
                    .accessibilityLabel("Dictation actions")
            }
        }
    }

    @ViewBuilder
    private func secondaryActions(_ entry: TranscriptionHistoryEntry) -> some View {
        if self.hasAudio(entry) {
            Button { self.exportPair(entry) } label: {
                Label("Export pair", systemImage: "square.and.arrow.up")
            }
            .fluidGlassAction()
        }
        Button { self.openFeedbackReport(for: entry) } label: {
            Label("Report issue", systemImage: "hand.thumbsup.slash")
        }
        .fluidGlassAction()
    }

    private func metadataItem(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(self.theme.palette.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(label).font(self.theme.typography.caption).foregroundStyle(.secondary)
                Text(value).font(self.theme.typography.bodyStrong).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
    }

    private func copyFinalText(_ entry: TranscriptionHistoryEntry) {
        guard let text = entry.clipboardText else { return }
        self.copyToClipboard(text)
        self.copyFeedbackTask?.cancel()
        self.copiedEntryID = entry.id
        self.copyFeedbackTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            self.copiedEntryID = nil
        }
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
        guard let audio = entry.audio else { return false }
        return self.availableAudioFiles.contains(audio.fileName)
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
