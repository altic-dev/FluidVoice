import Foundation

nonisolated enum ModelPreparationPhase: Sendable, Equatable {
    case preparingDownload
    case downloading
    case optimizing
    case loading
}

nonisolated struct ModelPreparationProgress: Sendable, Equatable {
    let phase: ModelPreparationPhase
    let fractionCompleted: Double?

    init(phase: ModelPreparationPhase, fractionCompleted: Double? = nil) {
        self.phase = phase
        self.fractionCompleted = fractionCompleted.map { max(0.0, min(1.0, $0)) }
    }

    static let preparingDownload = ModelPreparationProgress(phase: .preparingDownload)
    static let optimizing = ModelPreparationProgress(phase: .optimizing)
    static let loading = ModelPreparationProgress(phase: .loading)

    static func downloading(_ fractionCompleted: Double) -> ModelPreparationProgress {
        ModelPreparationProgress(phase: .downloading, fractionCompleted: fractionCompleted)
    }
}

/// Bridges provider callbacks into dependencies whose progress handlers are `@Sendable`.
/// The callback is immutable; callers remain responsible for hopping to their UI actor.
final nonisolated class ModelPreparationProgressRelay: @unchecked Sendable {
    private static let minimumDeliveryInterval: TimeInterval = 0.1

    private let handler: ((ModelPreparationProgress) -> Void)?
    private let lock = NSLock()
    private var lastPhase: ModelPreparationPhase?
    private var lastDeliveredPercentage: Int?
    private var lastDeliveryTime: TimeInterval = 0
    private var pendingProgress: ModelPreparationProgress?
    private var deliveryScheduled = false

    init(_ handler: ((ModelPreparationProgress) -> Void)?) {
        self.handler = handler
    }

    func report(_ progress: ModelPreparationProgress) {
        let now = ProcessInfo.processInfo.systemUptime
        let delivery = self.lock.withLock { () -> (immediate: Bool, delay: TimeInterval?) in
            if progress.phase != self.lastPhase {
                self.lastPhase = progress.phase
                self.pendingProgress = nil
                self.lastDeliveredPercentage = nil
                self.lastDeliveryTime = now
                return (true, nil)
            }

            guard progress.phase == .downloading else { return (false, nil) }

            let percentage = Int((progress.fractionCompleted ?? 0) * 100)
            guard percentage != self.lastDeliveredPercentage else { return (false, nil) }

            let elapsed = now - self.lastDeliveryTime
            if elapsed >= Self.minimumDeliveryInterval {
                self.pendingProgress = nil
                self.lastDeliveredPercentage = percentage
                self.lastDeliveryTime = now
                return (true, nil)
            }

            self.pendingProgress = progress
            guard !self.deliveryScheduled else { return (false, nil) }
            self.deliveryScheduled = true
            return (false, Self.minimumDeliveryInterval - elapsed)
        }

        if delivery.immediate {
            self.handler?(progress)
        } else if let delay = delivery.delay {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.flushPendingProgress()
            }
        }
    }

    private func flushPendingProgress() {
        let progress = self.lock.withLock { () -> ModelPreparationProgress? in
            self.deliveryScheduled = false
            guard let progress = self.pendingProgress,
                  progress.phase == self.lastPhase
            else {
                self.pendingProgress = nil
                return nil
            }

            self.pendingProgress = nil
            self.lastDeliveredPercentage = Int((progress.fractionCompleted ?? 0) * 100)
            self.lastDeliveryTime = ProcessInfo.processInfo.systemUptime
            return progress
        }
        if let progress {
            self.handler?(progress)
        }
    }
}

// MARK: - Transcription Result

/// Unified result type for ASR transcription across all providers
/// Named ASRTranscriptionResult to avoid conflict with MeetingTranscriptionService.TranscriptionResult
struct ASRTranscriptionResult {
    let text: String
    let confidence: Float
    let pronunciationEnrollment: PronunciationEnrollmentCapture?

    init(
        text: String,
        confidence: Float = 1.0,
        pronunciationEnrollment: PronunciationEnrollmentCapture? = nil
    ) {
        self.text = text
        self.confidence = confidence
        self.pronunciationEnrollment = pronunciationEnrollment
    }
}

nonisolated struct ASRWordTiming: Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

// MARK: - Transcription Provider Protocol

/// Protocol that abstracts speech-to-text transcription.
/// Implementations can use different backends (FluidAudio, transcribe.cpp, etc.)
protocol TranscriptionProvider {
    /// Display name of the provider
    var name: String { get }

    /// Whether this provider is available on the current system
    var isAvailable: Bool { get }

    /// Whether models are downloaded and ready
    var isReady: Bool { get }

    /// Download/prepare models for transcription.
    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws

    /// Transcribe audio samples
    /// - Parameter samples: 16kHz mono PCM float samples
    /// - Returns: Transcription result with text and confidence
    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult

    /// Transcribe audio for live streaming updates.
    /// Providers can use faster/lighter paths than final transcription when needed.
    func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult

    /// Transcribe audio for final output when recording stops.
    /// Providers can use higher-quality passes (e.g., vocabulary rescoring) here.
    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult

    /// Transcribe audio captured while training dictionary replacements.
    /// Providers can bypass final-output transforms that would distort the saved phrase.
    func transcribeDictionaryTraining(_ samples: [Float]) async throws -> ASRTranscriptionResult

    /// Meeting word alignment only; dictation never calls the method this gates.
    var supportsWordTimings: Bool { get }

    func transcribeWithWordTimings(_ samples: [Float]) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming])

    /// Whether this provider prefers to handle long-form file transcription itself.
    /// This is useful when the backend already has model-native long-audio chunking/reassembly.
    var prefersNativeFileTranscription: Bool { get }

    /// Transcribe a complete audio/video file.
    /// Providers that do not implement this can rely on MeetingTranscriptionService fallback chunking.
    func transcribeFile(at fileURL: URL) async throws -> ASRTranscriptionResult

    /// Check if models exist on disk (without loading them)
    func modelsExistOnDisk() -> Bool

    /// Clear cached models
    func clearCache() async throws

    /// Whether cancellation should discard an incomplete app-managed model cache.
    var shouldClearCacheAfterCancellation: Bool { get }
}

// Default implementation for optional methods
extension TranscriptionProvider {
    func modelsExistOnDisk() -> Bool { return false }
    func clearCache() async throws {}
    var shouldClearCacheAfterCancellation: Bool { true }
    var prefersNativeFileTranscription: Bool { false }
    var supportsWordTimings: Bool { false }

    func transcribeWithWordTimings(_ samples: [Float]) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming]) {
        (try await self.transcribe(samples), [])
    }
    func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribe(samples)
    }

    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribe(samples)
    }

    func transcribeDictionaryTraining(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribeFinal(samples)
    }

    func transcribeFile(at fileURL: URL) async throws -> ASRTranscriptionResult {
        throw NSError(
            domain: "TranscriptionProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "\(self.name) does not implement native file transcription."]
        )
    }
}

// MARK: - Architecture Detection

/// Utility to detect the current CPU architecture
enum CPUArchitecture {
    case applesilicon
    case intel

    static var current: CPUArchitecture {
        #if arch(arm64)
        return .applesilicon
        #else
        return .intel
        #endif
    }

    static var isAppleSilicon: Bool {
        current == .applesilicon
    }

    static var isIntel: Bool {
        current == .intel
    }
}
