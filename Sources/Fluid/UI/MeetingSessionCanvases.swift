import AppKit
import SwiftUI

struct MeetingRecordingCanvas: View {
    let session: MeetingSession
    let trackHealth: [MeetingAudioTrackKind: MeetingTrackHealth]
    let liveTranscript: MeetingLiveTranscriptSnapshot
    let isStopping: Bool
    let onStop: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: self.theme.metrics.spacing.md) {
                    Label(
                        self.isStopping ? "Saving recording" : "Recording",
                        systemImage: self.isStopping ? "stop.circle.fill" : "record.circle.fill"
                    )
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.isStopping ? self.theme.palette.warning : Color(nsColor: .systemRed))
                    Spacer(minLength: 0)
                    Text(Self.durationText(context.date.timeIntervalSince(self.session.startedAt)))
                        .font(self.theme.typography.codeCaption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(self.isStopping ? "Meeting recording is stopping" : "Meeting recording in progress"), " +
                        "\(Self.durationText(context.date.timeIntervalSince(self.session.startedAt))) elapsed"
                )
            }

            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                MeetingDocumentTitle(title: self.session.title)
                    .lineLimit(2)
                    .help(self.session.title)
                Text(self.sourceSummary)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .lineLimit(1)
                    .help(self.sourceSummary)
            }

            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: self.theme.metrics.spacing.xl) { self.sourceHealth }
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) { self.sourceHealth }
                }
                Divider()
            }

            MeetingLiveTranscriptCard(snapshot: self.liveTranscript)

            Divider()
            FluidGlassControlGroup {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: self.theme.metrics.spacing.lg) {
                        self.recordingFooter
                        Spacer(minLength: 0)
                        self.stopButton
                    }
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                        self.recordingFooter
                        HStack {
                            Spacer(minLength: 0)
                            self.stopButton
                        }
                    }
                }
            }
        }
    }

    private var recordingFooter: some View {
        Text(self.isStopping
            ? "Saving your recording before transcription begins."
            : "Speaker labels are added after recording.")
            .font(self.theme.typography.caption)
            .foregroundStyle(self.theme.palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var stopButton: some View {
        Button(action: self.onStop) {
            if self.isStopping {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Saving recording…")
                }
            } else {
                Label("Stop & Transcribe", systemImage: "stop.fill")
            }
        }
        .meetingGlassAction(prominent: true, tone: Color(nsColor: .systemRed))
        .disabled(self.isStopping)
    }

    @ViewBuilder
    private var sourceHealth: some View {
        if self.session.mode == .onlineCall {
            MeetingTrackHealthRow(title: "Meeting audio", systemImage: "macwindow", health: self.trackHealth[.applicationAudio] ?? .waiting)
        }
        MeetingTrackHealthRow(title: "Microphone", systemImage: "mic", health: self.trackHealth[.microphone] ?? .waiting)
    }

    private var sourceSummary: String {
        let microphoneName = self.session.selectedMicrophone.displayName
        guard self.session.mode == .onlineCall else { return microphoneName }
        let applicationName = self.session.capturedApplication?.displayName ?? "Meeting audio"
        return "\(applicationName) · \(microphoneName)"
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// Live captions during recording only — rows identify capture source, not a person; the offline
/// diarization pipeline replaces this view's content entirely on completion.
private struct MeetingLiveTranscriptCard: View {
    let snapshot: MeetingLiveTranscriptSnapshot

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            HStack {
                Text("Live transcript")
                    .font(self.theme.typography.sectionTitle)
                    .foregroundStyle(self.theme.palette.primaryText)
                Spacer()
                FluidGlassControlGroup {
                    Button {
                        MeetingRecordingPillController.shared.expand()
                    } label: {
                        Image(systemName: "captions.bubble")
                    }
                    .meetingGlassAction(circular: true)
                    .help("Show the live captions overlay")
                    .accessibilityLabel("Show live captions overlay")
                }
            }

            if let indicator = self.availabilityIndicator {
                Label(indicator, systemImage: "exclamationmark.circle")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if self.rows.isEmpty {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                    Text(self.availabilityIndicator == nil ? "Listening for conversation" : "Waiting for captions")
                        .font(self.theme.typography.body)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    Text("Your conversation will appear here as people speak.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.tertiaryText)
                }
                .padding(.top, self.theme.metrics.spacing.sm)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                self.scrollingBubbleList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var rows: [MeetingLiveBubbleComposer.Row] {
        MeetingLiveBubbleComposer.rows(for: self.snapshot)
    }

    private var availabilityIndicator: String? {
        switch self.snapshot.availability {
        case .available:
            return nil
        case let .unavailable(reason), let .degraded(reason):
            return reason
        }
    }

    private var scrollingBubbleList: some View {
        MeetingLiveBubbleScrollList(rows: self.rows, documentStyle: true)
            .frame(minHeight: 120, maxHeight: .infinity)
    }
}

struct MeetingProcessingCanvas: View {
    let session: MeetingSession
    let stage: MeetingProcessingStage

    @Environment(\.theme) private var theme

    private let stages: [MeetingProcessingStage] = [
        .saving,
        .identifyingSpeakers,
        .transcribing,
        .finalizing,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                    .fixedSize()
                Text("Preparing your transcript")
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }

            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                MeetingDocumentTitle(title: self.session.title)
                Text("You can close this window. Processing continues on this Mac.")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }

            Divider()
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xxl) {
                ForEach(Array(self.stages.enumerated()), id: \.element) { index, stage in
                    HStack(spacing: self.theme.metrics.spacing.md) {
                        Image(systemName: self.icon(for: stage, index: index))
                            .foregroundStyle(self.color(for: stage, index: index))
                            .font(self.theme.typography.sectionTitle)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                            Text(Self.title(for: stage))
                                .font(self.theme.typography.bodyStrong)
                                .foregroundStyle(self.stage != .completed && index > self.activeIndex
                                    ? self.theme.palette.secondaryText : self.theme.palette.primaryText)
                            if stage == self.stage {
                                Text(Self.detail(for: stage))
                                    .font(self.theme.typography.caption)
                                    .foregroundStyle(self.theme.palette.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(Self.title(for: stage)), \(self.accessibilityStatus(for: stage, index: index))")
                }
            }
            .padding(.vertical, self.theme.metrics.spacing.sm)
        }
    }

    private var activeIndex: Int {
        self.stages.firstIndex(of: self.stage) ?? 0
    }

    private func icon(for stage: MeetingProcessingStage, index: Int) -> String {
        if self.stage == .completed || index < self.activeIndex { return "checkmark.circle.fill" }
        if stage == self.stage { return "circle.dotted" }
        return "circle"
    }

    private func color(for stage: MeetingProcessingStage, index: Int) -> Color {
        if self.stage == .completed || index < self.activeIndex { return self.theme.palette.success }
        if stage == self.stage { return self.theme.palette.accent }
        return self.theme.palette.tertiaryText
    }

    private func accessibilityStatus(for stage: MeetingProcessingStage, index: Int) -> String {
        if self.stage == .completed || index < self.activeIndex { return "complete" }
        if stage == self.stage { return "in progress" }
        return "waiting"
    }

    private static func title(for stage: MeetingProcessingStage) -> String {
        switch stage {
        case .pending: return "Waiting"
        case .saving: return "Saving"
        case .identifyingSpeakers: return "Identifying speakers"
        case .transcribing: return "Transcribing"
        case .finalizing: return "Finalizing"
        case .completed: return "Complete"
        }
    }

    private static func detail(for stage: MeetingProcessingStage) -> String {
        switch stage {
        case .pending: "Your recording is waiting to be processed."
        case .saving: "Finishing and saving the captured audio."
        case .identifyingSpeakers: "Finding the different voices in your meeting."
        case .transcribing: "Turning your conversation into text."
        case .finalizing: "Putting the transcript and speaker labels together."
        case .completed: "Your transcript is ready."
        }
    }
}

/// Escape also dismisses: viewing a past meeting is a detail view, not a mode.
private struct MeetingCloseTranscriptButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            MeetingDocumentActionLabel(title: "Close", symbol: "xmark")
        }
        .meetingGlassAction()
        .keyboardShortcut(.cancelAction)
        .help("Close this transcript")
        .accessibilityLabel("Close transcript")
    }
}

/// The same label box gives Button and Menu identical native control geometry.
private struct MeetingDocumentActionLabel: View {
    let title: String
    var symbol: String? = nil
    var disclosure = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            if let symbol {
                Image(systemName: symbol).frame(width: 14, height: 14)
            }
            Text(self.title)
            if self.disclosure {
                Image(systemName: "chevron.down")
                    .font(self.theme.typography.captionSmall)
                    .frame(width: 10, height: 14)
            }
        }
        .font(self.theme.typography.bodySmallStrong)
        .frame(height: 20)
        .contentShape(Rectangle())
    }
}

struct MeetingResultCanvas: View {
    let session: MeetingSession
    let isQuiescent: Bool
    let canUndo: Bool
    @State private var showsProbableEchoes = false
    let onCopyTranscript: (MeetingSession, Bool) -> Void
    let onExportTranscript: (MeetingSession, MeetingTranscriptExportFormat, Bool) -> Void
    let onReassignSegment: (MeetingTranscriptSegmentID, SessionSpeakerID) -> Void
    let onNameUnknownSegment: (MeetingTranscriptSegmentID, String) -> Void
    let onRenameSpeaker: (SessionSpeakerID, String) -> Void
    let onMergeSpeakers: (SessionSpeakerID, SessionSpeakerID) -> Void
    let onUndo: () -> Void
    let onRenameSession: (String) -> Void
    let onAssignSpeakers: ([SessionSpeakerID: String]) async -> String?
    let onClose: (() -> Void)?

    var summaryASRService: ASRService? = nil

    @Environment(\.theme) private var theme
    @State private var pendingRenameSpeaker: MeetingSessionSpeaker?
    @State private var pendingRenameText = ""
    @State private var pendingNameUnknownSegmentID: MeetingTranscriptSegmentID?
    @State private var pendingUnknownSpeakerName = ""
    @State private var isRenamingSession = false
    @State private var pendingRenameSessionText = ""
    @State private var isShowingAssignSpeakers = false
    @State private var assignSpeakersFocus: SessionSpeakerID?
    @State private var copied = false
    @State private var copyRevision = 0
    @State private var documentSection: MeetingDocumentSection = .transcript
    @ObservedObject private var summaryActivity = MeetingSummaryActivityCoordinator.shared

    /// Naming is reached by clicking a speaker's name, so the sheet opens on the one clicked.
    private func presentAssignSpeakers(focusing speakerID: SessionSpeakerID?) {
        guard self.isQuiescent, !self.session.activeSpeakers.isEmpty else { return }
        self.assignSpeakersFocus = speakerID
        self.isShowingAssignSpeakers = true
    }

    private var speakerNames: [SessionSpeakerID: String] {
        Dictionary(uniqueKeysWithValues: self.session.activeSpeakers.map { ($0.id, $0.displayName) })
    }

    private func chipTint(for speaker: MeetingSessionSpeaker) -> Color? {
        speaker.isLocalUser ? self.theme.palette.accent : self.speakerTints[speaker.id]
    }

    private var speakerTints: [SessionSpeakerID: Color] {
        MeetingSpeakerPalette.tints(for: self.session.activeSpeakers)
    }

    private var hasEchoSegments: Bool {
        self.session.transcriptSegments.contains(where: \.isEcho)
    }

    /// Single projection so shown and copied never disagree.
    private func visibleSegments(sorted: [MeetingTranscriptSegment]) -> [MeetingTranscriptSegment] {
        self.showsProbableEchoes ? sorted : sorted.filter { !$0.isEcho }
    }

    /// Sorted once with per-row display state — no per-row re-sorting. Compares the resolved
    /// displayed label (not the raw speaker id) so consecutive nil-speaker rows in different
    /// attribution states — e.g. `unassigned` then `timingUncertain` — each still show a label.
    private func rows(
        for visibleSegments: [MeetingTranscriptSegment]
    ) -> [(segment: MeetingTranscriptSegment, showsLabel: Bool, isLocal: Bool)] {
        let speakerNames = self.speakerNames
        var previousLabelIdentity: String?
        return visibleSegments.map { segment in
            let labelIdentity = MeetingTranscriptExporter.speakerLabelIdentity(
                for: segment,
                in: self.session,
                speakerNames: speakerNames
            )
            let showsLabel = labelIdentity != previousLabelIdentity
            previousLabelIdentity = labelIdentity
            return (segment, showsLabel, self.isLocalSegment(segment))
        }
    }

    var body: some View {
        let speakerNames = self.speakerNames
        let sorted = self.session.transcriptSegments.sorted { $0.start.seconds < $1.start.seconds }
        let visibleSegments = self.visibleSegments(sorted: sorted)
        let visibleSpeakerIDs = Set(visibleSegments.compactMap(\.speakerID))
        let activeSpeakers = self.session.activeSpeakers.filter { visibleSpeakerIDs.contains($0.id) }
        let rows = self.rows(for: visibleSegments)
        // One scroller preserves a readable document at short window heights.
        ScrollView {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xxl) {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
                    self.documentHeader(hasText: !visibleSegments.isEmpty)
                    MeetingDocumentTabs(selection: self.$documentSection, isEnabled: self.summaryActivity.selectionLock == nil)
                }

                if self.documentSection == .summary {
                    MeetingSummaryView(session: self.session, asrService: self.summaryASRService, isQuiescent: self.isQuiescent)
                        .id("\(self.session.id)-\(self.session.updatedAt)")
                } else {
                    if !activeSpeakers.isEmpty {
                        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                            self.speakerStrip(activeSpeakers)
                            if self.session.state == .completed,
                               let note = Self.speakerAccuracyNote(speakerCount: self.session.activeSpeakers.count)
                            {
                                self.speakerAccuracyNoteView(note, speakerCount: self.session.activeSpeakers.count)
                            }
                        }
                    }

                    if visibleSegments.isEmpty {
                        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                            Text("No transcript text")
                                .font(self.theme.typography.bodyStrong)
                                .foregroundStyle(self.theme.palette.primaryText)
                            Text(self.emptyTranscriptDescription)
                                .font(self.theme.typography.body)
                                .foregroundStyle(self.theme.palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, self.theme.metrics.spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        LazyVStack(alignment: .leading, spacing: self.theme.metrics.spacing.xxl) {
                            ForEach(rows, id: \.segment.id) { row in
                                MeetingTranscriptSegmentRow(
                                    segment: row.segment,
                                    speakerName: MeetingTranscriptExporter.speakerLabel(
                                        for: row.segment,
                                        in: self.session,
                                        speakerNames: speakerNames
                                    ),
                                    speakerTint: row.segment.speakerID.flatMap { self.speakerTints[$0] },
                                    onRenameSpeakerTapped: {
                                        if let speakerID = row.segment.speakerID {
                                            self.presentAssignSpeakers(focusing: speakerID)
                                        } else {
                                            self.pendingNameUnknownSegmentID = row.segment.id
                                            self.pendingUnknownSpeakerName = ""
                                        }
                                    },
                                    isLocalUser: row.isLocal,
                                    showsSpeakerLabel: row.showsLabel,
                                    reassignTargets: activeSpeakers.filter { $0.id != row.segment.speakerID },
                                    isQuiescent: self.isQuiescent,
                                    onReassign: { speakerID in self.onReassignSegment(row.segment.id, speakerID) }
                                )
                            }
                        }
                        .padding(.bottom, self.theme.metrics.spacing.xxl)
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .id(self.session.id)
        .task(id: self.copyRevision) {
            guard self.copied else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            self.copied = false
        }
        .alert(
            "Rename Speaker",
            isPresented: Binding(
                get: { self.pendingRenameSpeaker != nil },
                set: { if !$0 { self.pendingRenameSpeaker = nil } }
            )
        ) {
            TextField("Speaker name", text: self.$pendingRenameText)
            Button("Cancel", role: .cancel) { self.pendingRenameSpeaker = nil }
            Button("Rename") {
                if let speaker = self.pendingRenameSpeaker {
                    self.onRenameSpeaker(speaker.id, self.pendingRenameText)
                }
                self.pendingRenameSpeaker = nil
            }
        } message: {
            Text("Enter a new name for this speaker.")
        }
        .alert(
            "Name Unknown Speaker",
            isPresented: Binding(
                get: { self.pendingNameUnknownSegmentID != nil },
                set: { if !$0 { self.pendingNameUnknownSegmentID = nil } }
            )
        ) {
            TextField("Speaker name", text: self.$pendingUnknownSpeakerName)
            Button("Cancel", role: .cancel) { self.pendingNameUnknownSegmentID = nil }
            Button("Save") {
                if let segmentID = self.pendingNameUnknownSegmentID {
                    self.onNameUnknownSegment(segmentID, self.pendingUnknownSpeakerName)
                }
                self.pendingNameUnknownSegmentID = nil
            }
        } message: {
            Text("This name applies only to this transcript turn.")
        }
        .alert("Rename Meeting", isPresented: self.$isRenamingSession) {
            TextField("Meeting title", text: self.$pendingRenameSessionText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { self.onRenameSession(self.pendingRenameSessionText) }
        } message: {
            Text("Enter a new title for this meeting.")
        }
        // Prevents an echo toggle left on for one meeting from leaking into the next.
        .onChange(of: self.session.id) { _, _ in
            self.documentSection = .transcript
            self.copied = false
            self.showsProbableEchoes = false
            self.isShowingAssignSpeakers = false
            self.pendingNameUnknownSegmentID = nil
        }
        .sheet(isPresented: self.$isShowingAssignSpeakers) {
            MeetingAssignSpeakersSheet(
                speakers: self.session.activeSpeakers,
                quotesBySpeaker: Dictionary(uniqueKeysWithValues: self.session.activeSpeakers.map {
                    ($0.id, MeetingAssignSpeakersQuoteSource.sampleQuotes(for: $0.id, in: self.session.transcriptSegments))
                }),
                tints: self.speakerTints,
                accentColor: self.theme.palette.accent,
                focusedSpeakerID: self.assignSpeakersFocus,
                onSave: self.onAssignSpeakers,
                onCancel: { self.isShowingAssignSpeakers = false }
            )
        }
    }

    /// Actions sit beside the title so the header has no empty corner above the tabs.
    private func documentHeader(hasText: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: self.theme.metrics.spacing.lg) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                MeetingDocumentTitle(title: self.session.title)
                    .editableTitle(
                        self.session.title,
                        id: String(describing: self.session.id),
                        enabled: self.isQuiescent,
                        editorFont: .system(.largeTitle, design: .serif).weight(.medium),
                        onRename: self.onRenameSession
                    )
                self.meetingMetadata
                if self.session.state != .completed { self.documentStatus }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            FluidGlassControlGroup {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    self.transcriptActions(hasText: hasText)
                }
            }
            .fixedSize()
        }
    }

    private var documentStatus: some View {
        Label(self.statusText, systemImage: self.statusIcon)
            .font(self.theme.typography.caption)
            .foregroundStyle(self.statusColor)
            .fixedSize()
    }

    /// Diarization stays dependable up to this many voices; beyond it, speakers merge or split.
    static let reliableSpeakerLimit = 8

    /// Uses the same count as the history row, so both places describe the same number.
    static func speakerAccuracyNote(speakerCount: Int) -> String? {
        guard speakerCount > 0 else { return nil }
        guard speakerCount > self.reliableSpeakerLimit else {
            return "Speaker labels are automatic and may not be exact. Click a name to fix it."
        }
        return "\(speakerCount) speakers found. Above \(self.reliableSpeakerLimit), labels are less reliable: one person may show up twice, or two people as one."
    }

    private func speakerAccuracyNoteView(_ note: String, speakerCount: Int) -> some View {
        Label {
            Text(note).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: speakerCount > Self.reliableSpeakerLimit ? "exclamationmark.circle" : "info.circle")
        }
        .font(self.theme.typography.caption)
        .foregroundStyle(self.theme.palette.tertiaryText)
        .accessibilityElement(children: .combine)
    }

    private func speakerStrip(_ speakers: [MeetingSessionSpeaker]) -> some View {
        HStack(spacing: self.theme.metrics.spacing.md) {
            Text("Speakers")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.tertiaryText)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: self.theme.metrics.spacing.lg) {
                    ForEach(speakers) { speaker in
                        MeetingSpeakerChip(
                            title: self.displayName(for: speaker),
                            systemImage: speaker.isLocalUser
                                ? "person.crop.circle.badge.checkmark" : "person.crop.circle",
                            tint: self.chipTint(for: speaker) ?? self.theme.palette.primaryText,
                            action: { self.presentAssignSpeakers(focusing: speaker.id) }
                        )
                        .disabled(!self.isQuiescent)
                        .contextMenu { self.speakerChipMenu(for: speaker) }
                    }
                }
                .padding(.vertical, self.theme.metrics.spacing.xs)
            }
        }
    }

    @ViewBuilder private func transcriptActions(hasText: Bool) -> some View {
        Button {
            self.onCopyTranscript(self.session, self.showsProbableEchoes)
            self.copied = true
            self.copyRevision += 1
        } label: {
            MeetingDocumentActionLabel(title: self.copied ? "Copied" : "Copy", symbol: self.copied ? "checkmark" : "doc.on.doc")
        }
        .meetingGlassAction()
        .disabled(!hasText || self.documentSection != .transcript)
        .help("Copy transcript")
        .accessibilityLabel(self.copied ? "Transcript copied" : "Copy transcript")
        Menu {
            Menu("Export", systemImage: "square.and.arrow.up") {
                Button("Text…") { self.onExportTranscript(self.session, .text, self.showsProbableEchoes) }
                Button("JSON…") { self.onExportTranscript(self.session, .json, self.showsProbableEchoes) }
            }
            .disabled(!hasText || self.documentSection != .transcript)
            Divider()
            self.renameMeetingAction
            Button("Undo correction", systemImage: "arrow.uturn.backward", action: self.onUndo)
                .disabled(!self.canUndo || !self.isQuiescent)
            if self.hasEchoSegments {
                Divider()
                Toggle("Show probable echo", isOn: self.$showsProbableEchoes)
            }
            if let onClose {
                Divider()
                Button("Close transcript", systemImage: "xmark", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        } label: {
            MeetingDocumentActionLabel(title: "More", disclosure: true)
        }
        .fluidGlassMenuAction()
        .meetingHoverFeedback()
        .help("More transcript actions")
        .accessibilityLabel("More transcript actions")
    }

    private var renameMeetingAction: some View {
        Button("Rename meeting…", systemImage: "pencil") {
            self.pendingRenameSessionText = self.session.title
            self.isRenamingSession = true
        }
        .disabled(!self.isQuiescent)
    }

    @ViewBuilder
    private func speakerChipMenu(for speaker: MeetingSessionSpeaker) -> some View {
        Button("Rename…", systemImage: "pencil") {
            self.pendingRenameSpeaker = speaker
            self.pendingRenameText = speaker.displayName
        }
        .disabled(!self.isQuiescent)
        if !speaker.isLocalUser {
            let eligibleTargets = self.session.activeSpeakers.filter {
                $0.id != speaker.id && !$0.isLocalUser && $0.trackKind == speaker.trackKind
            }
            if !eligibleTargets.isEmpty {
                Menu("Merge into") {
                    ForEach(eligibleTargets) { target in
                        Button(target.displayName) {
                            self.onMergeSpeakers(speaker.id, target.id)
                        }
                    }
                }
                .disabled(!self.isQuiescent)
            }
        }
    }

    private func displayName(for speaker: MeetingSessionSpeaker) -> String {
        guard speaker.isLocalUser,
              speaker.displayName.caseInsensitiveCompare("You") != .orderedSame
        else {
            return speaker.displayName
        }
        return "\(speaker.displayName) (You)"
    }

    // Only explicitly persisted legacy ownership metadata receives the local-user treatment.
    private func isLocalSegment(_ segment: MeetingTranscriptSegment) -> Bool {
        guard let speakerID = segment.speakerID,
              let speaker = self.session.speakers.first(where: { $0.id == speakerID })
        else { return false }
        return speaker.isLocalUser
    }

    private var meetingMetadata: some View {
        HStack(spacing: self.theme.metrics.spacing.md) {
            Text(self.session.startedAt.formatted(date: .abbreviated, time: .omitted))
                .fixedSize()
                .help(self.session.startedAt.formatted(date: .complete, time: .shortened))
            Text("·").accessibilityHidden(true)
            Label(Self.durationText(self.session.duration), systemImage: "clock")
                .fixedSize()
            Text("·").accessibilityHidden(true)
            Label(self.sourceName, systemImage: self.session.mode == .onlineCall ? "macwindow" : "person.2")
                .lineLimit(1)
                .help("\(self.sourceName)\nMicrophone: \(self.session.selectedMicrophone.displayName)")
        }
        .font(self.theme.typography.caption)
        .foregroundStyle(self.theme.palette.secondaryText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(self.session.startedAt.formatted(date: .abbreviated, time: .shortened)), " +
                "\(Self.durationText(self.session.duration)), \(self.sourceName), " +
                "microphone: \(self.session.selectedMicrophone.displayName)"
        )
    }

    private var sourceName: String {
        self.session.capturedApplication?.displayName ?? "In-room meeting"
    }

    private var emptyTranscriptDescription: String {
        if self.hasEchoSegments, !self.showsProbableEchoes {
            return "All transcript turns are marked as probable echo. Choose Show probable echo from the More menu to view them."
        }
        if self.session.retention.audioDeletedAt != nil {
            return "No transcript text is available. The captured audio has been deleted."
        }
        if self.session.hasRetryableAudio {
            return "No transcript text is available. The captured audio is saved on this Mac."
        }
        if self.session.hasFinalizedAudio {
            return "No transcript text is available. Some captured audio is saved on this Mac."
        }
        return "There is no transcript text or saved audio available for this meeting."
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

    private var statusIcon: String {
        switch self.session.state {
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .interrupted: "exclamationmark.circle.fill"
        case .processing: "ellipsis.circle.fill"
        case .recording, .recordingDegraded, .preparing, .stopping: "record.circle.fill"
        }
    }

    private var statusColor: Color {
        switch self.session.state {
        case .completed: self.theme.palette.success
        case .failed: Color(nsColor: .systemRed)
        case .interrupted: self.theme.palette.warning
        case .processing: self.theme.palette.accent
        case .recording, .recordingDegraded, .preparing, .stopping: self.theme.palette.warning
        }
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct MeetingFailureCanvas: View {
    let session: MeetingSession?
    let message: String
    let isRetrying: Bool
    let onRetrySession: (MeetingSession) -> Void
    let onRevealAudio: (MeetingSession) -> Void
    let onRecordAgain: (MeetingSession) -> Void
    let onClose: (() -> Void)?

    @Environment(\.theme) private var theme

    private var hasRecoverableAudio: Bool {
        self.session?.hasRetryableAudio == true
    }

    private var title: String {
        guard let session else { return "Meeting setup failed" }
        let lastFailureDomain = session.failures.last?.domain
        if lastFailureDomain == .processing ||
            (session.state == .interrupted && !session.processingAttempts.isEmpty)
        {
            return session.state == .interrupted
                ? "Meeting transcription was interrupted"
                : "Meeting transcription failed"
        }
        if self.hasRecoverableAudio {
            return session.state == .interrupted
                ? "Meeting recording was interrupted"
                : "Meeting recording failed"
        }
        return "Meeting setup failed"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
            HStack(spacing: self.theme.metrics.spacing.lg) {
                Label(self.title, systemImage: "exclamationmark.circle")
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.theme.palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let onClose {
                    FluidGlassControlGroup {
                        MeetingCloseTranscriptButton(action: onClose)
                    }
                }
            }
            MeetingDocumentTitle(title: self.session?.title ?? "Recording setup")
            Divider()
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
                Text(self.message)
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.primaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if self.hasRecoverableAudio {
                    Label {
                        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                            Text("Your captured audio is preserved")
                                .font(self.theme.typography.bodyStrong)
                            Text("Retry transcription, or open the audio files on this Mac.")
                                .font(self.theme.typography.caption)
                                .foregroundStyle(self.theme.palette.secondaryText)
                        }
                    } icon: {
                        Image(systemName: "checkmark.shield")
                            .foregroundStyle(self.theme.palette.success)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            FluidGlassControlGroup {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: self.theme.metrics.spacing.sm) { self.recoveryActions }
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) { self.recoveryActions }
                }
            }
        }
    }

    @ViewBuilder
    private var recoveryActions: some View {
        if let session, self.hasRecoverableAudio {
            Button(action: { self.onRetrySession(session) }) {
                if self.isRetrying {
                    HStack(spacing: self.theme.metrics.spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text("Retrying…")
                    }
                } else {
                    Label("Retry transcription", systemImage: "arrow.clockwise")
                }
            }
            .meetingGlassAction(prominent: true)
            .disabled(self.isRetrying)
            Button("Show audio", systemImage: "folder", action: { self.onRevealAudio(session) })
                .meetingGlassAction()
        }
        if let session {
            Button("Record again", systemImage: "arrow.counterclockwise.circle") {
                self.onRecordAgain(session)
            }
            .meetingGlassAction(prominent: !self.hasRecoverableAudio)
            .disabled(self.isRetrying)
        }
    }
}

private struct MeetingTrackHealthRow: View {
    let title: String
    let systemImage: String
    let health: MeetingTrackHealth

    @Environment(\.theme) private var theme

    private var statusText: String {
        switch self.health.status {
        case .waiting: return "Waiting for audio"
        case .healthy: return "Receiving audio"
        case .degraded: return self.health.detail ?? "Audio source degraded"
        case .unavailable: return self.health.detail ?? "Audio source unavailable"
        case .stopped: return "Stopped"
        }
    }

    private var statusColor: Color {
        switch self.health.status {
        case .healthy: self.theme.palette.success
        case .degraded, .unavailable: self.theme.palette.warning
        case .waiting, .stopped: self.theme.palette.secondaryText
        }
    }

    private var statusIcon: String {
        switch self.health.status {
        case .healthy: "checkmark.circle.fill"
        case .degraded, .unavailable: "exclamationmark.circle.fill"
        case .waiting: "ellipsis.circle"
        case .stopped: "stop.circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Label(self.title, systemImage: self.systemImage)
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize()
                ProgressView(value: min(max(Double(self.health.level), 0), 1))
                    .progressViewStyle(.linear)
                    .frame(width: 44)
                    .accessibilityLabel("\(self.title) level")
                Image(systemName: self.statusIcon)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.statusColor)
                    .accessibilityLabel(self.statusText)
            }
            if self.health.status == .degraded || self.health.status == .unavailable {
                Text(self.statusText)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.warning)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help("\(self.title): \(self.statusText)")
    }
}

private struct MeetingSpeakerChip: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    @Environment(\.theme) private var theme
    var body: some View {
        Button(action: self.action) {
            HStack(spacing: self.theme.metrics.spacing.xs) {
                Label(self.title, systemImage: self.systemImage)
                Image(systemName: "chevron.right")
                    .font(.fluidSystem(size: 9, weight: .semibold))
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            .font(self.theme.typography.captionStrong)
            .foregroundStyle(self.tint)
        }
        .buttonStyle(.borderless)
        .meetingHoverFeedback()
        .help("Edit speaker names")
        .accessibilityLabel("Edit speaker name: \(self.title)")
    }
}

private struct MeetingTranscriptSegmentRow: View {
    let segment: MeetingTranscriptSegment
    let speakerName: String
    let speakerTint: Color?
    let onRenameSpeakerTapped: (() -> Void)?
    let isLocalUser: Bool
    let showsSpeakerLabel: Bool
    let reassignTargets: [MeetingSessionSpeaker]
    let isQuiescent: Bool
    let onReassign: (SessionSpeakerID) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: self.theme.metrics.spacing.lg) {
            Text(MeetingTranscriptExporter.timestampText(self.segment.start.seconds))
                .font(self.theme.typography.codeCaption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .frame(width: 58, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                if self.showsSpeakerLabel { self.speakerLabel }
                Text(self.segment.text)
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.primaryText)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if self.segment.isEcho {
                    Text("Probable echo").font(self.theme.typography.caption).foregroundStyle(.secondary)
                }
            }
        }
        .opacity(self.segment.isEcho ? 0.6 : 1)
        .contextMenu {
            Menu("Reassign to") {
                ForEach(self.reassignTargets) { target in
                    Button(target.displayName) {
                        self.onReassign(target.id)
                    }
                }
            }
            .disabled(!self.isQuiescent || self.reassignTargets.isEmpty)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(MeetingTranscriptExporter.timestampText(self.segment.start.seconds)), \(self.speakerName), \(self.segment.text)"
        )
    }

    private var speakerLabel: some View {
        let name = Text(self.speakerName)
            .foregroundColor(self.nameColor)
            .fontWeight(.semibold)
            .font(self.theme.typography.bodySmallStrong)

        return HStack(spacing: 8) {
            if let onRenameSpeakerTapped = self.onRenameSpeakerTapped {
                Button(action: onRenameSpeakerTapped) {
                    HStack(spacing: 3) {
                        name
                        // Always shown, not hover-only, so the affordance survives an unfocused window.
                        Image(systemName: "chevron.right")
                            .font(.fluidSystem(size: 10, weight: .semibold))
                            .foregroundColor(self.nameColor)
                            .opacity(0.65)
                    }
                }
                .buttonStyle(.plain)
                .meetingHoverFeedback(cornerRadius: self.theme.metrics.corners.sm)
                .disabled(!self.isQuiescent)
                // No .help here: the tooltip lands on top of the turn's first line of text.
                .accessibilityLabel("Rename \(self.speakerName)")
                .pointerStyle(.link)
            } else {
                name
            }
        }
    }

    private var nameColor: Color {
        if self.isLocalUser { return self.theme.palette.accent }
        return self.speakerTint ?? self.theme.palette.tertiaryText
    }
}
