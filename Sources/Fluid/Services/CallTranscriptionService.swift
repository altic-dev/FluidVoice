import Combine
import Foundation

@MainActor
final class CallTranscriptionService: ObservableObject {
    private struct SourceTranscription {
        let results: [(track: CapturedAudioTrack, result: TranscriptionResult)]
        let processingTime: TimeInterval
        let failures: [String]
    }

    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var status = ""

    private let asrService: ASRService
    private let fileTranscriptionService: MeetingTranscriptionService
    private let audioCaptureCoordinator: AudioCaptureCoordinator
    private var captureSession: CallCaptureSession?
    private var pipelineWaiters: [CheckedContinuation<Void, Never>] = []
    private var isWaitingForDictation = false
    private var isTerminating = false

    init(
        asrService: ASRService,
        audioCaptureCoordinator: AudioCaptureCoordinator = .shared
    ) {
        self.asrService = asrService
        self.fileTranscriptionService = MeetingTranscriptionService(asrService: asrService)
        self.audioCaptureCoordinator = audioCaptureCoordinator
    }

    func start() async throws {
        guard !self.isRecording, !self.isTranscribing else { return }
        guard let microphone = AppServices.shared.microphonePreferenceCoordinator.inputDeviceForCapture() else {
            self.status = "Call capture failed"
            throw CallTranscriptionError.microphoneUnavailable
        }
        guard !self.asrService.isMicrophonePreviewRunningOrStarting else {
            self.status = "Call capture unavailable"
            throw CallTranscriptionError.audioCaptureInUse
        }

        self.isTranscribing = true
        defer { self.finishPipelineActivity() }
        self.status = "Starting call capture..."

        let session = CallCaptureSession(microphoneDevice: microphone)
        do {
            try await session.start()
            self.captureSession = session
            self.isRecording = true
            self.status = "Recording call"
        } catch {
            self.status = "Call capture failed"
            throw error
        }
    }

    func stopAndTranscribe() async throws {
        guard let session = self.captureSession, self.isRecording, !self.isTranscribing else {
            throw CallTranscriptionError.notRecording
        }

        self.isRecording = false
        self.isTranscribing = true
        defer { self.finishPipelineActivity() }
        self.captureSession = nil
        self.status = "Finalizing call audio..."

        let capturedAudio: CapturedCallAudio
        do {
            capturedAudio = try await session.stop()
        } catch {
            self.status = "Call capture failed"
            throw error
        }
        defer { capturedAudio.remove() }

        if self.asrService.isRunningOrStarting {
            self.status = "Waiting for dictation to finish..."
        }
        self.isWaitingForDictation = true
        while !self.audioCaptureCoordinator.reserve(for: .call) {
            await self.audioCaptureCoordinator.waitUntilReleased(.dictation)
            guard !self.isTerminating else {
                self.isWaitingForDictation = false
                return
            }
        }
        self.isWaitingForDictation = false
        defer { self.audioCaptureCoordinator.release(for: .call) }
        guard !self.isTerminating else { return }

        AnalyticsService.shared.recordUsage(
            mode: .meeting,
            transcriptionModel: SettingsStore.shared.selectedSpeechModel.analyticsDescriptor
        )
        var recordingURL: URL?
        do {
            self.status = "Saving call recording..."
            async let savedRecording = CallRecordingStore.shared.save(capturedAudio)
            async let transcription = self.transcribeSources(capturedAudio)

            let savedRecordingURL = try await savedRecording
            recordingURL = savedRecordingURL
            let sourceTranscription = try await transcription
            let result = self.assembleResult(
                sourceTranscription.results,
                capturedAudio: capturedAudio,
                processingTime: sourceTranscription.processingTime,
                sourceFilePath: savedRecordingURL.path,
                sourceFailures: sourceTranscription.failures
            )
            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CallTranscriptionError.noSpeechRecognized
            }
            FileTranscriptionHistoryStore.shared.addEntry(result)
            self.status = "Call transcript complete"
        } catch {
            CallRecordingStore.shared.deleteIfOwned(path: recordingURL?.path)
            self.status = "Call transcription failed"
            throw error
        }
    }

    func stopForTermination() async {
        self.isTerminating = true

        // ASR shutdown releases an active dictation and lets the pending call task unwind.
        guard !self.isWaitingForDictation else { return }

        while self.isTranscribing, self.captureSession == nil {
            await self.waitForPipelineActivity()
        }
        guard let session = self.captureSession else { return }

        self.captureSession = nil
        self.isRecording = false
        self.isTranscribing = true
        defer { self.finishPipelineActivity() }
        if let capturedAudio = try? await session.stop() {
            capturedAudio.remove()
        }
    }

    private func transcribeSources(_ capturedAudio: CapturedCallAudio) async throws -> SourceTranscription {
        let startedAt = Date()
        var sourceResults: [(track: CapturedAudioTrack, result: TranscriptionResult)] = []
        var sourceFailures: [String] = []
        var lastError: Error?

        if !capturedAudio.tracks.contains(where: { $0.source == .system }) {
            sourceFailures.append("System audio was not captured.")
        }
        if !capturedAudio.tracks.contains(where: { $0.source == .microphone }) {
            sourceFailures.append("Microphone audio was not captured.")
        }

        for track in capturedAudio.tracks {
            let sourceName = track.source == .microphone ? "your microphone" : "other participants"
            self.status = "Transcribing \(sourceName)..."
            do {
                let expectedSpeakerCount = track.source == .microphone ? 1 : nil
                let result = try await self.fileTranscriptionService.transcribeSourceFile(
                    track.url,
                    options: .callTrack(expectedSpeakerCount: expectedSpeakerCount)
                )
                sourceResults.append((track, result))
            } catch {
                lastError = error
                sourceFailures.append("\(sourceName.capitalized) could not be transcribed.")
                DebugLogger.shared.warning(
                    "Call source transcription failed for \(sourceName): \(error.localizedDescription)",
                    source: "CallTranscriptionService"
                )
            }
        }

        guard !sourceResults.isEmpty else {
            throw lastError ?? CallTranscriptionError.noAudioCaptured
        }
        return SourceTranscription(
            results: sourceResults,
            processingTime: Date().timeIntervalSince(startedAt),
            failures: sourceFailures
        )
    }

    private func assembleResult(
        _ sourceResults: [(track: CapturedAudioTrack, result: TranscriptionResult)],
        capturedAudio: CapturedCallAudio,
        processingTime: TimeInterval,
        sourceFilePath: String,
        sourceFailures: [String]
    ) -> TranscriptionResult {
        var segments: [SpeakerTranscriptSegment] = []
        var gaps: [SpeakerTranscriptGap] = []
        var notices = sourceFailures
        var weightedConfidence: Float = 0
        var confidenceWeight: Float = 0
        var remoteSpeakerLabels: [String: String] = [:]

        for sourceResult in sourceResults {
            let result = sourceResult.result
            let offset = capturedAudio.relativeStart(for: sourceResult.track)
            let weight = Float(max(1, result.duration))
            weightedConfidence += result.confidence * weight
            confidenceWeight += weight

            if let notice = result.speakerLabelingNotice {
                let source = sourceResult.track.source == .microphone ? "Microphone" : "System audio"
                notices.append("\(source): \(notice)")
            }
            gaps.append(contentsOf: result.speakerLabelingGaps.map {
                SpeakerTranscriptGap(
                    startSeconds: $0.startSeconds + offset,
                    endSeconds: $0.endSeconds + offset
                )
            })

            if result.speakerSegments.isEmpty {
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let speaker = sourceResult.track.source == .microphone ? "You" : "Other participant"
                segments.append(SpeakerTranscriptSegment(
                    speaker: speaker,
                    startSeconds: offset,
                    endSeconds: offset + result.duration,
                    text: text
                ))
                continue
            }

            for segment in result.speakerSegments {
                let speaker: String
                if sourceResult.track.source == .microphone {
                    speaker = "You"
                } else if let existing = remoteSpeakerLabels[segment.speaker] {
                    speaker = existing
                } else {
                    speaker = "Speaker \(remoteSpeakerLabels.count + 1)"
                    remoteSpeakerLabels[segment.speaker] = speaker
                }
                segments.append(SpeakerTranscriptSegment(
                    speaker: speaker,
                    startSeconds: segment.startSeconds + offset,
                    endSeconds: segment.endSeconds + offset,
                    text: segment.text
                ))
            }
        }

        segments.sort {
            if $0.startSeconds == $1.startSeconds {
                return $0.speaker < $1.speaker
            }
            return $0.startSeconds < $1.startSeconds
        }
        gaps.sort { $0.startSeconds < $1.startSeconds }
        let duration = sourceResults.map {
            capturedAudio.relativeStart(for: $0.track) + $0.result.duration
        }.max() ?? 0

        return TranscriptionResult(
            text: segments.map(\.plainText).joined(separator: "\n\n"),
            confidence: confidenceWeight > 0 ? weightedConfidence / confidenceWeight : 0,
            duration: duration,
            processingTime: processingTime,
            fileName: capturedAudio.fileName,
            sourceFilePath: sourceFilePath,
            kind: .call,
            speakerSegments: segments,
            speakerLabelingNotice: notices.isEmpty ? nil : notices.joined(separator: " "),
            speakerLabelingGaps: gaps
        )
    }

    private func waitForPipelineActivity() async {
        await withCheckedContinuation { continuation in
            self.pipelineWaiters.append(continuation)
        }
    }

    private func finishPipelineActivity() {
        self.isTranscribing = false
        let waiters = self.pipelineWaiters
        self.pipelineWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }
}
