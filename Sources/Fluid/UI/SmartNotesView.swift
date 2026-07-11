import AppKit
import SwiftUI

struct SmartNotesView: View {
    @ObservedObject private var store = SmartNotesStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var selectedNoteID: UUID?
    @State private var notePendingDeletion: SmartNote?

    private var selectedNote: SmartNote? {
        guard let selectedNoteID else { return self.store.notes.first }
        return self.store.notes.first(where: { $0.id == selectedNoteID }) ?? self.store.notes.first
    }

    var body: some View {
        VStack(spacing: 0) {
            self.header
            Divider()

            if self.store.notes.isEmpty {
                self.emptyState
            } else {
                HSplitView {
                    self.noteList
                        .frame(minWidth: 230, idealWidth: 280, maxWidth: 340)
                    self.noteDetail
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Smart Notes")
        .onAppear {
            self.store.reload()
            if self.selectedNoteID == nil {
                self.selectedNoteID = self.store.notes.first?.id
            }
        }
        .confirmationDialog(
            "Delete this note?",
            isPresented: Binding(
                get: { self.notePendingDeletion != nil },
                set: { if !$0 { self.notePendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Note", role: .destructive) {
                guard let note = self.notePendingDeletion else { return }
                try? self.store.delete(note)
                self.notePendingDeletion = nil
                self.selectedNoteID = self.store.notes.first?.id
            }
            Button("Cancel", role: .cancel) {
                self.notePendingDeletion = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Smart Notes")
                    .font(.title2.weight(.semibold))
                Text("Dictate from anywhere. Notes are saved as Markdown in Documents/FluidVoice Notes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("Enhance with AI", isOn: Binding(
                get: { self.settings.smartNotesAIEnhancementEnabled },
                set: { self.settings.smartNotesAIEnhancementEnabled = $0 }
            ))
            .toggleStyle(.switch)
            .help("Organize new notes, add a title, category, and tags using the configured AI provider.")

            Button("Open Folder") {
                try? FileManager.default.createDirectory(
                    at: self.store.notesDirectoryURL,
                    withIntermediateDirectories: true
                )
                NSWorkspace.shared.open(self.store.notesDirectoryURL)
            }

            Button {
                self.store.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh notes")
        }
        .padding(18)
    }

    private var noteList: some View {
        List(selection: self.$selectedNoteID) {
            ForEach(self.store.notes) { note in
                VStack(alignment: .leading, spacing: 5) {
                    Text(note.title)
                        .font(.body.weight(.medium))
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Text(note.createdAt, style: .date)
                        Text(note.createdAt, style: .time)
                        if note.isAIEnhanced {
                            Label("AI", systemImage: "sparkles")
                                .foregroundStyle(.purple)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .tag(note.id)
                .contextMenu {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([note.fileURL])
                    }
                    Button("Delete", role: .destructive) {
                        self.notePendingDeletion = note
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var noteDetail: some View {
        if let note = self.selectedNote {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(note.title)
                                .font(.largeTitle.weight(.bold))
                                .textSelection(.enabled)

                            HStack(spacing: 8) {
                                if let category = note.category {
                                    Label(category, systemImage: "folder")
                                }
                                ForEach(note.tags, id: \.self) { tag in
                                    Text("#\(tag)")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Menu {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([note.fileURL])
                            }
                            Button("Delete", role: .destructive) {
                                self.notePendingDeletion = note
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                    }

                    Divider()

                    Text(note.body)
                        .font(.body)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(28)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "note.text.badge.plus")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.secondary)
            Text("No Smart Notes Yet")
                .font(.title3.weight(.semibold))
            Text("Set a Smart Notes shortcut in Settings, then use it to dictate your first note.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Notes Folder") {
                NSWorkspace.shared.open(self.store.notesDirectoryURL)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
