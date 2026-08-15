import SwiftUI

/// Sample-quote extraction, kept separate from the view so it stays trivially testable.
nonisolated enum MeetingAssignSpeakersQuoteSource {
    private static let maxQuoteLength = 180

    /// First two things a speaker actually said: final, non-echo, in time order.
    static func sampleQuotes(for speakerID: SessionSpeakerID, in segments: [MeetingTranscriptSegment]) -> [String] {
        segments
            .filter { $0.speakerID == speakerID && !$0.isEcho && $0.status == .final }
            .sorted { $0.start.seconds < $1.start.seconds }
            .compactMap { segment -> String? in
                let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : Self.truncated(trimmed)
            }
            .prefix(2)
            .map { $0 }
    }

    private static func truncated(_ text: String) -> String {
        guard text.count > Self.maxQuoteLength else { return text }
        let cutoff = text.index(text.startIndex, offsetBy: Self.maxQuoteLength)
        let prefix = text[text.startIndex..<cutoff]
        if let lastSpace = prefix.lastIndex(of: " ") {
            return "\(text[text.startIndex..<lastSpace])…"
        }
        return "\(prefix)…"
    }
}

nonisolated enum MeetingAssignSpeakersValidation {
    /// Only a collision the user just created blocks the save. Two speakers can already share a
    /// name — the pipeline emits a bare "Speaker" for re-matched clusters — and that transcript
    /// must stay nameable rather than deadlocking on a duplicate nobody typed.
    static func duplicateName(
        current: [(id: SessionSpeakerID, displayName: String)],
        drafts: [SessionSpeakerID: String]
    ) -> String? {
        let resulting = current.map { speaker -> (name: String, changed: Bool) in
            let typed = (drafts[speaker.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = typed.isEmpty ? speaker.displayName : typed
            return (name, name != speaker.displayName)
        }
        for index in resulting.indices {
            for other in resulting[(index + 1)...]
            where other.name.caseInsensitiveCompare(resulting[index].name) == .orderedSame {
                guard resulting[index].changed || other.changed else { continue }
                return other.name
            }
        }
        return nil
    }
}

struct MeetingAssignSpeakersSheet: View {
    let speakers: [MeetingSessionSpeaker]
    let quotesBySpeaker: [SessionSpeakerID: [String]]
    let tints: [SessionSpeakerID: Color]
    let accentColor: Color
    let focusedSpeakerID: SessionSpeakerID?
    let onSave: ([SessionSpeakerID: String]) async -> String?
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    @State private var drafts: [SessionSpeakerID: String]
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: SessionSpeakerID?

    init(
        speakers: [MeetingSessionSpeaker],
        quotesBySpeaker: [SessionSpeakerID: [String]],
        tints: [SessionSpeakerID: Color],
        accentColor: Color,
        focusedSpeakerID: SessionSpeakerID? = nil,
        onSave: @escaping ([SessionSpeakerID: String]) async -> String?,
        onCancel: @escaping () -> Void
    ) {
        self.speakers = speakers
        self.quotesBySpeaker = quotesBySpeaker
        self.tints = tints
        self.accentColor = accentColor
        self.focusedSpeakerID = focusedSpeakerID
        self.onSave = onSave
        self.onCancel = onCancel
        self._drafts = State(initialValue: Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.displayName) }))
    }

    var body: some View {
        VStack(spacing: 0) {
            self.header

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
                        ForEach(self.speakers) { speaker in
                            self.row(for: speaker).id(speaker.id)
                        }
                    }
                    .padding(self.theme.metrics.spacing.xl)
                }
                .onAppear {
                    guard let focusedSpeakerID = self.focusedSpeakerID else { return }
                    proxy.scrollTo(focusedSpeakerID, anchor: .center)
                    self.focusedField = focusedSpeakerID
                }
            }

            if let errorMessage {
                Divider()
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.warning)
                    .padding(.horizontal, self.theme.metrics.spacing.xl)
                    .padding(.vertical, self.theme.metrics.spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack(spacing: self.theme.metrics.spacing.md) {
                Spacer()
                Button("Cancel", action: self.onCancel)
                    .fluidButton(.compact, size: .medium)
                    .keyboardShortcut(.cancelAction)
                    .disabled(self.isSaving)
                Button("Save names") { Task { await self.save() } }
                    .fluidButton(.accent, size: .medium)
                    .keyboardShortcut(.defaultAction)
                    .disabled(self.isSaving)
            }
            .padding(self.theme.metrics.spacing.lg)
        }
        .frame(minWidth: 480, idealWidth: 560, maxWidth: 560)
        .frame(minHeight: 420, idealHeight: 560)
        .background(self.theme.palette.windowBackground)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                Text("Assign speakers")
                    .font(self.theme.typography.title)
                Text("Name each voice and we'll relabel the whole transcript.")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            Spacer()
            Button("Close", systemImage: "xmark") { self.onCancel() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .accessibilityLabel("Close")
        }
        .padding(.horizontal, self.theme.metrics.spacing.xl)
        .padding(.vertical, self.theme.metrics.spacing.lg)
    }

    @ViewBuilder
    private func row(for speaker: MeetingSessionSpeaker) -> some View {
        let tint = speaker.isLocalUser ? self.accentColor : (self.tints[speaker.id] ?? self.theme.palette.tertiaryText)
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Circle()
                    .fill(tint)
                    .frame(width: 10, height: 10)
                Text(speaker.displayName)
                    .font(self.theme.typography.captionSmall)
                    .tracking(1.1)
                    .textCase(.uppercase)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }

            let quotes = self.quotesBySpeaker[speaker.id] ?? []
            if quotes.isEmpty {
                Text("No sample audio")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.tertiaryText)
                    .padding(.leading, self.theme.metrics.spacing.md)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(tint.opacity(0.35)).frame(width: 2)
                    }
            } else {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                    ForEach(Array(quotes.enumerated()), id: \.offset) { _, quote in
                        Text(quote)
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.theme.palette.secondaryText)
                            .padding(.leading, self.theme.metrics.spacing.md)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(tint.opacity(0.35)).frame(width: 2)
                            }
                    }
                }
            }

            TextField(
                speaker.displayName,
                text: Binding(
                    get: { self.drafts[speaker.id] ?? speaker.displayName },
                    set: { self.drafts[speaker.id] = $0 }
                ),
                prompt: Text(speaker.displayName)
            )
            .textFieldStyle(.roundedBorder)
            .focused(self.$focusedField, equals: speaker.id)
            .disabled(self.isSaving)
        }
    }

    private func save() async {
        self.errorMessage = nil

        if let duplicate = MeetingAssignSpeakersValidation.duplicateName(
            current: self.speakers.map { (id: $0.id, displayName: $0.displayName) },
            drafts: self.drafts
        ) {
            self.errorMessage = "Two speakers are both named \"\(duplicate)\". Give them different names, or merge them from the transcript."
            return
        }

        self.isSaving = true
        let message = await self.onSave(self.drafts)
        self.isSaving = false

        if let message {
            self.errorMessage = message
        } else {
            // No separate "dismiss" callback: onCancel is just "close the sheet" either way.
            self.onCancel()
        }
    }
}
