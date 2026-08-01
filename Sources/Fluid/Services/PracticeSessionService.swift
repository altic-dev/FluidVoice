//
//  PracticeSessionService.swift
//  Voix
//
//  Orchestrates one practice session: record -> transcribe -> analyze -> coach -> store.
//

import AVFoundation
import Combine
import Foundation

@MainActor
final class PracticeSessionService: ObservableObject {
    static let shared = PracticeSessionService()

    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case analyzing
        case coaching
        case done
        case failed(String)

        /// Whether a spinner/disabled state is appropriate.
        var isBusy: Bool {
            switch self {
            case .transcribing, .analyzing, .coaching: true
            case .idle, .recording, .done, .failed: false
            }
        }

        var statusLabel: String? {
            switch self {
            case .transcribing: "Transcribing…"
            case .analyzing: "Analyzing delivery…"
            case .coaching: "Coaching…"
            case .idle, .recording, .done, .failed: nil
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var recordingStartedAt: Date?
    /// Result of the session that just finished, held for display.
    @Published private(set) var currentSession: PracticeSession?

    private var store: PracticeSessionStore { .shared }

    var isRecording: Bool {
        self.phase == .recording
    }

    // Live preview reads ASRService.partialTranscription directly. Mirroring it here
    // would look like a published property while never actually publishing.

    // MARK: - Session lifecycle

    /// Starts capture. Microphone authorization, model warm-up and Bluetooth route
    /// recovery all come free from the inherited ASR stack.
    func startPractice() async {
        guard self.phase != .recording else { return }

        let asr = AppServices.shared.asr

        // Onboarding normally asks first, so this only bites someone who reached
        // Practice without it. Prompt rather than just reporting the failure —
        // `start()` bails silently when the mic is not already authorized.
        if asr.micStatus == .notDetermined {
            asr.requestMicAccess()
            self.phase = .failed("Grant microphone access, then press record again.")
            return
        }

        self.currentSession = nil
        self.phase = .recording
        self.recordingStartedAt = Date()

        // Claim the recorder before starting it, so the dictation pipeline stands down
        // for the whole session rather than racing us at either end.
        asr.isPracticeSessionActive = true
        await asr.start()

        // start() returns without throwing even when it bailed (denied mic, no model),
        // so a stuck non-running engine is the signal that capture never began.
        if !asr.isRunning {
            asr.isPracticeSessionActive = false
            self.phase = .failed("Could not start recording. Check microphone access and that a speech model is installed.")
            self.recordingStartedAt = nil
        }
    }

    /// Stops capture and runs the full transcribe -> analyze -> coach pipeline.
    func stopPractice() async {
        guard self.phase == .recording else { return }

        let startedAt = self.recordingStartedAt
        self.recordingStartedAt = nil
        self.phase = .transcribing

        let asr = AppServices.shared.asr
        let transcript = await asr.stop(forPracticeSession: true)
        let snapshot = asr.consumeLastCompletedAudioSnapshot()
        // Released only after the snapshot is in hand: awaiting stop() is a suspension
        // point, and handing the recorder back any earlier reopens the race.
        asr.isPracticeSessionActive = false

        guard let snapshot, !snapshot.samples.isEmpty else {
            self.phase = .failed("No audio was captured for this session.")
            return
        }

        self.phase = .analyzing
        let fillerWords = SettingsStore.shared.fillerWords
        let metrics = await Self.analyze(snapshot: snapshot, transcript: transcript, fillerWords: fillerWords)

        // Wall-clock is the honest duration when the snapshot is short (a dropped
        // buffer, say), but the sample count is what the metrics were computed from.
        let duration = metrics.durationSeconds > 0
            ? metrics.durationSeconds
            : (startedAt.map { Date().timeIntervalSince($0) } ?? 0)

        self.phase = .coaching
        var feedback = ""
        var model = ""
        var coachingError: String?
        do {
            let result = try await Self.requestCoaching(transcript: transcript, metrics: metrics)
            feedback = result.text
            model = result.model
        } catch {
            // The measurements are the durable part; keep the session either way.
            coachingError = Self.describe(error)
            DebugLogger.shared.error(
                "Practice coaching failed: \(error.localizedDescription)",
                source: "PracticeSessionService"
            )
        }

        let session = PracticeSession(
            durationSeconds: duration,
            transcript: transcript,
            feedback: feedback,
            model: model,
            coachingError: coachingError,
            metrics: metrics
        )
        self.store.add(session)
        self.currentSession = session
        self.phase = .done
    }

    /// Clears the finished session so the view returns to its resting state.
    func reset() {
        guard !self.phase.isBusy else { return }
        self.currentSession = nil
        self.recordingStartedAt = nil
        self.phase = .idle
    }

    // MARK: - Analysis

    /// Hops off the main actor: a 10 minute speech is ~9.6 M samples, and the
    /// analysis is pure computation with no UI dependency.
    private nonisolated static func analyze(
        snapshot: DictationAudioSnapshot,
        transcript: String,
        fillerWords: [String]
    ) async -> DeliveryMetrics {
        await Task.detached(priority: .userInitiated) {
            SpeechAnalysisService.analyze(
                pcm: snapshot.samples,
                sampleRate: Double(snapshot.sampleRate),
                rawTranscript: transcript,
                fillerWords: fillerWords
            )
        }.value
    }

    // MARK: - Coaching

    struct CoachingResult {
        let text: String
        let model: String
    }

    enum CoachingError: LocalizedError {
        case exhaustedByReasoning

        var errorDescription: String? {
            switch self {
            case .exhaustedByReasoning:
                "The model used its entire token budget reasoning and never wrote an answer. Try a non-reasoning model, or a shorter recording."
            }
        }
    }

    /// Mirrors the non-PrivateAI branch of `DictationPostProcessingService.process`
    /// — same route resolution, same missing-model/key guards, same client — but
    /// deliberately not its prompt: `effectiveDictationSystemPrompt` is a transcript
    /// *cleanup* instruction, and `applyGAAVFormatting` rewrites the model's prose.
    /// Neither belongs anywhere near coaching output.
    private static func requestCoaching(
        transcript: String,
        metrics: DeliveryMetrics
    ) async throws -> CoachingResult {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AIProcessingError.emptyResponse
        }

        let settings = SettingsStore.shared
        let resolved = DictationProviderRoute.resolve(settings: settings)

        guard !resolved.providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !resolved.usesPrivateAI
        else {
            throw AIProcessingError.noVerifiedProvider
        }
        guard !resolved.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProcessingError.missingModel(provider: resolved.providerKey)
        }

        let isLocal = ModelRepository.shared.isLocalEndpoint(resolved.baseURL)
        if !isLocal, resolved.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AIProcessingError.missingAPIKey(provider: resolved.providerKey)
        }

        let userMessage = """
        TRANSCRIPT
        \(trimmed)

        \(metrics.summaryText())
        """

        var config = LLMClient.Config(
            messages: [
                ["role": "system", "content": Self.coachPrompt],
                ["role": "user", "content": userMessage],
            ],
            model: resolved.model,
            baseURL: resolved.baseURL,
            apiKey: resolved.apiKey,
            streaming: false,
            tools: [],
            temperature: settings.isTemperatureUnsupported(resolved.model) ? nil : 0.7,
            extraParameters: [:]
        )
        // Coaching is a long structured answer over a possibly long transcript, and it
        // runs in the background rather than in a typing hot path.
        //
        // The budget is deliberately generous because reasoning models spend it before
        // writing anything. At 4000 this failed in the field: deepseek-v4-flash spent
        // 45s and ~17 KB on reasoning_content for a 142-word transcript and returned an
        // empty answer. A six-section critique is only ~1500 tokens; the rest is
        // headroom for models that think first.
        config.timeoutSeconds = 180
        config.maxTokens = 16_000

        let response = try await LLMClient.shared.call(config)
        guard !response.content.isEmpty else {
            // LLMClient routes reasoning_content into `thinking`, so reasoning present
            // with no answer means the budget ran out mid-thought rather than the model
            // declining to respond. Those need different fixes, so name them differently.
            if response.thinking?.isEmpty == false {
                throw CoachingError.exhaustedByReasoning
            }
            throw AIProcessingError.emptyResponse
        }
        return CoachingResult(text: response.content, model: resolved.model)
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Prompt

    /// ponytail: hardcoded for v1. Promote to an editable setting once it has been
    /// iterated against real recordings — an editable prompt that is still wrong is
    /// just a wrong prompt with more surface area.
    static let coachPrompt = """
    You are an experienced speech and communication coach. Below is a verbatim \
    speech-to-text transcript of a practiced speech, followed by delivery metrics \
    measured from the audio itself.

    The transcript may contain speech-recognition artifacts — misheard words, missing \
    punctuation, odd capitalization. Do not critique grammar-level noise; critique the \
    speech that was actually given.

    Respond in Markdown with these sections:

    1. **Core message** — state it in one sentence. If you cannot find one, say so \
    plainly; that is the most useful thing you can tell them.
    2. **What's working** — be specific, and quote short phrases.
    3. **Content** — structure (hook, thesis, flow, close), clarity, persuasiveness. \
    Name vague or unsupported claims.
    4. **Delivery** — interpret the measured numbers, citing the actual measurements.

    Reference points. Overall speaking rate: 100–130 WPM is the target for a practiced \
    talk. A value inside that range is fine — say so and move on rather than reaching \
    for a criticism. Articulation rate well above overall WPM means time is going into \
    pauses rather than into fast talking. Roughly 60–75% of the span being voiced is \
    normal for connected speech, because ordinary gaps between words fall below the \
    silence threshold; treat it as a problem only well below that. Strategic pauses \
    land at clause boundaries while dead air does not. Pitch standard deviation near \
    zero reads as monotone. Filler rates above roughly 4 per minute start to distract.

    Only the figures in the metrics block are measured. Anything else is a guess — \
    including the length or placement of pauses shorter than the 0.5s threshold, which \
    are not measured at all. State such conclusions as inferences in plain words \
    ("this suggests…"), never as findings.
    5. **Concrete improvements** — ideas, facts or examples worth adding (flag which \
    would need verification), what to cut or reorder, and one specific delivery drill.
    6. **Suggested outline** — a revised structure they could rehearse next.

    Be direct and specific. Quote short phrases when critiquing them. Do not pad with \
    praise you cannot justify from the transcript.
    """
}
