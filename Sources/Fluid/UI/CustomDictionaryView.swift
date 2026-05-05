//
//  CustomDictionaryView.swift
//  fluid
//
//  Custom dictionary for correcting commonly misheard words.
//  Created: 2025-12-21
//

import SwiftUI

struct CustomDictionaryView: View {
    private enum SuggestionApprovalResult {
        case applied
        case alreadyPresent
        case conflict(existingReplacement: String)
    }

    private let maxVisibleAutoLearnSuggestions = 5
    private let addedSuggestionConfirmationDelay: TimeInterval = 1.25
    @Environment(\.theme) private var theme
    @State private var entries: [SettingsStore.CustomDictionaryEntry] = SettingsStore.shared.customDictionaryEntries
    @State private var boostTerms: [ParakeetVocabularyStore.VocabularyConfig.Term] = []
    @State private var autoLearnSuggestions: [SettingsStore.AutoLearnSuggestion] = SettingsStore.shared.autoLearnCustomDictionarySuggestions
    @State private var confirmingAddedSuggestionIDs: Set<UUID> = []
    @State private var showAddSheet = false
    @State private var editingEntry: SettingsStore.CustomDictionaryEntry?
    @State private var showAddBoostSheet = false
    @State private var editingBoostTerm: EditableBoostTerm?
    @State private var autoLearnEnabled: Bool = SettingsStore.shared.autoLearnCustomDictionaryEnabled
    @State private var showAutoLearnInfo = false

    // Collapsible section states
    @State private var isAutoLearnSectionExpanded = true
    @State private var isOfflineSectionExpanded = false
    @State private var isAISectionExpanded = true

    @State private var boostStatusMessage = "Add custom words for better Parakeet recognition."
    @State private var boostHasError = false
    @State private var vocabBoostingEnabled: Bool = SettingsStore.shared.vocabularyBoostingEnabled
    @State private var autoLearnStatusMessage: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                self.pageHeader

                self.autoLearnSection

                self.offlineReplacementSection

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
        .sheet(isPresented: self.$showAddBoostSheet) {
            AddBoostTermSheet(existingTerms: self.existingBoostTerms()) { newTerm in
                self.boostTerms.append(newTerm)
                self.saveBoostTerms()
            }
        }
        .sheet(item: self.$editingBoostTerm) { editable in
            EditBoostTermSheet(
                term: editable.term,
                existingTerms: self.existingBoostTerms(excludingIndex: editable.index)
            ) { updatedTerm in
                guard self.boostTerms.indices.contains(editable.index) else { return }
                self.boostTerms[editable.index] = updatedTerm
                self.saveBoostTerms()
            }
        }
        .onAppear {
            self.loadBoostTerms()
            self.reloadAutoLearnSuggestions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .autoLearnSuggestionsDidChange)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                self.reloadAutoLearnSuggestions()
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

            Text("Add words and replacements FluidVoice should remember.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var pendingAutoLearnSuggestions: [SettingsStore.AutoLearnSuggestion] {
        return self.autoLearnSuggestions
            .filter { suggestion in
                guard suggestion.status == .pending else { return false }

                let threshold = AutoLearnDictionaryService.shared.displayThreshold(for: suggestion)
                return suggestion.occurrences >= threshold
            }
            .sorted { lhs, rhs in
                if lhs.occurrences != rhs.occurrences {
                    return lhs.occurrences > rhs.occurrences
                }

                let lhsHighSignal = AutoLearnDictionaryService.shared.isHighSignalReplacement(lhs.replacement)
                let rhsHighSignal = AutoLearnDictionaryService.shared.isHighSignalReplacement(rhs.replacement)
                if lhsHighSignal != rhsHighSignal {
                    return lhsHighSignal
                }

                if lhs.lastObservedAt != rhs.lastObservedAt {
                    return lhs.lastObservedAt > rhs.lastObservedAt
                }

                return lhs.replacement.localizedCaseInsensitiveCompare(rhs.replacement) == .orderedAscending
            }
    }

    private var visibleAutoLearnSuggestions: [SettingsStore.AutoLearnSuggestion] {
        Array(self.pendingAutoLearnSuggestions.prefix(self.maxVisibleAutoLearnSuggestions))
    }

    private var hiddenAutoLearnSuggestionCount: Int {
        max(0, self.pendingAutoLearnSuggestions.count - self.visibleAutoLearnSuggestions.count)
    }

    private var autoLearnSection: some View {
        ThemedCard(hoverEffect: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            self.isAutoLearnSectionExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: self.isAutoLearnSectionExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 16)

                            Text("Replacement Suggestions")
                                .font(.headline)

                            Text("Alpha")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color(red: 1.0, green: 0.35, blue: 0.35)))
                                .foregroundStyle(.white)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        self.showAutoLearnInfo.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "info.circle")
                            Text("How it works")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(self.theme.palette.accent)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(self.theme.palette.accent.opacity(self.showAutoLearnInfo ? 0.14 : 0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(self.theme.palette.accent.opacity(0.30), lineWidth: 1)
                                )
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("How suggestions work")
                    .popover(isPresented: self.$showAutoLearnInfo, arrowEdge: .top) {
                        self.autoLearnInfoPopover
                    }

                    Spacer()

                    if !self.pendingAutoLearnSuggestions.isEmpty {
                        Text("\(self.pendingAutoLearnSuggestions.count)")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary))
                            .foregroundStyle(.secondary)
                    }
                }

                if self.isAutoLearnSectionExpanded {
                    Divider()
                        .padding(.vertical, 12)

                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: self.$autoLearnEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Suggest replacements from corrections")
                                    .font(.subheadline.weight(.medium))
                                Text("When you correct dictated text, FluidVoice can queue likely replacements for review.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: self.autoLearnEnabled) { _, newValue in
                            SettingsStore.shared.autoLearnCustomDictionaryEnabled = newValue
                            if !newValue {
                                AutoLearnDictionaryService.shared.stopMonitoring()
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(self.theme.palette.contentBackground.opacity(0.6))
                        )

                        if let autoLearnStatusMessage {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Color.orange)
                                Text(autoLearnStatusMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.orange.opacity(0.08))
                            )
                        }

                        if self.pendingAutoLearnSuggestions.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "sparkles.rectangle.stack")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.tertiary)
                                Text(
                                    self.autoLearnEnabled
                                        ? "No suggestions yet"
                                        : "Turn this on to review replacement suggestions from future corrections."
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(self.visibleAutoLearnSuggestions) { suggestion in
                                    AutoLearnSuggestionRow(
                                        suggestion: suggestion,
                                        isAdded: self.confirmingAddedSuggestionIDs.contains(suggestion.id),
                                        onApprove: { self.approveSuggestion(suggestion) },
                                        onDismiss: { self.dismissSuggestion(suggestion) }
                                    )
                                }

                                if self.hiddenAutoLearnSuggestionCount > 0 {
                                    Text("\(self.hiddenAutoLearnSuggestionCount) more waiting. Add or dismiss one to show the next.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.top, 4)
                                }
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private var autoLearnInfoPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How suggestions work")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                self.autoLearnInfoRow(
                    icon: "waveform",
                    text: "FluidVoice watches text you just dictated for a short time."
                )
                self.autoLearnInfoRow(
                    icon: "pencil",
                    text: "If you correct that text, FluidVoice can suggest a replacement."
                )
                self.autoLearnInfoRow(
                    icon: "number",
                    text: "Most suggestions appear after 2 corrections. Technical spellings like FluidVoice can appear after 1."
                )
                self.autoLearnInfoRow(
                    icon: "checkmark.circle",
                    text: "Nothing is added to Instant Replacement until you choose Add."
                )
                self.autoLearnInfoRow(
                    icon: "xmark.circle",
                    text: "Dismissed suggestions can return if you make the same correction again."
                )
            }
        }
        .frame(width: 384, alignment: .leading)
        .padding(14)
        .background(self.theme.palette.elevatedCardBackground.opacity(0.98))
        .presentationBackground(self.theme.palette.elevatedCardBackground.opacity(0.98))
    }

    private func autoLearnInfoRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(self.theme.palette.accent)
                .frame(width: 16, alignment: .center)

            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Instant Replacement

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
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.fluidGreen.opacity(0.2)))
                            .foregroundStyle(Color.fluidGreen)

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

    // MARK: - Custom Words (Parakeet)

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

                        Text("Custom Words (Parakeet)")
                            .font(.headline)

                        Text("PARAKEET")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(self.theme.palette.accent.opacity(0.2)))
                            .foregroundStyle(self.theme.palette.accent)

                        Text("\(self.boostTerms.count)")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary))
                            .foregroundStyle(.secondary)

                        Spacer()

                        if self.isAISectionExpanded && !self.boostTerms.isEmpty {
                            Button {
                                self.showAddBoostSheet = true
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

                if self.isAISectionExpanded {
                    Divider()
                        .padding(.vertical, 12)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Add names, product words, and uncommon terms in a simple form.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("Words from Instant Replacement are also used here automatically.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text("Applies when using a Parakeet voice engine.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        HStack {
                            Toggle(isOn: self.$vocabBoostingEnabled) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Vocabulary Boosting")
                                        .font(.subheadline.weight(.medium))
                                    Text("Uses a secondary ML model to improve recognition of custom words. Disable if you experience issues.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .onChange(of: self.vocabBoostingEnabled) { _, newValue in
                                SettingsStore.shared.vocabularyBoostingEnabled = newValue
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(self.theme.palette.contentBackground.opacity(0.6))
                        )

                        if self.boostTerms.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "waveform.and.magnifyingglass")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.tertiary)
                                Text("No custom words yet")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Button {
                                    self.showAddBoostSheet = true
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "plus")
                                        Text("Add Custom Word")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(self.theme.palette.accent)
                                .controlSize(.small)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(Array(self.boostTerms.enumerated()), id: \.offset) { index, term in
                                    BoostTermRow(
                                        term: term,
                                        onEdit: {
                                            self.editingBoostTerm = EditableBoostTerm(index: index, term: term)
                                        },
                                        onDelete: {
                                            self.deleteBoostTerm(at: index)
                                        }
                                    )
                                }
                            }

                            HStack {
                                Button {
                                    self.showAddBoostSheet = true
                                } label: {
                                    Label("Add Word", systemImage: "plus")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(self.theme.palette.accent)
                                .controlSize(.small)

                                Spacer()
                            }
                        }

                        HStack {
                            Image(systemName: self.boostHasError ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(self.boostHasError ? .red : .secondary)
                            Text(self.boostStatusMessage)
                                .font(.caption)
                                .foregroundStyle(self.boostHasError ? .red : .secondary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(self.boostHasError ? Color.red.opacity(0.08) : self.theme.palette.contentBackground.opacity(0.6))
                        )
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
        NotificationCenter.default.post(name: .parakeetVocabularyDidChange, object: nil)
    }

    private func loadBoostTerms() {
        do {
            self.boostTerms = try ParakeetVocabularyStore.shared.loadUserBoostTerms()
            self.boostStatusMessage = "Loaded \(self.boostTerms.count) custom words."
            self.boostHasError = false
        } catch {
            self.boostTerms = []
            self.boostStatusMessage = "Couldn't load custom words: \(error.localizedDescription)"
            self.boostHasError = true
        }
    }

    private func reloadAutoLearnSuggestions() {
        self.autoLearnSuggestions = SettingsStore.shared.autoLearnCustomDictionarySuggestions
        self.autoLearnEnabled = SettingsStore.shared.autoLearnCustomDictionaryEnabled
    }

    private func saveAutoLearnSuggestions() {
        SettingsStore.shared.autoLearnCustomDictionarySuggestions = self.autoLearnSuggestions
    }

    private func approveSuggestion(_ suggestion: SettingsStore.AutoLearnSuggestion) {
        let trigger = suggestion.originalText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let replacement = suggestion.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty, !replacement.isEmpty else { return }

        switch self.applySuggestion(trigger: trigger, replacement: replacement) {
        case .applied:
            self.autoLearnStatusMessage = nil
            self.saveEntries()
            self.confirmAndRemoveApprovedSuggestion(suggestion)
        case .alreadyPresent:
            self.autoLearnStatusMessage = nil
            self.confirmAndRemoveApprovedSuggestion(suggestion)
        case .conflict(let existingReplacement):
            self.autoLearnStatusMessage =
                "\"\(trigger)\" already maps to \"\(existingReplacement)\". Review the existing dictionary entry before approving this suggestion."
        }
    }

    private func confirmAndRemoveApprovedSuggestion(_ suggestion: SettingsStore.AutoLearnSuggestion) {
        withAnimation(.easeInOut(duration: 0.15)) {
            self.confirmingAddedSuggestionIDs.insert(suggestion.id)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + self.addedSuggestionConfirmationDelay) {
            guard self.confirmingAddedSuggestionIDs.contains(suggestion.id) else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                self.autoLearnSuggestions.removeAll { $0.id == suggestion.id }
                self.confirmingAddedSuggestionIDs.remove(suggestion.id)
            }
            self.saveAutoLearnSuggestions()
        }
    }

    private func dismissSuggestion(_ suggestion: SettingsStore.AutoLearnSuggestion) {
        guard let index = self.autoLearnSuggestions.firstIndex(where: { $0.id == suggestion.id }) else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            self.autoLearnSuggestions[index].status = .dismissed
            self.autoLearnSuggestions[index].dismissedAtOccurrenceCount = self.autoLearnSuggestions[index].occurrences
            self.confirmingAddedSuggestionIDs.remove(suggestion.id)
        }
        self.saveAutoLearnSuggestions()
    }

    private func applySuggestion(trigger: String, replacement: String) -> SuggestionApprovalResult {
        if let mappedEntry = self.entries.first(where: { $0.triggers.contains(trigger) }) {
            if mappedEntry.replacement.caseInsensitiveCompare(replacement) == .orderedSame {
                return .alreadyPresent
            }
            return .conflict(existingReplacement: mappedEntry.replacement)
        }

        if let index = self.entries.firstIndex(where: { $0.replacement.caseInsensitiveCompare(replacement) == .orderedSame }) {
            if self.entries[index].triggers.contains(trigger) {
                return .alreadyPresent
            }
            self.entries[index].triggers.append(trigger)
            self.entries[index].triggers = Array(Set(self.entries[index].triggers)).sorted()
            return .applied
        }

        self.entries.append(
            SettingsStore.CustomDictionaryEntry(
                triggers: [trigger],
                replacement: replacement
            )
        )
        return .applied
    }

    private func saveBoostTerms() {
        do {
            try ParakeetVocabularyStore.shared.saveUserBoostTerms(self.boostTerms)
            self.boostStatusMessage = "Saved \(self.boostTerms.count) custom words."
            self.boostHasError = false
        } catch {
            self.boostStatusMessage = "Couldn't save custom words: \(error.localizedDescription)"
            self.boostHasError = true
        }
    }

    private func deleteBoostTerm(at index: Int) {
        guard self.boostTerms.indices.contains(index) else { return }
        self.boostTerms.remove(at: index)
        self.saveBoostTerms()
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

    private func existingBoostTerms(excludingIndex: Int? = nil) -> Set<String> {
        var terms: Set<String> = []
        for (index, term) in self.boostTerms.enumerated() where index != excludingIndex {
            terms.insert(term.text.lowercased())
        }
        return terms
    }
}

private struct EditableBoostTerm: Identifiable {
    let id = UUID()
    let index: Int
    let term: ParakeetVocabularyStore.VocabularyConfig.Term
}

private enum BoostStrengthPreset: String, CaseIterable, Identifiable {
    case mild = "Mild"
    case balanced = "Balanced"
    case strong = "Strong"

    var id: String { self.rawValue }

    var weight: Float {
        switch self {
        case .mild: return 5.0
        case .balanced: return 10.0
        case .strong: return 13.0
        }
    }

    var hint: String {
        switch self {
        case .mild: return "Very light nudge with minimal impact."
        case .balanced: return "Best default for most names and product terms."
        case .strong: return "Use when this word should win more often in noisy audio."
        }
    }

    static func nearest(for weight: Float) -> Self {
        if weight < 8.5 { return .mild }
        if weight > 11.5 { return .strong }
        return .balanced
    }
}

// MARK: - Boost Term Row

struct BoostTermRow: View {
    let term: ParakeetVocabularyStore.VocabularyConfig.Term
    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(self.term.text)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(self.theme.palette.accent)
            }

            Spacer()

            if let weight = self.term.weight {
                Text("\(BoostStrengthPreset.nearest(for: weight).rawValue) priority")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary))
                    .foregroundStyle(.secondary)
            }

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

// MARK: - Add Boost Term Sheet

struct AddBoostTermSheet: View {
    @Environment(\.dismiss) private var dismiss

    let existingTerms: Set<String>
    let onSave: (ParakeetVocabularyStore.VocabularyConfig.Term) -> Void

    @State private var termText = ""
    @State private var strength: BoostStrengthPreset = .balanced

    private var normalizedTerm: String {
        self.termText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDuplicate: Bool {
        self.existingTerms.contains(self.normalizedTerm.lowercased())
    }

    private var canSave: Bool {
        !self.normalizedTerm.isEmpty && !self.isDuplicate
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Add Custom Word")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Preferred Word or Phrase")
                        .font(.subheadline.weight(.medium))
                    TextField("FluidVoice", text: self.$termText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { self.saveIfValid() }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Word Priority")
                        .font(.subheadline.weight(.medium))
                    Picker("Word Priority", selection: self.$strength) {
                        ForEach(BoostStrengthPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(self.strength.hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if self.isDuplicate {
                    Text("This term already exists.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Button("Cancel") { self.dismiss() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Save") { self.saveIfValid() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!self.canSave)
                        .keyboardShortcut(.return, modifiers: [])
                }
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 460, maxWidth: 520)
        .frame(minHeight: 300, idealHeight: 340, maxHeight: 460)
        .onAppear {
            // Always start new entries at the recommended default.
            self.termText = ""
            self.strength = .balanced
        }
    }

    private func saveIfValid() {
        guard self.canSave else { return }
        self.onSave(
            ParakeetVocabularyStore.VocabularyConfig.Term(
                text: self.normalizedTerm,
                weight: self.strength.weight,
                aliases: []
            )
        )
        self.dismiss()
    }
}

// MARK: - Edit Boost Term Sheet

struct EditBoostTermSheet: View {
    @Environment(\.dismiss) private var dismiss

    let term: ParakeetVocabularyStore.VocabularyConfig.Term
    let existingTerms: Set<String>
    let onSave: (ParakeetVocabularyStore.VocabularyConfig.Term) -> Void

    @State private var termText = ""
    @State private var strength: BoostStrengthPreset = .balanced

    private var normalizedTerm: String {
        self.termText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDuplicate: Bool {
        self.existingTerms.contains(self.normalizedTerm.lowercased())
    }

    private var canSave: Bool {
        !self.normalizedTerm.isEmpty && !self.isDuplicate
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Edit Custom Word")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Preferred Word or Phrase")
                        .font(.subheadline.weight(.medium))
                    TextField("FluidVoice", text: self.$termText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { self.saveIfValid() }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Word Priority")
                        .font(.subheadline.weight(.medium))
                    Picker("Word Priority", selection: self.$strength) {
                        ForEach(BoostStrengthPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(self.strength.hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if self.isDuplicate {
                    Text("This term already exists.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Button("Cancel") { self.dismiss() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Save") { self.saveIfValid() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!self.canSave)
                        .keyboardShortcut(.return, modifiers: [])
                }
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 460, maxWidth: 520)
        .frame(minHeight: 300, idealHeight: 340, maxHeight: 460)
        .onAppear {
            self.termText = self.term.text
            self.strength = BoostStrengthPreset.nearest(for: self.term.weight ?? BoostStrengthPreset.balanced.weight)
        }
    }

    private func saveIfValid() {
        guard self.canSave else { return }
        self.onSave(
            ParakeetVocabularyStore.VocabularyConfig.Term(
                text: self.normalizedTerm,
                weight: self.strength.weight,
                aliases: self.term.aliases
            )
        )
        self.dismiss()
    }
}

// MARK: - Dictionary Entry Row

private let dictionaryRowActionColumnWidth: CGFloat = 112
private let suggestionActionButtonHeight: CGFloat = 24
private let suggestionAddButtonWidth: CGFloat = 62
private let suggestionDismissButtonWidth: CGFloat = 24
private let suggestionActionButtonCornerRadius: CGFloat = 5
private let suggestionDismissIconFont = Font.system(size: 9, weight: .medium)

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
            .frame(width: dictionaryRowActionColumnWidth, alignment: .trailing)
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
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(self.theme.palette.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(self.theme.palette.cardBorder.opacity(0.5), lineWidth: 1)
                        )
                )
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
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(self.theme.palette.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(self.theme.palette.cardBorder.opacity(0.5), lineWidth: 1)
                        )
                )
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

// MARK: - AutoLearn Suggestion Row

struct AutoLearnSuggestionRow: View {
    let suggestion: SettingsStore.AutoLearnSuggestion
    let isAdded: Bool
    let onApprove: () -> Void
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Left: original text + metadata
            VStack(alignment: .leading, spacing: 5) {
                Text("When heard:")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Text(self.suggestion.originalText)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))

                HStack(spacing: 6) {
                    Text(self.occurrenceText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Text("·")
                        .foregroundStyle(.quaternary)

                    Text(self.relativeTimestamp)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Centre: directional arrow
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            // Right: replacement text
            VStack(alignment: .leading, spacing: 5) {
                Text("Replace with:")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Text(self.suggestion.replacement)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(self.theme.palette.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Actions
            HStack(spacing: 6) {
                Button {
                    if !self.isAdded {
                        self.onApprove()
                    }
                } label: {
                    HStack(spacing: 4) {
                        if self.isAdded {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                        }

                        Text(self.isAdded ? "Added" : "Add")
                    }
                        .font(.caption2.weight(.semibold))
                        .frame(width: suggestionAddButtonWidth, height: suggestionActionButtonHeight)
                        .foregroundStyle(self.theme.palette.accent)
                        .background(
                            RoundedRectangle(cornerRadius: suggestionActionButtonCornerRadius)
                                .fill(self.theme.palette.accent.opacity(self.isAdded ? 0.18 : 0.10))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: suggestionActionButtonCornerRadius)
                                .stroke(
                                    self.theme.palette.accent.opacity(self.isAdded ? 0.55 : 0.34),
                                    lineWidth: 1
                                )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(self.isAdded ? "Added to Instant Replacement" : "Add to Instant Replacement")
                .accessibilityLabel(self.isAdded ? "Added to Instant Replacement" : "Add to Instant Replacement")

                Button {
                    self.onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(suggestionDismissIconFont)
                        .frame(width: suggestionDismissButtonWidth, height: suggestionActionButtonHeight)
                        .foregroundStyle(.secondary)
                        .background(
                            RoundedRectangle(cornerRadius: suggestionActionButtonCornerRadius)
                                .fill(Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: suggestionActionButtonCornerRadius)
                                .stroke(Color.white.opacity(0.16), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(self.isAdded)
                .help("Dismiss for now")
                .accessibilityLabel("Dismiss this suggestion for now")
            }
            .frame(width: dictionaryRowActionColumnWidth, alignment: .trailing)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
        .transition(.opacity.combined(with: .move(edge: .top)))
        .animation(.easeInOut(duration: 0.15), value: self.isAdded)
    }

    private var relativeTimestamp: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self.suggestion.lastObservedAt, relativeTo: Date())
    }

    private var occurrenceText: String {
        self.suggestion.occurrences == 1
            ? "1 correction"
            : "\(self.suggestion.occurrences) corrections"
    }
}
