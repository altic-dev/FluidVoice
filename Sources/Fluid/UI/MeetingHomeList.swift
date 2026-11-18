import SwiftUI

struct MeetingHomeActions {
    let openMeeting: (MeetingSessionID) -> Void
    let startRecording: () -> Void
    let refresh: () -> Void
    let retry: (MeetingSessionID) -> Void
    let revealAudio: (MeetingSession) -> Void
    let exportAudio: (MeetingSession) -> Void
    let exportTranscript: (MeetingSession, MeetingTranscriptExportFormat) -> Void
    let requestAudioDeletion: (MeetingSessionID) -> Void
    let requestDeletion: (MeetingSessionID) -> Void
    let rename: (MeetingSessionID, String) -> Void
    let recordAgain: (MeetingSession) -> Void
    let openIntegrations: () -> Void
}

struct MeetingHomeList: View {
    let sessions: [MeetingSession]
    let historyErrorMessage: String?
    let actionErrorMessage: String?
    let isLoading: Bool
    let isQuiescent: Bool
    let canStartRecording: Bool
    let actions: MeetingHomeActions

    @State private var renameSessionID: MeetingSessionID?
    @State private var renameDraft = ""
    @State private var searchText = ""

    @Environment(\.theme) private var theme

    private let columnWidth: CGFloat = 720
    private var pageInset: CGFloat {
        self.theme.metrics.spacing.lg * 2
    }

    /// Row highlights extend past the column so row text lines up with the header.
    private var rowOutset: CGFloat {
        self.theme.metrics.spacing.md
    }

    private var filteredSessions: [MeetingSession] {
        let query = self.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return self.sessions }
        return self.sessions.filter { session in
            session.title.localizedCaseInsensitiveContains(query) ||
                session.capturedApplication?.displayName.localizedCaseInsensitiveContains(query) == true ||
                session.activeSpeakers.contains(where: { $0.displayName.localizedCaseInsensitiveContains(query) })
        }
    }

    /// Sessions arrive newest-first, so a first-seen-order bucket walk keeps groups chronological.
    private var groupedSessions: [(key: String, sessions: [MeetingSession])] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [MeetingSession]] = [:]
        for session in self.filteredSessions {
            let key = Self.dayLabel(for: session.startedAt, calendar: calendar)
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(session)
        }
        return order.map { (key: $0, sessions: buckets[$0] ?? []) }
    }

    private static func dayLabel(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        VStack(spacing: 0) {
            self.header
            self.content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(self.theme.palette.windowBackground)
        .alert("Rename Meeting", isPresented: Binding(
            get: { self.renameSessionID != nil },
            set: { if !$0 { self.renameSessionID = nil } }
        )) {
            TextField("Meeting title", text: self.$renameDraft)
            Button("Cancel", role: .cancel) { self.renameSessionID = nil }
            Button("Rename") {
                if self.isQuiescent, let id = self.renameSessionID,
                   self.sessions.contains(where: { $0.id == id })
                {
                    self.actions.rename(id, self.renameDraft)
                }
                self.renameSessionID = nil
            }
            .disabled(!self.isQuiescent || self.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            self.titleRow
            self.searchField
            if let actionErrorMessage, !actionErrorMessage.isEmpty {
                Label(actionErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let historyErrorMessage, !self.sessions.isEmpty {
                Text(historyErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: self.columnWidth)
        .padding(.horizontal, self.pageInset)
        .padding(.top, self.pageInset)
        .padding(.bottom, self.theme.metrics.spacing.md)
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: self.theme.metrics.spacing.sm) {
            MeetingDocumentTitle(title: "Meetings")
            Text("\(self.sessions.count)")
                .font(self.theme.typography.badge)
                .foregroundStyle(self.theme.palette.secondaryText)
            Spacer()
            Button(action: self.actions.refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .meetingHoverFeedback()
            .help("Refresh meetings")
            .accessibilityLabel("Refresh meetings")
            FluidGlassControlGroup {
                Button(action: self.actions.startRecording) {
                    Label("Start recording", systemImage: "record.circle")
                }
                .meetingGlassAction(prominent: true, spacious: true)
                .disabled(!self.canStartRecording)
                .keyboardShortcut("n", modifiers: .command)
            }
            .fixedSize()
        }
    }

    private var searchField: some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search meetings", text: self.$searchText).textFieldStyle(.plain)
            if !self.searchText.isEmpty {
                Button { self.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .meetingHoverFeedback()
                .accessibilityLabel("Clear meeting search")
            }
        }
        .padding(self.theme.metrics.spacing.md)
        .fluidDropdownSurface()
    }

    @ViewBuilder
    private var content: some View {
        if let historyErrorMessage, self.sessions.isEmpty {
            ContentUnavailableView(
                "History unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(historyErrorMessage)
            )
        } else if self.isLoading, self.sessions.isEmpty {
            ProgressView("Loading meetings…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if self.filteredSessions.isEmpty {
            ContentUnavailableView(
                self.searchText.isEmpty ? "No meetings yet" : "No matching meetings",
                systemImage: self.searchText.isEmpty ? "person.2.wave.2" : "magnifyingglass",
                description: Text(
                    self.searchText.isEmpty
                        ? "Completed meetings will appear here."
                        : "Try a different title, app, or speaker."
                )
            )
        } else {
            self.sessionList
        }
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(self.groupedSessions, id: \.key) { group in
                    Section {
                        ForEach(group.sessions, content: self.row(for:))
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

    private func row(for session: MeetingSession) -> some View {
        MeetingHomeRow(
            session: session,
            isQuiescent: self.isQuiescent,
            onSelect: { self.actions.openMeeting(session.id) },
            onRetry: { self.actions.retry(session.id) },
            onRename: { self.actions.rename(session.id, $0) },
            onRecordAgain: { self.actions.recordAgain(session) }
        )
        .contextMenu { self.contextMenu(for: session) }
        .overlay(alignment: .topTrailing) {
            Menu { self.contextMenu(for: session) } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .meetingHoverFeedback()
            .accessibilityLabel("Actions for \(session.title)")
            .padding(self.theme.metrics.spacing.sm)
        }
    }

    @ViewBuilder
    private func contextMenu(for session: MeetingSession) -> some View {
        Button("Rename…", systemImage: "pencil") {
            self.renameDraft = session.title
            self.renameSessionID = session.id
        }
        .disabled(!self.isQuiescent)
        Divider()
        if session.hasRetryableAudio, session.state == .failed || session.state == .interrupted {
            Button("Retry Transcription", systemImage: "arrow.clockwise") {
                self.actions.retry(session.id)
            }
            .disabled(!self.isQuiescent)
        }
        Button("Reveal Audio", systemImage: "folder") {
            self.actions.revealAudio(session)
        }
        Button("Export Audio…", systemImage: "square.and.arrow.up") {
            self.actions.exportAudio(session)
        }
        .disabled(!session.hasFinalizedAudio)
        Button("Export Transcript (Text)…", systemImage: "doc.text") {
            self.actions.exportTranscript(session, .text)
        }
        .disabled(!session.transcriptSegments.contains(where: { !$0.isEcho }))
        Button("Export Transcript (Markdown)…", systemImage: "doc.richtext") {
            self.actions.exportTranscript(session, .markdown)
        }
        .disabled(!session.transcriptSegments.contains(where: { !$0.isEcho }))
        Button("Export Transcript (JSON)…", systemImage: "curlybraces") {
            self.actions.exportTranscript(session, .json)
        }
        .disabled(session.transcriptSegments.isEmpty)
        if session.hasFinalizedAudio, session.retention.audioDeletedAt == nil, session.state == .completed {
            Button("Delete Audio (Keep Transcript)…", systemImage: "waveform.slash") {
                self.actions.requestAudioDeletion(session.id)
            }
            .disabled(!self.isQuiescent)
        }
        Divider()
        Button("Integrations…", systemImage: "link", action: self.actions.openIntegrations)
        Divider()
        Button("Delete Meeting…", systemImage: "trash", role: .destructive) {
            self.actions.requestDeletion(session.id)
        }
        .disabled(!self.isQuiescent)
    }
}

private struct MeetingHomeRow: View {
    let session: MeetingSession
    let isQuiescent: Bool
    let onSelect: () -> Void
    let onRetry: () -> Void
    let onRename: (String) -> Void
    let onRecordAgain: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            Button(action: self.onSelect) {
                HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) {
                    self.tile
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                        Text(self.session.title)
                            .font(self.theme.typography.bodyStrong)
                            .foregroundStyle(self.theme.palette.primaryText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .padding(.trailing, self.theme.metrics.spacing.xxl)
                        self.secondaryLine
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, self.theme.metrics.spacing.md)
                .padding(.vertical, self.theme.metrics.spacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(self.session.title), \(self.statusText), \(self.sourceName)")
            .editableTitle(self.session.title, id: String(describing: self.session.id), enabled: self.isQuiescent, onRename: self.onRename)
            if let actionLabel {
                Button(actionLabel, action: self.performAction)
                    .buttonStyle(.borderless)
                    .meetingHoverFeedback()
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.actionColor)
                    .disabled(!self.isQuiescent)
                    .accessibilityLabel(self.actionAccessibilityLabel ?? actionLabel)
                    .padding(.leading, 18 + self.theme.metrics.spacing.md * 2)
                    .padding(.bottom, self.theme.metrics.spacing.sm)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.rowBackground)
                .animation(self.reduceMotion ? nil : .easeOut(duration: 0.14), value: self.isHovered && self.isEnabled)
        }
        .contentShape(Rectangle())
        .onHover { self.isHovered = $0 && self.isEnabled }
        .onChange(of: self.isEnabled) { _, enabled in
            if !enabled { self.isHovered = false }
        }
        .onDisappear { self.isHovered = false }
        .accessibilityElement(children: .contain)
    }

    private var tile: some View {
        Image(systemName: self.tileIcon)
            .font(self.theme.typography.bodySmall)
            .foregroundStyle(self.tileIconColor)
            .frame(width: 18, height: 22)
    }

    private var secondaryLine: some View {
        HStack(spacing: self.theme.metrics.spacing.xs) {
            ForEach(Array(self.secondaryTextParts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Text("·").foregroundStyle(self.theme.palette.tertiaryText)
                }
                Text(part)
            }
        }
        .font(self.theme.typography.caption)
        .foregroundStyle(self.theme.palette.secondaryText)
        .lineLimit(1)
    }

    private func performAction() {
        switch self.session.state {
        case .interrupted: self.onRetry()
        case .failed: self.onRecordAgain()
        default: break
        }
    }

    private var timeText: String {
        self.session.startedAt.formatted(date: .omitted, time: .shortened)
    }

    private var secondaryTextParts: [String] {
        switch self.session.state {
        case .completed:
            var parts = [self.timeText, Self.durationText(self.session.duration)]
            if !self.session.activeSpeakers.isEmpty {
                parts.append(self.session.activeSpeakers.count == 1 ? "1 speaker" : "\(self.session.activeSpeakers.count) speakers")
            }
            return parts
        case .interrupted:
            return [self.timeText, "Interrupted"]
        case .failed:
            return [self.timeText, "Failed"]
        case .processing:
            return [self.timeText, "Processing"]
        case .recording, .recordingDegraded, .preparing, .stopping:
            return [self.timeText, "Recording"]
        }
    }

    private var actionLabel: String? {
        switch self.session.state {
        case .interrupted: return self.session.hasRetryableAudio ? "Retry" : nil
        case .failed: return "Record again"
        default: return nil
        }
    }

    /// The row shows a short "Retry"; spoken output keeps the full sentence.
    private var actionAccessibilityLabel: String? {
        switch self.session.state {
        case .interrupted: return self.session.hasRetryableAudio ? "Retry transcription" : nil
        case .failed: return "Record again"
        default: return nil
        }
    }

    private var actionColor: Color {
        self.session.state == .interrupted ? self.theme.palette.warning : self.theme.palette.accent
    }

    private var rowBackground: Color {
        if self.isHovered && self.isEnabled { return self.theme.palette.primaryText.opacity(0.06) }
        return .clear
    }

    private var sourceName: String {
        self.session.capturedApplication?.displayName ?? "In-room"
    }

    private var statusText: String {
        switch self.session.state {
        case .completed: "Completed"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        case .processing: "Processing"
        case .recording, .recordingDegraded, .preparing, .stopping: "Recording"
        }
    }

    private var tileIcon: String {
        switch self.session.state {
        case .interrupted: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle"
        default: "doc.text"
        }
    }

    private var tileIconColor: Color {
        switch self.session.state {
        case .interrupted: self.theme.palette.warning
        case .failed: Color(nsColor: .systemRed)
        default: self.theme.palette.secondaryText
        }
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let totalMinutes = max(0, Int(duration / 60))
        if totalMinutes >= 60 {
            return "\(totalMinutes / 60)h \(totalMinutes % 60)m"
        }
        return "\(max(1, totalMinutes))m"
    }
}
