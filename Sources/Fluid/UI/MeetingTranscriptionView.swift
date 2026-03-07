import SwiftUI
import UniformTypeIdentifiers

struct MeetingTranscriptionView: View {
    let asrService: ASRService
    @StateObject private var transcriptionService: MeetingTranscriptionService
    @State private var selectedFileURL: URL?
    @Environment(\.theme) private var theme

    init(asrService: ASRService) {
        self.asrService = asrService
        _transcriptionService = StateObject(wrappedValue: MeetingTranscriptionService(asrService: asrService))
    }

    @State private var showingFilePicker = false
    @State private var showingExportDialog = false
    @State private var exportFormat: ExportFormat = .text
    @State private var showingCopyConfirmation = false
    @State private var isDropTargeted = false
    @State private var dropErrorMessage: String?

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

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(Color.fluidGreen)

                Text("Meeting Transcription")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Upload audio or video files to transcribe")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 40)
            .padding(.bottom, 30)

            // Main Content Area
            ScrollView {
                VStack(spacing: 24) {
                    // File Selection Card
                    self.fileSelectionCard

                    // Progress Card (only show when transcribing)
                    if self.transcriptionService.isTranscribing {
                        self.progressCard
                    }

                    // Results Card (only show when we have results)
                    if let result = transcriptionService.result {
                        self.resultsCard(result: result)
                    }

                    // Error Card (only show when we have an error)
                    if let error = transcriptionService.error {
                        self.errorCard(error: error)
                    }

                    // Drop error (unsupported file type)
                    if let message = self.dropErrorMessage {
                        self.dropErrorCard(message: message)
                    }
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(self.theme.palette.windowBackground)
        .overlay(
            Group {
                if self.showingCopyConfirmation {
                    Text("Copied!")
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.fluidGreen.opacity(0.9))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                        .padding()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            },
            alignment: .topTrailing
        )
    }

    // MARK: - File Selection Card

    private var fileSelectionCard: some View {
        VStack(spacing: 16) {
            if let fileURL = selectedFileURL {
                // Show selected file
                HStack {
                    Image(systemName: "doc.fill")
                        .font(.title2)
                        .foregroundColor(Color.fluidGreen)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(fileURL.lastPathComponent)
                            .font(.headline)

                        Text(self.formatFileSize(fileURL: fileURL))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button(action: {
                        self.selectedFileURL = nil
                        self.transcriptionService.reset()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(self.theme.palette.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(self.theme.palette.cardBorder.opacity(0.5), lineWidth: 1)
                        )
                )

                // Transcribe Button
                Button(action: {
                    Task {
                        await self.transcribeFile()
                    }
                }) {
                    HStack {
                        Image(systemName: "waveform")
                        Text("Transcribe")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                
                .disabled(self.transcriptionService.isTranscribing)

            } else {
                // File picker button – whole area is tappable; supports drag-and-drop
                Button(action: {
                    self.showingFilePicker = true
                }) {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.up.doc.fill")
                            .font(.system(size: 32))

                        Text("Choose Audio or Video File")
                            .font(.headline)

                        Text("Supported: WAV, MP3, M4A, MP4, MOV, and more")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(self.theme.palette.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                        .foregroundColor(Color.fluidGreen.opacity(self.isDropTargeted ? 0.7 : 0.3))
                )
                .onDrop(of: [.fileURL], isTargeted: self.$isDropTargeted) { providers in
                    self.handleDrop(providers: providers)
                }
            }
        }
        .fileImporter(
            isPresented: self.$showingFilePicker,
            allowedContentTypes: [
                .audio,
                .movie,
                .mpeg4Movie,
                UTType(filenameExtension: "wav") ?? .audio,
                UTType(filenameExtension: "mp3") ?? .audio,
                UTType(filenameExtension: "m4a") ?? .audio,
            ],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                if let url = urls.first {
                    self.selectedFileURL = url
                    self.transcriptionService.reset()
                }
            case let .failure(error):
                DebugLogger.shared.error("File picker error: \(error)", source: "MeetingTranscriptionView")
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
                    

                Text(self.transcriptionService.currentStatus)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(self.theme.palette.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1)
                )
        )
    }

    // MARK: - Results Card

    private func resultsCard(result: TranscriptionResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with stats
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transcription Complete")
                        .font(.headline)

                    HStack(spacing: 16) {
                        Label("\(String(format: "%.1f", result.duration))s", systemImage: "clock")
                        Label("\(String(format: "%.0f%%", result.confidence * 100))", systemImage: "checkmark.circle")
                        Label(
                            "\(String(format: "%.1f", result.duration / result.processingTime))x",
                            systemImage: "speedometer"
                        )
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                Spacer()

                // Action buttons
                HStack(spacing: 8) {
                    Button(action: {
                        self.copyToClipboard(result.text)
                    }) {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy to clipboard")

                    Button(action: {
                        self.showingExportDialog = true
                    }) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .help("Export transcription")
                }
                .buttonStyle(.borderless)
            }

            Divider()

            // Transcription text
            ScrollView {
                Text(result.text)
                    .font(.body)
                    
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(maxHeight: 300)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(self.theme.palette.contentBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1)
                    )
            )
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(self.theme.palette.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1)
                )
        )
        .fileExporter(
            isPresented: self.$showingExportDialog,
            document: TranscriptionDocument(
                result: result,
                format: self.exportFormat,
                service: self.transcriptionService
            ),
            contentType: self.exportFormat == .text ? .plainText : .json,
            defaultFilename: "\(result.fileName)_transcript.\(self.exportFormat.fileExtension)"
        ) { result in
            switch result {
            case .success:
                DebugLogger.shared.info("File exported successfully", source: "MeetingTranscriptionView")
            case let .failure(error):
                DebugLogger.shared.error("Export failed: \(error)", source: "MeetingTranscriptionView")
            }
        }
    }

    // MARK: - Error Card

    private func errorCard(error: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)

            Text(error)
                .font(.subheadline)

            Spacer()

            Button("Dismiss") {
                self.transcriptionService.reset()
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.red.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
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
                .font(.subheadline)

            Spacer()

            Button("Dismiss") {
                self.dropErrorMessage = nil
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.red.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.red.opacity(0.4), lineWidth: 1)
                )
        )
    }

    // MARK: - Helper Functions

    private static let supportedFileExtensions = ["wav", "mp3", "m4a", "aac", "flac", "aiff", "caf", "mp4", "mov"]

    private static let dropErrorCopy = "Accepted file types: WAV, MP3, M4A, MP4, MOV, and more."

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
            DebugLogger.shared.error("Transcription error: \(error)", source: "MeetingTranscriptionView")
        }
    }

    private func formatFileSize(fileURL: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attributes[.size] as? Int64
        else {
            return "Unknown size"
        }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
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

    let result: TranscriptionResult
    let format: MeetingTranscriptionView.ExportFormat
    let service: MeetingTranscriptionService

    init(
        result: TranscriptionResult,
        format: MeetingTranscriptionView.ExportFormat,
        service: MeetingTranscriptionService
    ) {
        self.result = result
        self.format = format
        self.service = service
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnknown)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("temp.\(self.format.fileExtension)")

        switch self.format {
        case .text:
            try self.service.exportToText(self.result, to: tempURL)
        case .json:
            try self.service.exportToJSON(self.result, to: tempURL)
        }

        let data = try Data(contentsOf: tempURL)
        try? FileManager.default.removeItem(at: tempURL)

        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Preview

struct MeetingTranscriptionView_Previews: PreviewProvider {
    static var previews: some View {
        MeetingTranscriptionView(asrService: ASRService())
            .frame(width: 700, height: 800)
    }
}
