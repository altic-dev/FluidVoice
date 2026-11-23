import SwiftUI

struct DictionaryHomeActions {
    let addWord: () -> Void
    let edit: (SettingsStore.CustomDictionaryEntry) -> Void
    let delete: (SettingsStore.CustomDictionaryEntry) -> Void
    let importDictionary: () -> Void
    let exportDictionary: () -> Void
    let openCustomWords: () -> Void
}

/// The dictionary landing page: saved words at a glance, with adding a word one click away.
struct DictionaryHomeList<CustomWords: View>: View {
    let entries: [SettingsStore.CustomDictionaryEntry]
    let notice: String?
    let actions: DictionaryHomeActions
    @Binding var isCustomWordsPresented: Bool
    @ViewBuilder let customWords: () -> CustomWords

    @State private var searchText = ""
    @State private var pendingDeletion: SettingsStore.CustomDictionaryEntry?
    @State private var isMoreMenuPresented = false

    @Environment(\.theme) private var theme

    private let columnWidth: CGFloat = 720
    private var pageInset: CGFloat {
        self.theme.metrics.spacing.lg * 2
    }

    /// Row highlights extend past the column so row text lines up with the header.
    private var rowOutset: CGFloat {
        self.theme.metrics.spacing.md
    }

    private var filteredEntries: [SettingsStore.CustomDictionaryEntry] {
        let query = self.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = query.isEmpty ? self.entries : self.entries.filter { entry in
            entry.replacement.localizedCaseInsensitiveContains(query) ||
                entry.triggers.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return matches.sorted { $0.replacement.localizedCaseInsensitiveCompare($1.replacement) == .orderedAscending }
    }

    private var groupedEntries: [(key: String, entries: [SettingsStore.CustomDictionaryEntry])] {
        var order: [String] = []
        var buckets: [String: [SettingsStore.CustomDictionaryEntry]] = [:]
        for entry in self.filteredEntries {
            let key = Self.sectionKey(for: entry.replacement)
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(entry)
        }
        return order.map { (key: $0, entries: buckets[$0] ?? []) }
    }

    private static func sectionKey(for word: String) -> String {
        guard let first = word.trimmingCharacters(in: .whitespacesAndNewlines).first, first.isLetter else { return "#" }
        return String(first).uppercased()
    }

    var body: some View {
        VStack(spacing: 0) {
            self.header
            self.content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .alert("Remove word?", isPresented: Binding(
            get: { self.pendingDeletion != nil },
            set: { if !$0 { self.pendingDeletion = nil } }
        )) {
            Button("Cancel", role: .cancel) { self.pendingDeletion = nil }
            Button("Remove", role: .destructive) {
                if let entry = self.pendingDeletion { self.actions.delete(entry) }
                self.pendingDeletion = nil
            }
        } message: {
            Text("This removes the saved corrections and pronunciation for this word.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            self.titleRow
            Text("FluidVoice fixes these words in dictation and finished meeting transcripts.")
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let notice {
                Label(notice, systemImage: "info.circle")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !self.entries.isEmpty {
                self.searchField
            }
        }
        .frame(maxWidth: self.columnWidth)
        .padding(.horizontal, self.pageInset)
        .padding(.top, self.pageInset)
        .padding(.bottom, self.theme.metrics.spacing.md)
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: self.theme.metrics.spacing.sm) {
            MeetingDocumentTitle(title: "Dictionary")
            Text("\(self.entries.count)")
                .font(self.theme.typography.badge)
                .foregroundStyle(self.theme.palette.secondaryText)
            Spacer()
            FluidGlassControlGroup {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    Button(action: self.actions.addWord) {
                        Label("Add word", systemImage: "plus")
                    }
                    .meetingGlassAction(prominent: true, spacious: true)

                    Button { self.isMoreMenuPresented.toggle() } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(self.theme.palette.primaryText)
                    }
                    .fluidGlassAction(circular: true, spacious: true)
                    .accessibilityLabel("More dictionary actions")
                    .help("Import, export, and advanced options")
                    .popover(isPresented: self.$isMoreMenuPresented, arrowEdge: .bottom) {
                        self.moreMenu
                    }
                }
            }
            .fixedSize()
            // Anchored apart from the More button so the two popovers never compete for one anchor.
            .popover(isPresented: self.$isCustomWordsPresented, arrowEdge: .bottom) {
                self.customWords()
            }
        }
    }

    private var moreMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            DictionaryMenuItem(title: "Import…", systemImage: "square.and.arrow.down") {
                self.runFromMoreMenu(self.actions.importDictionary)
            }
            DictionaryMenuItem(title: "Export…", systemImage: "square.and.arrow.up") {
                self.runFromMoreMenu(self.actions.exportDictionary)
            }
            .disabled(self.entries.isEmpty)
            Divider().padding(.vertical, 4)
            DictionaryMenuItem(title: "Custom Words (Advanced)…", systemImage: "slider.horizontal.3") {
                self.runFromMoreMenu(self.actions.openCustomWords)
            }
        }
        .padding(6)
        .frame(minWidth: 240)
    }

    /// Waits for the menu popover to close so the next sheet, panel, or popover can present.
    private func runFromMoreMenu(_ action: @escaping () -> Void) {
        self.isMoreMenuPresented = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            action()
        }
    }

    private var searchField: some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search words", text: self.$searchText).textFieldStyle(.plain)
            if !self.searchText.isEmpty {
                Button { self.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .meetingHoverFeedback()
                .accessibilityLabel("Clear word search")
            }
        }
        .padding(self.theme.metrics.spacing.md)
        .fluidDropdownSurface()
    }

    @ViewBuilder
    private var content: some View {
        if self.entries.isEmpty {
            ContentUnavailableView {
                Label("No words yet", systemImage: "character.book.closed")
            } description: {
                Text("Add names, brands, and jargon FluidVoice gets wrong. Say each one a few times and it learns how you pronounce it.")
            } actions: {
                Button(action: self.actions.addWord) {
                    Label("Add your first word", systemImage: "plus")
                }
                .fluidGlassAction(prominent: true, tone: self.theme.palette.accent)
            }
            .frame(maxHeight: .infinity)
        } else if self.filteredEntries.isEmpty {
            ContentUnavailableView.search(text: self.searchText)
                .frame(maxHeight: .infinity)
        } else {
            self.entryList
        }
    }

    private var entryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(self.groupedEntries, id: \.key) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            self.row(for: entry)
                        }
                    } header: {
                        Text(group.key)
                            .font(self.theme.typography.caption)
                            .foregroundStyle(self.theme.palette.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, self.rowOutset)
                            .padding(.top, self.theme.metrics.spacing.lg)
                            .padding(.bottom, self.theme.metrics.spacing.xs)
                    }
                }
            }
            .frame(maxWidth: self.columnWidth + self.rowOutset * 2)
            .padding(.horizontal, self.pageInset - self.rowOutset)
            .padding(.bottom, self.pageInset)
            .frame(maxWidth: .infinity)
        }
    }

    private func row(for entry: SettingsStore.CustomDictionaryEntry) -> some View {
        DictionaryHomeRow(
            entry: entry,
            onSelect: { self.actions.edit(entry) },
            onDelete: { self.pendingDeletion = entry }
        )
        .contextMenu {
            Button("Edit…", systemImage: "pencil") { self.actions.edit(entry) }
            Divider()
            Button("Remove Word…", systemImage: "trash", role: .destructive) { self.pendingDeletion = entry }
        }
    }
}

private struct DictionaryHomeRow: View {
    let entry: SettingsStore.CustomDictionaryEntry
    let onSelect: () -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var triggerText: String {
        self.entry.triggers.isEmpty ? "Learned from your voice" : self.entry.triggers.joined(separator: ", ")
    }

    private var highlighted: Bool {
        self.isHovered && self.isEnabled
    }

    var body: some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            Button(action: self.onSelect) {
                HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) {
                    Image(systemName: "textformat")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .frame(width: 18, height: 22)
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                        Text(self.entry.replacement)
                            .font(self.theme.typography.bodyStrong)
                            .foregroundStyle(self.theme.palette.primaryText)
                            .lineLimit(1)
                        HStack(spacing: self.theme.metrics.spacing.xs) {
                            if !self.entry.triggers.isEmpty {
                                Text("Fixes").foregroundStyle(self.theme.palette.tertiaryText)
                            }
                            Text(self.triggerText).lineLimit(1).truncationMode(.tail)
                            if self.entry.caseSensitive {
                                Text("·").foregroundStyle(self.theme.palette.tertiaryText)
                                Text("Match case")
                            }
                        }
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(self.theme.metrics.spacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(self.entry.replacement), fixes \(self.triggerText)")
            .accessibilityHint("Opens the word for editing")

            Button(action: self.onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.theme.palette.secondaryText)
            .meetingHoverFeedback()
            .help("Remove word")
            .accessibilityLabel("Remove \(self.entry.replacement)")
            .padding(.trailing, self.theme.metrics.spacing.sm)
        }
        .background {
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.highlighted ? self.theme.palette.primaryText.opacity(0.06) : .clear)
                .allowsHitTesting(false)
        }
        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.14), value: self.highlighted)
        .onHover { self.isHovered = $0 && self.isEnabled }
        .onDisappear { self.isHovered = false }
    }
}

private struct DictionaryMenuItem: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Button(action: self.action) {
            Label(self.title, systemImage: self.systemImage)
                .font(self.theme.typography.body)
                .foregroundStyle(self.isEnabled ? self.theme.palette.primaryText : self.theme.palette.tertiaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    self.isHovered && self.isEnabled ? self.theme.palette.primaryText.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
    }
}
