import AppKit
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct HistoryPinRevealRequest: Equatable {
    let entryID: UUID
    private let nonce = UUID()

    func target(selectedID: UUID?, visibleIDs: [UUID]) -> UUID? {
        guard selectedID == self.entryID, visibleIDs.contains(self.entryID) else { return nil }
        return self.entryID
    }
}

/// A hidden existing row can be selected from sidebar search even when the list is empty.
nonisolated enum HistorySelectionRevealPolicy {
    static func needsFilterReset(
        requestedID: UUID?,
        selectedID: UUID?,
        allEntries: [TranscriptionHistoryEntry],
        visibleEntries: [TranscriptionHistoryEntry]
    ) -> Bool {
        guard let selectedID, requestedID == selectedID else { return false }
        return !visibleEntries.contains { $0.id == selectedID }
            && allEntries.contains { $0.id == selectedID }
    }
}

struct TranscriptionHistoryView: View {
    @ObservedObject private var historyStore = TranscriptionHistoryStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme

    @State private var searchQuery: String = ""
    @State private var pinnedOnly = false
    @State private var pinRevealRequest: HistoryPinRevealRequest?
    @State private var showClearConfirmation: Bool = false
    @State private var showReportConfirmation: Bool = false
    @State private var selectedReportEntry: TranscriptionHistoryEntry?
    @State private var audioEntryID: UUID?
    @State private var copiedEntryID: UUID?
    @State private var copyFeedbackTask: Task<Void, Never>?
    @State private var availableAudioFiles: Set<String> = []
    @State private var audioAvailabilityRevision = UUID()
    @FocusState private var listFocused: Bool

    private struct AudioAvailabilityRequest: Equatable {
        let fileNames: [String]
        let revision: UUID
    }

    private var audioAvailabilityRequest: AudioAvailabilityRequest {
        AudioAvailabilityRequest(
            fileNames: self.historyStore.entries.compactMap { $0.audio?.fileName },
            revision: self.audioAvailabilityRevision
        )
    }

    /// Lives in the store so the sidebar search can select a row before this view
    /// exists, and the store's delete and clear paths keep it valid.
    private var selectedEntryID: UUID? {
        get { self.historyStore.selectedEntryID }
        nonmutating set { self.historyStore.selectedEntryID = newValue }
    }

    private var filteredEntries: [TranscriptionHistoryEntry] {
        self.historyStore.search(query: self.searchQuery, starredOnly: self.pinnedOnly, pinnedFirst: true)
    }

    private var selectedEntry: TranscriptionHistoryEntry? {
        guard let id = selectedEntryID else { return self.filteredEntries.first }
        return self.filteredEntries.first(where: { $0.id == id })
    }

    var body: some View {
        HSplitView {
            // MARK: - Left Panel: Entry List

            VStack(spacing: 0) {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    FluidSearchField(text: self.$searchQuery, placeholder: "Search transcriptions...")
                    FluidDropdownPicker("History filter", selectedTitle: self.pinnedOnly ? "Pinned" : "All", selection: self.$pinnedOnly) {
                        Text("All").tag(false)
                        Text("Pinned").tag(true)
                    }
                    .fluidDropdownStyle()
                    .fixedSize()
                }
                .padding(self.theme.metrics.spacing.md)

                if self.historyStore.isLoading {
                    ProgressView("Loading history…")
                        .controlSize(.small)
                        .padding(self.theme.metrics.spacing.md)
                } else if let error = self.historyStore.persistenceError {
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .fluidText(.label)
                            .foregroundStyle(self.theme.look.text)
                        Button("Retry saving history") {
                            self.historyStore.retryPersistence()
                        }
                        .fluidAction()
                    }
                    .padding(self.theme.metrics.spacing.md)
                }

                FluidHairline()

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
            .frame(minWidth: 280, idealWidth: 408, maxWidth: 480)

            // MARK: - Right Panel: Entry Detail

            if let entry = selectedEntry {
                self.entryDetailView(entry)
                    .frame(minWidth: 400)
            } else {
                self.noSelectionView
                    .frame(minWidth: 400)
            }
        }
        .fluidCanvas()
        .onChange(of: self.historyStore.searchSelectionRequest) { _, _ in
            self.revealExternalSelection()
        }
        .onChange(of: self.filteredEntries.map(\.id)) { _, visibleIDs in
            if let selectedEntryID = self.selectedEntryID, visibleIDs.contains(selectedEntryID) { return }
            self.selectedEntryID = visibleIDs.first
        }
        .onChange(of: self.selectedEntry?.id) { _, _ in
            self.audioEntryID = nil
        }
        .onDisappear {
            self.pinRevealRequest = nil
            self.availableAudioFiles = []
            self.audioEntryID = nil
            self.copyFeedbackTask?.cancel()
            self.copiedEntryID = nil
        }
        .onAppear {
            self.audioAvailabilityRevision = UUID()
            self.revealExternalSelection()
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
            Text("This will permanently delete all \(self.historyStore.entries.count) transcription entries, including pinned entries. This action cannot be undone.")
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

    // MARK: - Entry List

    private var entryListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: self.theme.metrics.spacing.xs) {
                    ForEach(self.filteredEntries) { entry in
                        self.entryRow(entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, self.theme.metrics.spacing.sm)
                .padding(.vertical, self.theme.metrics.spacing.sm)
            }
            .focusable()
            .focusEffectDisabled()
            .focused(self.$listFocused)
            .onMoveCommand { direction in
                self.moveSelection(direction, proxy: proxy)
            }
            .onCopyCommand {
                self.copyCommandProviders()
            }
            .onAppear { self.reveal(self.selectedEntryID, with: proxy) }
            .onChange(of: self.historyStore.selectedEntryID) { _, id in self.reveal(id, with: proxy) }
            .task(id: self.pinRevealRequest) {
                guard let request = self.pinRevealRequest else { return }
                // Let the reordered rows reach the list before following the selected one.
                await Task.yield()
                guard !Task.isCancelled, self.pinRevealRequest == request else { return }
                if let id = request.target(selectedID: self.selectedEntryID, visibleIDs: self.filteredEntries.map(\.id)) {
                    proxy.scrollTo(id)
                }
                if self.pinRevealRequest == request { self.pinRevealRequest = nil }
            }
        }
    }

    /// Parent-level handling also runs when no list exists to observe the selection.
    private func revealExternalSelection() {
        guard let request = self.historyStore.searchSelectionRequest else { return }
        defer { self.historyStore.consumeSearchSelectionRequest(request) }
        guard HistorySelectionRevealPolicy.needsFilterReset(
            requestedID: request.entryID,
            selectedID: self.selectedEntryID,
            allEntries: self.historyStore.entries,
            visibleEntries: self.filteredEntries
        ) else { return }
        self.searchQuery = ""
        self.pinnedOnly = false
    }

    /// The parent clears a hidden selection's filters; scroll after that view update.
    private func reveal(_ id: UUID?, with proxy: ScrollViewProxy) {
        guard let id else { return }
        if !self.filteredEntries.contains(where: { $0.id == id }) {
            DispatchQueue.main.async { proxy.scrollTo(id) }
        } else {
            proxy.scrollTo(id)
        }
    }

    private func entryRow(_ entry: TranscriptionHistoryEntry) -> some View {
        let isSelected = self.selectedEntryID == entry.id
        let look = self.theme.look
        let isCopied = self.copiedEntryID == entry.id
        return HistoryHoverRow(isSelected: isSelected) { showsActions in
            ZStack(alignment: .bottomTrailing) {
                Button {
                    self.selectedEntryID = entry.id
                    self.listFocused = true
                } label: {
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs + 2) {
                        HStack(spacing: self.theme.metrics.spacing.sm) {
                            HistoryAppIcon(appName: entry.appName)
                            Spacer(minLength: 4)
                            Text(entry.relativeTimeString)
                                .fluidText(.label)
                                .foregroundStyle(look.tertiaryText)
                        }
                        .padding(.trailing, 36)
                        .frame(minHeight: 28)
                        Text(entry.previewText)
                            .fluidText(.body)
                            .foregroundStyle(look.text)
                            .lineLimit(2).multilineTextAlignment(.leading)
                        HStack(spacing: self.theme.metrics.spacing.sm + 2) {
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
                                    .foregroundStyle(look.text)
                                    .help(entry.aiProcessingError ?? "")
                                    .accessibilityLabel("AI cleanup failed")
                            }
                            Spacer(minLength: 0)
                            if self.settings.showHistoryPerformanceMetrics, let speed = entry.aiTokensPerSecond {
                                Text(TranscriptionHistoryEntry.formattedTokensPerSecond(speed, compact: true))
                                    .foregroundStyle(look.secondaryText)
                                    .monospacedDigit()
                                    .fixedSize()
                                    .help("AI generation speed, in tokens per second—not total processing time")
                            }
                        }
                        .fluidText(.label)
                        .foregroundStyle(look.tertiaryText)
                        .padding(.trailing, 84)
                        .frame(minHeight: 28)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    self.selectedEntryID = entry.id
                    self.listFocused = true
                    self.copyFinalText(entry)
                })
                .help("Double-click to copy final text")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityAction(named: Text("Copy final text")) { self.copyFinalText(entry) }
                .accessibilityAction(named: Text("Report issue")) { self.openFeedbackReport(for: entry) }
                .accessibilityAction(named: Text(entry.isStarred ? "Unpin transcription" : "Pin transcription")) {
                    self.togglePin(entry)
                }
                // Row buttons are not Tab stops: the list is one keyboard stop, arrows move the
                // selection, and every action is also in the detail panel and the right-click menu.
                // Thousands of focusable buttons made each scroll frame rebuild the focus map.
                // Hidden rows fade the actions instead of building them on hover, so a row passing
                // under the pointer only changes opacity. Disabled while hidden so keyboard focus never
                // lands on an invisible button; the row's accessibility actions cover every row.
                HStack(spacing: self.theme.metrics.spacing.xs) {
                    // A tick means "selected" in this look, so a copy says so in words.
                    if isCopied {
                        Text("Copied")
                            .fluidText(.label)
                            .foregroundStyle(look.secondaryText)
                    } else {
                        Button {
                            self.copyFinalText(entry)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .fluidGlassAction(circular: true, quiet: true)
                        .focusable(false)
                        .help("Copy final text")
                        .accessibilityLabel("Copy final text")
                    }
                    Button {
                        self.openFeedbackReport(for: entry)
                    } label: {
                        Image(systemName: "flag")
                    }
                    .fluidGlassAction(circular: true, quiet: true)
                    .focusable(false)
                    .help("Report an issue with this dictation")
                    .accessibilityLabel("Report issue")
                }
                .opacity(showsActions ? 1 : 0)
                .disabled(!showsActions)
                .allowsHitTesting(showsActions)
                .accessibilityHidden(!showsActions)
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    self.togglePin(entry)
                } label: {
                    Image(systemName: entry.isStarred ? "pin.fill" : "pin")
                        .foregroundStyle(entry.isStarred ? look.text : look.tertiaryText)
                }
                .fluidGlassAction(circular: true, quiet: true)
                .focusable(false)
                .help(entry.isStarred ? "Unpin transcription" : "Pin transcription")
                .accessibilityLabel(entry.isStarred ? "Unpin transcription" : "Pin transcription")
                .accessibilityIdentifier("History.Pin.\(entry.id.uuidString)")
            }
        }
        .padding(self.theme.metrics.spacing.md)
        .contextMenu { self.entryActions(entry) }
    }

    @ViewBuilder
    private func entryActions(_ entry: TranscriptionHistoryEntry) -> some View {
        Button {
            self.togglePin(entry)
        } label: {
            Label(entry.isStarred ? "Unpin" : "Pin", systemImage: entry.isStarred ? "pin.slash" : "pin")
        }

        Divider()

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
            Label("Report issue...", systemImage: "flag")
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

    private func togglePin(_ entry: TranscriptionHistoryEntry) {
        self.pinRevealRequest = nil
        self.historyStore.toggleStar(id: entry.id)
        guard self.selectedEntryID == entry.id, self.filteredEntries.contains(where: { $0.id == entry.id }) else { return }
        self.pinRevealRequest = HistoryPinRevealRequest(entryID: entry.id)
    }

    // MARK: - Empty State

    private var emptyStateIcon: String {
        if !self.searchQuery.isEmpty { return "magnifyingglass" }
        return self.pinnedOnly ? "pin" : "clock.arrow.circlepath"
    }

    private var emptyStateTitle: String {
        if !self.searchQuery.isEmpty { return "No Results" }
        return self.pinnedOnly ? "No Pinned Transcriptions" : "No History Yet"
    }

    private var emptyStateMessage: String {
        if !self.searchQuery.isEmpty { return "Try a different search term" }
        return self.pinnedOnly
            ? "Pin a transcription to keep it at the top of History"
            : "Your transcriptions will appear here"
    }

    private var emptyStateView: some View {
        let look = self.theme.look
        return VStack(spacing: self.theme.metrics.spacing.lg) {
            Spacer()

            Image(systemName: self.emptyStateIcon)
                .font(.fluidSystem(size: 36, weight: .light))
                .foregroundStyle(look.tertiaryText)
                .accessibilityHidden(true)

            VStack(spacing: self.theme.metrics.spacing.xs) {
                Text(self.emptyStateTitle)
                    .fluidText(.rowTitle)
                    .foregroundStyle(look.secondaryText)

                Text(self.emptyStateMessage)
                    .fluidText(.label)
                    .foregroundStyle(look.tertiaryText)
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
            FluidHairline()

            HStack {
                Text(self.filteredEntries.count == 1 ? "1 entry" : "\(self.filteredEntries.count) entries")
                    .fluidText(.label)
                    .foregroundStyle(self.theme.look.tertiaryText)

                Spacer()

                if !self.historyStore.entries.isEmpty {
                    Button("Clear All") {
                        self.showClearConfirmation = true
                    }
                    .fluidGlassAction(quiet: true)
                }
            }
            .padding(.leading, self.theme.metrics.spacing.lg)
            .padding(.trailing, self.theme.metrics.spacing.sm)
            .padding(.vertical, self.theme.metrics.spacing.xs)
        }
    }

    // MARK: - Entry Detail View

    private func entryDetailView(_ entry: TranscriptionHistoryEntry) -> some View {
        let spacing = self.theme.metrics.spacing
        return ScrollView {
            VStack(alignment: .leading, spacing: FluidSettingsLayout.groupSpacing) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: spacing.lg) {
                        self.detailHeading(entry)
                        Spacer(minLength: spacing.md)
                        self.detailActions(entry)
                    }
                    VStack(alignment: .leading, spacing: spacing.lg) {
                        self.detailHeading(entry)
                        self.detailActions(entry)
                    }
                }
                if self.audioEntryID == entry.id {
                    HistoryInlineAudioView(entry: entry)
                        .id(entry.id)
                }
                if let error = entry.aiProcessingError {
                    FluidSettingsGroup {
                        FluidSettingsBlock {
                            Label {
                                VStack(alignment: .leading, spacing: spacing.xs) {
                                    Text("AI enhancement failed—raw transcription was used")
                                        .fluidText(.rowTitle)
                                        .foregroundStyle(self.theme.look.text)
                                    Text(error)
                                        .fluidText(.label)
                                        .foregroundStyle(self.theme.look.secondaryText)
                                        .textSelection(.enabled)
                                }
                            } icon: {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(self.theme.look.text)
                            }
                        }
                    }
                }
                HistoryTextComparisonView(entry: entry, copy: self.copyToClipboard)
                    .id(entry.id)
                FluidSettingsGroup(title: "Processing") {
                    FluidSettingsBlock {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: spacing.lg, alignment: .leading)], alignment: .leading, spacing: spacing.lg) {
                            if self.settings.showHistoryPerformanceMetrics {
                                if let duration = entry.parakeetProcessingDurationMilliseconds ?? entry.transcriptionDurationMilliseconds {
                                    self.metadataItem(label: "Transcription", value: TranscriptionHistoryEntry.formattedDuration(milliseconds: duration))
                                }
                                if let duration = entry.aiProcessingDurationMilliseconds {
                                    self.metadataItem(label: "AI cleanup", value: TranscriptionHistoryEntry.formattedDuration(milliseconds: duration))
                                }
                                if let speed = entry.aiTokensPerSecond {
                                    self.metadataItem(label: "AI speed", value: TranscriptionHistoryEntry.formattedTokensPerSecond(speed, compact: true))
                                }
                            }
                            self.metadataItem(
                                label: entry.aiProcessingError == nil ? "AI model" : "AI model (failed)",
                                value: self.recordedModel(entry) ?? (entry.wasAIProcessed ? "Not recorded" : "No AI cleanup")
                            )
                        }
                    }
                }
                FluidSettingsGroup(title: "Details") {
                    FluidSettingsBlock {
                        LazyVGrid(columns: self.detailColumns, alignment: .leading, spacing: spacing.lg) {
                            self.metadataItem(label: "Application", value: entry.appName.isEmpty ? "Unknown" : entry.appName)
                            self.metadataItem(label: "Recording", value: self.recordingDurationText(for: entry))
                            self.metadataItem(label: "Audio size", value: self.audioSizeText(for: entry))
                        }
                    }
                }
            }
            .fluidPageContent()
        }
    }

    private func detailHeading(_ entry: TranscriptionHistoryEntry) -> some View {
        HStack(spacing: self.theme.metrics.spacing.md) {
            FluidGlyphTile(systemImage: "clock.arrow.circlepath", size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Dictation details")
                    .fluidText(.detailTitle)
                    .foregroundStyle(self.theme.look.text)
                Text(entry.fullDateString)
                    .fluidText(.label)
                    .foregroundStyle(self.theme.look.tertiaryText)
            }
        }
    }

    private var detailColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: self.theme.metrics.spacing.lg, alignment: .leading), count: 3)
    }

    private func recordedModel(_ entry: TranscriptionHistoryEntry) -> String? {
        guard let model = entry.processingModel?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else { return nil }
        return ModelDisplayName.forID(model)
    }

    private func detailActions(_ entry: TranscriptionHistoryEntry) -> some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            Button("Report issue") { self.openFeedbackReport(for: entry) }
                .fluidAction()
            Button(self.copiedEntryID == entry.id ? "Copied" : "Copy text") { self.copyFinalText(entry) }
                .fluidAction(.primary)
                .disabled(entry.clipboardText == nil)
            if self.hasAudio(entry) {
                Button(self.audioEntryID == entry.id ? "Close audio" : "Audio") {
                    self.audioEntryID = self.audioEntryID == entry.id ? nil : entry.id
                }
                .fluidAction()
            }
            Menu { self.entryActions(entry) } label: { Image(systemName: "ellipsis") }
                .menuIndicator(.hidden)
                .fluidGlassAction(circular: true, quiet: true)
                .accessibilityLabel("Dictation actions")
        }
        .fixedSize()
    }

    private func metadataItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .fluidText(.label)
                .foregroundStyle(self.theme.look.tertiaryText)
            Text(value)
                .fluidText(.rowTitle)
                .foregroundStyle(self.theme.look.text)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copyFinalText(_ entry: TranscriptionHistoryEntry) {
        guard let text = entry.clipboardText else { return }
        self.copyToClipboard(text)
        self.showCopiedFeedback(for: entry)
    }

    private func showCopiedFeedback(for entry: TranscriptionHistoryEntry) {
        self.copyFeedbackTask?.cancel()
        self.copiedEntryID = entry.id
        self.copyFeedbackTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            self.copiedEntryID = nil
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
        let entries = self.filteredEntries
        guard !entries.isEmpty else { return }
        let current = self.selectedEntryID.flatMap { id in entries.firstIndex(where: { $0.id == id }) }
        let next: Int
        switch direction {
        case .up: next = max((current ?? 0) - 1, 0)
        case .down: next = current.map { min($0 + 1, entries.count - 1) } ?? 0
        default: return
        }
        let id = entries[next].id
        self.selectedEntryID = id
        proxy.scrollTo(id)
    }

    private func copyCommandProviders() -> [NSItemProvider] {
        guard let entry = self.selectedEntry, let text = entry.clipboardText else { return [] }
        ClipboardAudit.record("ui_copy_command")
        self.showCopiedFeedback(for: entry)
        return [NSItemProvider(object: text as NSString)]
    }

    private func copyToClipboard(_ text: String) {
        ClipboardAudit.record("ui_copy_begin")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ClipboardAudit.record("ui_copy_end")
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

    private func recordingDurationText(for entry: TranscriptionHistoryEntry) -> String {
        guard let audio = entry.audio else { return "Not saved" }
        return String(format: "%.1fs", Double(audio.durationMilliseconds) / 1000.0)
    }

    private func audioSizeText(for entry: TranscriptionHistoryEntry) -> String {
        guard let audio = entry.audio else { return "Not saved" }
        guard self.hasAudio(entry) else { return "Unavailable" }
        return ByteCountFormatter.string(fromByteCount: Int64(audio.byteCount), countStyle: .file)
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
        VStack(spacing: self.theme.metrics.spacing.lg) {
            Image(systemName: "text.quote")
                .font(.fluidSystem(size: 40, weight: .light))
                .foregroundStyle(self.theme.look.tertiaryText)
                .accessibilityHidden(true)

            Text("Select a transcription")
                .fluidText(.rowTitle)
                .foregroundStyle(self.theme.look.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        let look = self.theme.look
        let spacing = self.theme.metrics.spacing
        VStack(alignment: .leading, spacing: spacing.lg) {
            VStack(alignment: .leading, spacing: spacing.xs) {
                Text("Share anonymous datapoint")
                    .fluidText(.sheetTitle)
                    .foregroundStyle(look.text)
                Text("Help improve our model. Only the example shown below will be sent.")
                    .fluidText(.body)
                    .foregroundStyle(look.secondaryText)
            }

            self.feedbackField(title: "Raw Text", text: self.$inputText, height: 88)
            self.feedbackField(title: "Processed Text", text: self.$outputText, height: 88)
            self.feedbackField(title: "Processing Model", text: self.$processingModel, height: 40)
            self.feedbackField(title: "Comment optional", text: self.$comment, height: 72)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .fluidText(.label)
                    .foregroundStyle(look.text)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: spacing.sm) {
                Spacer()
                Button("Cancel") {
                    self.dismiss()
                }
                .fluidAction(size: .large)
                .keyboardShortcut(.cancelAction)
                .disabled(self.isSending)

                Button {
                    Task {
                        await self.sendReport()
                    }
                } label: {
                    HStack(spacing: spacing.sm) {
                        if self.isSending {
                            ProgressView()
                                .controlSize(.small)
                                .fixedSize()
                        }
                        Text(self.isSending ? "Sending..." : "Send Example")
                    }
                }
                .fluidAction(.primary, size: .large)
                .keyboardShortcut(.defaultAction)
                .disabled(self.isSendDisabled)
            }
        }
        .padding(spacing.xl)
        .frame(width: 520)
        .background(look.sheet)
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
        let look = self.theme.look
        let shape = RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
        return VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs + 2) {
            Text(title)
                .fluidText(.label)
                .foregroundStyle(look.secondaryText)

            TextEditor(text: text)
                .fluidText(.body)
                .foregroundStyle(look.text)
                .scrollContentBackground(.hidden)
                .padding(self.theme.metrics.spacing.sm)
                .frame(height: height)
                .background(look.quietFill, in: shape)
        }
    }

    private static func reportModel(for entry: TranscriptionHistoryEntry) -> String {
        let model = entry.processingModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return model.isEmpty ? "unknown" : model
    }
}

/// A list row with the shared hover and selected fills. Its row actions show while it is hovered,
/// selected or holds keyboard focus.
/// Hover and selection fill for a History row. `content` learns whether to show the row's actions
/// (hovered or selected). No per-row focus tracking: with thousands of rows it made every scroll
/// frame rebuild SwiftUI's focus map.
private struct HistoryHoverRow<Content: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isSelected: Bool
    @ViewBuilder let content: (Bool) -> Content
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FluidSettingsLayout.cornerRadius, style: .continuous)
        self.content(self.isHovered || self.isSelected)
            .background(
                FluidInteractionVisuals.fill(self.theme.palette, isSelected: self.isSelected, isHovered: self.isHovered),
                in: shape
            )
            // The selected entry is where the eye goes, so it alone gets the aura line.
            .fluidAuraEdge(shape, isOn: self.isSelected)
            .onHover { self.isHovered = $0 }
            .animation(self.reduceMotion ? nil : .easeOut(duration: 0.12), value: self.isHovered)
    }
}

#Preview {
    TranscriptionHistoryView()
        .frame(width: 800, height: 600)
        .environment(\.theme, AppTheme.dark)
}
