//
//  TranscriptionHistoryView.swift
//  Fluid
//
//  Transcription history browser with search and detail view
//

import SwiftUI

struct TranscriptionHistoryView: View {
    @ObservedObject private var historyStore = TranscriptionHistoryStore.shared
    @Environment(\.theme) private var theme
    
    @State private var searchQuery: String = ""
    @State private var showClearConfirmation: Bool = false
    @State private var selectedEntryID: UUID?
    
    private var filteredEntries: [TranscriptionHistoryEntry] {
        historyStore.search(query: searchQuery)
    }
    
    private var selectedEntry: TranscriptionHistoryEntry? {
        guard let id = selectedEntryID else { return filteredEntries.first }
        return filteredEntries.first(where: { $0.id == id })
    }
    
    var body: some View {
        HSplitView {
            // MARK: - Left Panel: Entry List
            VStack(spacing: 0) {
                // Search Bar
                searchBar
                    .padding(12)
                
                Divider()
                    .opacity(0.3)
                
                // Entry List
                if filteredEntries.isEmpty {
                    emptyStateView
                } else {
                    entryListView
                }
                
                // Footer with stats and clear button
                footerView
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
            .background(theme.palette.cardBackground.opacity(0.3))
            
            // MARK: - Right Panel: Entry Detail
            if let entry = selectedEntry {
                entryDetailView(entry)
                    .frame(minWidth: 400)
            } else {
                noSelectionView
                    .frame(minWidth: 400)
            }
        }
        .onAppear {
            if selectedEntryID == nil {
                selectedEntryID = filteredEntries.first?.id
            }
        }
        .alert("Clear All History", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear All", role: .destructive) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    historyStore.clearAllHistory()
                    selectedEntryID = nil
                }
            }
        } message: {
            Text("This will permanently delete all \(historyStore.entries.count) transcription entries. This action cannot be undone.")
        }
    }
    
    // MARK: - Search Bar
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            
            TextField("Search transcriptions...", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
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
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
    
    // MARK: - Entry List
    private var entryListView: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filteredEntries) { entry in
                    entryRow(entry)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }
    
    private func entryRow(_ entry: TranscriptionHistoryEntry) -> some View {
        let isSelected = selectedEntryID == entry.id
        
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedEntryID = entry.id
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
                            .foregroundStyle(isSelected ? .white.opacity(0.8) : theme.palette.accent)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(isSelected ? .white.opacity(0.2) : theme.palette.accent.opacity(0.15))
                            )
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
                    .fill(isSelected ? theme.palette.accent : Color.clear)
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
            
            Button(role: .destructive) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    historyStore.deleteEntry(id: entry.id)
                    if selectedEntryID == entry.id {
                        selectedEntryID = filteredEntries.first(where: { $0.id != entry.id })?.id
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
            
            Image(systemName: searchQuery.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            
            VStack(spacing: 4) {
                Text(searchQuery.isEmpty ? "No History Yet" : "No Results")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                
                Text(searchQuery.isEmpty 
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
                Text("\(historyStore.entries.count) entries")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                
                Spacer()
                
                // Clear All Button
                if !historyStore.entries.isEmpty {
                    Button {
                        showClearConfirmation = true
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
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    
                    Text(entry.fullDateString)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                
                Divider()
                    .opacity(0.3)
                
                // Final Text Section
                detailSection(
                    title: "Final Text",
                    content: entry.processedText,
                    badge: entry.wasAIProcessed ? "AI Enhanced" : nil
                )
                
                // Raw Text Section (only if different)
                if entry.wasAIProcessed {
                    detailSection(
                        title: "Original Transcription",
                        content: entry.rawText,
                        badge: nil,
                        isSecondary: true
                    )
                }
                
                Divider()
                    .opacity(0.3)
                
                // Metadata Grid
                metadataGrid(entry)
                
                Spacer(minLength: 20)
                
                // Delete Button
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            let nextEntry = filteredEntries.first(where: { $0.id != entry.id })
                            historyStore.deleteEntry(id: entry.id)
                            selectedEntryID = nextEntry?.id
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
        .background(theme.palette.cardBackground.opacity(0.15))
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
                        .foregroundStyle(theme.palette.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(theme.palette.accent.opacity(0.15))
                        )
                }
            }
            
            Text(content)
                .font(.system(size: 14, design: .default))
                .foregroundStyle(isSecondary ? .secondary : .primary)
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(.white.opacity(isSecondary ? 0.04 : 0.08), lineWidth: 1)
                        )
                )
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
                GridItem(.flexible(), spacing: 16)
            ], spacing: 12) {
                metadataItem(icon: "app.fill", label: "Application", value: entry.appName.isEmpty ? "Unknown" : entry.appName)
                metadataItem(icon: "macwindow", label: "Window", value: entry.windowTitle.isEmpty ? "Unknown" : entry.windowTitle)
                metadataItem(icon: "character.cursor.ibeam", label: "Characters", value: "\(entry.characterCount)")
                metadataItem(icon: "sparkles", label: "AI Processed", value: entry.wasAIProcessed ? "Yes" : "No")
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
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial.opacity(0.5))
        )
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
        .background(theme.palette.cardBackground.opacity(0.15))
    }
}

#Preview {
    TranscriptionHistoryView()
        .frame(width: 800, height: 600)
        .environment(\.theme, AppTheme.dark)
}

