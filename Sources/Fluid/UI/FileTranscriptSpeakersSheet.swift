import SwiftUI

struct FileTranscriptSpeakersSheet: View {
    private struct Speaker: Identifiable {
        let id: String
        let name: String
        let sample: String
    }

    let onSave: ([String: String]) -> Void
    let onCancel: () -> Void
    private let speakers: [Speaker]
    private let initialFocus: String?
    @State private var drafts: [String: String]
    @FocusState private var focusedSpeaker: String?
    @Environment(\.theme) private var theme

    init(
        entry: FileTranscriptionEntry,
        focusedSpeaker: String?,
        onSave: @escaping ([String: String]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onCancel = onCancel
        self.initialFocus = focusedSpeaker
        let speakers = entry.speakerIdentifiers.map { speaker in
            Speaker(
                id: speaker,
                name: entry.speakerDisplayName(for: speaker),
                sample: String((entry.speakerSegments.first { $0.speaker == speaker }?.text ?? "").prefix(180))
            )
        }
        self.speakers = speakers
        self._drafts = State(initialValue: Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.name) }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                MeetingDocumentTitle(title: "Edit speakers")
                Text("Names apply to every segment in this transcript.")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            .padding(self.theme.metrics.spacing.xl)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
                    ForEach(self.speakers) { speaker in
                        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                            Text(speaker.id)
                                .font(self.theme.typography.captionStrong)
                                .foregroundStyle(self.theme.palette.secondaryText)
                            Text(speaker.sample)
                                .font(self.theme.typography.bodySmall)
                                .foregroundStyle(self.theme.palette.secondaryText)
                                .lineLimit(2)
                            TextField(speaker.id, text: Binding(
                                get: { self.drafts[speaker.id] ?? speaker.name },
                                set: { self.drafts[speaker.id] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .focused(self.$focusedSpeaker, equals: speaker.id)
                            .accessibilityLabel("Name for \(speaker.id)")
                        }
                    }
                }
                .padding(self.theme.metrics.spacing.xl)
            }
            Divider()
            HStack(spacing: self.theme.metrics.spacing.md) {
                Text("Clear a name to restore its numbered label.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                Spacer(minLength: 0)
                Button("Cancel", action: self.onCancel)
                    .meetingGlassAction()
                    .keyboardShortcut(.cancelAction)
                Button("Save") { self.onSave(self.drafts) }
                    .meetingGlassAction(prominent: true)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!self.hasChanges)
            }
            .padding(self.theme.metrics.spacing.xl)
        }
        .frame(width: 560, height: min(640, 220 + CGFloat(self.speakers.count) * 140))
        .background(self.theme.palette.windowBackground)
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            self.focusedSpeaker = self.initialFocus ?? self.speakers.first?.id
        }
    }

    private var hasChanges: Bool {
        self.speakers.contains { speaker in
            let name = (self.drafts[speaker.id] ?? speaker.name).trimmingCharacters(in: .whitespacesAndNewlines)
            return (name.isEmpty ? speaker.id : name) != speaker.name
        }
    }
}
