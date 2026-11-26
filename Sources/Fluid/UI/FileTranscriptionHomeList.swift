import SwiftUI

struct FileTranscriptDaySection: Identifiable {
    let date: Date
    let entries: [FileTranscriptionEntry]
    var id: Date {
        self.date
    }

    var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self.date) { return "Today" }
        if calendar.isDateInYesterday(self.date) { return "Yesterday" }
        return self.date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// The library only renders short previews. Transcript text is created after opening a document.
struct FileTranscriptionHomeList: View {
    let sections: [FileTranscriptDaySection]
    let previews: [UUID: String]
    let isSearching: Bool
    let onOpen: (FileTranscriptionEntry) -> Void
    let onRename: (UUID, String) -> Void
    let onCopy: (FileTranscriptionEntry) -> Void
    let onExport: (FileTranscriptionEntry, FileTranscriptionView.ExportFormat) -> Void
    let onDelete: (FileTranscriptionEntry) -> Void

    @Environment(\.theme) private var theme
    @State private var renamingEntry: FileTranscriptionEntry?
    @State private var renameDraft = ""

    var body: some View {
        Group {
            if self.sections.isEmpty {
                ContentUnavailableView(
                    self.isSearching ? "No matching transcripts" : "No transcripts yet",
                    systemImage: self.isSearching ? "magnifyingglass" : "doc.text",
                    description: Text(
                        self.isSearching
                            ? "Try a filename or words from the transcript."
                            : "Choose an audio or video file to create your first transcript."
                    )
                )
            } else {
                self.library
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Rename transcript", isPresented: Binding(
            get: { self.renamingEntry != nil },
            set: { if !$0 { self.renamingEntry = nil } }
        )) {
            TextField("Transcript title", text: self.$renameDraft)
            Button("Cancel", role: .cancel) { self.renamingEntry = nil }
            Button("Rename") {
                if let entry = self.renamingEntry {
                    self.onRename(entry.id, self.renameDraft)
                }
                self.renamingEntry = nil
            }
            .disabled(self.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var library: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                    ForEach(self.sections) { section in
                        Section {
                            ForEach(section.entries) { entry in
                                self.row(entry)
                                    .id(entry.id)
                            }
                        } header: {
                            Text(section.title)
                                .font(self.theme.typography.caption)
                                .foregroundStyle(self.theme.palette.secondaryText)
                                .padding(.horizontal, self.theme.metrics.spacing.md)
                                .padding(.top, self.theme.metrics.spacing.lg)
                                .padding(.bottom, self.theme.metrics.spacing.xs)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                }
                // Match FluidMeet's text column, letting hover surfaces extend past its edges.
                .frame(maxWidth: 720 + self.theme.metrics.spacing.md * 2)
                .padding(.horizontal, self.theme.metrics.spacing.lg * 2 - self.theme.metrics.spacing.md)
                .padding(.bottom, self.theme.metrics.spacing.lg)
                // Center against the page, including a persistent native scrollbar gutter.
                .frame(width: geometry.size.width)
            }
        }
    }

    private func row(_ entry: FileTranscriptionEntry) -> some View {
        Button { self.onOpen(entry) } label: {
            HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) {
                Image(systemName: "doc.text")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .frame(width: 18, height: 22)
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                    Text(entry.displayTitle)
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.theme.palette.primaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    HStack(spacing: self.theme.metrics.spacing.sm) {
                        Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                        Text("·")
                        Text(Duration.seconds(entry.duration).formatted(.time(pattern: .hourMinuteSecond)))
                        if !entry.speakerSegments.isEmpty {
                            Image(systemName: "person.2")
                                .accessibilityLabel("Speaker labels")
                        }
                    }
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .lineLimit(1)
                    Text(self.previews[entry.id] ?? "")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .lineLimit(1)
                }
                .padding(.trailing, self.theme.metrics.spacing.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .multilineTextAlignment(.leading)
            .padding(self.theme.metrics.spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .meetingHoverFeedback(cornerRadius: self.theme.metrics.corners.md)
        .accessibilityHint("Open the full transcript")
        .contextMenu { self.actions(for: entry) }
        .overlay(alignment: .trailing) {
            Menu { self.actions(for: entry) } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .meetingHoverFeedback()
            .accessibilityLabel("Actions for \(entry.displayTitle)")
            .padding(.trailing, self.theme.metrics.spacing.sm)
        }
    }

    @ViewBuilder
    private func actions(for entry: FileTranscriptionEntry) -> some View {
        Button("Rename…", systemImage: "pencil") {
            self.renameDraft = entry.displayTitle
            self.renamingEntry = entry
        }
        Button("Copy transcript", systemImage: "doc.on.doc") { self.onCopy(entry) }
        Menu("Export transcript", systemImage: "square.and.arrow.up") {
            ForEach(FileTranscriptionView.ExportFormat.allCases, id: \.self) { format in
                Button(format.rawValue) { self.onExport(entry, format) }
            }
        }
        Divider()
        Button("Delete transcript…", systemImage: "trash", role: .destructive) { self.onDelete(entry) }
    }
}
