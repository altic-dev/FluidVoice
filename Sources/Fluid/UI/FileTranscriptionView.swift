import SwiftUI
import UniformTypeIdentifiers

enum FileTranscriptionSearchReveal {
    static func transcriptID(_ target: AppSearchHit.Target?) -> UUID? {
        guard case let .transcript(id) = target else { return nil }
        return id
    }
}

struct FileTranscriptionView: View {
    @ObservedObject var asrService: ASRService
    @ObservedObject private var transcriptionService: FileTranscriptionService
    @ObservedObject private var fileHistoryStore = FileTranscriptionHistoryStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @Binding private var revealTarget: AppSearchHit.Target?
    @State private var selectedFileURL: URL?
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(asrService: ASRService, transcriptionService: FileTranscriptionService, revealTarget: Binding<AppSearchHit.Target?> = .constant(nil)) {
        self._revealTarget = revealTarget
        self.asrService = asrService
        _transcriptionService = ObservedObject(wrappedValue: transcriptionService)
    }

    @State private var showingFilePicker = false
    @State private var showingExportDialog = false
    @State private var exportResult: TranscriptionResult?
    @State private var exportFormat: ExportFormat = .text
    @State private var showingCopyConfirmation = false
    @State private var isDropTargeted = false
    @State private var dropErrorMessage: String?
    @State private var searchQuery = ""
    @State private var openTranscriptID: UUID?
    @State private var pendingDeleteEntry: FileTranscriptionEntry?
    @State private var showingDeleteAllConfirmation = false
    @State private var speakerEditor: SpeakerEditorRequest?

    private struct SpeakerEditorRequest: Identifiable {
        let entry: FileTranscriptionEntry
        let focusedSpeaker: String?
        var id: UUID {
            self.entry.id
        }
    }

    private struct RowMetadata {
        let preview: String
        let fullDate: String
    }

    @State private var rowMetadata: [UUID: RowMetadata] = [:]
    @State private var librarySections: [FileTranscriptDaySection] = []

    private func updateSearchResults(entries: [FileTranscriptionEntry]) {
        let query = self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredEntries = query.isEmpty ? entries : entries.filter {
            $0.displayTitle.localizedStandardContains(query) || $0.fileName.localizedStandardContains(query) || $0.text.localizedStandardContains(query)
        }
        let calendar = Calendar.current
        self.librarySections = Dictionary(grouping: filteredEntries) { calendar.startOfDay(for: $0.timestamp) }
            .sorted { $0.key > $1.key }
            .map { FileTranscriptDaySection(date: $0.key, entries: $0.value) }
    }

    private var selectedEntry: FileTranscriptionEntry? {
        guard let id = self.openTranscriptID else { return nil }
        return self.fileHistoryStore.entries.first { $0.id == id }
    }

    enum ExportFormat: String, CaseIterable {
        case text = "Text (.txt)"
        case json = "JSON (.json)"

        var fileExtension: String {
            switch self {
            case .text: return "txt"
            case .json: return "json"
            }
        }
    }

    private var selectedFileIsVideo: Bool {
        guard let fileExtension = self.selectedFileURL?
            .pathExtension.lowercased()
        else { return false }
        return UTType(filenameExtension: fileExtension)?.conforms(to: .movie) ?? false
    }

    private var conflictingActivity: ASRExclusiveActivity? {
        guard let activity = self.asrService.activeExclusiveActivity,
              activity != .fileTranscription
        else {
            return nil
        }
        return activity
    }

    var body: some View {
        let entry = self.selectedEntry
        let isShowingHome = entry == nil
        GeometryReader { geometry in
            ZStack {
                // Retain the native library viewport while reading a document.
                self.transcriptHome
                    .offset(x: isShowingHome ? 0 : -geometry.size.width)
                    .opacity(isShowingHome ? 1 : 0)
                    .disabled(!isShowingHome)
                    .allowsHitTesting(isShowingHome)
                    .accessibilityHidden(!isShowingHome)
                if let entry {
                    self.transcriptDetail(entry: entry)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(self.pageAnimation, value: isShowingHome)
        .background(self.theme.palette.windowBackground)
        .clipped()
        .overlay(alignment: .topTrailing) {
            if self.showingCopyConfirmation {
                Text("Copied!")
                    .font(self.theme.typography.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(self.theme.palette.accent.opacity(0.9))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .padding()
                    .transition(self.reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(item: self.$speakerEditor) { request in
            FileTranscriptSpeakersSheet(
                entry: request.entry,
                focusedSpeaker: request.focusedSpeaker,
                onSave: { names in
                    self.fileHistoryStore.renameSpeakers(entryID: request.entry.id, names: names)
                    self.speakerEditor = nil
                },
                onCancel: { self.speakerEditor = nil }
            )
        }
        .fileExporter(
            isPresented: self.$showingExportDialog,
            document: TranscriptionDocument(
                result: self.exportResult ?? TranscriptionResult(text: "", confidence: 0, duration: 0, processingTime: 0, fileName: "transcript"),
                format: self.exportFormat
            ),
            contentType: self.exportFormat == .text ? .plainText : .json,
            defaultFilename: "\((self.exportResult?.fileName).map { "\($0)_transcript" } ?? "transcript").\(self.exportFormat.fileExtension)"
        ) { exportCompletion in
            switch exportCompletion {
            case .success:
                DebugLogger.shared.info("File exported successfully", source: "FileTranscriptionView")
            case let .failure(error):
                DebugLogger.shared.error("Export failed: \(error)", source: "FileTranscriptionView")
            }
            self.exportResult = nil
        }
        .fileImporter(
            isPresented: self.$showingFilePicker,
            allowedContentTypes: FileTranscriptionService.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                if let url = urls.first {
                    self.selectedFileURL = url
                    self.transcriptionService.reset()
                }
            case let .failure(error):
                DebugLogger.shared.error("File picker error: \(error)", source: "FileTranscriptionView")
            }
        }
        .onReceive(self.fileHistoryStore.$entries) { entries in
            self.rowMetadata = Dictionary(entries.map { entry in
                (entry.id, RowMetadata(preview: entry.previewText, fullDate: entry.fullDateString))
            }, uniquingKeysWith: { _, latest in latest })
            self.updateSearchResults(entries: entries)
            if let id = self.openTranscriptID, !entries.contains(where: { $0.id == id }) {
                self.openTranscriptID = nil
            }
        }
        .task(id: self.revealTarget) {
            guard let id = FileTranscriptionSearchReveal.transcriptID(self.revealTarget) else { return }
            self.searchQuery = ""
            self.updateSearchResults(entries: self.fileHistoryStore.entries)
            if self.fileHistoryStore.entries.contains(where: { $0.id == id }) {
                self.openTranscript(id: id)
            }
            self.revealTarget = nil
        }
        .onChange(of: self.searchQuery) { _, _ in
            self.updateSearchResults(entries: self.fileHistoryStore.entries)
        }
        .onChange(of: self.transcriptionService.isTranscribing) { _, isTranscribing in
            if isTranscribing {
                AccessibilityNotification.Announcement("File transcription started").post()
            } else if let result = self.transcriptionService.result,
                      self.fileHistoryStore.entries.contains(where: { $0.id == result.id })
            {
                self.openTranscript(id: result.id)
                self.selectedFileURL = nil
            }
        }
        .onChange(of: self.transcriptionService.result?.id) { _, resultID in
            guard resultID != nil else { return }
            self.searchQuery = ""
            AccessibilityNotification.Announcement("File transcription complete").post()
        }
        .onChange(of: self.transcriptionService.error) { _, error in
            guard let error, !error.isEmpty else { return }
            AccessibilityNotification.Announcement("File transcription failed. \(error)").post()
        }
        .alert("Delete transcript?", isPresented: Binding(
            get: { self.pendingDeleteEntry != nil },
            set: { if !$0 { self.pendingDeleteEntry = nil } }
        )) {
            Button("Cancel", role: .cancel) { self.pendingDeleteEntry = nil }
            Button("Delete", role: .destructive) {
                if let entry = self.pendingDeleteEntry {
                    self.fileHistoryStore.deleteEntry(id: entry.id)
                }
                self.pendingDeleteEntry = nil
            }
        } message: {
            Text("This deletes the saved transcript. Your original audio or video file is kept.")
        }
        .alert("Delete all transcripts?", isPresented: self.$showingDeleteAllConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete all", role: .destructive) { self.fileHistoryStore.clearAll() }
        } message: {
            Text("All saved file transcripts will be permanently deleted. Original files are kept.")
        }
        .onAppear {
            if self.selectedFileURL == nil, self.transcriptionService.result == nil {
                self.selectedFileURL = self.transcriptionService.currentFileURL
            }
        }
    }

    private var pageAnimation: Animation? {
        self.reduceMotion ? nil : .timingCurve(0.22, 0.8, 0.25, 1, duration: 0.34)
    }

    private func openTranscript(id: UUID) {
        self.fileHistoryStore.selectedEntryID = id
        self.openTranscriptID = id
    }

    private func newTranscript() {
        self.openTranscriptID = nil
        self.showingFilePicker = true
    }

    private func activityConflictCard(activity: ASRExclusiveActivity) -> some View {
        Label(
            "File transcription is paused while \(activity.displayName) is active.",
            systemImage: activity == .meeting ? "person.2.wave.2.fill" : "waveform.badge.mic"
        )
        .font(self.theme.typography.bodySmall)
        .foregroundStyle(self.theme.palette.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
                .fill(self.theme.palette.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1)
                )
        )
        .accessibilityLabel(
            "File transcription unavailable. Wait for the active \(activity.displayName) to finish."
        )
    }

    // MARK: - File Selection Card

    private var fileSelectionCard: some View {
        VStack(spacing: 16) {
            if let fileURL = self.selectedFileURL {
                VStack(spacing: self.theme.metrics.spacing.md) {
                    HStack(spacing: self.theme.metrics.spacing.md) {
                        Image(systemName: self.selectedFileIsVideo ? "film" : "waveform")
                            .foregroundStyle(self.theme.palette.secondaryText)
                        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                            Text(fileURL.lastPathComponent)
                                .font(self.theme.typography.bodySmallStrong)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(self.selectedFileIsVideo ? "Video file" : "Audio file")
                                .font(self.theme.typography.caption)
                                .foregroundStyle(self.theme.palette.secondaryText)
                        }
                        Spacer(minLength: self.theme.metrics.spacing.sm)
                        FluidGlassControlGroup {
                            HStack(spacing: self.theme.metrics.spacing.sm) {
                                Button {
                                    self.selectedFileURL = nil
                                    self.transcriptionService.reset()
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .meetingGlassAction(circular: true)
                                .disabled(self.transcriptionService.isTranscribing)
                                .accessibilityLabel("Remove selected file")
                                .help("Remove file")
                                Button {
                                    Task { await self.transcribeFile() }
                                } label: {
                                    Label(self.transcriptionService.isTranscribing ? "Transcribing…" : "Transcribe", systemImage: "waveform")
                                }
                                .meetingGlassAction(prominent: true)
                                .disabled(self.transcriptionService.isTranscribing || self.conflictingActivity != nil)
                                .help(self.conflictingActivity != nil ? "Wait for the active transcription to finish" : "Transcribe the selected file")
                            }
                        }
                        .fixedSize()
                    }
                    if SpeakerDiarizationService.isSupported {
                        Divider()
                        HStack(spacing: self.theme.metrics.spacing.md) {
                            Toggle("Label speakers", isOn: self.$settings.fileTranscriptionSpeakerLabelsEnabled)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .help("Identify who said what. Speaker models download on first use.")
                            Spacer(minLength: 0)
                            if self.settings.fileTranscriptionSpeakerLabelsEnabled {
                                Text("Speakers")
                                    .foregroundStyle(self.theme.palette.secondaryText)
                                FluidDropdownPicker(
                                    "Number of speakers",
                                    selectedTitle: self.settings.fileTranscriptionExpectedSpeakerCount == 0 ? "Auto" : String(self.settings.fileTranscriptionExpectedSpeakerCount),
                                    selection: self.$settings.fileTranscriptionExpectedSpeakerCount
                                ) {
                                    Text("Auto").tag(0)
                                    ForEach(2...8, id: \.self) { count in
                                        Text("\(count)").tag(count)
                                    }
                                }
                                .fluidDropdownStyle()
                                .frame(width: 90)
                            }
                        }
                        .font(self.theme.typography.bodySmall)
                        .disabled(self.transcriptionService.isTranscribing)
                    }
                }
                .padding(self.theme.metrics.spacing.lg)
                .background(self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.md))
            } else {
                Button { self.showingFilePicker = true } label: {
                    VStack(spacing: self.theme.metrics.spacing.xs) {
                        HStack(spacing: self.theme.metrics.spacing.sm) {
                            Image(systemName: "arrow.up.doc")
                                .foregroundStyle(self.theme.palette.secondaryText)
                            Text(self.isDropTargeted ? "Drop to transcribe" : "Drop audio or video to transcribe")
                        }
                        .font(self.theme.typography.bodySmall)
                        Text("or choose a file")
                            .font(self.theme.typography.caption)
                            .foregroundStyle(self.theme.palette.secondaryText)
                    }
                    .multilineTextAlignment(.center)
                    .padding(self.theme.metrics.spacing.lg)
                    .frame(maxWidth: .infinity, minHeight: 88)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: .command)
                .background(self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.md))
                .overlay {
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .foregroundStyle(self.theme.palette.secondaryText.opacity(self.isDropTargeted ? 0.7 : 0.2))
                        .allowsHitTesting(false)
                }
                .accessibilityLabel("Drop audio or video to transcribe, or choose a file")
                .help(FileTranscriptionService.supportedFormatsDescription)
                .onDrop(of: [.fileURL], isTargeted: self.$isDropTargeted) { providers in
                    self.handleDrop(providers: providers)
                }
            }
        }
    }

    // MARK: - Progress Card

    private var progressCard: some View {
        VStack(spacing: 16) {
            ProgressView(value: self.transcriptionService.progress)
                .progressViewStyle(.linear)

            HStack {
                ProgressView()
                    .controlSize(.small)
                    .fixedSize()

                Text(self.transcriptionService.currentStatus)
                    .font(self.theme.typography.bodySmall)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
                .fill(self.theme.palette.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1)
                )
        )
    }

    // MARK: - Transcript Home

    private var transcriptHome: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
                HStack(alignment: .firstTextBaseline, spacing: self.theme.metrics.spacing.sm) {
                    MeetingDocumentTitle(title: "Transcripts")
                    Text("\(self.fileHistoryStore.entries.count)")
                        .font(self.theme.typography.badge)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    Spacer()
                    Button("Delete all", systemImage: "trash", role: .destructive) {
                        self.showingDeleteAllConfirmation = true
                    }
                    .font(self.theme.typography.bodySmall)
                    .buttonStyle(.plain)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .padding(self.theme.metrics.spacing.sm)
                    .meetingHoverFeedback()
                    .disabled(self.fileHistoryStore.entries.isEmpty)
                }
                self.fileSelectionCard
                if let activity = self.conflictingActivity {
                    self.activityConflictCard(activity: activity)
                }
                if self.transcriptionService.isTranscribing {
                    self.progressCard
                }
                if let error = self.transcriptionService.error {
                    self.errorCard(error: error)
                }
                if let message = self.dropErrorMessage {
                    self.dropErrorCard(message: message)
                }
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search transcripts", text: self.$searchQuery)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Search filenames and transcript text")
                    if !self.searchQuery.isEmpty {
                        Button { self.searchQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .meetingHoverFeedback()
                        .accessibilityLabel("Clear transcript search")
                    }
                }
                .padding(self.theme.metrics.spacing.md)
                .fluidDropdownSurface()
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, self.theme.metrics.spacing.lg * 2)
            .padding(.top, self.theme.metrics.spacing.lg * 2)
            .padding(.bottom, self.theme.metrics.spacing.md)

            FileTranscriptionHomeList(
                sections: self.librarySections,
                previews: self.rowMetadata.mapValues(\.preview),
                isSearching: !self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                onOpen: { self.openTranscript(id: $0.id) },
                onRename: { self.fileHistoryStore.renameEntry(id: $0, to: $1) },
                onCopy: { self.copyToClipboard($0.text) },
                onExport: self.exportTranscript,
                onDelete: { self.pendingDeleteEntry = $0 }
            )
        }
    }

    private func exportTranscript(_ entry: FileTranscriptionEntry, format: ExportFormat) {
        self.exportFormat = format
        self.exportResult = entry.toTranscriptionResult()
        self.showingExportDialog = true
    }

    // MARK: - Transcript Document

    private func transcriptDetail(entry: FileTranscriptionEntry) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { self.openTranscriptID = nil } label: {
                    Label("All transcripts", systemImage: "chevron.left")
                }
                .meetingGlassAction()
                .keyboardShortcut("[", modifiers: .command)
                Spacer()
                if self.transcriptionService.isTranscribing {
                    ProgressView().controlSize(.small)
                    Text(self.transcriptionService.currentStatus)
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .lineLimit(1)
                } else if let error = self.transcriptionService.error {
                    Button { self.openTranscriptID = nil } label: {
                        Label("Transcription failed", systemImage: "exclamationmark.triangle")
                    }
                    .meetingGlassAction(tone: self.theme.palette.warning)
                    .help(error)
                    .accessibilityHint("Return to the upload to view the error and try again")
                }
                Button(action: self.newTranscript) {
                    Label("New transcript", systemImage: "plus")
                }
                .meetingGlassAction()
                .disabled(self.transcriptionService.isTranscribing)
                .keyboardShortcut("n", modifiers: .command)
            }
            .padding(.horizontal, FluidPageLayout.inset)
            .padding(.vertical, 12)
            Divider()

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                    MeetingDocumentTitle(title: entry.displayTitle)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .editableTitle(entry.displayTitle, id: entry.id.uuidString) {
                            self.fileHistoryStore.renameEntry(id: entry.id, to: $0)
                        }
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            self.transcriptMetadata(entry: entry)
                            Spacer()
                            self.transcriptActions(entry: entry)
                        }
                        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                            self.transcriptMetadata(entry: entry)
                            self.transcriptActions(entry: entry)
                        }
                    }
                }
                .padding(self.theme.metrics.spacing.lg)
                Divider()
                if entry.speakerSegments.isEmpty {
                    if let notice = entry.speakerLabelingNotice {
                        self.speakerNotice(notice)
                            .padding(self.theme.metrics.spacing.lg)
                    }
                    FileTranscriptTextView(entryID: entry.id, text: entry.text)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
                            if let notice = entry.speakerLabelingNotice {
                                self.speakerNotice(notice)
                            }
                            ForEach(entry.speakerSegments) { segment in
                                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                                    HStack {
                                        Button {
                                            self.speakerEditor = SpeakerEditorRequest(entry: entry, focusedSpeaker: segment.speaker)
                                        } label: {
                                            HStack(spacing: self.theme.metrics.spacing.xs) {
                                                Text(entry.speakerDisplayName(for: segment.speaker))
                                                Image(systemName: "pencil").imageScale(.small)
                                            }
                                            .foregroundStyle(self.theme.palette.accent)
                                        }
                                        .buttonStyle(.plain)
                                        .meetingHoverFeedback(cornerRadius: self.theme.metrics.corners.sm)
                                        .help("Edit speaker name for every segment")
                                        .accessibilityLabel("Edit speaker name: \(entry.speakerDisplayName(for: segment.speaker))")
                                        Text(segment.timestampText).foregroundStyle(self.theme.palette.secondaryText)
                                    }
                                    .font(self.theme.typography.captionStrong)
                                    Text(segment.text)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .font(self.theme.typography.body)
                        .textSelection(.enabled)
                        .lineSpacing(4)
                        .padding(self.theme.metrics.spacing.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity)
                    .id(entry.id)
                }
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, self.theme.metrics.spacing.lg)
            .padding(.top, self.theme.metrics.spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(self.theme.palette.windowBackground)
    }

    private func transcriptMetadata(entry: FileTranscriptionEntry) -> some View {
        HStack(spacing: self.theme.metrics.spacing.md) {
            Text(self.rowMetadata[entry.id]?.fullDate ?? "")
            Label(Duration.seconds(entry.duration).formatted(.time(pattern: .hourMinuteSecond)), systemImage: "clock")
            if !entry.speakerSegments.isEmpty {
                Image(systemName: "person.2")
                    .accessibilityLabel("Speaker labels")
                    .help("Speaker labels")
            }
        }
        .font(self.theme.typography.caption)
        .foregroundStyle(self.theme.palette.secondaryText)
    }

    private func transcriptActions(entry: FileTranscriptionEntry) -> some View {
        FluidGlassControlGroup {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                if !entry.speakerSegments.isEmpty {
                    Button {
                        self.speakerEditor = SpeakerEditorRequest(entry: entry, focusedSpeaker: nil)
                    } label: {
                        Label("Edit speakers", systemImage: "person.2")
                    }
                    .meetingGlassAction()
                }
                Button { self.copyToClipboard(entry.text) } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .meetingGlassAction()
                Menu {
                    ForEach(ExportFormat.allCases, id: \.self) { format in
                        Button(format.rawValue) { self.exportTranscript(entry, format: format) }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .meetingGlassAction()
                Menu {
                    Button("Delete transcript…", systemImage: "trash", role: .destructive) {
                        self.pendingDeleteEntry = entry
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .meetingGlassAction(circular: true)
                .accessibilityLabel("Transcript actions")
            }
        }
        .fixedSize()
    }

    private func speakerNotice(_ notice: String) -> some View {
        Label(notice, systemImage: "exclamationmark.triangle")
            .font(self.theme.typography.caption)
            .foregroundStyle(self.theme.palette.secondaryText)
    }

    // MARK: - Error Card

    private func errorCard(error: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)

            Text(error)
                .font(self.theme.typography.bodySmall)

            Spacer()

            Button("Dismiss") {
                self.transcriptionService.reset()
            }
            .fluidGlassAction()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
                .fill(Color.red.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
                        .stroke(Color.red.opacity(0.4), lineWidth: 1)
                )
        )
    }

    // MARK: - Drop Error Card

    private func dropErrorCard(message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)

            Text(message)
                .font(self.theme.typography.bodySmall)

            Spacer()

            Button("Dismiss") {
                self.dropErrorMessage = nil
            }
            .fluidGlassAction()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
                .fill(Color.red.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
                        .stroke(Color.red.opacity(0.4), lineWidth: 1)
                )
        )
    }

    // MARK: - Helper Functions

    private static let supportedFileExtensions = FileTranscriptionService.supportedFileExtensions

    private static let dropErrorCopy = FileTranscriptionService.dropErrorCopy

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL? = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            guard let url = url else { return }
            let ext = url.pathExtension.lowercased()
            guard Self.supportedFileExtensions.contains(ext) else {
                DispatchQueue.main.async {
                    self.dropErrorMessage = Self.dropErrorCopy
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.dropErrorMessage = nil
                    }
                }
                return
            }
            DispatchQueue.main.async {
                self.selectedFileURL = url
                self.transcriptionService.reset()
                self.dropErrorMessage = nil
            }
        }
        return true
    }

    private func transcribeFile() async {
        guard let fileURL = selectedFileURL else { return }

        do {
            _ = try await self.transcriptionService.transcribeFile(fileURL)
        } catch {
            DebugLogger.shared.error("Transcription error: \(error)", source: "FileTranscriptionView")
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        withAnimation(self.reduceMotion ? nil : .easeOut(duration: 0.18)) {
            self.showingCopyConfirmation = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(self.reduceMotion ? nil : .easeOut(duration: 0.18)) {
                self.showingCopyConfirmation = false
            }
        }
    }
}

// MARK: - Document for Export

struct TranscriptionDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.plainText, .json]
    }

    private let result: TranscriptionResult
    private let format: FileTranscriptionView.ExportFormat

    init(result: TranscriptionResult, format: FileTranscriptionView.ExportFormat) {
        self.result = result
        self.format = format
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnknown)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try self.makeFileWrapper()
    }

    nonisolated func makeFileWrapper() throws -> FileWrapper {
        let data: Data
        switch self.format {
        case .text:
            data = Data(self.result.textExport.utf8)
        case .json:
            data = try self.result.jsonExport
        }
        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Preview

#Preview {
    let asrService = ASRService()
    FileTranscriptionView(
        asrService: asrService,
        transcriptionService: FileTranscriptionService(asrService: asrService)
    )
    .frame(width: 700, height: 800)
}
