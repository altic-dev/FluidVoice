import SwiftUI

struct TranscriptionHistoryView: View {
    @ObservedObject private var historyStore = TranscriptionHistoryStore.shared
    @Environment(\.theme) private var theme

    @State private var searchQuery: String = ""
    @State private var showClearConfirmation: Bool = false
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
        .alert(isPresented: self.$showClearConfirmation) {
            Alert(
                title: Text("Clear All History"),
                message: Text("This will permanently delete all \(self.historyStore.entries.count) transcription entries. This action cannot be undone."),
                primaryButton: .destructive(Text("Clear All")) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.historyStore.clearAllHistory()
                        self.selectedEntryID = nil
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)

            TextField("Search transcriptions...", text: self.$searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))

            if !self.searchQuery.isEmpty {
                Button {
                    self.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
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
                        .foregroundColor(isSelected ? .white : .secondary)
                        .lineLimit(1)

                    if entry.wasAIProcessed {
                        Text("AI")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(isSelected ? .white.opacity(0.8) : self.theme.palette.accent)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(isSelected ? .white.opacity(0.2) : self.theme.palette.accent.opacity(0.15))
                            )
                    }

                    Spacer()

                    Text(entry.relativeTimeString)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(isSelected ? .white.opacity(0.7) : Color.secondary.opacity(0.6))
                }

                // Preview text
                Text(entry.previewText)
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .white.opacity(0.9) : .primary)
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
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.processedText, forType: .string)
            } label: {
                Label("Copy Text", systemImage: "doc.on.doc")
            }

            if entry.wasAIProcessed {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.rawText, forType: .string)
                } label: {
                    Label("Copy Raw Text", systemImage: "doc.on.doc.fill")
                }
            }

            Divider()

            Button {
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
                .foregroundColor(.secondary)

            VStack(spacing: 4) {
                Text(self.searchQuery.isEmpty ? "No History Yet" : "No Results")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)

                Text(self.searchQuery.isEmpty
                    ? "Your transcriptions will appear here"
                    : "Try a different search term")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
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
                    .foregroundColor(.secondary)

                Spacer()

                // Clear All Button
                if !self.historyStore.entries.isEmpty {
                    Button {
                        self.showClearConfirmation = true
                    } label: {
                        Text("Clear All")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
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
                    HStack {
                        Text("Transcription Details")
                            .font(.system(size: 18, weight: .semibold))

                        Spacer()

                        // Copy button
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.processedText, forType: .string)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.system(size: 12, weight: .medium))
                        }
                        
                        
                    }

                    Text(entry.fullDateString)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }

                Divider()
                    .opacity(0.3)

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
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            let nextEntry = self.filteredEntries.first(where: { $0.id != entry.id })
                            self.historyStore.deleteEntry(id: entry.id)
                            self.selectedEntryID = nextEntry?.id
                        }
                    } label: {
                        Label("Delete Entry", systemImage: "trash")
                            .font(.system(size: 12, weight: .medium))
                    }
                    
                    .accentColor(.red)
                    
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
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                if let badge = badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(self.theme.palette.accent)
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
                .foregroundColor(isSecondary ? .secondary : .primary)
                
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
                .foregroundColor(.secondary)
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
            }
        }
    }

    private func metadataItem(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)

                Text(value)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(self.theme.palette.cardBackground.opacity(0.9)))
    }

    // MARK: - No Selection View

    private var noSelectionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.quote")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.secondary)

            Text("Select a transcription")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(self.theme.palette.contentBackground)
    }
}

struct TranscriptionHistoryView_Previews: PreviewProvider {
    static var previews: some View {
        TranscriptionHistoryView()
            .frame(width: 800, height: 600)
            .environment(\.theme, AppTheme.dark)
    }
}
