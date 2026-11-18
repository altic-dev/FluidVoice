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
    @State private var transcriptListWidth: CGFloat = 320
    @State private var splitterDragStart: CGFloat?
    @State private var isSplitterHovered = false
    @State private var pendingDeleteEntry: FileTranscriptionEntry?
    @State private var showingClearConfirmation = false

    private struct RowMetadata {
        let preview: String
        let relativeDate: String
        let fullDate: String
    }

    @State private var rowMetadata: [UUID: RowMetadata] = [:]
    @State private var filteredEntries: [FileTranscriptionEntry] = []
    // Only an explicit global-search reveal may move the library viewport.
    @State private var pendingRevealID: UUID?

    private func updateSearchResults(entries: [FileTranscriptionEntry]) {
        let query = self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        self.filteredEntries = query.isEmpty ? entries : entries.filter {
            $0.displayTitle.localizedStandardContains(query) || $0.fileName.localizedStandardContains(query) || $0.text.localizedStandardContains(query)
        }
    }

    private var selectedEntry: FileTranscriptionEntry? {
        let entries = self.filteredEntries
        return entries.first { $0.id == self.fileHistoryStore.selectedEntryID } ?? entries.first
    }

    enum ExportFormat: String, CaseIterable, Sendable {
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
        guard let fileExtension = (self.selectedFileURL ?? self.transcriptionService.currentFileURL)?
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
        VStack(spacing: 0) {
            VStack(spacing: self.theme.metrics.spacing.sm) {
                if let activity = self.conflictingActivity {
                    self.activityConflictCard(activity: activity)
                }
                self.fileSelectionCard
                if self.transcriptionService.isTranscribing {
                    self.progressCard
                }
                if let error = self.transcriptionService.error {
                    self.errorCard(error: error)
                }
                if let message = self.dropErrorMessage {
                    self.dropErrorCard(message: message)
                }
            }
            .padding(FluidPageLayout.inset)

            FluidHairline()
            self.transcriptBrowser
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fluidCanvas()
        .overlay(alignment: .topTrailing) {
            if self.showingCopyConfirmation {
                Text("Copied!")
                    .fluidText(.label)
                    .foregroundStyle(self.theme.look.text)
                    .padding(.horizontal, self.theme.metrics.spacing.md)
                    .padding(.vertical, self.theme.metrics.spacing.xs + 2)
                    .background(self.theme.look.sheet, in: Capsule())
                    .overlay(Capsule().strokeBorder(self.theme.look.edge, lineWidth: 1))
                    .padding()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
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
        .onReceive(self.fileHistoryStore.$entries) { entries in
            self.rowMetadata = Dictionary(entries.map { entry in
                (entry.id, RowMetadata(preview: entry.previewText, relativeDate: entry.relativeTimeString, fullDate: entry.fullDateString))
            }, uniquingKeysWith: { _, latest in latest })
            self.updateSearchResults(entries: entries)
        }
        .task(id: self.revealTarget) {
            guard let id = FileTranscriptionSearchReveal.transcriptID(self.revealTarget) else { return }
            self.searchQuery = ""
            self.updateSearchResults(entries: self.fileHistoryStore.entries)
            self.fileHistoryStore.selectedEntryID = id
            self.pendingRevealID = self.filteredEntries.contains(where: { $0.id == id }) ? id : nil
            self.revealTarget = nil
        }
        .onChange(of: self.searchQuery) { _, _ in
            self.updateSearchResults(entries: self.fileHistoryStore.entries)
        }
        .onChange(of: self.transcriptionService.isTranscribing) { _, isTranscribing in
            guard isTranscribing else { return }
            AccessibilityNotification.Announcement("File transcription started").post()
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
        .alert("Clear all transcripts?", isPresented: self.$showingClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear all", role: .destructive) { self.fileHistoryStore.clearAll() }
        } message: {
            Text("All saved file transcripts will be permanently deleted. Original files are kept.")
        }
        .onAppear {
            if self.selectedFileURL == nil {
                self.selectedFileURL = self.transcriptionService.currentFileURL
            }
        }
    }

    private func activityConflictCard(activity: ASRExclusiveActivity) -> some View {
        FluidSurfaceCard(padding: self.theme.metrics.spacing.lg) {
            Text("File transcription is paused while \(activity.displayName) is active.")
                .fluidText(.body)
                .foregroundStyle(self.theme.look.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel(
            "File transcription unavailable. Wait for the active \(activity.displayName) to finish."
        )
    }

    // MARK: - File Selection Card

    private var fileSelectionCard: some View {
        VStack(spacing: 16) {
            if let fileURL = selectedFileURL ?? self.transcriptionService.currentFileURL {
                // Show selected file; it leads the page.
                FluidSurfaceCard(padding: self.theme.metrics.spacing.lg, leads: true) {
                    HStack(spacing: self.theme.metrics.spacing.md) {
                        FluidGlyphTile(systemImage: self.selectedFileIsVideo ? "film" : "waveform", size: 36)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(fileURL.lastPathComponent)
                                .fluidText(.rowTitle)
                                .foregroundStyle(self.theme.look.text)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Text(self.selectedFileIsVideo ? "Video file" : "Audio file")
                                .fluidText(.label)
                                .foregroundStyle(self.theme.look.tertiaryText)
                        }

                        Spacer()

                        HStack(spacing: self.theme.metrics.spacing.sm) {
                            Button("Remove") {
                                self.selectedFileURL = nil
                                self.transcriptionService.reset()
                            }
                            .fluidAction()
                            .disabled(self.transcriptionService.isTranscribing)
                            .help(self.transcriptionService.isTranscribing ? "Wait for transcription to finish" : "Remove file")
                            Button(self.transcriptionService.isTranscribing ? "Transcribing…" : "Transcribe file") {
                                Task {
                                    await self.transcribeFile()
                                }
                            }
                            .fluidAction(.primary)
                            .disabled(
                                self.transcriptionService.isTranscribing ||
                                    self.conflictingActivity != nil
                            )
                            .help(
                                self.conflictingActivity != nil
                                    ? "Wait for the active transcription to finish"
                                    : "Transcribe the selected file"
                            )
                        }
                    }
                }

                // Speaker labeling options (unavailable on Intel Macs)
                if SpeakerDiarizationService.isSupported {
                    FluidSettingsGroup {
                        FluidSettingsRow(
                            title: "Label speakers",
                            description: self.selectedFileIsVideo
                                ? "Available for audio files only"
                                : "Identify who said what (downloads speaker models on first use)"
                        ) {
                            Toggle("Label speakers", isOn: self.$settings.fileTranscriptionSpeakerLabelsEnabled)
                                .fluidSwitch()
                                .disabled(self.selectedFileIsVideo || self.transcriptionService.isTranscribing)
                        }

                        if self.settings.fileTranscriptionSpeakerLabelsEnabled, !self.selectedFileIsVideo {
                            FluidSettingsRow(title: "Number of speakers") {
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
                                .frame(width: 110)
                                .disabled(self.transcriptionService.isTranscribing)
                            }
                        }
                    }
                }

            } else {
                let shape = RoundedRectangle(cornerRadius: FluidSurfaceCard<EmptyView>.cornerRadius, style: .continuous)
                HStack(spacing: self.theme.metrics.spacing.md) {
                    FluidGlyphTile(systemImage: "doc.badge.plus", size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(self.isDropTargeted ? "Drop to select file" : "Transcribe a file")
                            .fluidText(.rowTitle)
                            .foregroundStyle(self.theme.look.text)
                        Text("Drop audio or video here, or choose a file.")
                            .fluidText(.body)
                            .foregroundStyle(self.theme.look.secondaryText)
                    }
                    Spacer(minLength: self.theme.metrics.spacing.sm)
                    Button("Choose file…") { self.showingFilePicker = true }
                        .fluidAction(.primary)
                }
                .frame(maxWidth: .infinity)
                .padding(self.theme.metrics.spacing.lg)
                .contentShape(Rectangle())
                .help(FileTranscriptionService.supportedFormatsDescription)
                .background(self.theme.look.card.top, in: shape)
                // A dashed edge marks the drop zone; it darkens while a file is over it.
                .overlay(
                    shape
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                        .foregroundStyle(self.isDropTargeted ? self.theme.look.text : self.theme.look.tertiaryText)
                        .allowsHitTesting(false)
                )
                .onDrop(of: [.fileURL], isTargeted: self.$isDropTargeted) { providers in
                    self.handleDrop(providers: providers)
                }
            }
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
    }

    // MARK: - Progress Card

    private var progressCard: some View {
        FluidSurfaceCard(padding: self.theme.metrics.spacing.lg) {
            VStack(spacing: self.theme.metrics.spacing.md) {
                ProgressView(value: self.transcriptionService.progress)
                    .progressViewStyle(.linear)
                    .tint(self.theme.look.data)

                HStack {
                    ProgressView()
                        .controlSize(.small)
                        .fixedSize()

                    Text(self.transcriptionService.currentStatus)
                        .fluidText(.body)
                        .foregroundStyle(self.theme.look.secondaryText)
                }
            }
        }
    }

    private var transcriptBrowser: some View {
        GeometryReader { geometry in
            let available = max(0, geometry.size.width - 10)
            let minimum = min(240, available / 2)
            let maximum = max(minimum, available - min(300, available / 2))
            let width = min(max(self.transcriptListWidth, minimum), maximum)
            HStack(spacing: 0) {
                self.transcriptList
                    .frame(width: width)
                self.transcriptDivider(width: width, minimum: minimum, maximum: maximum)
                Group {
                    if let entry = self.selectedEntry {
                        self.transcriptDetail(entry: entry)
                    } else {
                        self.emptyDetail
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func transcriptDivider(width: CGFloat, minimum: CGFloat, maximum: CGFloat) -> some View {
        ZStack {
            FluidHairline(axis: .vertical)
            Capsule()
                .fill(self.isSplitterHovered || self.splitterDragStart != nil
                    ? self.theme.look.text : self.theme.look.tertiaryText)
                .frame(width: 3, height: 28)
        }
        .frame(width: 10)
        .contentShape(Rectangle())
        .onHover { hovering in
            self.isSplitterHovered = hovering
            (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let start = self.splitterDragStart ?? width
                    self.splitterDragStart = start
                    self.transcriptListWidth = min(max(start + value.translation.width, minimum), maximum)
                }
                .onEnded { _ in self.splitterDragStart = nil }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { self.transcriptListWidth = 320 })
        .help("Drag to resize panes. Double-click to reset.")
        .accessibilityElement()
        .accessibilityLabel("Resize transcript panes")
        .accessibilityValue("File list width \(Int(width)) points")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: self.transcriptListWidth = min(width + 40, maximum)
            case .decrement: self.transcriptListWidth = max(width - 40, minimum)
            @unknown default: break
            }
        }
        .onDisappear {
            if self.isSplitterHovered { NSCursor.arrow.set() }
            self.isSplitterHovered = false
            self.splitterDragStart = nil
        }
    }

    // MARK: - Transcript Library

    private var transcriptList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transcripts")
                    .fluidText(.groupTitle)
                    .foregroundStyle(self.theme.look.text)
                Spacer()
                Text("\(self.filteredEntries.count)")
                    .fluidText(.label)
                    .foregroundStyle(self.theme.look.tertiaryText)
            }
            .padding(self.theme.metrics.spacing.lg)

            FluidSearchField(text: self.$searchQuery, placeholder: "Search transcripts…")
                .accessibilityLabel("Search filenames and transcript text")
                .padding(.horizontal, self.theme.metrics.spacing.md)
                .padding(.bottom, self.theme.metrics.spacing.md)
            FluidHairline()

            if self.filteredEntries.isEmpty {
                VStack(spacing: self.theme.metrics.spacing.xs) {
                    Text(self.searchQuery.isEmpty ? "No transcripts yet" : "No matching transcripts")
                        .fluidText(.rowTitle)
                        .foregroundStyle(self.theme.look.secondaryText)
                    Text(self.searchQuery.isEmpty ? "Transcribe a file to start your library." : "Try a filename or words from the transcript.")
                        .fluidText(.label)
                        .foregroundStyle(self.theme.look.tertiaryText)
                }
                .multilineTextAlignment(.center)
                .padding(self.theme.metrics.spacing.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: self.theme.metrics.spacing.xs) {
                            ForEach(self.filteredEntries) { entry in
                                self.transcriptRow(entry: entry).id(entry.id)
                            }
                        }
                        .padding(self.theme.metrics.spacing.sm)
                    }
                    .task(id: self.pendingRevealID) {
                        guard let id = self.pendingRevealID else { return }
                        await Task.yield()
                        guard !Task.isCancelled, self.pendingRevealID == id,
                              self.filteredEntries.contains(where: { $0.id == id }) else { return }
                        proxy.scrollTo(id)
                        self.pendingRevealID = nil
                    }
                }
            }
            FluidHairline()
            HStack {
                Text("Saved on this Mac")
                    .fluidText(.label)
                    .foregroundStyle(self.theme.look.tertiaryText)
                Spacer()
                Button("Clear all…") { self.showingClearConfirmation = true }
                    .fluidGlassAction(quiet: true)
                    .disabled(self.fileHistoryStore.entries.isEmpty)
            }
            .padding(.leading, self.theme.metrics.spacing.lg)
            .padding(.trailing, self.theme.metrics.spacing.sm)
            .padding(.vertical, self.theme.metrics.spacing.xs)
        }
    }

    private func transcriptRow(entry: FileTranscriptionEntry) -> some View {
        let isSelected = self.selectedEntry?.id == entry.id
        return HStack(spacing: self.theme.metrics.spacing.xs) {
            Button {
                self.pendingRevealID = nil
                self.fileHistoryStore.selectedEntryID = entry.id
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayTitle)
                        .fluidText(.rowTitle)
                        .foregroundStyle(self.theme.look.text)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(self.rowMetadata[entry.id]?.relativeDate ?? "")
                        .fluidText(.label)
                        .foregroundStyle(self.theme.look.tertiaryText)
                    Text(self.rowMetadata[entry.id]?.preview ?? "")
                        .fluidText(.label)
                        .foregroundStyle(self.theme.look.secondaryText)
                        .lineLimit(1)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(self.theme.metrics.spacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .editableTitle(entry.displayTitle, id: entry.id.uuidString, doubleClickEnabled: false) {
                self.fileHistoryStore.renameEntry(id: entry.id, to: $0)
            }
            Button { self.copyToClipboard(entry.text) } label: {
                Image(systemName: "doc.on.doc")
            }
            .fluidGlassAction(circular: true, quiet: true)
            .help("Copy transcript")
            .accessibilityLabel("Copy \(entry.displayTitle)")
            .padding(.trailing, self.theme.metrics.spacing.sm)
        }
        .fluidListRowFill(isSelected: isSelected)
    }

    private var emptyDetail: some View {
        VStack(spacing: self.theme.metrics.spacing.md) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.fluidSystem(size: 32, weight: .light))
                .foregroundStyle(self.theme.look.tertiaryText)
                .accessibilityHidden(true)
            Text(self.searchQuery.isEmpty ? "Your transcript appears here" : "No matching transcript")
                .fluidText(.rowTitle)
                .foregroundStyle(self.theme.look.secondaryText)
            Text("Select a file on the left to read, copy, or export its transcript.")
                .fluidText(.label)
                .foregroundStyle(self.theme.look.tertiaryText)
        }
        .multilineTextAlignment(.center)
        .padding(self.theme.metrics.spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func transcriptDetail(entry: FileTranscriptionEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                Text(entry.displayTitle)
                    .fluidText(.detailTitle)
                    .foregroundStyle(self.theme.look.text)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .editableTitle(entry.displayTitle, id: entry.id.uuidString) {
                        self.fileHistoryStore.renameEntry(id: entry.id, to: $0)
                    }
                Text([self.rowMetadata[entry.id]?.fullDate, Duration.seconds(entry.duration).formatted(.time(pattern: .hourMinuteSecond)), entry.speakerSegments.isEmpty ? nil : "Speaker labels"]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .fluidText(.label)
                    .foregroundStyle(self.theme.look.tertiaryText)
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    // The page's one main action stays in the file card above.
                    Button("Copy") { self.copyToClipboard(entry.text) }
                        .fluidAction()
                    Menu {
                        ForEach(ExportFormat.allCases, id: \.self) { format in
                            Button(format.rawValue) {
                                self.exportFormat = format
                                self.exportResult = entry.toTranscriptionResult()
                                self.showingExportDialog = true
                            }
                        }
                    } label: {
                        Text("Export")
                    }
                    .menuIndicator(.hidden)
                    .fluidAction()
                    .fixedSize()
                    Button("Delete", role: .destructive) { self.pendingDeleteEntry = entry }
                        .fluidAction()
                        .help("Delete transcript")
                        .accessibilityLabel("Delete transcript")
                    Spacer(minLength: 0)
                }
            }
            .padding(self.theme.metrics.spacing.lg)
            FluidHairline()
            if entry.speakerSegments.isEmpty {
                if let notice = entry.speakerLabelingNotice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .fluidText(.label)
                        .foregroundStyle(self.theme.look.secondaryText)
                        .padding(self.theme.metrics.spacing.lg)
                }
                FileTranscriptTextView(entryID: entry.id, text: entry.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
                        if let notice = entry.speakerLabelingNotice {
                            Label(notice, systemImage: "exclamationmark.triangle")
                                .fluidText(.label)
                                .foregroundStyle(self.theme.look.secondaryText)
                        }
                        ForEach(entry.speakerSegments) { segment in
                            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                                HStack {
                                    Text(segment.speaker).fluidText(.rowTitle).foregroundStyle(self.theme.look.text)
                                    Text(segment.timestampText).fluidText(.label).foregroundStyle(self.theme.look.tertiaryText)
                                }
                                Text(segment.text)
                                    .foregroundStyle(self.theme.look.text)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .fluidText(.body)
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .padding(self.theme.metrics.spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                .id(entry.id)
            }
        }
    }

    // MARK: - Error Card

    private func errorCard(error: String) -> some View {
        FluidSurfaceCard(padding: self.theme.metrics.spacing.lg) {
            HStack {
                Label(error, systemImage: "exclamationmark.triangle")
                    .fluidText(.body)
                    .foregroundStyle(self.theme.look.text)

                Spacer()

                Button("Dismiss") {
                    self.transcriptionService.reset()
                }
                .fluidAction()
            }
        }
    }

    // MARK: - Drop Error Card

    private func dropErrorCard(message: String) -> some View {
        FluidSurfaceCard(padding: self.theme.metrics.spacing.lg) {
            HStack {
                Label(message, systemImage: "exclamationmark.triangle")
                    .fluidText(.body)
                    .foregroundStyle(self.theme.look.text)

                Spacer()

                Button("Dismiss") {
                    self.dropErrorMessage = nil
                }
                .fluidAction()
            }
        }
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

        withAnimation {
            self.showingCopyConfirmation = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
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
