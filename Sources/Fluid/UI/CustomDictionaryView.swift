//
//  CustomDictionaryView.swift
//  fluid
//
//  Custom dictionary for correcting commonly misheard words.
//  Created: 2025-12-21
//

import SwiftUI

struct CustomDictionaryView: View {
    @Environment(\.theme) private var theme
    @State private var entries: [SettingsStore.CustomDictionaryEntry] = SettingsStore.shared.customDictionaryEntries
    @State private var showAddSheet = false
    @State private var editingEntry: SettingsStore.CustomDictionaryEntry?

    // Collapsible section states
    @State private var isOfflineSectionExpanded = true
    @State private var isAISectionExpanded = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                self.pageHeader

                // Section 1: Offline/Instant Replacement
                self.offlineReplacementSection

                // Section 2: AI Post-Processing (Coming Soon)
                self.aiPostProcessingSection
            }
            .padding(20)
        }
        .sheet(isPresented: self.$showAddSheet) {
            AddDictionaryEntrySheet(existingTriggers: self.allExistingTriggers()) { newEntry in
                self.entries.append(newEntry)
                self.saveEntries()
            }
        }
        .sheet(item: self.$editingEntry) { entry in
            EditDictionaryEntrySheet(
                entry: entry,
                existingTriggers: self.allExistingTriggers(excluding: entry.id)
            ) { updatedEntry in
                if let index = self.entries.firstIndex(where: { $0.id == updatedEntry.id }) {
                    self.entries[index] = updatedEntry
                    self.saveEntries()
                }
            }
        }
    }

    // MARK: - Page Header

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "text.book.closed.fill")
                    .font(.title2)
                    .foregroundStyle(self.theme.palette.accent)
                Text("Custom Dictionary")
                    .font(.title2)
                    .fontWeight(.semibold)
            }

            Text("Improve transcription accuracy by defining word replacements. Choose between instant offline replacement or AI-powered context-aware corrections.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Section 1: Offline Replacement

    private var offlineReplacementSection: some View {
        ThemedCard(hoverEffect: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Collapsible Header
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.isOfflineSectionExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Image(systemName: self.isOfflineSectionExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)

                        Text("Instant Replacement")
                            .font(.headline)

                        // Offline badge
                        Text("OFFLINE")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.green.opacity(0.2)))
                            .foregroundStyle(.green)

                        Spacer()

                        if !self.entries.isEmpty {
                            Text("\(self.entries.count)")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.quaternary))
                                .foregroundStyle(.secondary)
                        }

                        // Add button (only when expanded and has entries)
                        if self.isOfflineSectionExpanded && !self.entries.isEmpty {
                            Button {
                                self.showAddSheet = true
                            } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if self.isOfflineSectionExpanded {
                    Divider()
                        .padding(.vertical, 12)

                    // Description
                    Text("Simple find-and-replace. Works offline with zero latency. Replacements are applied instantly after transcription.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 12)

                    // Features
                    HStack(spacing: 12) {
                        Label("No AI needed", systemImage: "cpu")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Label("Zero latency", systemImage: "bolt.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Label("Case insensitive", systemImage: "textformat")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 12)

                    // Content
                    if self.entries.isEmpty {
                        self.offlineEmptyState
                    } else {
                        self.entriesListView
                    }
                }
            }
            .padding(14)
        }
    }

    // MARK: - Offline Empty State

    private var offlineEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus.circle.dashed")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)

            Text("No entries yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                self.showAddSheet = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("Add Entry")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(self.theme.palette.accent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - Entries List

    private var entriesListView: some View {
        VStack(spacing: 8) {
            ForEach(self.entries) { entry in
                DictionaryEntryRow(
                    entry: entry,
                    onEdit: { self.editingEntry = entry },
                    onDelete: { self.deleteEntry(entry) }
                )
            }
        }
    }

    // MARK: - Section 2: AI Post-Processing

    private var aiPostProcessingSection: some View {
        ThemedCard(hoverEffect: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Collapsible Header
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.isAISectionExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Image(systemName: self.isAISectionExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)

                        Text("AI Post-Processing")
                            .font(.headline)

                        // AI badge
                        Text("AI")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.purple.opacity(0.2)))
                            .foregroundStyle(.purple)

                        Text("COMING SOON")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tertiary)

                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if self.isAISectionExpanded {
                    Divider()
                        .padding(.vertical, 12)

                    // Description
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Context-aware corrections powered by your AI provider. The AI will understand context and apply intelligent replacements.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        // Planned features
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Context-aware replacements", systemImage: "brain.head.profile")
                            Label("Learns from your corrections", systemImage: "sparkles")
                            Label("Works with technical jargon", systemImage: "wrench.and.screwdriver")
                            Label("Requires AI provider API key", systemImage: "key")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        // Coming soon message
                        HStack {
                            Image(systemName: "hammer.fill")
                                .foregroundStyle(.orange)
                            Text("This feature is under development")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.1)))
                    }
                }
            }
            .padding(14)
        }
    }

    // MARK: - Actions

    private func saveEntries() {
        SettingsStore.shared.customDictionaryEntries = self.entries
        // Invalidate cached regex patterns so changes take effect immediately
        ASRService.invalidateDictionaryCache()
    }

    private func deleteEntry(_ entry: SettingsStore.CustomDictionaryEntry) {
        self.entries.removeAll { $0.id == entry.id }
        self.saveEntries()
    }

    /// Returns all existing trigger words for duplicate detection
    private func allExistingTriggers(excluding entryId: UUID? = nil) -> Set<String> {
        var triggers = Set<String>()
        for entry in self.entries where entry.id != entryId {
            for trigger in entry.triggers {
                triggers.insert(trigger.lowercased())
            }
        }
        return triggers
    }
}

// MARK: - Dictionary Entry Row

struct DictionaryEntryRow: View {
    let entry: SettingsStore.CustomDictionaryEntry
    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Triggers (left side)
            VStack(alignment: .leading, spacing: 4) {
                Text("When heard:")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                FlowLayout(spacing: 4) {
                    ForEach(self.entry.triggers, id: \.self) { trigger in
                        Text(trigger)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Arrow
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            // Replacement (right side)
            VStack(alignment: .leading, spacing: 4) {
                Text("Replace with:")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Text(self.entry.replacement)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(self.theme.palette.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Actions
            HStack(spacing: 6) {
                Button {
                    self.onEdit()
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button(role: .destructive) {
                    self.onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }
}

// MARK: - Add Entry Sheet

struct AddDictionaryEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let existingTriggers: Set<String>
    let onSave: (SettingsStore.CustomDictionaryEntry) -> Void

    @State private var triggersText = ""
    @State private var replacement = ""

    private var duplicateTriggers: [String] {
        self.parseTriggers().filter { self.existingTriggers.contains($0) }
    }

    private var canSave: Bool {
        !self.parseTriggers().isEmpty &&
            !self.replacement.trimmingCharacters(in: .whitespaces).isEmpty &&
            self.duplicateTriggers.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("Add Dictionary Entry")
                    .font(.headline)
                Spacer()
                Button("Cancel") { self.dismiss() }
                    .buttonStyle(.bordered)
            }

            Divider()

            // Triggers input
            VStack(alignment: .leading, spacing: 6) {
                Text("Misheard Words (triggers)")
                    .font(.subheadline.weight(.medium))
                Text("Enter words separated by commas. These are what the transcription might hear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("fluid voice, fluid boys", text: self.$triggersText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { self.saveIfValid() }

                // Duplicate warning
                if !self.duplicateTriggers.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Duplicate triggers: \(self.duplicateTriggers.joined(separator: ", "))")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                }
            }

            // Replacement input
            VStack(alignment: .leading, spacing: 6) {
                Text("Correct Spelling (replacement)")
                    .font(.subheadline.weight(.medium))
                Text("This is what will appear in the final transcription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("FluidVoice", text: self.$replacement)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { self.saveIfValid() }
            }

            Spacer()

            // Preview
            if !self.triggersText.isEmpty && !self.replacement.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preview")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    FlowLayout(spacing: 6) {
                        ForEach(self.parseTriggers(), id: \.self) { trigger in
                            Text(trigger)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 4).fill(
                                        self.duplicateTriggers.contains(trigger)
                                            ? AnyShapeStyle(Color.orange.opacity(0.3))
                                            : AnyShapeStyle(.quaternary)
                                    )
                                )
                        }

                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        Text(self.replacement)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(self.theme.palette.accent)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial))
            }

            // Save button
            HStack {
                Spacer()
                Button("Add Entry") { self.saveIfValid() }
                    .buttonStyle(.borderedProminent)
                    .tint(self.theme.palette.accent)
                    .disabled(!self.canSave)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(20)
        .frame(minWidth: 400, idealWidth: 450, maxWidth: 500)
        .frame(minHeight: 350, idealHeight: 400, maxHeight: 450)
    }

    private func parseTriggers() -> [String] {
        self.triggersText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    private func saveIfValid() {
        guard self.canSave else { return }

        let entry = SettingsStore.CustomDictionaryEntry(
            triggers: self.parseTriggers(),
            replacement: self.replacement.trimmingCharacters(in: .whitespaces)
        )
        self.onSave(entry)
        self.dismiss()
    }
}

// MARK: - Edit Entry Sheet

struct EditDictionaryEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let entry: SettingsStore.CustomDictionaryEntry
    let existingTriggers: Set<String>
    let onSave: (SettingsStore.CustomDictionaryEntry) -> Void

    @State private var triggersText = ""
    @State private var replacement = ""

    private var duplicateTriggers: [String] {
        self.parseTriggers().filter { self.existingTriggers.contains($0) }
    }

    private var canSave: Bool {
        !self.parseTriggers().isEmpty &&
            !self.replacement.trimmingCharacters(in: .whitespaces).isEmpty &&
            self.duplicateTriggers.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("Edit Dictionary Entry")
                    .font(.headline)
                Spacer()
                Button("Cancel") { self.dismiss() }
                    .buttonStyle(.bordered)
            }

            Divider()

            // Triggers input
            VStack(alignment: .leading, spacing: 6) {
                Text("Misheard Words (triggers)")
                    .font(.subheadline.weight(.medium))
                Text("Enter words separated by commas. These are what the transcription might hear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("fluid voice, fluid boys", text: self.$triggersText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { self.saveIfValid() }

                // Duplicate warning
                if !self.duplicateTriggers.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Duplicate triggers: \(self.duplicateTriggers.joined(separator: ", "))")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                }
            }

            // Replacement input
            VStack(alignment: .leading, spacing: 6) {
                Text("Correct Spelling (replacement)")
                    .font(.subheadline.weight(.medium))
                Text("This is what will appear in the final transcription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("FluidVoice", text: self.$replacement)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { self.saveIfValid() }
            }

            Spacer()

            // Preview
            if !self.triggersText.isEmpty && !self.replacement.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preview")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    FlowLayout(spacing: 6) {
                        ForEach(self.parseTriggers(), id: \.self) { trigger in
                            Text(trigger)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 4).fill(
                                        self.duplicateTriggers.contains(trigger)
                                            ? AnyShapeStyle(Color.orange.opacity(0.3))
                                            : AnyShapeStyle(.quaternary)
                                    )
                                )
                        }

                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        Text(self.replacement)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(self.theme.palette.accent)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial))
            }

            // Save button
            HStack {
                Spacer()
                Button("Save Changes") { self.saveIfValid() }
                    .buttonStyle(.borderedProminent)
                    .tint(self.theme.palette.accent)
                    .disabled(!self.canSave)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(20)
        .frame(minWidth: 400, idealWidth: 450, maxWidth: 500)
        .frame(minHeight: 320, idealHeight: 380, maxHeight: 420)
        .onAppear {
            self.triggersText = self.entry.triggers.joined(separator: ", ")
            self.replacement = self.entry.replacement
        }
    }

    private func parseTriggers() -> [String] {
        self.triggersText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    private func saveIfValid() {
        guard self.canSave else { return }

        let updatedEntry = SettingsStore.CustomDictionaryEntry(
            id: self.entry.id,
            triggers: self.parseTriggers(),
            replacement: self.replacement.trimmingCharacters(in: .whitespaces)
        )
        self.onSave(updatedEntry)
        self.dismiss()
    }
}
