import Accelerate
import AVFoundation
import Combine
import Darwin
import Foundation
#if arch(arm64)
import FluidAudio
#endif
import AppKit
import AudioToolbox
import CoreAudio

/// Serializes transcription operations and lets teardown cancel the real queued work.
private actor TranscriptionExecutor {
    private var lastTask: Task<Void, Never>?
    private var operationCancellations: [UUID: () -> Void] = [:]

    func run<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        let previous = self.lastTask
        let operationID = UUID()
        let task = Task<T, Error> {
            _ = await previous?.result
            try Task.checkCancellation()
            return try await operation()
        }
        self.operationCancellations[operationID] = { task.cancel() }
        self.lastTask = Task { _ = try? await task.value }
        defer { self.operationCancellations.removeValue(forKey: operationID) }
        return try await task.value
    }

    func cancelAndAwaitPending() async {
        for cancel in self.operationCancellations.values {
            cancel()
        }
        _ = await self.lastTask?.result
        self.lastTask = nil
        self.operationCancellations.removeAll()
    }
}

struct ShortAudioSilenceAssessment: Equatable {
    let durationMilliseconds: Int
    let isEligible: Bool
    let shouldSkipTranscription: Bool
    let peakAmplitude: Float
    let rmsAmplitude: Float
    let maximumFrameRMS: Float
}

enum AudioCaptureStartOutcome: Equatable {
    case started
    case alreadyActive
    case failed
}

enum ASRStopOutcome: Equatable {
    case success
    case empty
    case failed
}

// swiftlint:disable file_length type_body_length
/// A comprehensive speech recognition service that handles real-time audio transcription.
///
/// This service manages the entire ASR (Automatic Speech Recognition) pipeline including:
/// - Audio capture and processing
/// - Model downloading and management
/// - Real-time transcription
/// - Audio level visualization
/// - Text-to-speech integration
///
/// The service is designed to work seamlessly with macOS system APIs and provides
/// robust error handling and performance optimization.
///
/// ## Language Support
/// The service supports multiple models with varying language capabilities:
/// - **Parakeet TDT v3** (Default): Automatically detects and transcribes 25 European languages:
///   Bulgarian, Croatian, Czech, Danish, Dutch, English, Estonian, Finnish, French, German,
///   Greek, Hungarian, Italian, Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian,
///   Slovak, Slovenian, Spanish, Swedish, Russian, and Ukrainian.
/// - **Parakeet TDT v2**: Specialized for high-accuracy English transcription.
/// - **Apple Speech**: Supports all system languages available on macOS.
/// - **Whisper**: Supports 99 languages.
///
/// No manual language selection is required for Parakeet models - v3 automatically detects the spoken language.
/// ## Thread Safety
/// All public methods are marked with @MainActor to ensure thread safety.
/// Audio processing happens on background threads for optimal performance.
///
/// ## Model Management
/// The service automatically downloads and manages ASR models from Hugging Face.
/// Models are cached locally to avoid repeated downloads.
@MainActor
final class ASRService: ObservableObject {
    nonisolated static func shouldAssessShortAudioSilence(
        isEnabled: Bool,
        useDictionaryTrainingPath: Bool,
        hasRecognizedStreamingPreview: Bool
    ) -> Bool {
        isEnabled && !useDictionaryTrainingPath && !hasRecognizedStreamingPreview
    }

    nonisolated static func assessShortAudioSilence(
        _ samples: [Float],
        sampleRate: Int = 16_000
    ) -> ShortAudioSilenceAssessment {
        let durationMilliseconds = sampleRate > 0
            ? Int((Double(samples.count) / Double(sampleRate) * 1000).rounded())
            : 0
        let maximumSampleCount = max(sampleRate, 0) * 4
        guard !samples.isEmpty, sampleRate > 0, samples.count <= maximumSampleCount else {
            return ShortAudioSilenceAssessment(
                durationMilliseconds: durationMilliseconds,
                isEligible: false,
                shouldSkipTranscription: false,
                peakAmplitude: 0,
                rmsAmplitude: 0,
                maximumFrameRMS: 0
            )
        }

        let frameSize = max(sampleRate / 50, 1) // 20 ms
        var peak: Float = 0
        var totalSquareSum = 0.0
        var frameSquareSum = 0.0
        var frameSampleCount = 0
        var maximumFrameRMS: Float = 0

        for sample in samples {
            guard sample.isFinite else {
                return ShortAudioSilenceAssessment(
                    durationMilliseconds: durationMilliseconds,
                    isEligible: true,
                    shouldSkipTranscription: false,
                    peakAmplitude: peak,
                    rmsAmplitude: 0,
                    maximumFrameRMS: maximumFrameRMS
                )
            }

            let magnitude = abs(sample)
            peak = max(peak, magnitude)
            let square = Double(sample) * Double(sample)
            totalSquareSum += square
            frameSquareSum += square
            frameSampleCount += 1

            if frameSampleCount == frameSize {
                maximumFrameRMS = max(
                    maximumFrameRMS,
                    Float(sqrt(frameSquareSum / Double(frameSampleCount)))
                )
                frameSquareSum = 0
                frameSampleCount = 0
            }
        }

        if frameSampleCount > 0 {
            maximumFrameRMS = max(
                maximumFrameRMS,
                Float(sqrt(frameSquareSum / Double(frameSampleCount)))
            )
        }
        let rms = Float(sqrt(totalSquareSum / Double(samples.count)))

        // Calibrated conservatively against real FluidVoice captures. Requiring
        // all three conditions keeps quiet speech and short words on the ASR path.
        let shouldSkip = peak < 0.01 && rms < 0.002 && maximumFrameRMS < 0.0045
        return ShortAudioSilenceAssessment(
            durationMilliseconds: durationMilliseconds,
            isEligible: true,
            shouldSkipTranscription: shouldSkip,
            peakAmplitude: peak,
            rmsAmplitude: rms,
            maximumFrameRMS: maximumFrameRMS
        )
    }

    @Published var isRunning: Bool = false
    @Published var finalText: String = ""
    @Published var partialTranscription: String = ""
    @Published var wordBoostStatusText: String = "Word boost: off"
    @Published var micStatus: AVAuthorizationStatus = .notDetermined
    @Published var isAsrReady: Bool = false
    @Published var isDownloadingModel: Bool = false
    @Published var isLoadingModel: Bool = false // True when loading cached model into memory (not downloading)
    @Published private(set) var isCancellingModelPreparation: Bool = false
    @Published var modelsExistOnDisk: Bool = false
    @Published var downloadProgress: Double? = nil
    @Published var modelPreparationPhase: ModelPreparationPhase? = nil
    @Published var downloadingModelId: String? = nil // Tracks which model is currently being downloaded
    @Published private(set) var isCancellingModelDownload: Bool = false
    @Published private(set) var isDictionaryTrainingCaptureActive: Bool = false
    @Published private(set) var isMicrophonePreviewActive: Bool = false
    @Published private(set) var microphonePreviewError: String?
    @Published private(set) var audioCaptureStateSettledTick: UInt64 = 0
    private var microphonePreviewOperationGeneration: UInt64 = 0
    private var isMicrophonePreviewRequested = false
    private(set) var lastDictionaryTrainingResult: ASRTranscriptionResult?
    private(set) var lastStopOutcome: ASRStopOutcome = .empty
    private var lastFinalTranscriptionDurationMs: Int?
    private(set) var dictionaryTrainingAudioGeneration = 0

    @Published private(set) var isStarting: Bool = false // Guard against re-entrant start() calls
    private var audioCaptureStartWaiters: [CheckedContinuation<Void, Never>] = []
    var isRunningOrStarting: Bool {
        self.isRunning || self.isStarting
    }

    private let audioCaptureReadinessGate = AudioCaptureReadinessGate()
    private let firstPCMTimeoutNanoseconds: UInt64 = 2_000_000_000
    private var audioCaptureStartGeneration: UInt64 = 0
    private var audioCaptureAttemptID: UInt64 = 0
    private var isTerminating = false
    private var hasCompletedFirstTranscription: Bool = false // Track if model has warmed up with first transcription
    private var lastBoostHitTerm: String?
    private var hasPendingParakeetVocabularyReload: Bool = false
    private var vocabularyChangeObserver: NSObjectProtocol?
    private var settingsBackupRestoreObserver: NSObjectProtocol?
    private var clamshellStateChangeObserver: NSObjectProtocol?
    private var inputDeviceAvailabilityChangeObserver: NSObjectProtocol?

    // MARK: - Error Handling

    @Published var errorTitle: String = "Error"
    @Published var errorMessage: String = ""
    @Published var showError: Bool = false

    /// Returns a user-friendly status message for model loading state
    var modelStatusMessage: String {
        if self.isAsrReady { return "Model ready" }
        if self.isCancellingModelPreparation { return "Cancelling model preparation..." }
        if self.isCancellingModelDownload { return "Cancelling model download..." }
        if self.downloadingModelId != nil || self.isDownloadingModel || self.isLoadingModel {
            return self.modelPreparationStatusText
        }
        if self.modelsExistOnDisk { return "Model cached, needs loading" }
        return "Model not downloaded"
    }

    var modelPreparationStatusText: String {
        switch self.modelPreparationPhase {
        case .preparingDownload:
            return "Preparing download..."
        case .downloading:
            if let progress = self.downloadProgress {
                return "Downloading \(Int(progress * 100))%"
            }
            return "Downloading model..."
        case .optimizing:
            return "Optimizing model..."
        case .loading:
            return "Loading voice engine..."
        case nil:
            if self.isDownloadingModel { return "Preparing model..." }
            if self.isLoadingModel { return "Loading voice engine..." }
            return "Preparing model..."
        }
    }

    // MARK: - Transcription Provider (Settable)

    /// Cached providers to avoid re-instantiation
    private var fluidAudioProvider: FluidAudioProvider?
    private var parakeetRealtimeProvider: ParakeetRealtimeProvider?
    private var externalCoreMLProvider: ExternalCoreMLTranscriptionProvider?
    private var nemotronProviders: [NemotronProvider.Mode: NemotronProvider] = [:]
    private var whisperProvider: WhisperProvider?
    private var appleSpeechProvider: AppleSpeechProvider?
    /// Stored as Any? because @available cannot be applied to stored properties
    private var _appleSpeechAnalyzerProvider: Any?

    /// Prevent concurrent provider.prepare() calls (download/load) from overlapping.
    /// Subsequent callers await the in-flight task.
    private var ensureReadyTask: Task<Void, Error>?
    private var ensureReadyTaskID: UUID?
    private var ensureReadyProviderKey: String?
    private var ensureReadyOperationID: UUID?
    private var modelDownloadTask: Task<Void, Error>?
    private var modelDownloadOperationID: UUID?
    private var modelDownloadAnalyticsStates: [UUID: ModelDownloadAnalyticsState] = [:]
    private var modelExistenceCheckID: UUID?

    var hasActiveModelPreparation: Bool {
        self.ensureReadyTask != nil
    }

    var hasActiveModelDownload: Bool {
        self.modelDownloadTask != nil
    }

    func cancelModelPreparation() {
        guard let task = self.ensureReadyTask else { return }

        DebugLogger.shared.info("Cancelling ASR model preparation", source: "ASRService")
        self.isCancellingModelPreparation = true
        task.cancel()
    }

    func cancelModelDownload() {
        guard let task = self.modelDownloadTask else { return }
        self.isCancellingModelDownload = true
        task.cancel()
    }

    func shutdownForTermination() async {
        self.isTerminating = true
        let routeRecoveryShutdownStartedAt = Date().timeIntervalSince1970
        await self.cancelAudioRouteRecoveryAndWait()
        self.benchmarkLog(
            "route_recovery_shutdown elapsedMs=\(self.elapsedMilliseconds(since: routeRecoveryShutdownStartedAt))"
        )
        if self.isStarting, self.isRunning == false {
            await self.cancelPendingAudioCaptureStart(reason: "app_termination")
        }
        if self.isRunning {
            await self.stopWithoutTranscription()
        }
        let audioEngineShutdownStartedAt = Date().timeIntervalSince1970
        await self.retireAudioEngineAndWait(reason: "app_termination")
        self.benchmarkLog(
            "audio_engine_shutdown elapsedMs=\(self.elapsedMilliseconds(since: audioEngineShutdownStartedAt))"
        )
        let directCaptureShutdownStartedAt = Date().timeIntervalSince1970
        await self.directAudioLifecycleController.shutdown(reason: "app_termination")
        self.benchmarkLog(
            "direct_capture_shutdown phase=\(self.directAudioLifecycleController.snapshot.phase.rawValue) " +
                "elapsedMs=\(self.elapsedMilliseconds(since: directCaptureShutdownStartedAt))"
        )

        let preparationTask = self.ensureReadyTask
        let downloadTask = self.modelDownloadTask
        preparationTask?.cancel()
        downloadTask?.cancel()
        _ = await preparationTask?.result
        _ = await downloadTask?.result
        await self.providerResetDrain?.task.value
        await self.transcriptionExecutor.cancelAndAwaitPending()

        self.fluidAudioProvider = nil
        self.parakeetRealtimeProvider = nil
        self.externalCoreMLProvider = nil
        self.nemotronProviders.removeAll()
        self.whisperProvider = nil
        self.appleSpeechProvider = nil
        self._appleSpeechAnalyzerProvider = nil
        self.isAsrReady = false
        self.isLoadingModel = false
        self.isDownloadingModel = false
    }

    /// The transcription provider, selected based on the unified SpeechModel setting.
    /// Uses the new SettingsStore.selectedSpeechModel instead of old TranscriptionProviderOption.
    private var transcriptionProvider: TranscriptionProvider {
        let model = SettingsStore.shared.selectedSpeechModel

        switch model {
        case .appleSpeechAnalyzer:
            if #available(macOS 26.0, *) {
                return self.getAppleSpeechAnalyzerProvider()
            } else {
                // Fallback to legacy Apple Speech on older macOS
                return self.getAppleSpeechProvider()
            }
        case .appleSpeech:
            return self.getAppleSpeechProvider()
        case .parakeetTDT, .parakeetTDTv2:
            return self.getFluidAudioProvider()
        case .parakeetRealtime:
            return self.getParakeetRealtimeProvider()
        case .cohereTranscribeSixBit:
            return self.getExternalCoreMLProvider()
        case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
            return self.getNemotronProvider(mode: model.nemotronProviderMode)
        case .qwen3Asr:
            return self.getFluidAudioProvider()
        default:
            return self.getWhisperProvider()
        }
    }

    private func getFluidAudioProvider() -> FluidAudioProvider {
        if let existing = fluidAudioProvider {
            return existing
        }
        let provider = FluidAudioProvider(
            configureWordBoosting: SettingsStore.shared.vocabularyBoostingEnabled
        )
        self.fluidAudioProvider = provider
        DebugLogger.shared.info(
            "ASRService: Created FluidAudio provider [vocabBoosting=\(SettingsStore.shared.vocabularyBoostingEnabled)]",
            source: "ASRService"
        )
        return provider
    }

    private func getParakeetRealtimeProvider() -> ParakeetRealtimeProvider {
        if let existing = parakeetRealtimeProvider {
            return existing
        }
        let provider = ParakeetRealtimeProvider()
        self.parakeetRealtimeProvider = provider
        DebugLogger.shared.info("ASRService: Created Parakeet real-time provider", source: "ASRService")
        return provider
    }

    private func getExternalCoreMLProvider() -> ExternalCoreMLTranscriptionProvider {
        if let existing = externalCoreMLProvider {
            return existing
        }
        let provider = ExternalCoreMLTranscriptionProvider()
        self.externalCoreMLProvider = provider
        DebugLogger.shared.info("ASRService: Created external CoreML provider", source: "ASRService")
        return provider
    }

    private func getNemotronProvider(mode: NemotronProvider.Mode) -> NemotronProvider {
        if let existing = self.nemotronProviders[mode] { return existing }
        let provider = NemotronProvider(mode: mode)
        self.nemotronProviders[mode] = provider
        DebugLogger.shared.info("ASRService: Created \(provider.name) provider", source: "ASRService")
        return provider
    }

    private func getWhisperProvider() -> WhisperProvider {
        if let existing = whisperProvider {
            return existing
        }
        let provider = WhisperProvider()
        self.whisperProvider = provider
        DebugLogger.shared.info("ASRService: Created Whisper provider", source: "ASRService")
        return provider
    }

    private func getAppleSpeechProvider() -> AppleSpeechProvider {
        if let existing = appleSpeechProvider {
            return existing
        }
        let provider = AppleSpeechProvider()
        self.appleSpeechProvider = provider
        DebugLogger.shared.info("ASRService: Created AppleSpeech provider", source: "ASRService")
        return provider
    }

    @available(macOS 26.0, *)
    private func getAppleSpeechAnalyzerProvider() -> AppleSpeechAnalyzerProvider {
        if let existing = _appleSpeechAnalyzerProvider as? AppleSpeechAnalyzerProvider {
            return existing
        }
        let provider = AppleSpeechAnalyzerProvider()
        self._appleSpeechAnalyzerProvider = provider
        DebugLogger.shared.info("ASRService: Created AppleSpeechAnalyzer provider", source: "ASRService")
        return provider
    }

    /// Returns the user-friendly name of the currently selected speech model
    var activeProviderName: String {
        SettingsStore.shared.selectedSpeechModel.displayName
    }

    /// Exposes the transcription provider for file transcription (MeetingTranscriptionService)
    /// This allows file transcription to work with any provider (Parakeet, Whisper, etc.)
    var fileTranscriptionProvider: TranscriptionProvider {
        self.transcriptionProvider
    }

    private func currentTranscriptionAnalyticsDimensions() -> (provider: String, model: String) {
        let selectedModel = SettingsStore.shared.selectedSpeechModel
        return (
            provider: selectedModel.provider.rawValue.lowercased(),
            model: selectedModel.rawValue
        )
    }

    private func elapsedMilliseconds(since start: TimeInterval?) -> Int {
        guard let start else { return -1 }
        return Int(((Date().timeIntervalSince1970 - start) * 1000).rounded())
    }

    private func benchmarkLog(_ message: String) {
        DebugLogger.shared.benchmark("ASR_BENCH", message: "session=\(self.benchmarkSessionID) \(message)", source: "ASRBenchmark")
    }

    /// Gets a provider for a specific model (without changing the active selection)
    /// Used for downloading models without switching the active model.
    private func getProvider(for model: SettingsStore.SpeechModel) -> TranscriptionProvider {
        switch model {
        case .appleSpeechAnalyzer:
            if #available(macOS 26.0, *) {
                return AppleSpeechAnalyzerProvider()
            } else {
                return AppleSpeechProvider()
            }
        case .appleSpeech:
            return AppleSpeechProvider()
        case .parakeetTDT, .parakeetTDTv2:
            // Create a new provider configured for the specific model
            return FluidAudioProvider(modelOverride: model, configureWordBoosting: false)
        case .parakeetRealtime:
            return ParakeetRealtimeProvider()
        case .cohereTranscribeSixBit:
            return ExternalCoreMLTranscriptionProvider(modelOverride: model)
        case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
            return NemotronProvider(mode: model.nemotronProviderMode)
        case .qwen3Asr:
            // Qwen support removed; route legacy requests to Parakeet v3.
            return FluidAudioProvider(modelOverride: .parakeetTDT, configureWordBoosting: false)
        default:
            // Whisper models - create provider with specific model override
            return WhisperProvider(modelOverride: model)
        }
    }

    /// Downloads a specific model without changing the active selection.
    /// - Parameters:
    ///   - model: The model to download
    ///   - progressHandler: Optional callback for download progress (0.0 to 1.0)
    func downloadModel(
        _ model: SettingsStore.SpeechModel,
        source: AnalyticsModelDownloadSource = .settings,
        progressHandler: ((Double) -> Void)?
    ) async throws {
        guard self.modelDownloadTask == nil, self.ensureReadyTask == nil else {
            throw NSError(
                domain: "ASRService",
                code: -2001,
                userInfo: [NSLocalizedDescriptionKey: "Another model operation is already in progress."]
            )
        }

        let operationID = UUID()
        let provider = self.getProvider(for: model)
        self.modelDownloadOperationID = operationID
        self.downloadingModelId = model.id
        self.downloadProgress = nil
        self.modelPreparationPhase = .preparingDownload
        self.isCancellingModelDownload = false

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                DebugLogger.shared.info("Downloading model: \(model.displayName) (without changing active selection)", source: "ASRService")
                try await provider.prepare(progressHandler: { progress in
                    Task { @MainActor in
                        guard
                            self.modelDownloadOperationID == operationID,
                            !self.isCancellingModelDownload
                        else {
                            return
                        }
                        self.applyModelPreparationProgress(
                            progress,
                            updatesActiveModelState: false,
                            externalProgressHandler: progressHandler,
                            analyticsOperationID: operationID,
                            analyticsDescriptor: model.analyticsDescriptor,
                            analyticsSource: source
                        )
                    }
                })
                try Task.checkCancellation()
                DebugLogger.shared.info("Model download completed: \(model.displayName)", source: "ASRService")
            } catch {
                let wasCancelled = Task.isCancelled || Self.isModelPreparationCancellation(error)
                if wasCancelled,
                   provider.shouldClearCacheAfterCancellation,
                   provider.modelsExistOnDisk() == false
                {
                    try? await provider.clearCache()
                }
                if wasCancelled {
                    throw CancellationError()
                }
                throw error
            }
        }
        self.modelDownloadTask = task

        defer {
            if self.modelDownloadOperationID == operationID {
                self.modelDownloadTask = nil
                self.modelDownloadOperationID = nil
                self.downloadingModelId = nil
                self.downloadProgress = nil
                self.modelPreparationPhase = nil
                self.isCancellingModelDownload = false
            }
        }

        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            self.finishModelDownloadAnalytics(operationID: operationID, outcome: .succeeded)
        } catch is CancellationError {
            self.finishModelDownloadAnalytics(operationID: operationID, outcome: .cancelled)
            throw CancellationError()
        } catch {
            self.finishModelDownloadAnalytics(operationID: operationID, outcome: .failed)
            throw error
        }
    }

    /// Call this when the transcription provider setting changes to reset state
    func resetTranscriptionProvider() {
        let newModel = SettingsStore.shared.selectedSpeechModel
        DebugLogger.shared.info("ASRService: Switching to '\(newModel.displayName)', resetting provider state...", source: "ASRService")

        self.isAsrReady = false
        self.modelsExistOnDisk = false
        self.isLoadingModel = false
        self.isDownloadingModel = false
        if !self.hasActiveModelDownload {
            self.downloadProgress = nil
            self.modelPreparationPhase = nil
        }
        self.hasCompletedFirstTranscription = false // Reset warm-up state when switching models
        let retiringTask = self.ensureReadyTask
        if let task = retiringTask {
            self.isCancellingModelPreparation = true
            task.cancel()
        }
        let resetDrainID = UUID()
        let executor = self.transcriptionExecutor
        let resetDrainTask = Task { await executor.cancelAndAwaitPending() }
        self.providerResetDrain = (resetDrainID, resetDrainTask)
        // Keep the task handle until its provider has stopped and cancellation cleanup has
        // completed. The next ensureAsrReady call waits for it before touching the same cache.
        self.ensureReadyProviderKey = nil
        self.ensureReadyOperationID = nil
        self.lastBoostHitTerm = nil
        self.wordBoostStatusText = "Word boost: off"

        // Reset cached providers to force re-initialization with new settings
        self.fluidAudioProvider = nil
        self.parakeetRealtimeProvider = nil
        self.externalCoreMLProvider = nil
        self.whisperProvider = nil
        self.appleSpeechProvider = nil
        self._appleSpeechAnalyzerProvider = nil

        // CRITICAL FIX: Check if the NEW model's files exist on disk
        // This prevents UI from showing "Download" when model is already downloaded
        // Use Task for async check to support providers like AppleSpeechAnalyzerProvider
        Task { [weak self] in
            guard let self = self else { return }
            _ = await retiringTask?.result
            guard SettingsStore.shared.selectedSpeechModel == newModel else { return }
            await self.checkIfModelsExistAsync()
            await MainActor.run {
                self.refreshWordBoostStatus()
            }
            DebugLogger.shared.info("ASRService: Provider reset complete, will initialize '\(newModel.displayName)' on next use", source: "ASRService")
        }
    }

    // CRITICAL FIX (launch-time crash mitigation):
    // Combine's default ObservableObject.objectWillChange implementation uses Swift reflection to walk *stored*
    // properties. If we store an AVFoundation ObjC class type (like AVAudioEngine) directly, the reflection
    // path can trigger Objective-C class lookup for "AVAudioEngine" during SwiftUI/AttributeGraph's early
    // metadata processing window. On some systems this manifests as an EXC_BAD_ACCESS at 0x0 inside
    // swift_getTypeByMangledName / AttributeGraph (very similar to the crash reports we've been seeing).
    //
    // To reduce risk:
    // - We do NOT store AVAudioEngine as a stored property.
    // - We store it as AnyObject? and expose it through a computed property.
    // This keeps initialization lazy *and* keeps AVAudioEngine out of the reflected stored layout.
    private var engineStorage: AnyObject?
    private var engine: AVAudioEngine {
        if let existing = engineStorage as? AVAudioEngine {
            return existing
        }
        let created = AVAudioEngine()
        self.engineStorage = created
        return created
    }

    private var hasWarmAudioEngine: Bool {
        self.engineStorage is AVAudioEngine
    }

    private enum AudioCaptureBackend {
        case none
        case directCoreAudio
        case audioEngine
    }

    private struct AudioRouteRecoveryRequest {
        let generation: UInt64
        let reason: String
        let requiresIdlePrewarm: Bool
        let reconcilesInputSelection: Bool
    }

    private lazy var directAudioLifecycleController: DirectCoreAudioLifecycleController = {
        let pipeline = self.audioCapturePipeline
        return DirectCoreAudioLifecycleController(
            packetHandler: { samples, frameCount, sampleRate, inputHostTime, inputSampleTime in
                pipeline.handle(
                    samples: samples,
                    frameCount: frameCount,
                    sampleRate: sampleRate,
                    inputHostTime: inputHostTime,
                    inputSampleTime: inputSampleTime
                )
            },
            onFormatInvalidated: { [weak self] invalidation in
                Task { @MainActor [weak self] in
                    await self?.handleDirectCaptureFormatInvalidation(invalidation)
                }
            }
        )
    }()

    private var activeAudioCaptureBackend: AudioCaptureBackend = .none
    private var audioStartAttemptInputUID: String?
    private var audioStartAttemptInputName: String?
    private var audioStartAttemptIsBluetooth = false
    private var audioStartAttemptIsInternalMicrophone = false
    private var deferredBluetoothStartupRouteRecovery =
        AudioCaptureIdlePolicy.DeferredBluetoothRouteRecovery()
    private var silentPCMRecoveryWatchdog = AudioCaptureIdlePolicy.SilentPCMRecoveryWatchdog()

    private var hasPreparedAudioCapture: Bool {
        self.directAudioLifecycleController.snapshot.isPrepared || self.hasWarmAudioEngine
    }

    /// Detaches the current engine from main-actor state and returns a token that
    /// owns its final strong reference. The token must be handed to
    /// `audioEngineRetirementDrain`; dropping it directly would put deallocation
    /// back on the caller's actor.
    private func detachAudioEngineForRetirement(reason: String) -> AudioEngineRetirementToken? {
        self.audioEngineStandbyTask?.cancel()
        self.audioEngineStandbyTask = nil

        self.activeAudioCaptureBackend = .none

        if self.isEngineTapInstalled {
            if let engine = self.engineStorage as? AVAudioEngine {
                engine.inputNode.removeTap(onBus: 0)
            }
            self.isEngineTapInstalled = false
        }
        if let engine = self.engineStorage as? AVAudioEngine, engine.isRunning {
            engine.stop()
        }
        self.audioCapturePipeline.clearPreroll()

        let retirementToken = self.engineStorage.map(AudioEngineRetirementToken.init)
        self.engineStorage = nil
        DebugLogger.shared.debug("Audio engine retired (\(reason))", source: "ASRService")
        return retirementToken
    }

    /// Fire-and-forget retirement for paths that do not construct a replacement.
    /// All releases still share the serial drain, and capture startup waits on a
    /// drain barrier before it may create another engine.
    private func retireAudioEngine(reason: String) {
        guard let token = self.detachAudioEngineForRetirement(reason: reason) else { return }
        self.audioEngineRetirementDrain.schedule(token)
    }

    /// Route recovery and engine retry paths use this completion barrier so the
    /// old AVAudioEngine and its AVAudioIOUnit are fully deallocated before a
    /// replacement can touch Core Audio.
    private func retireAudioEngineAndWait(reason: String) async {
        if let token = self.detachAudioEngineForRetirement(reason: reason) {
            await self.audioEngineRetirementDrain.releaseAndWait(token)
        } else {
            await self.audioEngineRetirementDrain.waitForScheduledReleases()
        }
    }

    private func scheduleAudioEngineStandbyRetirement() {
        self.audioEngineStandbyTask?.cancel()
        let delay = self.audioEngineStandbyNanoseconds
        self.audioEngineStandbyTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            await self?.retireWarmAudioEngineIfIdle()
        }
    }

    private func retireWarmAudioEngineIfIdle() async {
        guard self.isRunning == false, self.isStarting == false else { return }
        await self.coolDownAudioEngineStandby(reason: "standby_timeout")
    }

    private func coolDownAudioEngineStandby(reason: String) async {
        self.audioEngineStandbyTask?.cancel()
        self.audioEngineStandbyTask = nil

        await self.directAudioLifecycleController.invalidate(reason: reason)
        await self.retireAudioEngineAndWait(reason: reason)
        self.benchmarkLog("audio_engine_standby retired=true reason=\(reason)")
        DebugLogger.shared.debug("Audio engine fully retired from standby (\(reason))", source: "ASRService")
    }

    private func prewarmConfiguredAudioCaptureIfPossible(
        reason: String,
        allowDuringRouteRecovery: Bool = false
    ) async {
        guard self.isTerminating == false else {
            DebugLogger.shared.debug("Audio capture prewarm skipped - app is terminating", source: "ASRService")
            return
        }
        guard self.micStatus == .authorized else {
            DebugLogger.shared.debug("Audio engine prewarm skipped - mic not authorized", source: "ASRService")
            return
        }
        guard self.isRunning == false,
              self.isStarting == false || allowDuringRouteRecovery
        else {
            DebugLogger.shared.debug("Audio engine prewarm skipped - capture active", source: "ASRService")
            return
        }
        guard allowDuringRouteRecovery || self.isRecoveringAudioRoute == false else {
            DebugLogger.shared.debug("Audio engine prewarm skipped - route recovery active", source: "ASRService")
            return
        }
        guard AudioCaptureIdlePolicy.shouldPrewarmCapture(
            experimentalDirectAudioCaptureEnabled: SettingsStore.shared.experimentalDirectAudioCaptureEnabled
        ) else {
            // Constructing AVAudioEngine while idle instantiates its input and
            // output audio units. Bluetooth headsets can then remain in the
            // low-bandwidth HFP route even though no recording is active.
            if self.hasWarmAudioEngine {
                await self.retireAudioEngineAndWait(reason: "legacy_idle_prewarm_suppressed")
            }
            DebugLogger.shared.debug(
                "Legacy AVAudioEngine idle prewarm skipped to preserve playback quality",
                source: "ASRService"
            )
            return
        }
        guard self.hasPreparedAudioCapture == false else {
            DebugLogger.shared.debug("Audio capture prewarm skipped - backend already prepared", source: "ASRService")
            return
        }

        // A legacy stop releases AVAudioEngine on the serial retirement drain.
        // Do not register a direct Core Audio backend until that teardown has
        // completed, then recheck state because this await yields the main actor.
        await self.audioEngineRetirementDrain.waitForScheduledReleases()
        guard self.isTerminating == false,
              self.isRunning == false,
              self.isStarting == false || allowDuringRouteRecovery,
              self.hasPreparedAudioCapture == false
        else {
            DebugLogger.shared.debug(
                "Audio capture prewarm skipped - state changed while waiting for engine retirement",
                source: "ASRService"
            )
            return
        }

        let startedAt = Date().timeIntervalSince1970
        do {
            _ = try await self.prepareDirectAudioInput(reason: reason)
            self.benchmarkLog("direct_audio_prewarm reason=\(reason) elapsedMs=\(self.elapsedMilliseconds(since: startedAt))")
        } catch {
            DebugLogger.shared.warning(
                "Direct Core Audio prewarm failed: \(error.localizedDescription)",
                source: "ASRService"
            )
        }
    }

    private func resolvedInputDeviceForCapture(
        availableInputs: [AudioDevice.Device] = AudioDevice.listInputDevices(),
        defaultInputUID: String? = AudioDevice.getDefaultInputDevice()?.uid,
        excluding excludedUIDs: Set<String> = []
    ) -> AudioDevice.Device? {
        return AppServices.shared.microphonePreferenceCoordinator.inputDeviceForCapture(
            availableInputs: availableInputs,
            defaultInputUID: defaultInputUID,
            excluding: excludedUIDs
        )
    }

    private func directCoreAudioDeviceSelection(
        excluding excludedUIDs: Set<String> = []
    ) -> DirectCoreAudioDeviceSelection? {
        if let inputUID = self.resolvedInputDeviceForCapture(excluding: excludedUIDs)?.uid {
            return .preferredUID(inputUID)
        }
        return nil
    }

    /// Prepares the direct device callback without starting hardware IO. This
    /// keeps the default idle state privacy-friendly while removing device and
    /// ring allocation from the hotkey path.
    private func prepareDirectAudioInput(
        reason: String
    ) async throws -> DirectCoreAudioLifecycleController.Snapshot {
        guard self.micStatus == .authorized else {
            throw NSError(
                domain: "ASRService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Microphone access is not authorized."]
            )
        }
        guard let selection = self.directCoreAudioDeviceSelection() else {
            throw NSError(
                domain: "ASRService",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "No usable microphone is available."]
            )
        }
        let device = try await self.directAudioLifecycleController.resolveDevice(
            selection: selection,
            reason: "prepare:\(reason)"
        )
        let snapshot = try await self.directAudioLifecycleController.prepare(
            deviceID: device.id,
            deviceName: device.name,
            reason: reason
        )
        DebugLogger.shared.info(
            "Prepared direct Core Audio input '\(device.name)' " +
                "(\(Int((snapshot.sampleRate ?? 0).rounded()))Hz, " +
                "\(snapshot.bufferFrameSize ?? 0) frames, generation=\(snapshot.generation), " +
                "reason=\(reason))",
            source: "ASRService"
        )
        return snapshot
    }

    private func startConfiguredAudioCapture(
        excluding excludedInputUIDs: Set<String> = [],
        forcingInputUID: String? = nil
    ) async throws {
        let previousAttemptIdentity = self.audioStartAttemptInputUID.map {
            AudioCaptureIdlePolicy.CaptureAttemptIdentity(
                uid: $0,
                name: self.audioStartAttemptInputName,
                isBluetooth: self.audioStartAttemptIsBluetooth,
                isInternalMicrophone: self.audioStartAttemptIsInternalMicrophone
            )
        }
        self.audioStartAttemptInputUID = nil
        self.audioStartAttemptInputName = nil
        self.audioStartAttemptIsBluetooth = false
        self.audioStartAttemptIsInternalMicrophone = false
        if SettingsStore.shared.experimentalDirectAudioCaptureEnabled {
            // A non-route path may have scheduled a fire-and-forget retirement.
            // Do not let direct capture startup overlap a queued AVAudioEngine
            // release.
            await self.audioEngineRetirementDrain.waitForScheduledReleases()
            do {
                let deviceSnapshot = await Task.detached(priority: .userInitiated) {
                    let allDevices = AudioDevice.listAllDevices()
                    return (
                        allDevices: allDevices,
                        defaultInputUID: AudioDevice.getDefaultInputDevice(from: allDevices)?.uid
                    )
                }.value
                let allDevices = deviceSnapshot.allDevices
                let availableInputs = allDevices.filter(\.hasInput)
                let selectedInput: AudioDevice.Device?
                if let forcingInputUID {
                    selectedInput = availableInputs.first { $0.uid == forcingInputUID }
                } else {
                    let resolvedInput = self.resolvedInputDeviceForCapture(
                        availableInputs: availableInputs,
                        defaultInputUID: deviceSnapshot.defaultInputUID,
                        excluding: excludedInputUIDs
                    )
                    selectedInput = AudioCaptureIdlePolicy.bluetoothInputAwaitingAvailability(
                        priorityInputUIDs: SettingsStore.shared.microphonePriority.map(\.uid),
                        preferredInputUID: SettingsStore.shared.preferredInputDeviceUID,
                        resolvedInputUID: resolvedInput?.uid,
                        allDevices: allDevices,
                        excluding: excludedInputUIDs
                    ) ?? resolvedInput
                }
                guard let attemptIdentity = AudioCaptureIdlePolicy.CaptureAttemptIdentity.resolve(
                    selectedInput: selectedInput,
                    forcingInputUID: forcingInputUID,
                    previous: previousAttemptIdentity
                ) else {
                    throw NSError(
                        domain: "ASRService",
                        code: -4,
                        userInfo: [NSLocalizedDescriptionKey: "No remaining microphone is available."]
                    )
                }
                let selection = DirectCoreAudioDeviceSelection.preferredUID(attemptIdentity.uid)
                // Preserve the selected endpoint's identity before the async UID
                // resolution, where Bluetooth topology churn can make it vanish.
                self.audioStartAttemptInputUID = attemptIdentity.uid
                self.audioStartAttemptInputName = attemptIdentity.name
                self.audioStartAttemptIsBluetooth = attemptIdentity.isBluetooth
                self.audioStartAttemptIsInternalMicrophone = attemptIdentity.isInternalMicrophone
                let device = try await self.directAudioLifecycleController.resolveDevice(
                    selection: selection,
                    reason: "recording_start"
                )
                self.audioStartAttemptInputUID = device.uid
                self.audioStartAttemptInputName = device.name
                self.audioStartAttemptIsBluetooth = device.isBluetooth
                self.audioStartAttemptIsInternalMicrophone = device.isUnavailableWhenClamshellClosed
                AppServices.shared.microphonePreferenceCoordinator.reportResolvedSelection(
                    uid: device.uid,
                    name: device.name
                )
                let snapshot = try await self.directAudioLifecycleController.start(
                    deviceID: device.id,
                    deviceName: device.name,
                    reason: "recording_start"
                )
                try Task.checkCancellation()
                self.activeAudioCaptureBackend = .directCoreAudio
                let callbackDurationMilliseconds =
                    Double(snapshot.bufferFrameSize ?? 0) /
                    max(snapshot.sampleRate ?? 0, 1) * 1000
                let callbackMs = Int(callbackDurationMilliseconds.rounded())
                self.benchmarkLog(
                    "audio_backend kind=direct_core_audio device=\(snapshot.deviceID ?? 0) " +
                        "generation=\(snapshot.generation) frames=\(snapshot.bufferFrameSize ?? 0) " +
                        "sampleRate=\(Int((snapshot.sampleRate ?? 0).rounded())) callbackMs=\(callbackMs)"
                )
                return
            } catch {
                await self.directAudioLifecycleController.invalidate(reason: "recording_start_failed")
                DebugLogger.shared.error(
                    "Direct Core Audio capture failed: \(error.localizedDescription)",
                    source: "ASRService"
                )
                throw error
            }
        }

        await self.directAudioLifecycleController.invalidate(reason: "av_audio_engine_selected")

        try await self.startAVAudioEngineCapture()
    }

    private func startAVAudioEngineCapture() async throws {
        await self.audioEngineRetirementDrain.waitForScheduledReleases()
        self.benchmarkLog("audio_backend kind=av_audio_engine reason=faster_recording_start_disabled")
        try self.configureSession()
        try await self.startEngine()
        try self.setupEngineTap()
        self.activeAudioCaptureBackend = .audioEngine
    }

    private func stopActiveAudioCapture(
        retainDirectPreparedCapture: Bool = true,
        reason: String
    ) async {
        switch self.activeAudioCaptureBackend {
        case .directCoreAudio:
            let report = await self.directAudioLifecycleController.stop(
                retainPrepared: retainDirectPreparedCapture,
                reason: reason
            )
            if report.status != noErr {
                DebugLogger.shared.warning(
                    "Direct Core Audio stop returned OSStatus \(report.status)",
                    source: "ASRService"
                )
            }
            if report.droppedPackets > 0 {
                DebugLogger.shared.warning(
                    "Direct Core Audio dropped \(report.droppedPackets) packet(s)",
                    source: "ASRService"
                )
            }
        case .audioEngine:
            self.removeEngineTap()
            if let engine = self.engineStorage as? AVAudioEngine, engine.isRunning {
                engine.stop()
            }
        case .none:
            break
        }
        self.activeAudioCaptureBackend = .none
    }

    private var inputFormat: AVAudioFormat?
    private var micPermissionGranted = false
    private var isRequestingMicrophoneAccess = false

    // Internal access for MeetingTranscriptionService to share models
    // Note: Only available when using FluidAudioProvider (Apple Silicon)
    #if arch(arm64)
    var asrManager: AsrManager? {
        (self.transcriptionProvider as? FluidAudioProvider)?.underlyingManager
    }
    #else
    var asrManager: Any? {
        nil
    }
    #endif

    // Thread-safe buffer to prevent "Array mutation while enumerating" and memory corruption crashes
    // during long sessions where reallocation occurs frequently.
    private let audioBuffer = ThreadSafeAudioBuffer()
    private var lastCompletedAudioSnapshot: DictationAudioSnapshot?

    // Streaming transcription state (no VAD)
    private var streamingTask: Task<Void, Never>?
    private var lastProcessedSampleCount: Int = 0
    private var isProcessingChunk: Bool = false
    private var skipNextChunk: Bool = false
    private var previousFullTranscription: String = ""
    private var benchmarkSessionID: Int = 0
    private var benchmarkRecordingStartedAt: TimeInterval?
    private var benchmarkStreamingChunkIndex: Int = 0
    private var benchmarkCompletedStreamingChunks: Int = 0
    private var benchmarkLastChunkSampleCount: Int = 0
    private let transcriptionExecutor = TranscriptionExecutor() // Serializes all CoreML access
    private var providerResetDrain: (id: UUID, task: Task<Void, Never>)?
    private var engineConfigurationChangeObserver: NSObjectProtocol?
    private let audioEngineRetirementDrain = AudioEngineRetirementDrain()
    private var audioRouteRecoveryTask: Task<Void, Never>?
    private let audioRouteRecoveryDelayNanoseconds: UInt64 = 300_000_000
    private var audioRouteRecoveryGeneration: UInt64 = 0
    private var pendingAudioRouteRecovery: AudioRouteRecoveryRequest?
    private var audioEngineStandbyTask: Task<Void, Never>?
    private let audioEngineStandbyNanoseconds: UInt64 = 8_000_000_000
    private var isEngineTapInstalled = false
    private var isRecoveringAudioRoute = false

    /// Tracks whether we paused system media for this recording session.
    /// Used to resume playback only if we were the ones who paused it.
    private var didPauseMediaForThisSession: Bool = false

    private var audioLevelSubject = PassthroughSubject<CGFloat, Never>()
    var audioLevelPublisher: AnyPublisher<CGFloat, Never> {
        self.audioLevelSubject.eraseToAnyPublisher()
    }

    private var lastAudioLevelSentAt: TimeInterval = 0

    func consumeLastCompletedAudioSnapshot() -> DictationAudioSnapshot? {
        let snapshot = self.lastCompletedAudioSnapshot
        self.lastCompletedAudioSnapshot = nil
        return snapshot
    }

    func consumeLastFinalTranscriptionDurationMs() -> Int? {
        let duration = self.lastFinalTranscriptionDurationMs
        self.lastFinalTranscriptionDurationMs = nil
        return duration
    }

    func dictionaryTrainingAudioChunk(at offset: Int, count: Int) -> [Float] {
        self.audioBuffer.getRange(startingAt: offset, count: count)
    }

    private var streamingChunkDurationSeconds: Double {
        let selectedModel = SettingsStore.shared.selectedSpeechModel
        return selectedModel.streamingPreviewIntervalSeconds
    }

    private var minimumStreamingPreviewSamples: Int {
        Int(SettingsStore.shared.selectedSpeechModel.minimumStreamingPreviewSeconds * 16_000)
    }

    /// Handles AVAudioEngine tap processing off the @MainActor to avoid touching main-actor state
    /// from CoreAudio's realtime callback thread.
    private lazy var audioCapturePipeline: AudioCapturePipeline = {
        let readinessGate = self.audioCaptureReadinessGate
        return AudioCapturePipeline(
            audioBuffer: self.audioBuffer,
            onFirstAudio: { sessionID, attemptID, sampleCount, frameLength, sampleRate, acquisitionMs, elapsedMs in
                Task {
                    readinessGate.signalFirstPCM(
                        sessionID: sessionID,
                        attemptID: attemptID
                    )
                }
                DispatchQueue.main.async {
                    let bufferMs = Int((Double(frameLength) / sampleRate * 1000).rounded())
                    DebugLogger.shared.benchmark(
                        "ASR_BENCH",
                        message: "session=\(sessionID) attempt=\(attemptID) " +
                            "first_audio sampleCount=\(sampleCount) frameLength=\(frameLength) " +
                            "sampleRate=\(Int(sampleRate.rounded())) bufferMs=\(bufferMs) " +
                            "acquisitionMs=\(acquisitionMs) elapsedMs=\(elapsedMs)",
                        source: "ASRBenchmark"
                    )
                }
            },
            onLevel: { [weak self] level in
                // Keep Combine sends on the main queue.
                DispatchQueue.main.async { [weak self] in
                    self?.audioLevelSubject.send(level)
                }
            },
            onCaptureHealth: { [weak self] sessionID, attemptID, audioMs, sampleCount, rms, peak in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard sessionID == self.benchmarkSessionID, self.isRunning else { return }
                    let silent = rms < 0.002 && peak < 0.01
                    self.benchmarkLog(
                        "capture_health attempt=\(attemptID) audioMs=\(audioMs) " +
                            "samples=\(sampleCount) rms=\(String(format: "%.6f", rms)) " +
                            "peak=\(String(format: "%.6f", peak)) silent=\(silent) " +
                            "inputUID=\(self.audioStartAttemptInputUID ?? "unknown")"
                    )
                    if self.silentPCMRecoveryWatchdog.shouldRecover(
                        isInternalMicrophone: self.audioStartAttemptIsInternalMicrophone,
                        isDirectCapture: self.activeAudioCaptureBackend == .directCoreAudio,
                        rms: rms,
                        peak: peak
                    ) {
                        self.benchmarkLog(
                            "capture_health_recovery_triggered attempt=\(attemptID) " +
                                "audioMs=\(audioMs) rms=\(String(format: "%.6f", rms)) " +
                                "peak=\(String(format: "%.6f", peak))"
                        )
                        self.scheduleAudioRouteRecovery(reason: "sustained silent PCM")
                    }
                }
            }
        )
    }()

    init() {
        // CRITICAL FIX: Do NOT call any framework-triggering APIs here!
        // This includes:
        // - AVCaptureDevice.authorizationStatus (triggers AVFCapture/CoreAudio)
        // - checkIfModelsExist() (accesses transcriptionProvider, can trigger FluidAudio/CoreML)
        //
        // All such calls are deferred to initialize() which runs 1.5 seconds after
        // SwiftUI's view graph is stable, preventing race conditions with AttributeGraph.
        //
        // Default values are set in the property declarations:
        // - micStatus = .notDetermined
        // - micPermissionGranted = false
        // - modelsExistOnDisk = false
        self.vocabularyChangeObserver = NotificationCenter.default.addObserver(
            forName: .parakeetVocabularyDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleParakeetVocabularyDidChange()
            }
        }
        self.settingsBackupRestoreObserver = NotificationCenter.default.addObserver(
            forName: .settingsBackupDidRestore,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleAudioRouteRecovery(
                    reason: "settings backup restored",
                    requiresIdlePrewarm: true,
                    reconcilesInputSelection: true
                )
            }
        }
        self.clamshellStateChangeObserver = NotificationCenter.default.addObserver(
            forName: .clamshellStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let isClosed = notification.userInfo?["isClosed"] as? Bool ?? ClamshellState.isClosed
            Task { @MainActor [weak self] in
                self?.handleClamshellStateChanged(isClosed: isClosed)
            }
        }
        self.inputDeviceAvailabilityChangeObserver = NotificationCenter.default.addObserver(
            forName: .inputDeviceAvailabilityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let deviceID = notification.userInfo?["deviceID"] as? AudioObjectID
            Task { @MainActor [weak self] in
                self?.handleInputDeviceAvailabilityChanged(deviceID: deviceID)
            }
        }
    }

    deinit {
        if let observer = self.vocabularyChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = self.engineConfigurationChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = self.settingsBackupRestoreObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = self.clamshellStateChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = self.inputDeviceAvailabilityChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func handleClamshellStateChanged(isClosed: Bool) {
        DebugLogger.shared.info(
            "Clamshell \(isClosed ? "closed" : "opened"); refreshing microphone availability",
            source: "ASRService"
        )
        self.scheduleAudioRouteRecovery(
            reason: isClosed ? "clamshell closed" : "clamshell opened",
            requiresIdlePrewarm: true,
            reconcilesInputSelection: true
        )
    }

    private func handleInputDeviceAvailabilityChanged(deviceID: AudioObjectID?) {
        let resolvedInput = AppServices.shared.microphonePreferenceCoordinator.inputDeviceForCapture()
        let preparedDeviceID = self.directAudioLifecycleController.snapshot.deviceID
        let confirmedUID = AppServices.shared.microphonePreferenceCoordinator.confirmedActiveInputUID
        let activeSelectionChanged = self.isRunning && resolvedInput?.uid != confirmedUID
        let preparedSelectionChanged = self.hasPreparedAudioCapture && resolvedInput?.id != preparedDeviceID
        guard activeSelectionChanged || preparedSelectionChanged else { return }

        self.scheduleAudioRouteRecovery(
            reason: "input availability changed:\(deviceID ?? 0)",
            requiresIdlePrewarm: true,
            reconcilesInputSelection: true
        )
    }

    @MainActor
    private func handleParakeetVocabularyDidChange() {
        let model = SettingsStore.shared.selectedSpeechModel
        guard model.supportsCustomVocabulary else { return }
        guard self.isRunning == false else {
            self.hasPendingParakeetVocabularyReload = true
            DebugLogger.shared.info(
                "ASRService: Vocabulary changed while recording; queued reload for when recording stops.",
                source: "ASRService"
            )
            return
        }
        self.hasPendingParakeetVocabularyReload = false
        self.resetTranscriptionProvider()
    }

    @MainActor
    private func applyPendingParakeetVocabularyReloadIfNeeded() {
        guard self.hasPendingParakeetVocabularyReload else { return }

        self.hasPendingParakeetVocabularyReload = false
        let model = SettingsStore.shared.selectedSpeechModel
        guard model.supportsCustomVocabulary else { return }

        DebugLogger.shared.info(
            "ASRService: Applying queued vocabulary reload after recording stopped.",
            source: "ASRService"
        )
        self.resetTranscriptionProvider()
    }

    private func refreshWordBoostStatus() {
        let model = SettingsStore.shared.selectedSpeechModel
        guard model.supportsCustomVocabulary,
              let provider = self.fluidAudioProvider,
              provider.isReady
        else {
            self.wordBoostStatusText = "Word boost: off"
            return
        }

        if provider.isWordBoostingActive {
            let count = provider.boostedVocabularyTermsCount
            if let lastHit = self.lastBoostHitTerm, !lastHit.isEmpty {
                self.wordBoostStatusText = "Word boost: ON (\(count) terms) • last hit: \(lastHit)"
            } else {
                self.wordBoostStatusText = "Word boost: ON (\(count) terms) • no hit yet"
            }
        } else {
            self.wordBoostStatusText = "Word boost: ON (0 terms loaded)"
        }
    }

    private func recordWordBoostHitIfAny(transcribedText: String) {
        let model = SettingsStore.shared.selectedSpeechModel
        guard model.supportsCustomVocabulary,
              let provider = self.fluidAudioProvider,
              provider.isWordBoostingActive
        else { return }

        let hits = provider.detectBoostedTerms(in: transcribedText, limit: 1)
        guard let hit = hits.first else { return }
        if hit != self.lastBoostHitTerm {
            self.lastBoostHitTerm = hit
            DebugLogger.shared.info("BOOST_HIT: '\(hit)'", source: "ASRService")
        }
        self.refreshWordBoostStatus()
    }

    /// Call this AFTER the app has finished launching to complete ASR initialization.
    /// This must be called from onAppear or later, never during init.
    func initialize() async {
        await AudioStartupGate.shared.scheduleOpenAfterInitialUISettled()
        await AudioStartupGate.shared.waitUntilOpen()
        guard self.isTerminating == false else { return }

        // Check microphone permission (deferred from init to avoid AVFCapture race condition)
        self.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        self.micPermissionGranted = (self.micStatus == .authorized)

        let initialInputSnapshot = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let devices = AudioDevice.listInputDevicesRefreshingLiveness()
                let defaultInputUID = AudioDevice.getDefaultInputDevice()?.uid
                continuation.resume(returning: (devices, defaultInputUID))
            }
        }
        guard self.isTerminating == false else { return }

        let microphonePreferenceCoordinator = AppServices.shared.microphonePreferenceCoordinator
        microphonePreferenceCoordinator.reconcileMicrophoneSelection(
            availableInputs: initialInputSnapshot.0,
            defaultInputUID: initialInputSnapshot.1
        )

        self.registerDefaultDeviceChangeListener()
        self.registerEngineConfigurationChangeObserver()
        self.registerDeviceListChangeListener()

        // Initialize device list cache
        self.cacheCurrentDeviceList(initialInputSnapshot.0)
        if microphonePreferenceCoordinator.needsMicrophonePriorityMigration {
            self.scheduleAudioRouteRecovery(
                reason: "app microphone migration pending",
                requiresIdlePrewarm: true,
                reconcilesInputSelection: true
            )
        }

        // Register the input callback and allocate its fixed ring now. This
        // does not start the device or show the microphone privacy indicator.
        await self.prewarmConfiguredAudioCaptureIfPossible(reason: "startup")

        // Check if models exist on disk and auto-load if present
        // This is done in a Task to support async model detection (e.g., AppleSpeechAnalyzerProvider)
        Task { [weak self] in
            guard let self = self else { return }

            // Use async check to accurately detect models (especially for Apple Speech Analyzer)
            await self.checkIfModelsExistAsync()

            // Auto-load models if they exist on disk to avoid "Downloaded but not loaded" state
            if self.modelsExistOnDisk {
                DebugLogger.shared.info("Models found on disk, auto-loading...", source: "ASRService")
                do {
                    try await self.ensureAsrReady()
                    DebugLogger.shared.info("Models auto-loaded successfully on startup", source: "ASRService")
                    await self.prewarmConfiguredAudioCaptureIfPossible(reason: "startup")
                } catch {
                    DebugLogger.shared.error("Failed to auto-load models on startup: \(error)", source: "ASRService")
                }
            }
        }
    }

    /// Check if models exist on disk without loading them (synchronous).
    ///
    /// **Note**: For `AppleSpeechAnalyzerProvider`, this returns a cached value that may be stale.
    /// Use `checkIfModelsExistAsync()` for an up-to-date result.
    func checkIfModelsExist() {
        self.modelExistenceCheckID = UUID()
        self.modelsExistOnDisk = self.transcriptionProvider.modelsExistOnDisk()
        DebugLogger.shared.debug("Models exist on disk: \(self.modelsExistOnDisk)", source: "ASRService")
    }

    /// Check if models exist on disk without loading them (async).
    ///
    /// This method performs an accurate async check for providers that require it
    /// (e.g., `AppleSpeechAnalyzerProvider` uses `SpeechTranscriber.installedLocales`).
    func checkIfModelsExistAsync() async {
        let model = SettingsStore.shared.selectedSpeechModel
        let checkID = UUID()
        self.modelExistenceCheckID = checkID
        let exists: Bool

        // For Apple Speech Analyzer, use the async refresh method
        if model == .appleSpeechAnalyzer {
            if #available(macOS 26.0, *) {
                let provider = self.getAppleSpeechAnalyzerProvider()
                exists = await provider.refreshModelsExistOnDiskAsync()
            } else {
                exists = self.getAppleSpeechProvider().modelsExistOnDisk()
            }
        } else {
            exists = model.isInstalled
        }

        guard
            self.modelExistenceCheckID == checkID,
            SettingsStore.shared.selectedSpeechModel == model
        else {
            return
        }
        self.modelsExistOnDisk = exists
        DebugLogger.shared.debug("Models exist on disk: \(self.modelsExistOnDisk)", source: "ASRService")
    }

    func requestMicAccess() {
        guard self.isRequestingMicrophoneAccess == false else { return }
        self.isRequestingMicrophoneAccess = true
        Task { @MainActor [weak self] in
            await AudioStartupGate.shared.scheduleOpenAfterInitialUISettled()
            await AudioStartupGate.shared.waitUntilOpen()
            guard let self else { return }
            guard self.isTerminating == false else {
                self.isRequestingMicrophoneAccess = false
                return
            }

            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self else { return }
                Task { @MainActor in
                    self.isRequestingMicrophoneAccess = false
                    self.micPermissionGranted = granted
                    self.micStatus = granted ? .authorized : .denied
                    if granted {
                        await self.prewarmConfiguredAudioCaptureIfPossible(reason: "permission_granted")
                    }
                }
            }
        }
    }

    func startMicrophonePreview() async {
        guard self.micStatus == .authorized,
              self.isRunning == false,
              self.isStarting == false,
              self.isTerminating == false
        else { return }

        self.microphonePreviewOperationGeneration &+= 1
        let operationGeneration = self.microphonePreviewOperationGeneration
        self.isMicrophonePreviewRequested = true

        if self.isMicrophonePreviewActive || self.audioCapturePipeline.isLevelMonitoringEnabled {
            self.audioCapturePipeline.setLevelMonitoringEnabled(false)
            _ = await self.directAudioLifecycleController.stop(
                retainPrepared: false,
                reason: "onboarding_microphone_preview_restart"
            )
            guard operationGeneration == self.microphonePreviewOperationGeneration,
                  self.isMicrophonePreviewRequested,
                  self.isRunning == false,
                  self.isStarting == false,
                  self.isTerminating == false,
                  Task.isCancelled == false
            else {
                self.abandonMicrophonePreviewRequestIfOwned(operationGeneration)
                return
            }
            self.activeAudioCaptureBackend = .none
            self.isMicrophonePreviewActive = false
            self.audioLevelSubject.send(0)
        }

        self.audioEngineStandbyTask?.cancel()
        self.audioEngineStandbyTask = nil
        await self.audioEngineRetirementDrain.waitForScheduledReleases()
        guard operationGeneration == self.microphonePreviewOperationGeneration,
              self.isMicrophonePreviewRequested,
              self.isRunning == false,
              self.isStarting == false,
              self.isTerminating == false,
              Task.isCancelled == false
        else {
            self.abandonMicrophonePreviewRequestIfOwned(operationGeneration)
            return
        }
        self.microphonePreviewError = nil
        self.audioCapturePipeline.setLevelMonitoringEnabled(true)

        do {
            guard let selection = self.directCoreAudioDeviceSelection() else {
                throw NSError(
                    domain: "ASRService",
                    code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "No usable microphone is available."]
                )
            }
            let device = try await self.directAudioLifecycleController.resolveDevice(
                selection: selection,
                reason: "onboarding_microphone_preview"
            )
            try Task.checkCancellation()
            guard operationGeneration == self.microphonePreviewOperationGeneration,
                  self.isRunning == false,
                  self.isStarting == false,
                  self.isTerminating == false
            else { throw CancellationError() }
            _ = try await self.directAudioLifecycleController.start(
                deviceID: device.id,
                deviceName: device.name,
                reason: "onboarding_microphone_preview"
            )
            try Task.checkCancellation()
            guard operationGeneration == self.microphonePreviewOperationGeneration,
                  self.isRunning == false,
                  self.isStarting == false,
                  self.isTerminating == false
            else { throw CancellationError() }
            self.activeAudioCaptureBackend = .directCoreAudio
            self.isMicrophonePreviewActive = true
            DebugLogger.shared.info(
                "Started onboarding microphone preview with '\(device.name)'",
                source: "ASRService"
            )
        } catch {
            // A newer preview, page-exit stop, or dictation start owns cleanup
            // after invalidating this operation. Do not tear down its capture.
            guard operationGeneration == self.microphonePreviewOperationGeneration else {
                return
            }
            self.audioCapturePipeline.setLevelMonitoringEnabled(false)
            await self.directAudioLifecycleController.invalidate(
                reason: "onboarding_microphone_preview_failed"
            )
            self.activeAudioCaptureBackend = .none
            self.isMicrophonePreviewActive = false
            self.isMicrophonePreviewRequested = false
            self.microphonePreviewError = error is CancellationError ? nil : error.localizedDescription
            guard error is CancellationError == false else { return }
            DebugLogger.shared.warning(
                "Onboarding microphone preview failed: \(error.localizedDescription)",
                source: "ASRService"
            )
        }
    }

    func stopMicrophonePreview(retainPreparedCapture: Bool = true) async {
        self.microphonePreviewOperationGeneration &+= 1
        let operationGeneration = self.microphonePreviewOperationGeneration
        self.isMicrophonePreviewRequested = false
        self.microphonePreviewError = nil
        guard self.isMicrophonePreviewActive || self.audioCapturePipeline.isLevelMonitoringEnabled else {
            return
        }

        self.audioCapturePipeline.setLevelMonitoringEnabled(false)
        _ = await self.directAudioLifecycleController.stop(
            retainPrepared: retainPreparedCapture,
            reason: "onboarding_microphone_preview_stop"
        )
        guard operationGeneration == self.microphonePreviewOperationGeneration else { return }
        self.activeAudioCaptureBackend = .none
        self.isMicrophonePreviewActive = false
        self.audioLevelSubject.send(0)
    }

    private func abandonMicrophonePreviewRequestIfOwned(_ operationGeneration: UInt64) {
        guard operationGeneration == self.microphonePreviewOperationGeneration else { return }
        self.isMicrophonePreviewRequested = false
        self.audioCapturePipeline.setLevelMonitoringEnabled(false)
        self.activeAudioCaptureBackend = .none
        self.isMicrophonePreviewActive = false
        self.microphonePreviewError = nil
        self.audioLevelSubject.send(0)
    }

    private func handOffMicrophonePreviewToCaptureStartIfNeeded() -> Bool {
        guard self.isMicrophonePreviewRequested ||
            self.isMicrophonePreviewActive ||
            self.audioCapturePipeline.isLevelMonitoringEnabled
        else { return false }

        // Invalidate preview ownership without stopping Core Audio. The direct
        // lifecycle serializes any in-flight preview start, and recording can
        // reuse the already-running input without losing opening PCM.
        self.microphonePreviewOperationGeneration &+= 1
        self.isMicrophonePreviewRequested = false
        self.audioCapturePipeline.setLevelMonitoringEnabled(false)
        self.isMicrophonePreviewActive = false
        self.microphonePreviewError = nil
        self.audioLevelSubject.send(0)
        return true
    }

    private func stopHandedOffMicrophonePreviewAfterCancelledStart() async {
        self.audioCapturePipeline.setRecordingEnabled(false)
        _ = await self.directAudioLifecycleController.stop(
            retainPrepared: true,
            reason: "cancelled_microphone_preview_handoff"
        )
        self.activeAudioCaptureBackend = .none
        self.audioLevelSubject.send(0)
    }

    func openSystemSettingsForMic() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Starts the speech recognition session.
    ///
    /// This method initiates audio capture and real-time processing. The service will:
    /// - Begin capturing audio from the default input device
    /// - Process audio in real-time for transcription
    /// - Provide audio level feedback for visualization
    ///
    /// ## Requirements
    /// - Microphone permission must be granted
    /// - ASR models must be available (will download if needed)
    /// - No existing recording session should be active
    ///
    /// ## Postconditions
    /// - `isRunning` will be `true`
    /// - Audio processing will begin immediately
    /// - Audio level updates will be published via `audioLevelPublisher`
    ///
    /// ## Errors
    /// If audio session configuration fails, the method will silently fail
    /// and `isRunning` will remain `false`. Check the debug logs for details.
    @discardableResult
    func start(
        forDictionaryTraining: Bool = false,
        onCaptureStarted: (@MainActor () -> Void)? = nil
    ) async -> AudioCaptureStartOutcome {
        DebugLogger.shared.info("🎤 START() called - beginning recording session", source: "ASRService")

        guard self.micStatus == .authorized else {
            DebugLogger.shared.error("❌ START() blocked - mic not authorized", source: "ASRService")
            return .failed
        }
        guard self.isRunning == false, self.isStarting == false else {
            DebugLogger.shared.warning("⚠️ START() blocked - already running (started: \(self.isRunning), starting: \(self.isStarting))", source: "ASRService")
            return .alreadyActive
        }
        guard self.isTerminating == false else {
            DebugLogger.shared.warning("START() blocked - app is terminating", source: "ASRService")
            return .failed
        }
        self.audioCaptureStartGeneration &+= 1
        let startGeneration = self.audioCaptureStartGeneration
        self.isStarting = true
        defer { self.finishAudioCaptureStart() }

        // Reserve the start before relinquishing preview ownership so a
        // press-and-hold release can cancel the handoff. Keep the running input
        // alive; startConfiguredAudioCapture reuses it for zero-stop first PCM.
        let handedOffMicrophonePreview = self.handOffMicrophonePreviewToCaptureStartIfNeeded()

        // Reset media pause state for this session
        self.didPauseMediaForThisSession = false
        self.audioEngineStandbyTask?.cancel()
        self.audioEngineStandbyTask = nil
        await self.waitForPendingAudioRouteRecoveryBeforeStart()
        guard startGeneration == self.audioCaptureStartGeneration,
              self.isTerminating == false
        else {
            if handedOffMicrophonePreview {
                await self.stopHandedOffMicrophonePreviewAfterCancelledStart()
            }
            DebugLogger.shared.debug(
                "Audio capture start cancelled during route handoff generation=\(startGeneration)",
                source: "ASRService"
            )
            return .failed
        }

        DebugLogger.shared.debug("🧹 Clearing buffers and state", source: "ASRService")
        self.finalText.removeAll()
        self.audioBuffer.clear(keepingCapacity: true) // specific optimization for restart
        self.partialTranscription.removeAll()
        self.previousFullTranscription.removeAll()
        self.lastBoostHitTerm = nil
        self.lastProcessedSampleCount = 0
        self.isProcessingChunk = false
        self.skipNextChunk = false
        self.benchmarkSessionID += 1
        self.silentPCMRecoveryWatchdog = AudioCaptureIdlePolicy.SilentPCMRecoveryWatchdog()
        let captureSessionID = self.benchmarkSessionID
        self.audioCaptureAttemptID &+= 1
        var readinessAttemptID = self.audioCaptureAttemptID
        self.audioCaptureReadinessGate.arm(
            sessionID: captureSessionID,
            attemptID: readinessAttemptID
        )
        self.benchmarkRecordingStartedAt = Date().timeIntervalSince1970
        self.benchmarkStreamingChunkIndex = 0
        self.benchmarkCompletedStreamingChunks = 0
        self.benchmarkLastChunkSampleCount = 0
        (self.transcriptionProvider as? FluidAudioProvider)?.resetStreamingPreviewCache()
        self.audioCapturePipeline.setRecordingEnabled(
            true,
            sessionID: captureSessionID,
            attemptID: readinessAttemptID,
            startHostTime: mach_absolute_time()
        )
        self.refreshWordBoostStatus()
        let dims = self.currentTranscriptionAnalyticsDimensions()
        self.benchmarkLog("recording_start model=\(dims.model) provider=\(dims.provider) supportsStreaming=\(SettingsStore.shared.selectedSpeechModel.supportsStreaming)")
        DebugLogger.shared.debug("✅ Buffers cleared", source: "ASRService")

        self.isDictionaryTrainingCaptureActive = false

        do {
            let maximumStartAttempts =
                SettingsStore.shared.experimentalDirectAudioCaptureEnabled
                    ? max(AudioDevice.listInputDevices().count, 1) + 1
                    : 1
            var startAttempt = 1
            var fallbackAttempt = 1
            var failedInputUIDs = Set<String>()
            var immediatelyRetriedInputUID: String?
            var bluetoothStabilization = AudioCaptureIdlePolicy.BluetoothInputStabilization()
            var forcedInputUID: String?
            self.audioStartAttemptInputUID = nil
            while true {
                let routeGenerationAtStart = self.audioRouteRecoveryGeneration
                do {
                    try await self.startConfiguredAudioCapture(
                        excluding: failedInputUIDs,
                        forcingInputUID: forcedInputUID
                    )
                } catch {
                    guard let failedUID = self.audioStartAttemptInputUID else { throw error }
                    let now = ProcessInfo.processInfo.systemUptime
                    let retryBluetoothInput = bluetoothStabilization.shouldRetry(
                        inputUID: failedUID,
                        isBluetoothInput: self.audioStartAttemptIsBluetooth,
                        now: now
                    )
                    let retrySameInput = retryBluetoothInput || immediatelyRetriedInputUID == nil
                    if retryBluetoothInput {
                        forcedInputUID = failedUID
                        immediatelyRetriedInputUID = failedUID
                        self.logBluetoothStartupRetry(
                            uid: failedUID,
                            attempt: startAttempt + 1,
                            elapsed: bluetoothStabilization.elapsed(at: now),
                            reason: error.localizedDescription
                        )
                    } else {
                        forcedInputUID = nil
                        if bluetoothStabilization.inputUID == failedUID {
                            self.logBluetoothStartupStabilizationEnded(
                                uid: failedUID,
                                elapsed: bluetoothStabilization.elapsed(at: now),
                                outcome: "budget_exhausted"
                            )
                        }
                        if immediatelyRetriedInputUID == nil {
                            immediatelyRetriedInputUID = failedUID
                        } else {
                            failedInputUIDs.insert(failedUID)
                        }
                        fallbackAttempt += 1
                    }
                    guard retryBluetoothInput || fallbackAttempt <= maximumStartAttempts,
                          startGeneration == self.audioCaptureStartGeneration,
                          self.isTerminating == false
                    else {
                        throw error
                    }
                    readinessAttemptID = try await self.prepareAudioCaptureStartRetry(
                        sessionID: captureSessionID,
                        startGeneration: startGeneration,
                        completedAttempt: startAttempt,
                        reason: "backend_start_error:\(error.localizedDescription)",
                        waitForTopologyQuiet: retryBluetoothInput || retrySameInput == false
                    )
                    startAttempt += 1
                    continue
                }
                self.benchmarkLog(
                    "first_pcm_wait_begin attempt=\(startAttempt) " +
                        "attemptID=\(readinessAttemptID) " +
                        "timeoutMs=\(self.firstPCMTimeoutNanoseconds / 1_000_000) " +
                        "routeGeneration=\(routeGenerationAtStart) " +
                        "captureGeneration=\(self.directAudioLifecycleController.snapshot.generation)"
                )
                let readiness = await self.audioCaptureReadinessGate.wait(
                    sessionID: captureSessionID,
                    attemptID: readinessAttemptID,
                    timeoutNanoseconds: self.firstPCMTimeoutNanoseconds
                )
                guard startGeneration == self.audioCaptureStartGeneration,
                      self.isTerminating == false
                else {
                    throw CancellationError()
                }
                let routeStayedStable =
                    routeGenerationAtStart == self.audioRouteRecoveryGeneration &&
                    self.pendingAudioRouteRecovery == nil &&
                    self.isRecoveringAudioRoute == false
                if readiness == .ready, routeStayedStable {
                    if let stabilizedUID = bluetoothStabilization.inputUID {
                        self.logBluetoothStartupStabilizationEnded(
                            uid: stabilizedUID,
                            elapsed: bluetoothStabilization.elapsed(
                                at: ProcessInfo.processInfo.systemUptime
                            ),
                            outcome: "first_pcm"
                        )
                    }
                    AppServices.shared.microphonePreferenceCoordinator.confirmActiveSelection(
                        uid: self.audioStartAttemptInputUID,
                        name: self.audioStartAttemptInputName
                    )
                    self.benchmarkLog(
                        "first_pcm_wait_end result=ready attempt=\(startAttempt) " +
                            "attemptID=\(readinessAttemptID) " +
                            "bufferedSamples=\(self.audioBuffer.count)"
                    )
                    break
                }

                self.benchmarkLog(
                    "first_pcm_wait_end result=\(readiness) attempt=\(startAttempt) " +
                        "attemptID=\(readinessAttemptID) " +
                        "routeStable=\(routeStayedStable)"
                )
                if readiness == .cancelled {
                    throw CancellationError()
                }
                var retrySameInput = false
                var retryBluetoothInput = false
                if let failedUID = self.audioStartAttemptInputUID {
                    let now = ProcessInfo.processInfo.systemUptime
                    retryBluetoothInput = bluetoothStabilization.shouldRetry(
                        inputUID: failedUID,
                        isBluetoothInput: self.audioStartAttemptIsBluetooth,
                        now: now
                    )
                    retrySameInput = retryBluetoothInput || (
                        readiness == .formatInvalidated && immediatelyRetriedInputUID == nil
                    )
                    if retryBluetoothInput {
                        forcedInputUID = failedUID
                        immediatelyRetriedInputUID = failedUID
                        self.logBluetoothStartupRetry(
                            uid: failedUID,
                            attempt: startAttempt + 1,
                            elapsed: bluetoothStabilization.elapsed(at: now),
                            reason: "readiness_\(readiness)"
                        )
                    } else {
                        forcedInputUID = nil
                        if bluetoothStabilization.inputUID == failedUID {
                            self.logBluetoothStartupStabilizationEnded(
                                uid: failedUID,
                                elapsed: bluetoothStabilization.elapsed(at: now),
                                outcome: "budget_exhausted"
                            )
                        }
                        if retrySameInput {
                            immediatelyRetriedInputUID = failedUID
                        } else {
                            failedInputUIDs.insert(failedUID)
                            fallbackAttempt += 1
                        }
                    }
                }
                guard retryBluetoothInput || fallbackAttempt <= maximumStartAttempts else {
                    let message: String
                    switch readiness {
                    case .timedOut:
                        message = "The selected microphone started but did not deliver audio."
                    case .formatInvalidated:
                        message = "The microphone format did not stabilize after reconnecting."
                    case .staleSession:
                        message = "Audio capture was replaced before the microphone became ready."
                    case .cancelled:
                        message = "Audio capture was cancelled."
                    case .ready:
                        message = "The microphone route changed before capture became stable."
                    }
                    throw NSError(
                        domain: "ASRService",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )
                }

                readinessAttemptID = try await self.prepareAudioCaptureStartRetry(
                    sessionID: captureSessionID,
                    startGeneration: startGeneration,
                    completedAttempt: startAttempt,
                    reason: "readiness_\(readiness)_routeStable_\(routeStayedStable)",
                    waitForTopologyQuiet: retryBluetoothInput || retrySameInput == false
                )
                startAttempt += 1
            }
            self.isDictionaryTrainingCaptureActive = forDictionaryTraining
            self.isRunning = true
            DebugLogger.shared.info(
                "✅ Audio capture running after first PCM (session=\(captureSessionID))",
                source: "ASRService"
            )
            onCaptureStarted?()

            // Pause only after capture is live so media control cannot delay the
            // first PCM packet. A quick stop while this await is in flight is
            // handled explicitly below.
            if SettingsStore.shared.pauseMediaDuringTranscription {
                let didPause = await MediaPlaybackService.shared.pauseIfPlaying()
                guard self.isRunning else {
                    if didPause {
                        await MediaPlaybackService.shared.resumeIfWePaused(true)
                    }
                    return .started
                }
                self.didPauseMediaForThisSession = didPause
                if didPause {
                    DebugLogger.shared.info("🎵 Paused system media for transcription", source: "ASRService")
                }
            }

            // Direct capture already owns a required device-liveness listener
            // on its off-main lifecycle queue.
            if self.activeAudioCaptureBackend == .audioEngine,
               let currentDevice = getCurrentlyBoundInputDevice()
            {
                DebugLogger.shared.debug("👀 Starting device monitoring for: \(currentDevice.name)", source: "ASRService")
                self.startMonitoringDevice(currentDevice.id)
            } else if self.activeAudioCaptureBackend == .audioEngine {
                DebugLogger.shared.debug("ℹ️ No device to monitor", source: "ASRService")
            }

            // Only start streaming for models that support it (large Whisper models are too slow)
            let model = SettingsStore.shared.selectedSpeechModel
            if model.supportsStreaming, !forDictionaryTraining {
                DebugLogger.shared.debug("📡 Starting streaming transcription...", source: "ASRService")
                self.benchmarkLog("streaming_timer_start intervalMs=\(Int((self.streamingChunkDurationSeconds * 1000).rounded())) minSamples=\(self.minimumStreamingPreviewSamples)")
                self.startStreamingTranscription()
            } else if forDictionaryTraining {
                DebugLogger.shared.debug("⏸️ Skipping streaming for dictionary training sample", source: "ASRService")
            } else {
                DebugLogger.shared.debug("⏸️ Skipping streaming - model '\(model.displayName)' does not support real-time chunk processing", source: "ASRService")
            }
            DebugLogger.shared.info("✅ START() completed successfully", source: "ASRService")
            return .started
        } catch {
            await self.audioCaptureReadinessGate.cancel(
                sessionID: captureSessionID,
                attemptID: readinessAttemptID
            )
            self.isDictionaryTrainingCaptureActive = false
            self.audioCapturePipeline.setRecordingEnabled(false)
            self.isRunning = false
            await self.stopActiveAudioCapture(
                retainDirectPreparedCapture: false,
                reason: "start_failed"
            )
            await self.retireAudioEngineAndWait(reason: "start_failed")
            let wasCancelled =
                error is CancellationError ||
                startGeneration != self.audioCaptureStartGeneration ||
                self.isTerminating
            if wasCancelled {
                DebugLogger.shared.info(
                    "Audio capture start cancelled generation=\(startGeneration)",
                    source: "ASRService"
                )
            } else {
                DebugLogger.shared.error("Failed to start ASR session: \(error)", source: "ASRService")
            }

            // Resume media if we paused it before the failure
            if self.didPauseMediaForThisSession {
                await MediaPlaybackService.shared.resumeIfWePaused(true)
                self.didPauseMediaForThisSession = false
                DebugLogger.shared.info("🎵 Resumed system media after start failure", source: "ASRService")
            }

            guard wasCancelled == false else { return .failed }
            AppServices.shared.microphonePreferenceCoordinator.markActiveSelectionUnavailable()

            // Provide user-friendly error feedback
            let nsError = error as NSError
            let noUsableMicrophone = nsError.domain == "ASRService" && nsError.code == -4
            let errorMessage: String
            if nsError.domain == "ASRService" {
                if noUsableMicrophone {
                    errorMessage = "No usable microphone is available. Open your MacBook or connect a microphone, then try again."
                } else if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                    // Extract useful info from AVFoundation error
                    if underlyingError.domain == AVFoundationErrorDomain || underlyingError.domain == NSOSStatusErrorDomain {
                        errorMessage = "Failed to start audio recording. The audio device may be in use by another application or unavailable. Please check your audio settings and try again."
                    } else {
                        errorMessage = "Failed to start audio recording: \(underlyingError.localizedDescription)"
                    }
                } else {
                    errorMessage = "Failed to start audio recording after multiple attempts. Please check your audio device and try again."
                }
            } else {
                errorMessage = "Failed to start audio recording: \(error.localizedDescription)"
            }

            self.errorTitle = noUsableMicrophone ? "Microphone Unavailable" : "Recording Error"
            self.errorMessage = errorMessage
            self.showError = true

            // Post notification for UI to display
            NotificationCenter.default.post(
                name: NSNotification.Name("ASRServiceStartFailed"),
                object: nil,
                userInfo: ["errorMessage": errorMessage]
            )
            return .failed
        }
    }

    func waitForPendingStart() async {
        guard self.isStarting else { return }
        await withCheckedContinuation { continuation in
            if self.isStarting {
                self.audioCaptureStartWaiters.append(continuation)
            } else {
                continuation.resume()
            }
        }
    }

    private func prepareAudioCaptureStartRetry(
        sessionID: Int,
        startGeneration: UInt64,
        completedAttempt: Int,
        reason: String,
        waitForTopologyQuiet: Bool = true
    ) async throws -> UInt64 {
        self.audioCapturePipeline.setRecordingEnabled(false)
        await self.directAudioLifecycleController.invalidate(
            reason: "start_retry_attempt_\(completedAttempt):\(reason)"
        )
        // Invalidation retires the packet gate and drains accepted packets, so
        // this clear cannot be followed by late PCM from the failed attempt.
        self.audioBuffer.clear(keepingCapacity: true)
        let routeRecoveryWasPending = self.audioRouteRecoveryTask != nil
        await self.waitForPendingAudioRouteRecoveryBeforeStart()
        guard startGeneration == self.audioCaptureStartGeneration,
              self.isTerminating == false
        else {
            throw CancellationError()
        }
        if routeRecoveryWasPending == false, waitForTopologyQuiet {
            try await Task.sleep(nanoseconds: self.audioRouteRecoveryDelayNanoseconds)
        }
        guard startGeneration == self.audioCaptureStartGeneration,
              self.isTerminating == false
        else {
            throw CancellationError()
        }

        self.audioCaptureAttemptID &+= 1
        let attemptID = self.audioCaptureAttemptID
        self.audioCaptureReadinessGate.arm(
            sessionID: sessionID,
            attemptID: attemptID
        )
        self.audioCapturePipeline.setRecordingEnabled(
            true,
            sessionID: sessionID,
            attemptID: attemptID,
            startHostTime: mach_absolute_time()
        )
        DebugLogger.shared.info(
            "Retrying direct audio startup in the same session after \(reason) " +
                "(nextAttempt=\(completedAttempt + 1))",
            source: "ASRService"
        )
        return attemptID
    }

    private func logBluetoothStartupRetry(
        uid: String,
        attempt: Int,
        elapsed: TimeInterval,
        reason: String
    ) {
        let elapsedMilliseconds = Int((elapsed * 1000).rounded())
        let admissionWindowMilliseconds = Int(
            (AudioCaptureIdlePolicy.BluetoothInputStabilization.retryAdmissionWindow * 1000).rounded()
        )
        self.benchmarkLog(
            "bluetooth_start_retry uid=\(uid) attempt=\(attempt) " +
                "elapsedMs=\(elapsedMilliseconds) " +
                "admissionWindowMs=\(admissionWindowMilliseconds) reason=\(reason)"
        )
    }

    private func logBluetoothStartupStabilizationEnded(
        uid: String,
        elapsed: TimeInterval,
        outcome: String
    ) {
        self.benchmarkLog(
            "bluetooth_start_stabilization_end uid=\(uid) outcome=\(outcome) " +
                "elapsedMs=\(Int((elapsed * 1000).rounded()))"
        )
    }

    func cancelPendingAudioCaptureStart(reason: String) async {
        guard self.isStarting, self.isRunning == false else { return }
        self.audioCaptureStartGeneration &+= 1
        let cancelledSessionID = self.benchmarkSessionID
        self.benchmarkLog(
            "capture_start_cancel reason=\(reason) session=\(cancelledSessionID) " +
                "generation=\(self.audioCaptureStartGeneration)"
        )
        await self.audioCaptureReadinessGate.cancel(
            sessionID: cancelledSessionID,
            attemptID: self.audioCaptureAttemptID
        )
        await self.waitForPendingStart()
    }

    private func finishAudioCaptureStart() {
        self.isStarting = false
        let deferredRecovery = self.deferredBluetoothStartupRouteRecovery.take()
        self.audioCaptureStateSettledTick &+= 1
        let waiters = self.audioCaptureStartWaiters
        self.audioCaptureStartWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }

        if let deferredRecovery {
            Task { @MainActor [weak self] in
                await self?.processDeferredBluetoothStartupRouteRecovery(deferredRecovery)
            }
        }
    }

    private func processDeferredBluetoothStartupRouteRecovery(
        _ request: AudioCaptureIdlePolicy.DeferredBluetoothRouteRecovery.Request
    ) async {
        do {
            try await Task.sleep(nanoseconds: self.audioRouteRecoveryDelayNanoseconds)
        } catch {
            return
        }
        guard self.isTerminating == false else { return }

        let snapshot = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let devices = AudioDevice.listInputDevicesRefreshingLiveness()
                let defaultInputUID = AudioDevice.getDefaultInputDevice()?.uid
                continuation.resume(returning: (devices, defaultInputUID))
            }
        }
        guard self.isTerminating == false else { return }
        if self.isStarting {
            self.deferredBluetoothStartupRouteRecovery.preserve(
                reason: request.reason,
                requiresIdlePrewarm: request.requiresIdlePrewarm,
                reconcilesInputSelection: request.reconcilesInputSelection
            )
            return
        }

        let microphonePreferenceCoordinator = AppServices.shared.microphonePreferenceCoordinator
        let resolvedInput: AudioDevice.Device?
        if request.reconcilesInputSelection {
            resolvedInput = microphonePreferenceCoordinator.reconcileMicrophoneSelection(
                availableInputs: snapshot.0,
                defaultInputUID: snapshot.1
            )
        } else {
            resolvedInput = microphonePreferenceCoordinator.inputDeviceForCapture(
                availableInputs: snapshot.0,
                defaultInputUID: snapshot.1
            )
        }
        self.cacheCurrentDeviceList(snapshot.0)

        let activeSnapshot = self.directAudioLifecycleController.snapshot
        let shouldRecover = AudioCaptureIdlePolicy.shouldRecoverAfterDeferredBluetoothReconciliation(
            isRunning: self.isRunning,
            confirmedInputUID: microphonePreferenceCoordinator.confirmedActiveInputUID,
            activeDeviceID: activeSnapshot.deviceID,
            resolvedInputUID: resolvedInput?.uid,
            resolvedDeviceID: resolvedInput?.id,
            hasPreparedCapture: self.hasPreparedAudioCapture,
            requiresIdlePrewarm: request.requiresIdlePrewarm
        )
        guard shouldRecover else {
            self.benchmarkLog(
                "bluetooth_deferred_reconciliation_noop event=\(request.reason) " +
                    "resolvedUID=\(resolvedInput?.uid ?? "none")"
            )
            return
        }

        self.scheduleAudioRouteRecovery(
            reason: "deferred after Bluetooth startup: \(request.reason)",
            requiresIdlePrewarm: request.requiresIdlePrewarm,
            reconcilesInputSelection: false
        )
    }

    /// Stops the recording session and returns the transcribed text.
    ///
    /// This method performs the complete transcription process:
    /// 1. Stops audio capture and processing
    /// 2. Ensures ASR models are ready
    /// 3. Transcribes all recorded audio
    /// 4. Returns the final transcribed text
    ///
    /// ## Process
    /// - Stops the audio engine and removes processing tap
    /// - Validates that ASR models are available and ready
    /// - Processes all recorded audio through the ASR pipeline
    /// - Returns the transcribed text for use by the caller
    ///
    /// ## Returns
    /// The transcribed text from the entire recording session, or an empty string if transcription fails.
    ///
    /// ## Note
    /// This method does not update `finalText` property to avoid UI conflicts.
    /// Callers should handle the returned text as needed.
    ///
    /// ## Errors
    /// Returns empty string if:
    /// - No recording was in progress
    /// - ASR models are not available
    /// - Transcription process fails
    /// Check debug logs for detailed error information.
    /// - Parameter onCaptureStopped: Optional callback fired on the main actor
    ///   after the audio engine has stopped but before the (potentially slow)
    ///   final transcription pass. Use this for immediate stop cues that
    ///   shouldn't wait on finalization. Only invoked when capture was actually
    ///   running (i.e. not when `stop()` early-returns because `isRunning` is false).
    func stop(
        onCaptureStopped: (@MainActor () -> Void)? = nil,
        forDictionaryTraining: Bool = false
    ) async -> String {
        DebugLogger.shared.info("🛑 STOP() called - beginning shutdown sequence", source: "ASRService")
        self.lastStopOutcome = .empty
        self.lastFinalTranscriptionDurationMs = nil
        if forDictionaryTraining || self.isDictionaryTrainingCaptureActive {
            self.lastDictionaryTrainingResult = nil
        }
        self.lastCompletedAudioSnapshot = nil
        let stopStartedAt = Date().timeIntervalSince1970
        self.benchmarkLog("stop_start ageMs=\(self.elapsedMilliseconds(since: self.benchmarkRecordingStartedAt)) bufferedSamples=\(self.audioBuffer.count)")

        if self.isStarting, self.isRunning == false {
            await self.cancelPendingAudioCaptureStart(reason: "recording_stop")
        }
        guard self.isRunning else {
            self.isDictionaryTrainingCaptureActive = false
            DebugLogger.shared.warning("⚠️ STOP() - not running, returning empty string", source: "ASRService")
            return ""
        }
        let useDictionaryTrainingPath = forDictionaryTraining || self.isDictionaryTrainingCaptureActive
        defer {
            self.applyPendingParakeetVocabularyReloadIfNeeded()
            self.isDictionaryTrainingCaptureActive = false
        }

        await self.cancelAudioRouteRecoveryAndWait()

        // Capture media pause state before we reset it, for resuming at the end
        let shouldResumeMedia = self.didPauseMediaForThisSession
        self.didPauseMediaForThisSession = false // Reset for next session

        DebugLogger.shared.debug("📍 Preparing final transcription", source: "ASRService")

        // Freeze an exact acquisition boundary before stopping hardware. The
        // direct IOProc is synchronously drained and the pipeline trims the
        // final hardware packet to this host time, preserving the last phoneme
        // without appending audio from the next session.
        self.audioCapturePipeline.markRecordingEnd(atHostTime: mach_absolute_time())

        // Set isRunning to false before teardown so in-flight ASR chunks stop safely.
        DebugLogger.shared.debug("🚫 Setting isRunning = false...", source: "ASRService")
        self.isRunning = false
        DebugLogger.shared.debug("✅ isRunning disabled", source: "ASRService")

        // Stop monitoring device to prevent callbacks after stop
        DebugLogger.shared.debug("👁️ Stopping device monitoring...", source: "ASRService")
        self.stopMonitoringDevice()
        DebugLogger.shared.debug("✅ Device monitoring stopped", source: "ASRService")

        await self.stopActiveAudioCapture(reason: "recording_stop")
        self.audioCapturePipeline.finishRecording()
        self.audioCaptureStateSettledTick &+= 1

        // A prepared direct IOProc owns only fixed memory and registration; it
        // does not run hardware, show the mic indicator, or hold Bluetooth in
        // headset mode. Keep it prepared across idle periods. AVAudioEngine is
        // detached immediately and released by the off-main serial drain so
        // Bluetooth can return to stereo A2DP without delaying stop cues or
        // transcription. The next capture waits on the drain before creating
        // another engine.
        if self.directAudioLifecycleController.snapshot.isPrepared {
            self.audioEngineStandbyTask?.cancel()
            self.audioEngineStandbyTask = nil
            DebugLogger.shared.debug("♻️ Direct audio capture remains prepared", source: "ASRService")
        } else {
            self.retireAudioEngine(reason: "recording_stop_release")
        }

        // Capture has fully ended — invoke the callback so callers can play a
        // stop cue or release capture-dependent UI without waiting on the
        // (potentially slow) final transcription pass.
        await MainActor.run { onCaptureStopped?() }

        let directCaptureSnapshot = self.directAudioLifecycleController.snapshot
        self.benchmarkLog(
            "audio_capture_prepared retained=\(directCaptureSnapshot.isPrepared) " +
                "phase=\(directCaptureSnapshot.phase.rawValue) generation=\(directCaptureSnapshot.generation)"
        )

        // CRITICAL FIX: Await completion of streaming task AND any pending transcriptions
        // This prevents use-after-free crashes (EXC_BAD_ACCESS) when clearing buffer
        DebugLogger.shared.debug("⏳ Awaiting stopStreamingTimerAndAwait()...", source: "ASRService")
        let streamingStopStartedAt = Date().timeIntervalSince1970
        await self.stopStreamingTimerAndAwait()
        self.benchmarkLog("stop_streaming_wait elapsedMs=\(self.elapsedMilliseconds(since: streamingStopStartedAt))")
        DebugLogger.shared.debug("✅ stopStreamingTimerAndAwait() completed", source: "ASRService")

        self.isProcessingChunk = false
        self.skipNextChunk = false
        self.previousFullTranscription.removeAll()

        // NOW it's safe to access the buffer - all pending tasks have completed
        // Thread-safe copy of recorded audio
        var pcm = self.audioBuffer.getAll()
        self.audioBuffer.clear()
        let capturedPCM = pcm
        self.benchmarkLog("stop_audio_drained samples=\(pcm.count) audioMs=\(Int((Double(pcm.count) / 16_000.0 * 1000).rounded()))")

        // Drop recordings with no audio at all — nothing to transcribe.
        guard !pcm.isEmpty else {
            DebugLogger.shared.debug(
                "stop(): no audio captured, skipping transcription",
                source: "ASRService"
            )
            DebugLogger.shared.info(
                "Final ASR result | provider=\(self.transcriptionProvider.name) | samples=0 | textChars=0 | confidence=nil | reason=no_audio",
                source: "ASRService"
            )
            if shouldResumeMedia {
                await MediaPlaybackService.shared.resumeIfWePaused(true)
                DebugLogger.shared.info("🎵 Resumed system media after empty audio", source: "ASRService")
            }
            self.benchmarkLog("stop_end result=empty totalMs=\(self.elapsedMilliseconds(since: stopStartedAt)) reason=no_audio")
            return ""
        }

        let hasRecognizedStreamingPreview = !self.partialTranscription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        if Self.shouldAssessShortAudioSilence(
            isEnabled: SettingsStore.shared.skipSilentRecordingsEnabled,
            useDictionaryTrainingPath: useDictionaryTrainingPath,
            hasRecognizedStreamingPreview: hasRecognizedStreamingPreview
        ) {
            let silenceGateStartedAt = ProcessInfo.processInfo.systemUptime
            let silenceAssessment = Self.assessShortAudioSilence(pcm)
            let silenceGateMicroseconds = Int(
                ((ProcessInfo.processInfo.systemUptime - silenceGateStartedAt) * 1_000_000).rounded()
            )
            self.benchmarkLog(
                "silence_gate eligible=\(silenceAssessment.isEligible) skip=\(silenceAssessment.shouldSkipTranscription) " +
                    "audioMs=\(silenceAssessment.durationMilliseconds) analysisUs=\(silenceGateMicroseconds) " +
                    "peak=\(String(format: "%.6f", silenceAssessment.peakAmplitude)) " +
                    "rms=\(String(format: "%.6f", silenceAssessment.rmsAmplitude)) " +
                    "maxFrameRms=\(String(format: "%.6f", silenceAssessment.maximumFrameRMS))"
            )

            if silenceAssessment.shouldSkipTranscription {
                DebugLogger.shared.info(
                    "Final ASR result | provider=\(self.transcriptionProvider.name) | samples=\(pcm.count) | textChars=0 | confidence=nil | reason=short_silence",
                    source: "ASRService"
                )
                if shouldResumeMedia {
                    await MediaPlaybackService.shared.resumeIfWePaused(true)
                    DebugLogger.shared.info("🎵 Resumed system media after silent audio", source: "ASRService")
                }
                self.benchmarkLog(
                    "stop_end result=empty totalMs=\(self.elapsedMilliseconds(since: stopStartedAt)) reason=short_silence"
                )
                return ""
            }
        } else if hasRecognizedStreamingPreview {
            self.benchmarkLog("silence_gate eligible=false skip=false reason=streaming_preview")
        }

        // Pad sub-1s buffers with trailing silence so short utterances (e.g.
        // "yes", "stop") still transcribe. whisper.cpp asserts on buffers
        // shorter than 1s; every other provider handles silence padding
        // without issue, so we pad unconditionally rather than branching per
        // provider.
        let minSamples = 16_000
        if pcm.count < minSamples {
            let originalCount = pcm.count
            pcm.append(contentsOf: repeatElement(0.0, count: minSamples - pcm.count))
            DebugLogger.shared.debug(
                "stop(): padded short audio with silence (\(originalCount) → \(pcm.count) samples)",
                source: "ASRService"
            )
        }

        do {
            var provider = self.transcriptionProvider
            let ensureStartedAt = Date().timeIntervalSince1970
            if self.isAsrReady, provider.isReady {
                self.benchmarkLog("stop_ensure_ready skipped=true elapsedMs=0")
            } else {
                DebugLogger.shared.debug("🔍 Calling ensureAsrReady()...", source: "ASRService")
                try await self.ensureAsrReady()
                provider = self.transcriptionProvider
                self.benchmarkLog("stop_ensure_ready skipped=false elapsedMs=\(self.elapsedMilliseconds(since: ensureStartedAt))")
                DebugLogger.shared.debug("✅ ensureAsrReady() completed", source: "ASRService")
            }

            guard provider.isReady else {
                DebugLogger.shared.error("Transcription provider is not ready", source: "ASRService")
                self.lastStopOutcome = .failed
                // Resume media playback if we paused it
                if shouldResumeMedia {
                    await MediaPlaybackService.shared.resumeIfWePaused(true)
                    DebugLogger.shared.info("🎵 Resumed system media after provider not ready", source: "ASRService")
                }
                self.benchmarkLog("stop_end result=empty totalMs=\(self.elapsedMilliseconds(since: stopStartedAt)) reason=provider_not_ready")
                return ""
            }

            DebugLogger.shared.debug("Starting transcription with \(pcm.count) samples (\(Float(pcm.count) / 16_000.0) seconds)", source: "ASRService")
            let finalStartedAt = Date().timeIntervalSince1970
            let result: ASRTranscriptionResult
            let finalSource: String
            if useDictionaryTrainingPath {
                result = try await self.transcriptionExecutor.run { [provider] in
                    try await provider.transcribeDictionaryTraining(pcm)
                }
                self.lastDictionaryTrainingResult = result
                finalSource = "dictionaryTraining"
            } else {
                result = try await self.transcriptionExecutor.run { [provider] in
                    try await provider.transcribeFinal(pcm)
                }
                finalSource = "full"
            }
            let finalElapsedMs = self.elapsedMilliseconds(since: finalStartedAt)
            if !useDictionaryTrainingPath {
                self.lastFinalTranscriptionDurationMs = finalElapsedMs
            }
            let finalAudioSeconds = Double(pcm.count) / 16_000.0
            let finalRTF = finalAudioSeconds > 0 ? (Double(finalElapsedMs) / 1000.0) / finalAudioSeconds : 0
            DebugLogger.shared.debug("stop(): final transcription finished source=\(finalSource)", source: "ASRService")
            DebugLogger.shared.debug(
                "Transcription completed: '\(result.text)' (confidence: \(result.confidence))",
                source: "ASRService"
            )
            DebugLogger.shared.info(
                "Final ASR result | provider=\(provider.name) | samples=\(pcm.count) | textChars=\(result.text.trimmingCharacters(in: .whitespacesAndNewlines).count) | confidence=\(result.confidence)",
                source: "ASRService"
            )
            self.benchmarkLog(
                "final_done elapsedMs=\(finalElapsedMs) samples=\(pcm.count) audioMs=\(Int((finalAudioSeconds * 1000).rounded())) " +
                    "textChars=\(result.text.trimmingCharacters(in: .whitespacesAndNewlines).count) rtf=\(String(format: "%.3f", finalRTF)) streamedChunks=\(self.benchmarkCompletedStreamingChunks) source=\(finalSource)"
            )

            // Mark first transcription as complete to clear loading state
            if !self.hasCompletedFirstTranscription {
                self.hasCompletedFirstTranscription = true
                DispatchQueue.main.async {
                    self.isLoadingModel = false
                    self.modelPreparationPhase = nil
                    DebugLogger.shared.info("✅ Model warmed up - first transcription completed", source: "ASRService")
                }
            }

            // Do not update self.finalText here to avoid instant binding insert in playground
            let textWithoutFillers = ASRService.removeFillerWords(result.text)
            let dictionaryText = useDictionaryTrainingPath
                ? textWithoutFillers
                : ASRService.applyCustomDictionary(textWithoutFillers)
            let outputText = useDictionaryTrainingPath
                ? dictionaryText
                : ASRService.applySpokenPunctuationFormatting(dictionaryText)
            if !useDictionaryTrainingPath {
                self.recordWordBoostHitIfAny(transcribedText: outputText)
            }
            DebugLogger.shared.debug("After post-processing: '\(outputText)'", source: "ASRService")
            self.benchmarkLog("stop_end result=success totalMs=\(self.elapsedMilliseconds(since: stopStartedAt)) recordingAgeMs=\(self.elapsedMilliseconds(since: self.benchmarkRecordingStartedAt)) cleanedChars=\(outputText.count)")
            if !useDictionaryTrainingPath,
               SettingsStore.shared.saveTranscriptionHistory,
               SettingsStore.shared.saveAudioWithTranscriptionHistory,
               !capturedPCM.isEmpty
            {
                self.lastCompletedAudioSnapshot = DictationAudioSnapshot(
                    samples: capturedPCM,
                    sampleRate: 16_000,
                    channels: 1
                )
            }

            // Resume media playback if we paused it
            if shouldResumeMedia {
                await MediaPlaybackService.shared.resumeIfWePaused(true)
                DebugLogger.shared.info("🎵 Resumed system media after transcription", source: "ASRService")
            }

            self.lastStopOutcome = outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .empty
                : .success
            return outputText
        } catch {
            self.lastStopOutcome = .failed
            DebugLogger.shared.error("ASR transcription failed: \(error)", source: "ASRService")
            DebugLogger.shared.error("Error details: \(error.localizedDescription)", source: "ASRService")
            let nsError = error as NSError
            DebugLogger.shared.error("Error domain: \(nsError.domain), code: \(nsError.code)", source: "ASRService")
            DebugLogger.shared.error("Error userInfo: \(nsError.userInfo)", source: "ASRService")

            // Clear loading state if this was the first transcription attempt
            // This ensures the UI doesn't show a perpetual loading state on error
            if !self.hasCompletedFirstTranscription {
                self.hasCompletedFirstTranscription = true
                DispatchQueue.main.async {
                    self.isLoadingModel = false
                    self.modelPreparationPhase = nil
                    DebugLogger.shared.info("⚠️ First transcription failed - clearing loading state", source: "ASRService")
                }
            }

            // Note: We intentionally do NOT show an error popup here.
            // Common errors like "audio too short" are expected during normal use
            // (e.g., accidental hotkey press) and would disrupt the user's workflow.
            // Errors are logged for debugging purposes.

            // Resume media playback if we paused it
            if shouldResumeMedia {
                await MediaPlaybackService.shared.resumeIfWePaused(true)
                DebugLogger.shared.info("🎵 Resumed system media after transcription failure", source: "ASRService")
            }

            self.benchmarkLog("stop_end result=error totalMs=\(self.elapsedMilliseconds(since: stopStartedAt)) error=\(error.localizedDescription)")
            return ""
        }
    }

    func transcribeSamplesForAPI(_ inputSamples: [Float]) async throws -> ASRTranscriptionResult {
        var samples = inputSamples
        guard !samples.isEmpty else {
            return ASRTranscriptionResult(text: "", confidence: 0)
        }

        let minSamples = 16_000
        if samples.count < minSamples {
            samples.append(contentsOf: repeatElement(0.0, count: minSamples - samples.count))
        }

        try await self.ensureAsrReady()
        guard self.transcriptionProvider.isReady else {
            throw NSError(
                domain: "ASRService",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Transcription provider is not ready."]
            )
        }

        let result = try await transcriptionExecutor.run { [provider = self.transcriptionProvider] in
            try await provider.transcribeFinal(samples)
        }

        if !self.hasCompletedFirstTranscription {
            self.hasCompletedFirstTranscription = true
            self.isLoadingModel = false
            self.modelPreparationPhase = nil
        }

        let cleanedText = ASRService.applySpokenPunctuationFormatting(
            ASRService.applyCustomDictionary(ASRService.removeFillerWords(result.text))
        )
        self.recordWordBoostHitIfAny(transcribedText: cleanedText)
        return ASRTranscriptionResult(text: cleanedText, confidence: result.confidence)
    }

    func transcribeFileForAPI(_ fileURL: URL) async throws -> (result: ASRTranscriptionResult, sampleCount: Int) {
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw NSError(
                domain: "ASRService",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Audio file is not readable."]
            )
        }

        let estimatedSamples = try LocalAPIAudioDecoder.estimatedSampleCount(for: fileURL)

        try await self.ensureAsrReady()
        let provider = self.transcriptionProvider
        guard provider.isReady else {
            throw NSError(
                domain: "ASRService",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Transcription provider is not ready."]
            )
        }

        if provider.prefersNativeFileTranscription,
           estimatedSamples > 0,
           estimatedSamples < 16_000
        {
            let reader = try LocalAPIAudioDecoder.ChunkReader(fileURL: fileURL)
            let samples = try await reader.nextSamples()
            let result = try await self.transcribeSamplesForAPI(samples)
            return (result, sampleCount: estimatedSamples)
        }

        guard provider.prefersNativeFileTranscription else {
            let reader = try LocalAPIAudioDecoder.ChunkReader(fileURL: fileURL)
            let (combinedText, confidence, processedSampleCount) = try await transcriptionExecutor.run { [provider] in
                var textParts: [String] = []
                var weightedConfidence = 0.0
                var processedSampleCount = 0

                while true {
                    var samples = try await reader.nextSamples()
                    let sampleCount = samples.count
                    guard sampleCount > 0 else { break }
                    if sampleCount < 16_000 {
                        samples.append(contentsOf: repeatElement(0.0, count: 16_000 - sampleCount))
                    }

                    let result = try await provider.transcribeFinal(samples)
                    if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        textParts.append(result.text)
                    }
                    weightedConfidence += Double(result.confidence) * Double(sampleCount)
                    processedSampleCount += sampleCount
                }

                let confidence = processedSampleCount > 0
                    ? Float(weightedConfidence / Double(processedSampleCount))
                    : 0
                return (textParts.joined(separator: " "), confidence, processedSampleCount)
            }

            guard processedSampleCount > 0 else {
                return (ASRTranscriptionResult(text: "", confidence: 0), sampleCount: 0)
            }

            if !self.hasCompletedFirstTranscription {
                self.hasCompletedFirstTranscription = true
                self.isLoadingModel = false
                self.modelPreparationPhase = nil
            }

            let cleanedText = ASRService.applySpokenPunctuationFormatting(
                ASRService.applyCustomDictionary(ASRService.removeFillerWords(combinedText))
            )
            self.recordWordBoostHitIfAny(transcribedText: cleanedText)
            return (
                ASRTranscriptionResult(text: cleanedText, confidence: confidence),
                sampleCount: estimatedSamples
            )
        }

        let result = try await transcriptionExecutor.run { [provider] in
            try await provider.transcribeFile(at: fileURL)
        }

        if !self.hasCompletedFirstTranscription {
            self.hasCompletedFirstTranscription = true
            self.isLoadingModel = false
            self.modelPreparationPhase = nil
        }

        let cleanedText = ASRService.applySpokenPunctuationFormatting(
            ASRService.applyCustomDictionary(ASRService.removeFillerWords(result.text))
        )
        self.recordWordBoostHitIfAny(transcribedText: cleanedText)
        return (ASRTranscriptionResult(text: cleanedText, confidence: result.confidence), estimatedSamples)
    }

    func stopWithoutTranscription() async {
        if self.isStarting, self.isRunning == false {
            await self.cancelPendingAudioCaptureStart(reason: "stop_without_transcription")
        }
        guard self.isRunning else { return }
        defer {
            self.applyPendingParakeetVocabularyReloadIfNeeded()
            self.isDictionaryTrainingCaptureActive = false
        }

        await self.cancelAudioRouteRecoveryAndWait()

        // Capture media pause state before we reset it, for resuming at the end
        let shouldResumeMedia = self.didPauseMediaForThisSession
        self.didPauseMediaForThisSession = false // Reset for next session

        DebugLogger.shared.info("🛑 Stopping recording - releasing audio devices", source: "ASRService")

        // CRITICAL: Set isRunning to false FIRST to signal any in-flight chunks to abort early
        self.isRunning = false
        self.audioCapturePipeline.setRecordingEnabled(false)

        // Stop monitoring device
        self.stopMonitoringDevice()

        await self.stopActiveAudioCapture(
            retainDirectPreparedCapture: false,
            reason: "stop_without_transcription"
        )
        DebugLogger.shared.debug("Audio capture stopped", source: "ASRService")

        // Cancel/no-transcription paths stay conservative and retire the engine.
        await self.retireAudioEngineAndWait(reason: "stop_without_transcription")
        self.audioCaptureStateSettledTick &+= 1

        // CRITICAL FIX: Await completion of streaming task AND any pending transcriptions
        // This prevents use-after-free crashes (EXC_BAD_ACCESS) when clearing buffer
        await self.stopStreamingTimerAndAwait()

        // NOW it's safe to clear the buffer
        self.audioBuffer.clear()
        self.partialTranscription.removeAll()
        self.previousFullTranscription.removeAll()
        self.lastBoostHitTerm = nil
        self.lastProcessedSampleCount = 0
        self.isProcessingChunk = false
        self.skipNextChunk = false
        self.refreshWordBoostStatus()

        // Resume media playback if we paused it
        if shouldResumeMedia {
            await MediaPlaybackService.shared.resumeIfWePaused(true)
            DebugLogger.shared.info("🎵 Resumed system media after stopping without transcription", source: "ASRService")
        }
    }

    private func configureSession() throws {
        DebugLogger.shared.debug("🔧 configureSession() - ENTERED", source: "ASRService")

        let wasWarm = self.hasWarmAudioEngine
        let engine = self.engine
        DebugLogger.shared.debug(
            wasWarm ? "♻️ Reusing warm audio engine" : "ℹ️ Creating audio engine lazily",
            source: "ASRService"
        )

        if engine.isRunning {
            DebugLogger.shared.debug("⚠️ Engine is running, stopping before configuration", source: "ASRService")
            engine.stop()
            DebugLogger.shared.debug("✅ Engine stopped", source: "ASRService")
        }

        // Force input node instantiation (ensures the underlying AUHAL AudioUnit exists)
        DebugLogger.shared.debug("📍 Forcing input node instantiation...", source: "ASRService")
        _ = engine.inputNode
        DebugLogger.shared.debug("Input node instantiated", source: "ASRService")

        // Force output node instantiation for output device binding
        DebugLogger.shared.debug("📍 Forcing output node instantiation...", source: "ASRService")
        _ = engine.outputNode
        DebugLogger.shared.debug("✅ Output node instantiated", source: "ASRService")

        // NOTE: Device binding occurs in startEngine() BEFORE engine.prepare()
        // Per CoreAudio docs, device must be set before AudioUnit initialization (prepare)
        // Since sync mode is always ON, binding actually no-ops and uses system defaults

        DebugLogger.shared.debug("✅ configureSession() - COMPLETED", source: "ASRService")
    }

    /// In independent mode, attempt to bind AVAudioEngine's input to the user's preferred input device.
    /// In sync-with-system mode, we intentionally do nothing so the engine follows macOS defaults.
    /// Returns true if binding succeeded or if no binding was needed, false if binding failed completely.
    @discardableResult
    private func bindPreferredInputDeviceIfNeeded() -> Bool {
        DebugLogger.shared.debug("bindPreferredInputDeviceIfNeeded() - Starting input device binding", source: "ASRService")

        guard let device = self.resolvedInputDeviceForCapture() else {
            DebugLogger.shared.error(
                "No input device available for manual microphone capture.",
                source: "ASRService"
            )
            return false
        }

        DebugLogger.shared.debug(
            "Attempting to bind AVAudioEngine input to capture device '\(device.name)' (uid: \(device.uid))",
            source: "ASRService"
        )

        let ok = self.setEngineInputDevice(deviceID: device.id, deviceUID: device.uid, deviceName: device.name)
        if ok == false {
            DebugLogger.shared.warning(
                "Failed to bind engine input to '\(device.name)' (uid: \(device.uid)). Trying system default input.",
                source: "ASRService"
            )
            return self.tryBindToSystemDefaultInput()
        }

        DebugLogger.shared.info("✅ Bound AVAudioEngine input to '\(device.name)'", source: "ASRService")
        return true
    }

    /// In independent mode, attempt to bind AVAudioEngine's output to the user's preferred output device.
    /// In sync-with-system mode, we intentionally do nothing so the engine follows macOS defaults.
    /// Returns true if binding succeeded or if no binding was needed, false if binding failed completely.
    @discardableResult
    private func bindPreferredOutputDeviceIfNeeded() -> Bool {
        DebugLogger.shared.debug("bindPreferredOutputDeviceIfNeeded() - Starting output device binding", source: "ASRService")

        DebugLogger.shared.info("Using current macOS default output device", source: "ASRService")
        return true
    }

    /// Attempts to bind to the system default input device as a fallback.
    /// Returns true if binding succeeded, false otherwise.
    private func tryBindToSystemDefaultInput() -> Bool {
        guard let defaultDevice = AudioDevice.getDefaultInputDevice() else {
            DebugLogger.shared.error(
                "No system default input device available. Cannot start audio capture.",
                source: "ASRService"
            )
            return false
        }

        DebugLogger.shared.info(
            "Attempting to bind to system default input: '\(defaultDevice.name)' (uid: \(defaultDevice.uid))",
            source: "ASRService"
        )

        let ok = self.setEngineInputDevice(
            deviceID: defaultDevice.id,
            deviceUID: defaultDevice.uid,
            deviceName: defaultDevice.name
        )

        if !ok {
            DebugLogger.shared.error(
                "Failed to bind to system default input device '\(defaultDevice.name)'. Audio capture cannot proceed.",
                source: "ASRService"
            )
        }

        return ok
    }

    /// Attempts to bind to the system default output device as a fallback.
    /// Returns true if binding succeeded, false otherwise.
    private func tryBindToSystemDefaultOutput() -> Bool {
        DebugLogger.shared.debug("tryBindToSystemDefaultOutput() - Starting", source: "ASRService")

        guard let defaultDevice = AudioDevice.getDefaultOutputDevice() else {
            DebugLogger.shared.error(
                "No system default output device available. Cannot bind output.",
                source: "ASRService"
            )
            return false
        }

        DebugLogger.shared.info(
            "Attempting to bind to system default output: '\(defaultDevice.name)' (uid: \(defaultDevice.uid))",
            source: "ASRService"
        )

        let ok = self.setEngineOutputDevice(
            deviceID: defaultDevice.id,
            deviceUID: defaultDevice.uid,
            deviceName: defaultDevice.name
        )

        if !ok {
            DebugLogger.shared.error(
                "Failed to bind to system default output device '\(defaultDevice.name)'. Audio playback may not work correctly.",
                source: "ASRService"
            )
        }

        return ok
    }

    /// Selects a specific CoreAudio device for AVAudioEngine's input node without changing system defaults.
    /// This uses the AUHAL AudioUnit backing `engine.inputNode` on macOS.
    @discardableResult
    private func setEngineInputDevice(deviceID: AudioObjectID, deviceUID: String, deviceName: String) -> Bool {
        DebugLogger.shared.debug("setEngineInputDevice() - Binding input to device ID: \(deviceID)", source: "ASRService")
        AppServices.shared.microphonePreferenceCoordinator.reportResolvedSelection(
            uid: deviceUID,
            name: deviceName
        )

        let inputNode = self.engine.inputNode

        // `AVAudioInputNode` is backed by an AudioUnit on macOS. Setting this property selects
        // which physical device the node captures from.
        guard let audioUnit = inputNode.audioUnit else {
            DebugLogger.shared.error(
                "Unable to access AudioUnit for AVAudioEngine.inputNode; cannot bind to '\(deviceName)' (uid: \(deviceUID))",
                source: "ASRService"
            )
            return false
        }

        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )

        if status != noErr {
            // OSStatus -10851 (kAudioUnitErr_InvalidPropertyValue) occurs for aggregate devices (Bluetooth, etc.)
            // This is expected for certain device types - not a fatal error
            if status == -10_851 {
                DebugLogger.shared.warning(
                    "Cannot bind INPUT to '\(deviceName)' - likely an aggregate device (OSStatus: \(status)). Will use system default.",
                    source: "ASRService"
                )
            } else {
                DebugLogger.shared.error(
                    "AudioUnitSetProperty(CurrentDevice) failed for INPUT '\(deviceName)' (uid: \(deviceUID), id: \(deviceID)) with OSStatus: \(status)",
                    source: "ASRService"
                )
            }
            return false
        }

        DebugLogger.shared.info("✅ Bound ASR input to '\(deviceName)' (uid: \(deviceUID), id: \(deviceID))", source: "ASRService")
        return true
    }

    /// Selects a specific CoreAudio device for AVAudioEngine's output node without changing system defaults.
    /// This uses the AUHAL AudioUnit backing `engine.outputNode` on macOS.
    @discardableResult
    private func setEngineOutputDevice(deviceID: AudioObjectID, deviceUID: String, deviceName: String) -> Bool {
        DebugLogger.shared.debug("setEngineOutputDevice() - Binding output to device ID: \(deviceID)", source: "ASRService")

        let outputNode = self.engine.outputNode

        // `AVAudioOutputNode` is backed by an AudioUnit on macOS. Setting this property selects
        // which physical device the node outputs to.
        guard let audioUnit = outputNode.audioUnit else {
            DebugLogger.shared.error(
                "Unable to access AudioUnit for AVAudioEngine.outputNode; cannot bind to '\(deviceName)' (uid: \(deviceUID))",
                source: "ASRService"
            )
            return false
        }

        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )

        if status != noErr {
            // OSStatus -10851 (kAudioUnitErr_InvalidPropertyValue) occurs for aggregate devices (Bluetooth, etc.)
            // This is expected for certain device types - not a fatal error
            if status == -10_851 {
                DebugLogger.shared.warning(
                    "Cannot bind OUTPUT to '\(deviceName)' - likely an aggregate device (OSStatus: \(status)). Will use system default.",
                    source: "ASRService"
                )
            } else {
                DebugLogger.shared.error(
                    "AudioUnitSetProperty(CurrentDevice) failed for OUTPUT '\(deviceName)' (uid: \(deviceUID), id: \(deviceID)) with OSStatus: \(status)",
                    source: "ASRService"
                )
            }
            return false
        }

        DebugLogger.shared.info("✅ Bound ASR output to '\(deviceName)' (uid: \(deviceUID), id: \(deviceID))", source: "ASRService")
        return true
    }

    /// Explicitly unbinds the input device from AVAudioEngine's AudioUnit
    /// This is CRITICAL for releasing Bluetooth devices so macOS can switch back to high-quality A2DP mode
    private func unbindInputDevice() {
        DebugLogger.shared.debug("unbindInputDevice() - Releasing input device binding to restore Bluetooth quality", source: "ASRService")

        guard let audioUnit = self.engine.inputNode.audioUnit else {
            DebugLogger.shared.warning("No AudioUnit for input node - cannot unbind device", source: "ASRService")
            return
        }

        // Set device to kAudioObjectUnknown (0) to explicitly release the device binding
        var unknownDevice = AudioObjectID(kAudioObjectUnknown)
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &unknownDevice,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )

        if status == noErr {
            DebugLogger.shared.info("✅ Input device unbound - Bluetooth can now return to high-quality mode", source: "ASRService")
        } else {
            DebugLogger.shared.error("❌ Failed to unbind input device: OSStatus \(status)", source: "ASRService")
        }
    }

    /// Explicitly unbinds the output device from AVAudioEngine's AudioUnit
    /// This ensures complete release of audio device resources
    private func unbindOutputDevice() {
        DebugLogger.shared.debug("unbindOutputDevice() - Releasing output device binding", source: "ASRService")

        guard let audioUnit = self.engine.outputNode.audioUnit else {
            DebugLogger.shared.warning("No AudioUnit for output node - cannot unbind device", source: "ASRService")
            return
        }

        // Set device to kAudioObjectUnknown (0) to explicitly release the device binding
        var unknownDevice = AudioObjectID(kAudioObjectUnknown)
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &unknownDevice,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )

        if status == noErr {
            DebugLogger.shared.info("✅ Output device unbound - Audio device fully released", source: "ASRService")
        } else {
            DebugLogger.shared.error("❌ Failed to unbind output device: OSStatus \(status)", source: "ASRService")
        }
    }

    private func startEngine() async throws {
        DebugLogger.shared.debug("🚀 startEngine() - ENTERED", source: "ASRService")
        var attempts = 0
        var lastError: Error?

        while attempts < 3 {
            do {
                // CRITICAL: Bind devices BEFORE prepare() - must be set before AudioUnit initialization
                // Note: This may fail for aggregate devices (Bluetooth, etc.) with OSStatus -10851
                // In that case, we fall back to system defaults (same as sync mode)
                DebugLogger.shared.debug("🎚️ Binding input device (before prepare)...", source: "ASRService")
                let inputBindOk = self.bindPreferredInputDeviceIfNeeded()
                DebugLogger.shared.debug("✅ Input device binding result: \(inputBindOk)", source: "ASRService")

                DebugLogger.shared.debug("🔊 Binding output device (before prepare)...", source: "ASRService")
                let outputBindOk = self.bindPreferredOutputDeviceIfNeeded()
                DebugLogger.shared.debug("✅ Output device binding result: \(outputBindOk)", source: "ASRService")

                // If binding failed (e.g., aggregate device), engine will use system defaults
                if !inputBindOk || !outputBindOk {
                    DebugLogger.shared.info(
                        "⚠️ Device binding failed (likely aggregate device). Engine will use system default devices.",
                        source: "ASRService"
                    )
                }

                // Prepare the engine to allocate resources and establish format SYNCHRONOUSLY
                // This ensures the audio graph is fully initialized before we proceed
                DebugLogger.shared.debug("📋 Preparing engine (allocating resources)...", source: "ASRService")
                self.engine.prepare()
                DebugLogger.shared.debug("✅ Engine prepared", source: "ASRService")

                // Log engine state before attempting to start
                let inputNode = self.engine.inputNode
                let inputFormat = inputNode.inputFormat(forBus: 0)
                DebugLogger.shared.debug(
                    "(startEngine(): before engine.start attempt \(attempts + 1)) " +
                        "Engine IO device = \(inputNode.outputFormat(forBus: 0).sampleRate)Hz, " +
                        "Input format = \(inputFormat.sampleRate)Hz \(inputFormat.channelCount)ch",
                    source: "ASRService"
                )

                try self.engine.start()
                DebugLogger.shared.info("AVAudioEngine started successfully on attempt \(attempts + 1)", source: "ASRService")
                return
            } catch {
                lastError = error
                attempts += 1

                // Log the actual error from AVFoundation
                DebugLogger.shared.error(
                    "AVAudioEngine start failed (attempt \(attempts)/3): \(error.localizedDescription) " +
                        "[Domain: \((error as NSError).domain), Code: \((error as NSError).code)]",
                    source: "ASRService"
                )

                // If this isn't the last attempt, recreate engine and reconfigure
                if attempts < 3 {
                    DebugLogger.shared.debug("⚠️ Start failed, recreating engine for retry...", source: "ASRService")
                    await self.retireAudioEngineAndWait(reason: "start_retry")
                    // Need to reconfigure the new engine
                    try? self.configureSession()
                    DebugLogger.shared.debug("✅ Engine recreated and reconfigured, will retry", source: "ASRService")
                }
            }
        }

        // All retries failed - throw the actual error with context
        let errorMessage = "Failed to start AVAudioEngine after 3 attempts. Last error: \(lastError?.localizedDescription ?? "unknown")"
        DebugLogger.shared.error(errorMessage, source: "ASRService")

        // If we have a last error, wrap it with more context; otherwise create a new error
        if let lastError = lastError {
            throw NSError(
                domain: "ASRService",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: errorMessage,
                    NSUnderlyingErrorKey: lastError,
                ]
            )
        } else {
            throw NSError(domain: "ASRService", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }
    }

    private func removeEngineTap() {
        guard self.isEngineTapInstalled else { return }
        if let engine = self.engineStorage as? AVAudioEngine {
            engine.inputNode.removeTap(onBus: 0)
        }
        self.isEngineTapInstalled = false
    }

    private func setupEngineTap() throws {
        DebugLogger.shared.debug("🎧 setupEngineTap() - ENTERED", source: "ASRService")
        let input = self.engine.inputNode

        // On Intel Macs (especially after wake from sleep), the audio HAL may not have
        // finished initializing even after engine.start() returns. The format can be
        // temporarily 0Hz/0ch while the hardware negotiates with CoreAudio.
        // We retry a few times with small delays to handle this race condition.
        var inFormat = input.inputFormat(forBus: 0)
        var retryCount = 0
        let maxRetries = 5
        let retryDelayMs: UInt32 = 100_000 // 100ms in microseconds

        while inFormat.sampleRate == 0 || inFormat.channelCount == 0 {
            retryCount += 1
            if retryCount > maxRetries {
                DebugLogger.shared.error(
                    "❌ INVALID INPUT FORMAT after \(maxRetries) retries: \(inFormat.sampleRate)Hz \(inFormat.channelCount)ch - Cannot install tap!",
                    source: "ASRService"
                )
                throw NSError(
                    domain: "ASRService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Audio input format is invalid (\(inFormat.sampleRate)Hz, \(inFormat.channelCount)ch). The microphone may still be initializing after wake from sleep. Please try again in a few seconds."]
                )
            }

            DebugLogger.shared.warning(
                "⏳ Input format not ready (attempt \(retryCount)/\(maxRetries)): \(inFormat.sampleRate)Hz \(inFormat.channelCount)ch - waiting 100ms...",
                source: "ASRService"
            )

            // Small synchronous delay to let HAL initialize
            // Using usleep since we're on MainActor and need to block briefly
            usleep(retryDelayMs)

            // Re-query the format
            inFormat = input.inputFormat(forBus: 0)
        }

        if retryCount > 0 {
            DebugLogger.shared.info(
                "✅ Input format became valid after \(retryCount) retries: \(inFormat.sampleRate)Hz \(inFormat.channelCount)ch",
                source: "ASRService"
            )
        }

        DebugLogger.shared.debug(
            "✅ Valid input format: \(inFormat.sampleRate)Hz \(inFormat.channelCount)ch",
            source: "ASRService"
        )

        self.inputFormat = inFormat
        let pipeline = self.audioCapturePipeline
        if self.isEngineTapInstalled {
            input.removeTap(onBus: 0)
            self.isEngineTapInstalled = false
        }
        DebugLogger.shared.debug("🎧 Installing tap on bus 0...", source: "ASRService")
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, time in
            pipeline.handle(buffer: buffer, time: time)
        }
        self.isEngineTapInstalled = true
        DebugLogger.shared.debug("✅ setupEngineTap() - COMPLETED", source: "ASRService")
    }

    private func scheduleAudioRouteRecovery(
        reason: String,
        requiresIdlePrewarm: Bool = false,
        reconcilesInputSelection: Bool = false,
        invalidatesCurrentStart: Bool = false
    ) {
        guard self.isTerminating == false else {
            self.benchmarkLog("route_recovery_ignored reason=app_terminating event=\(reason)")
            return
        }
        if AudioCaptureIdlePolicy.shouldDeferRouteRecoveryToBluetoothStart(
            directCaptureEnabled: SettingsStore.shared.experimentalDirectAudioCaptureEnabled,
            isStarting: self.isStarting,
            isRunning: self.isRunning,
            attemptedInputIsBluetooth: self.audioStartAttemptIsBluetooth
        ) {
            // AirPods and other Bluetooth inputs can replace their streams more
            // than once while entering microphone mode. The active start owns
            // its bounded retry loop; a second recovery owner would exclude the
            // same healthy device before the Bluetooth route settles.
            let disposition = AudioCaptureIdlePolicy.bluetoothStartupRouteChangeDisposition(
                invalidatesCurrentStart: invalidatesCurrentStart,
                requiresIdlePrewarm: requiresIdlePrewarm,
                reconcilesInputSelection: reconcilesInputSelection
            )
            if disposition == .retryCurrentStart {
                // Make routeStayedStable false even if first PCM won the
                // readiness-gate race. The startup loop then retries the same
                // Bluetooth input without handing it to active-route recovery.
                self.audioRouteRecoveryGeneration &+= 1
                self.benchmarkLog(
                    "bluetooth_start_route_invalidation_retry event=\(reason) " +
                        "routeGeneration=\(self.audioRouteRecoveryGeneration)"
                )
                return
            }
            if disposition == .preserveDeferredWork {
                self.deferredBluetoothStartupRouteRecovery.preserve(
                    reason: reason,
                    requiresIdlePrewarm: requiresIdlePrewarm,
                    reconcilesInputSelection: reconcilesInputSelection
                )
            }
            self.benchmarkLog(
                "bluetooth_start_route_change_deferred event=\(reason) " +
                    "disposition=\(disposition)"
            )
            return
        }
        self.audioRouteRecoveryGeneration &+= 1
        let requiresPrewarmAfterRecovery =
            requiresIdlePrewarm || self.pendingAudioRouteRecovery?.requiresIdlePrewarm == true
        let reconcilesInputAfterRecovery =
            reconcilesInputSelection || self.pendingAudioRouteRecovery?.reconcilesInputSelection == true
        let request = AudioRouteRecoveryRequest(
            generation: self.audioRouteRecoveryGeneration,
            reason: reason,
            requiresIdlePrewarm: requiresPrewarmAfterRecovery,
            reconcilesInputSelection: reconcilesInputAfterRecovery
        )
        self.pendingAudioRouteRecovery = request

        self.audioLevelSubject.send(0.0)
        if self.isRunning || self.isStarting {
            // Stop accepting samples immediately, but do not touch AVAudioEngine
            // until Core Audio has been quiet for the debounce interval.
            self.audioCapturePipeline.setRecordingEnabled(false)
            DebugLogger.shared.warning(
                "Audio route changed during capture; waiting for topology quiet " +
                    "(\(reason), generation=\(request.generation), " +
                    "isStarting=\(self.isStarting), isRunning=\(self.isRunning))",
                source: "ASRService"
            )
        } else {
            DebugLogger.shared.debug(
                "Audio route changed while idle; waiting for topology quiet (\(reason), generation=\(request.generation))",
                source: "ASRService"
            )
        }

        self.audioRouteRecoveryTask?.cancel()
        guard self.isRecoveringAudioRoute == false else {
            // The in-flight recovery observes cancellation after its awaited
            // retirement barrier, then arms the latest generation.
            return
        }

        self.armAudioRouteRecovery(request)
    }

    private func armAudioRouteRecovery(_ request: AudioRouteRecoveryRequest) {
        let recoveryDelayNanoseconds = self.audioRouteRecoveryDelayNanoseconds
        self.audioRouteRecoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: recoveryDelayNanoseconds)
            } catch {
                return
            }
            await self?.performAudioRouteRecovery(request)
        }
    }

    /// Cancels a sleeping or active recovery and waits until any detached engine
    /// release has drained. Start/stop paths use this to avoid racing a route
    /// rebuild that yielded while AVAudioEngine was deallocating.
    private func cancelAudioRouteRecoveryAndWait() async {
        self.audioRouteRecoveryGeneration &+= 1
        self.pendingAudioRouteRecovery = nil
        let task = self.audioRouteRecoveryTask
        task?.cancel()
        _ = await task?.result
        self.audioRouteRecoveryTask = nil
        self.isRecoveringAudioRoute = false
        await self.audioEngineRetirementDrain.waitForScheduledReleases()
    }

    /// Recording startup must let an already-scheduled route rebuild finish.
    /// Cancelling it here can preserve the stale prepared generation that the
    /// route event was meant to retire.
    private func waitForPendingAudioRouteRecoveryBeforeStart() async {
        let startedAt = Date().timeIntervalSince1970
        var waitedGenerations: [UInt64] = []
        while let task = self.audioRouteRecoveryTask {
            let generation = self.audioRouteRecoveryGeneration
            waitedGenerations.append(generation)
            self.benchmarkLog("route_recovery_handoff_wait generation=\(generation)")
            _ = await task.result
            if self.pendingAudioRouteRecovery == nil,
               self.isRecoveringAudioRoute == false
            {
                self.audioRouteRecoveryTask = nil
                break
            }
        }
        await self.audioEngineRetirementDrain.waitForScheduledReleases()
        self.benchmarkLog(
            "route_recovery_handoff_end generations=\(waitedGenerations) " +
                "elapsedMs=\(self.elapsedMilliseconds(since: startedAt)) " +
                "capturePhase=\(self.directAudioLifecycleController.snapshot.phase.rawValue)"
        )
    }

    private func performAudioRouteRecovery(_ request: AudioRouteRecoveryRequest) async {
        guard self.isTerminating == false,
              request.generation == self.audioRouteRecoveryGeneration,
              Task.isCancelled == false
        else { return }
        guard self.isRecoveringAudioRoute == false else { return }

        self.isRecoveringAudioRoute = true
        defer {
            self.finishAudioRouteRecovery(request)
        }

        if request.reconcilesInputSelection,
           await self.reconcileInputSelectionAfterTopologySettles(request) == false
        {
            return
        }

        if self.isRunning {
            await self.recoverActiveAudioRoute(request)
        } else {
            await self.recoverIdleAudioRoute(request)
        }
    }

    private func finishAudioRouteRecovery(_ completedRequest: AudioRouteRecoveryRequest) {
        self.isRecoveringAudioRoute = false

        guard let pendingRequest = self.pendingAudioRouteRecovery else {
            self.audioRouteRecoveryTask = nil
            return
        }
        guard pendingRequest.generation != completedRequest.generation else {
            self.pendingAudioRouteRecovery = nil
            self.audioRouteRecoveryTask = nil
            return
        }

        self.armAudioRouteRecovery(pendingRequest)
    }

    private func reconcileInputSelectionAfterTopologySettles(
        _ request: AudioRouteRecoveryRequest
    ) async -> Bool {
        let snapshot = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let devices = AudioDevice.listInputDevicesRefreshingLiveness()
                let defaultInputUID = AudioDevice.getDefaultInputDevice()?.uid
                continuation.resume(returning: (devices, defaultInputUID))
            }
        }
        guard request.generation == self.audioRouteRecoveryGeneration,
              Task.isCancelled == false
        else { return false }

        let currentUIDs = Set(snapshot.0.map(\.uid))
        guard currentUIDs == self.cachedDeviceUIDs else {
            self.cacheCurrentDeviceList(snapshot.0)
            self.scheduleAudioRouteRecovery(
                reason: "input topology still settling",
                requiresIdlePrewarm: request.requiresIdlePrewarm,
                reconcilesInputSelection: true
            )
            return false
        }

        AppServices.shared.microphonePreferenceCoordinator.reconcileMicrophoneSelection(
            availableInputs: snapshot.0,
            defaultInputUID: snapshot.1
        )
        return true
    }

    private func recoverIdleAudioRoute(_ request: AudioRouteRecoveryRequest) async {
        let shouldRebuild = self.hasPreparedAudioCapture || request.requiresIdlePrewarm
        guard shouldRebuild else { return }
        let shouldRestoreMicrophonePreview = self.isMicrophonePreviewRequested
        let microphonePreviewGeneration = self.microphonePreviewOperationGeneration

        // If another event arrives while retirement is draining, the next
        // generation still needs to restore the prepared capture backend.
        self.pendingAudioRouteRecovery = AudioRouteRecoveryRequest(
            generation: request.generation,
            reason: request.reason,
            requiresIdlePrewarm: true,
            reconcilesInputSelection: request.reconcilesInputSelection
        )
        await self.directAudioLifecycleController.invalidate(
            reason: "idle_route_change:\(request.reason)"
        )
        await self.retireAudioEngineAndWait(reason: "idle_route_change:\(request.reason)")

        guard request.generation == self.audioRouteRecoveryGeneration, Task.isCancelled == false else { return }
        if shouldRestoreMicrophonePreview,
           self.isMicrophonePreviewRequested,
           microphonePreviewGeneration == self.microphonePreviewOperationGeneration
        {
            await self.startMicrophonePreview()
        } else {
            await self.prewarmConfiguredAudioCaptureIfPossible(
                reason: "idle_route_change",
                allowDuringRouteRecovery: true
            )
        }
    }

    private func recoverActiveAudioRoute(_ request: AudioRouteRecoveryRequest) async {
        guard self.isRunning else { return }

        DebugLogger.shared.info(
            "Recovering audio route after \(request.reason) (generation=\(request.generation))",
            source: "ASRService"
        )
        self.audioCapturePipeline.setRecordingEnabled(false)
        self.stopMonitoringDevice()
        await self.stopActiveAudioCapture(
            retainDirectPreparedCapture: false,
            reason: "active_route_recovery"
        )
        await self.retireAudioEngineAndWait(reason: "audio_route_recovery")

        guard request.generation == self.audioRouteRecoveryGeneration, Task.isCancelled == false else { return }

        do {
            let maximumAttempts = SettingsStore.shared.experimentalDirectAudioCaptureEnabled
                ? max(AudioDevice.listInputDevices().count, 1) + 1
                : 1
            var failedInputUIDs = Set<String>()
            var immediatelyRetriedInputUID: String?
            var completedAttempts = 0

            while completedAttempts < maximumAttempts {
                completedAttempts += 1
                self.audioCaptureAttemptID &+= 1
                let readinessAttemptID = self.audioCaptureAttemptID
                self.audioCaptureReadinessGate.arm(
                    sessionID: self.benchmarkSessionID,
                    attemptID: readinessAttemptID
                )
                self.audioCapturePipeline.setRecordingEnabled(
                    true,
                    sessionID: self.benchmarkSessionID,
                    attemptID: readinessAttemptID,
                    startHostTime: mach_absolute_time()
                )

                do {
                    try await self.startConfiguredAudioCapture(excluding: failedInputUIDs)
                } catch {
                    if let failedUID = self.audioStartAttemptInputUID {
                        let retrySameInput = immediatelyRetriedInputUID == nil
                        if retrySameInput {
                            immediatelyRetriedInputUID = failedUID
                        }
                        if retrySameInput == false {
                            failedInputUIDs.insert(failedUID)
                        }
                    }
                    guard completedAttempts < maximumAttempts else { throw error }
                    self.audioCapturePipeline.setRecordingEnabled(false)
                    await self.stopActiveAudioCapture(
                        retainDirectPreparedCapture: false,
                        reason: "active_route_recovery_start_retry"
                    )
                    continue
                }

                guard request.generation == self.audioRouteRecoveryGeneration,
                      Task.isCancelled == false
                else {
                    self.audioCapturePipeline.setRecordingEnabled(false)
                    await self.stopActiveAudioCapture(
                        retainDirectPreparedCapture: false,
                        reason: "superseded_route_recovery_start"
                    )
                    return
                }
                let readiness = await self.audioCaptureReadinessGate.wait(
                    sessionID: self.benchmarkSessionID,
                    attemptID: readinessAttemptID,
                    timeoutNanoseconds: self.firstPCMTimeoutNanoseconds
                )
                guard request.generation == self.audioRouteRecoveryGeneration,
                      Task.isCancelled == false
                else {
                    self.audioCapturePipeline.setRecordingEnabled(false)
                    await self.stopActiveAudioCapture(
                        retainDirectPreparedCapture: false,
                        reason: "superseded_route_recovery_readiness"
                    )
                    return
                }
                if readiness == .ready {
                    AppServices.shared.microphonePreferenceCoordinator.confirmActiveSelection(
                        uid: self.audioStartAttemptInputUID,
                        name: self.audioStartAttemptInputName
                    )
                    self.benchmarkLog(
                        "route_recovery_first_pcm generation=\(request.generation) " +
                            "attempt=\(completedAttempts) attemptID=\(readinessAttemptID) " +
                            "bufferedSamples=\(self.audioBuffer.count)"
                    )

                    if self.activeAudioCaptureBackend == .audioEngine,
                       let currentDevice = self.getCurrentlyBoundInputDevice()
                    {
                        self.startMonitoringDevice(currentDevice.id)
                    }

                    DebugLogger.shared.info(
                        "Audio route recovery succeeded (generation=\(request.generation), " +
                            "attempt=\(completedAttempts))",
                        source: "ASRService"
                    )
                    return
                }

                if let failedUID = self.audioStartAttemptInputUID {
                    let retrySameInput = readiness == .formatInvalidated &&
                        immediatelyRetriedInputUID == nil
                    if retrySameInput {
                        immediatelyRetriedInputUID = failedUID
                    }
                    if retrySameInput == false {
                        failedInputUIDs.insert(failedUID)
                    }
                }
                guard completedAttempts < maximumAttempts else {
                    throw NSError(
                        domain: "ASRService",
                        code: -3,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "No replacement microphone delivered audio (\(readiness)).",
                        ]
                    )
                }
                self.audioCapturePipeline.setRecordingEnabled(false)
                await self.stopActiveAudioCapture(
                    retainDirectPreparedCapture: false,
                    reason: "active_route_recovery_readiness_retry"
                )
            }
            throw NSError(
                domain: "ASRService",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "No replacement microphone is available."]
            )
        } catch {
            guard request.generation == self.audioRouteRecoveryGeneration, Task.isCancelled == false else { return }
            self.audioCapturePipeline.setRecordingEnabled(false)
            await self.stopActiveAudioCapture(
                retainDirectPreparedCapture: false,
                reason: "active_route_recovery_failed"
            )
            DebugLogger.shared.error("Audio route recovery failed: \(error)", source: "ASRService")
            AppServices.shared.microphonePreferenceCoordinator.markActiveSelectionUnavailable()

            // Avoid asking stopWithoutTranscription() to await the recovery task
            // that is currently executing this catch block.
            self.audioRouteRecoveryTask = nil
            await self.stopWithoutTranscription()
            NotificationCenter.default.post(
                name: NSNotification.Name("ASRServiceDeviceDisconnected"),
                object: nil,
                userInfo: ["errorMessage": "Recording stopped because the audio device changed."]
            )
        }
    }

    private func handleDirectCaptureFormatInvalidation(
        _ invalidation: DirectCoreAudioLifecycleController.FormatInvalidation
    ) async {
        let captureSnapshot = self.directAudioLifecycleController.snapshot
        guard invalidation.generation == captureSnapshot.generation else {
            self.benchmarkLog(
                "direct_format_invalidation_ignored staleGeneration=\(invalidation.generation) " +
                    "currentGeneration=\(captureSnapshot.generation) property=\(invalidation.reason)"
            )
            return
        }
        let sessionID = self.benchmarkSessionID
        self.audioCapturePipeline.setRecordingEnabled(false)
        if self.isStarting, self.isRunning == false {
            await self.audioCaptureReadinessGate.signalFormatInvalidation(
                sessionID: sessionID,
                attemptID: self.audioCaptureAttemptID
            )
        }
        self.benchmarkLog(
            "direct_format_invalidation generation=\(invalidation.generation) " +
                "device=\(invalidation.deviceID) property=\(invalidation.reason) " +
                "wasRunning=\(invalidation.wasRunning) isStarting=\(self.isStarting)"
        )
        AppServices.shared.audioObserver.signalInputAvailabilityChanged()
        if invalidation.reason == "audio_service_restarted" {
            self.reestablishAudioHardwareListenersAfterServiceReset()
            AppServices.shared.audioObserver.restartObservingAfterAudioServiceReset()
        }
        DebugLogger.shared.warning(
            "Direct capture generation \(invalidation.generation) invalidated by " +
                "\(invalidation.reason); scheduling serialized route recovery",
            source: "ASRService"
        )
        self.scheduleAudioRouteRecovery(
            reason: "direct format changed: \(invalidation.reason)",
            requiresIdlePrewarm: true,
            invalidatesCurrentStart: true
        )
    }

    private func handleDefaultInputChanged() {
        // Microphone priority is app-owned. A macOS default-input change must
        // never move or restart FluidVoice's selected microphone.
    }

    private func handleDefaultOutputChanged() {
        // Input-only direct capture has no output device dependency.
        if self.directAudioLifecycleController.snapshot.isPrepared {
            return
        }

        self.scheduleAudioRouteRecovery(reason: "default output changed")
    }

    private func handleEngineConfigurationChanged(_ changedEngineIdentifier: ObjectIdentifier) {
        guard let currentEngine = self.engineStorage as? AVAudioEngine,
              ObjectIdentifier(currentEngine) == changedEngineIdentifier
        else { return }
        guard AudioCaptureIdlePolicy.shouldRecoverEngineConfigurationChange(
            isRunning: self.isRunning,
            isStarting: self.isStarting
        ) else {
            DebugLogger.shared.debug(
                "Ignoring AVAudioEngine configuration change while capture is idle",
                source: "ASRService"
            )
            return
        }

        self.scheduleAudioRouteRecovery(reason: "engine configuration changed")
    }

    private func registerEngineConfigurationChangeObserver() {
        guard self.engineConfigurationChangeObserver == nil else { return }

        // queue: nil (synchronous delivery on the posting thread) is load-bearing:
        // AVAudioEngine posts this notification from its internal serial queue, and
        // NotificationCenter blocks a post until queued observers finish. With
        // queue: .main that wait can never end when the main thread is itself
        // blocked on the engine's queue (dealloc/stop during retirement) — a
        // permanent deadlock (#542). The body only hops to the main actor, which
        // is safe from any thread.
        self.engineConfigurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let changedEngine = notification.object as? AVAudioEngine else { return }
            let changedEngineIdentifier = ObjectIdentifier(changedEngine)
            Task { @MainActor [weak self] in
                self?.handleEngineConfigurationChanged(changedEngineIdentifier)
            }
        }
    }

    private var defaultInputListenerInstalled = false
    private var defaultInputListenerToken: AudioObjectPropertyListenerBlock?
    private var defaultOutputListenerToken: AudioObjectPropertyListenerBlock?

    private func reestablishAudioHardwareListenersAfterServiceReset() {
        // The reset invalidates these registrations in HAL; do not attempt to
        // remove the stale tokens before installing replacements.
        self.defaultInputListenerInstalled = false
        self.defaultInputListenerToken = nil
        self.defaultOutputListenerToken = nil
        self.deviceListListenerInstalled = false
        self.deviceListListenerToken = nil
        self.monitoredDeviceID = nil
        self.monitoredDeviceIsAliveListenerToken = nil
        self.registerDefaultDeviceChangeListener()
        self.registerDeviceListChangeListener()
        let defaultInputReady = self.defaultInputListenerInstalled
        let defaultOutputReady = self.defaultOutputListenerToken != nil
        let deviceListReady = self.deviceListListenerInstalled
        self.benchmarkLog(
            "audio_service_restart listeners_reestablished " +
                "defaultInput=\(defaultInputReady) defaultOutput=\(defaultOutputReady) " +
                "deviceList=\(deviceListReady)"
        )
        let logMessage =
            "ASR hardware listeners after Core Audio service reset: " +
            "defaultInput=\(defaultInputReady), defaultOutput=\(defaultOutputReady), " +
            "deviceList=\(deviceListReady)"
        if defaultInputReady, defaultOutputReady, deviceListReady {
            DebugLogger.shared.warning(
                "Re-registered \(logMessage)",
                source: "ASRService"
            )
        } else {
            DebugLogger.shared.error(
                "Failed to fully re-register \(logMessage)",
                source: "ASRService"
            )
        }
    }

    private func registerDefaultDeviceChangeListener() {
        guard self.defaultInputListenerInstalled == false || self.defaultOutputListenerToken == nil else { return }
        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var outputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        if self.defaultInputListenerInstalled == false {
            let inputToken: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                // Defer to next runloop pass — CoreAudio may hold an internal lock during
                // this callback, and our handler makes synchronous CoreAudio queries that
                // would deadlock waiting for the same lock.
                DispatchQueue.main.async { self?.handleDefaultInputChanged() }
            }
            let inputStatus = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &inputAddress,
                DispatchQueue.main,
                inputToken
            )

            if inputStatus == noErr {
                self.defaultInputListenerInstalled = true
                self.defaultInputListenerToken = inputToken
            } else {
                self.defaultInputListenerToken = nil
                DebugLogger.shared.error("Failed to register default input listener: \(inputStatus)", source: "ASRService")
            }
        }

        if self.defaultOutputListenerToken == nil {
            let outputToken: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                DispatchQueue.main.async { self?.handleDefaultOutputChanged() }
            }
            let outputStatus = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &outputAddress,
                DispatchQueue.main,
                outputToken
            )

            if outputStatus == noErr {
                self.defaultOutputListenerToken = outputToken
            } else {
                self.defaultOutputListenerToken = nil
                DebugLogger.shared.warning("Failed to register default output listener: \(outputStatus)", source: "ASRService")
            }
        }
    }

    // MARK: - Device Monitoring (Bluetooth Auto-Switch & Disconnect Handling)

    private var deviceListListenerInstalled = false
    private var deviceListListenerToken: AudioObjectPropertyListenerBlock?
    private var monitoredDeviceID: AudioObjectID?
    private var monitoredDeviceIsAliveListenerToken: AudioObjectPropertyListenerBlock?

    /// Registers a listener for device list changes (additions/removals)
    /// This enables auto-switching to newly connected devices (especially Bluetooth)
    private func registerDeviceListChangeListener() {
        guard self.deviceListListenerInstalled == false else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let token: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Defer to next runloop pass — CoreAudio may hold an internal lock during
            // this callback, and our handler makes synchronous CoreAudio queries that
            // would deadlock waiting for the same lock.
            DispatchQueue.main.async { self?.handleDeviceListChanged() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            token
        )

        if status == noErr {
            self.deviceListListenerInstalled = true
            self.deviceListListenerToken = token
            DebugLogger.shared.debug("Device list change listener registered", source: "ASRService")
        } else {
            self.deviceListListenerToken = nil
            DebugLogger.shared.error("Failed to register device list listener: \(status)", source: "ASRService")
        }
    }

    /// Monitors a specific device for availability (DeviceIsAlive property)
    /// Used to detect when preferred device disconnects
    private func startMonitoringDevice(_ deviceID: AudioObjectID) {
        // Unregister previous device if any
        self.stopMonitoringDevice()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let token: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.handleDeviceAvailabilityChanged(deviceID: deviceID) }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &address,
            DispatchQueue.main,
            token
        )

        if status == noErr {
            self.monitoredDeviceID = deviceID
            self.monitoredDeviceIsAliveListenerToken = token
            DebugLogger.shared.debug("Started monitoring device ID: \(deviceID)", source: "ASRService")
        } else {
            self.monitoredDeviceID = nil
            self.monitoredDeviceIsAliveListenerToken = nil
            DebugLogger.shared.error("Failed to monitor device \(deviceID): \(status)", source: "ASRService")
        }
    }

    /// Stops monitoring the currently monitored device
    private func stopMonitoringDevice() {
        guard let deviceID = self.monitoredDeviceID else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        if let token = self.monitoredDeviceIsAliveListenerToken {
            _ = AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, token)
        }
        self.monitoredDeviceID = nil
        self.monitoredDeviceIsAliveListenerToken = nil
        DebugLogger.shared.debug("Stopped monitoring device ID: \(deviceID)", source: "ASRService")
    }

    /// Handles device list changes (new device connected or device removed)
    private func handleDeviceListChanged() {
        DebugLogger.shared.info("🔄 Device list changed - checking for new/removed devices", source: "ASRService")

        // Perform CoreAudio queries off the main thread — during a device topology change
        // the HAL may still be settling, and synchronous queries on main can deadlock.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let currentDevices = AudioDevice.listInputDevicesRefreshingLiveness()
            let defaultInputUID = AudioDevice.getDefaultInputDevice()?.uid

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let cachedUIDs = self.cachedDeviceUIDs
                let cachedDeviceIDsByUID = self.cachedInputDeviceIDsByUID
                let cachedLivenessByUID = self.cachedInputLivenessByUID
                let currentUIDs = Set(currentDevices.map(\.uid))
                let currentDeviceIDsByUID = Dictionary(
                    currentDevices.map { ($0.uid, $0.id) },
                    uniquingKeysWith: { current, _ in current }
                )
                let currentLivenessByUID = Dictionary(
                    currentDevices.map { ($0.uid, $0.isAlive) },
                    uniquingKeysWith: { current, _ in current }
                )

                DebugLogger.shared.debug("Current input devices: \(currentDevices.map { $0.name }.joined(separator: ", "))", source: "ASRService")

                if currentUIDs != cachedUIDs ||
                    currentDeviceIDsByUID != cachedDeviceIDsByUID ||
                    currentLivenessByUID != cachedLivenessByUID
                {
                    let microphonePreferenceCoordinator =
                        AppServices.shared.microphonePreferenceCoordinator
                    let migrationPending = microphonePreferenceCoordinator.needsMicrophonePriorityMigration
                    let resolvedInput = microphonePreferenceCoordinator.reconcileMicrophoneSelection(
                        availableInputs: currentDevices,
                        defaultInputUID: defaultInputUID
                    )
                    let priorityUIDs = SettingsStore.shared.microphonePriority.map(\.uid)
                    let livenessRequiresRecovery =
                        (self.isRunning &&
                            resolvedInput?.uid != microphonePreferenceCoordinator.confirmedActiveInputUID) ||
                        (self.hasPreparedAudioCapture &&
                            resolvedInput?.id != self.directAudioLifecycleController.snapshot.deviceID)
                    let shouldReconcileInputSelection = AudioCaptureIdlePolicy.shouldReconcileInputSelection(
                        priorityInputUIDs: priorityUIDs,
                        migrationPending: migrationPending,
                        previousInputUIDs: cachedUIDs,
                        currentInputUIDs: currentUIDs
                    ) || AudioCaptureIdlePolicy.didResolvedPriorityInputIdentityChange(
                        priorityInputUIDs: priorityUIDs,
                        previousInputDeviceIDsByUID: cachedDeviceIDsByUID,
                        currentInputDeviceIDsByUID: currentDeviceIDsByUID
                    ) || livenessRequiresRecovery
                    if shouldReconcileInputSelection {
                        self.scheduleAudioRouteRecovery(
                            reason: "app microphone availability changed",
                            requiresIdlePrewarm: true,
                            reconcilesInputSelection: true
                        )
                    }
                }

                self.cacheCurrentDeviceList(currentDevices)
            }
        }
    }

    /// Handles device availability changes (device disconnected or reconnected)
    private func handleDeviceAvailabilityChanged(deviceID: AudioObjectID) {
        DebugLogger.shared.info("⚠️ Device availability changed for ID: \(deviceID)", source: "ASRService")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let isAlive = AudioDevice.refreshInputDeviceLiveness(deviceID: deviceID)
            DispatchQueue.main.async { [weak self] in
                self?.applyDeviceAvailability(isAlive: isAlive, deviceID: deviceID)
            }
        }
    }

    private func applyDeviceAvailability(isAlive: Bool, deviceID: AudioObjectID) {
        DebugLogger.shared.debug(
            "Device \(deviceID) cached alive status: \(isAlive)",
            source: "ASRService"
        )
        if isAlive == false {
            // Device disconnected
            DebugLogger.shared.warning("❌ Monitored device (ID: \(deviceID)) DISCONNECTED", source: "ASRService")
            self.stopMonitoringDevice()

            if self.isRunning {
                DebugLogger.shared.info(
                    "Device changed during recording - deferring rebuild until audio route recovery",
                    source: "ASRService"
                )
                self.scheduleAudioRouteRecovery(
                    reason: "monitored input disconnected",
                    reconcilesInputSelection: true
                )
            } else {
                DebugLogger.shared.info("Not recording - device disconnect handled gracefully", source: "ASRService")
            }
        } else {
            DebugLogger.shared.info("✅ Device (ID: \(deviceID)) is still alive", source: "ASRService")
        }
    }

    /// Gets the currently bound input device (if determinable)
    private func getCurrentlyBoundInputDevice() -> AudioDevice.Device? {
        let directSnapshot = self.directAudioLifecycleController.snapshot
        if let deviceID = directSnapshot.deviceID {
            return AudioDevice.Device(
                id: deviceID,
                uid: "",
                name: directSnapshot.deviceName ?? "Direct Core Audio input",
                hasInput: true,
                hasOutput: false
            )
        }

        // Check if engine exists before accessing inputNode
        guard self.engineStorage != nil else { return nil }
        guard let audioUnit = self.engine.inputNode.audioUnit else { return nil }

        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )

        if status == noErr, deviceID != 0 {
            return AudioDevice.listInputDevices().first { $0.id == deviceID }
        }

        return nil
    }

    /// Device caching for change detection
    private var cachedDeviceUIDs: Set<String> = []
    private var cachedInputDeviceIDsByUID: [String: AudioObjectID] = [:]
    private var cachedInputLivenessByUID: [String: Bool] = [:]

    private func cacheCurrentDeviceList(_ devices: [AudioDevice.Device]) {
        self.cachedDeviceUIDs = Set(devices.map { $0.uid })
        self.cachedInputDeviceIDsByUID = Dictionary(
            devices.map { ($0.uid, $0.id) },
            uniquingKeysWith: { current, _ in current }
        )
        self.cachedInputLivenessByUID = Dictionary(
            devices.map { ($0.uid, $0.isAlive) },
            uniquingKeysWith: { current, _ in current }
        )
    }

    // Audio tap processing is handled by AudioCapturePipeline (thread-safe).

    func ensureAsrReady() async throws {
        try await self.ensureAsrReady(source: .automatic, progressHandler: nil)
    }

    func ensureAsrReady(progressHandler: ((Double) -> Void)?) async throws {
        try await self.ensureAsrReady(source: .automatic, progressHandler: progressHandler)
    }

    func ensureAsrReady(
        source: AnalyticsModelDownloadSource,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws {
        guard self.modelDownloadTask == nil else {
            throw NSError(
                domain: "ASRService",
                code: -2001,
                userInfo: [NSLocalizedDescriptionKey: "Another model download is already in progress."]
            )
        }
        if let drain = self.providerResetDrain {
            await drain.task.value
            if self.providerResetDrain?.id == drain.id {
                self.providerResetDrain = nil
            }
        }
        let provider = self.transcriptionProvider
        let model = SettingsStore.shared.selectedSpeechModel
        let providerKey = "\(model.id):\(type(of: provider)):\(provider.name)"
        DebugLogger.shared.info(
            "ensureAsrReady() requested for model=\(model.id) [supportsStreaming=\(model.supportsStreaming)] provider=\(providerKey)",
            source: "ASRService"
        )

        // Single-flight for the same model. A reset invalidates the provider key but retains
        // the retiring task so replacements can wait for cache cleanup before starting.
        while let existingTask = self.ensureReadyTask {
            let existingTaskID = self.ensureReadyTaskID
            if self.ensureReadyProviderKey == providerKey,
               self.ensureReadyOperationID == existingTaskID,
               !self.isCancellingModelPreparation
            {
                try await existingTask.value
                return
            }

            self.isCancellingModelPreparation = true
            existingTask.cancel()
            _ = await existingTask.result
            if self.ensureReadyTaskID == existingTaskID {
                self.ensureReadyTask = nil
                self.ensureReadyTaskID = nil
                self.ensureReadyProviderKey = nil
                self.isCancellingModelPreparation = false
            }
        }

        guard SettingsStore.shared.selectedSpeechModel == model else {
            throw CancellationError()
        }

        let operationID = UUID()
        let task = Task { @MainActor in
            try await self.performEnsureAsrReady(
                provider: provider,
                operationID: operationID,
                analyticsSource: source,
                externalProgressHandler: progressHandler
            )
        }
        self.ensureReadyTask = task
        self.ensureReadyTaskID = operationID
        self.ensureReadyProviderKey = providerKey
        self.ensureReadyOperationID = operationID
        self.isCancellingModelPreparation = false

        defer {
            if ensureReadyTaskID == operationID {
                ensureReadyTask = nil
                ensureReadyTaskID = nil
                ensureReadyProviderKey = nil
                if ensureReadyOperationID == operationID {
                    ensureReadyOperationID = nil
                }
                isCancellingModelPreparation = false
            }
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performEnsureAsrReady(
        provider: TranscriptionProvider,
        operationID: UUID,
        analyticsSource: AnalyticsModelDownloadSource,
        externalProgressHandler: ((Double) -> Void)? = nil
    ) async throws {
        guard self.ensureReadyOperationID == operationID else { throw CancellationError() }
        self.isCancellingModelPreparation = false
        DebugLogger.shared.debug(
            "ensureAsrReady(begin): provider=\(provider.name), providerReady=\(provider.isReady), isAsrReady=\(self.isAsrReady), isRunning=\(self.isRunning)",
            source: "ASRService"
        )

        // Check if already ready
        if self.isAsrReady, provider.isReady {
            DebugLogger.shared.debug("ASR already ready with loaded models, skipping initialization", source: "ASRService")
            self.refreshWordBoostStatus()
            return
        }

        // If the flag is set but provider isn't ready (e.g., provider switch without reset), re-init.
        if self.isAsrReady, !provider.isReady {
            DebugLogger.shared.debug("ASR marked ready but provider not ready; re-initializing", source: "ASRService")
        }

        self.isAsrReady = false
        let modelsAlreadyCached = provider.modelsExistOnDisk()

        let totalStartTime = Date()
        do {
            let initializationStart = Date()
            DebugLogger.shared.info("=== ASR INITIALIZATION START ===", source: "ASRService")
            DebugLogger.shared.info("Using provider: \(provider.name) [providerReady=\(provider.isReady)]", source: "ASRService")

            DebugLogger.shared.info("Models already cached on disk: \(modelsAlreadyCached)", source: "ASRService")
            DebugLogger.shared.debug("Model cache lookup complete in \(String(format: "%.3f", Date().timeIntervalSince(totalStartTime)))s", source: "ASRService")

            // Suppress stderr noise during model loading (ALWAYS restore, even on failure).
            let originalStderr = dup(STDERR_FILENO)
            var didRedirectStderr = false
            if originalStderr != -1 {
                let devNull = open("/dev/null", O_WRONLY)
                if devNull != -1 {
                    dup2(devNull, STDERR_FILENO)
                    close(devNull)
                    didRedirectStderr = true
                }
            }

            defer {
                // Only restore if we actually redirected stderr.
                if didRedirectStderr, originalStderr != -1 {
                    dup2(originalStderr, STDERR_FILENO)
                }
                if originalStderr != -1 {
                    close(originalStderr)
                }
            }

            // Set correct loading state based on whether models are cached.
            try Task.checkCancellation()
            guard self.ensureReadyOperationID == operationID else { throw CancellationError() }
            if modelsAlreadyCached {
                self.isLoadingModel = true
                self.isDownloadingModel = false
                self.downloadProgress = nil
                self.modelPreparationPhase = .loading
                DebugLogger.shared.info("📦 LOADING cached model into memory...", source: "ASRService")
            } else {
                self.isDownloadingModel = true
                self.isLoadingModel = false
                self.downloadProgress = nil
                self.modelPreparationPhase = .preparingDownload
                DebugLogger.shared.info("⬇️ DOWNLOADING model...", source: "ASRService")
            }

            // Use the transcription provider to prepare models
            let downloadStartTime = Date()
            DebugLogger.shared.info("Calling transcriptionProvider.prepare()...", source: "ASRService")
            try await self.prepareProviderWithRecovery(
                provider: provider,
                modelsAlreadyCached: modelsAlreadyCached,
                progressHandler: { [weak self] progress in
                    DispatchQueue.main.async {
                        guard
                            let self,
                            self.ensureReadyOperationID == operationID,
                            !self.isCancellingModelPreparation
                        else {
                            return
                        }
                        self.applyModelPreparationProgress(
                            progress,
                            updatesActiveModelState: true,
                            externalProgressHandler: externalProgressHandler,
                            analyticsOperationID: operationID,
                            analyticsDescriptor: SettingsStore.shared.selectedSpeechModel.analyticsDescriptor,
                            analyticsSource: analyticsSource
                        )
                    }
                }
            )
            try Task.checkCancellation()
            guard self.ensureReadyOperationID == operationID else { throw CancellationError() }
            let downloadDuration = Date().timeIntervalSince(downloadStartTime)
            DebugLogger.shared.info("✓ Provider preparation completed in \(String(format: "%.1f", downloadDuration)) seconds", source: "ASRService")

            self.isDownloadingModel = false
            // Keep isLoadingModel true until first transcription completes (for large models that need warm-up)
            if !self.hasCompletedFirstTranscription {
                self.isLoadingModel = true
                self.modelPreparationPhase = .loading
                DebugLogger.shared.info("⏳ Model loaded, waiting for first transcription to complete...", source: "ASRService")
            } else {
                self.isLoadingModel = false
                self.modelPreparationPhase = nil
            }
            self.downloadProgress = nil
            self.modelsExistOnDisk = true

            let totalDuration = Date().timeIntervalSince(initializationStart)
            DebugLogger.shared.info("=== ASR INITIALIZATION COMPLETE ===", source: "ASRService")
            DebugLogger.shared.info("Total initialization time: \(String(format: "%.1f", totalDuration)) seconds", source: "ASRService")

            self.isAsrReady = true
            self.isCancellingModelPreparation = false
            self.refreshWordBoostStatus()
            self.finishModelDownloadAnalytics(operationID: operationID, outcome: .succeeded)
        } catch is CancellationError {
            self.finishModelDownloadAnalytics(operationID: operationID, outcome: .cancelled)
            DebugLogger.shared.info("ASR initialization cancelled", source: "ASRService")
            if provider.shouldClearCacheAfterCancellation,
               provider.modelsExistOnDisk() == false
            {
                do {
                    try await provider.clearCache()
                } catch {
                    DebugLogger.shared.warning(
                        "Failed to clear incomplete model cache after cancellation: \(error)",
                        source: "ASRService"
                    )
                }
            }
            if self.ensureReadyOperationID == operationID {
                self.isDownloadingModel = false
                self.isLoadingModel = false
                self.downloadProgress = nil
                self.modelPreparationPhase = nil
                self.modelsExistOnDisk = provider.modelsExistOnDisk()
                self.isCancellingModelPreparation = false
            }
            throw CancellationError()
        } catch {
            if Task.isCancelled || Self.isModelPreparationCancellation(error) {
                self.finishModelDownloadAnalytics(operationID: operationID, outcome: .cancelled)
                if provider.shouldClearCacheAfterCancellation,
                   provider.modelsExistOnDisk() == false
                {
                    try? await provider.clearCache()
                }
                if self.ensureReadyOperationID == operationID {
                    self.isDownloadingModel = false
                    self.isLoadingModel = false
                    self.downloadProgress = nil
                    self.modelPreparationPhase = nil
                    self.modelsExistOnDisk = provider.modelsExistOnDisk()
                    self.isCancellingModelPreparation = false
                }
                throw CancellationError()
            }
            self.finishModelDownloadAnalytics(operationID: operationID, outcome: .failed)
            DebugLogger.shared.error("ASR initialization failed with error: \(error)", source: "ASRService")
            DebugLogger.shared.error("Error details: \(error.localizedDescription)", source: "ASRService")
            if self.ensureReadyOperationID == operationID {
                self.isDownloadingModel = false
                self.isLoadingModel = false
                self.downloadProgress = nil
                self.modelPreparationPhase = nil
            }
            throw error
        }
    }

    private func applyModelPreparationProgress(
        _ progress: ModelPreparationProgress,
        updatesActiveModelState: Bool,
        externalProgressHandler: ((Double) -> Void)?,
        analyticsOperationID: UUID? = nil,
        analyticsDescriptor: AnalyticsModelDescriptor? = nil,
        analyticsSource: AnalyticsModelDownloadSource = .automatic
    ) {
        switch progress.phase {
        case .preparingDownload:
            self.downloadProgress = nil
            if updatesActiveModelState {
                self.isDownloadingModel = true
                self.isLoadingModel = false
            }
        case .downloading:
            if let analyticsOperationID, let analyticsDescriptor {
                self.beginModelDownloadAnalytics(
                    operationID: analyticsOperationID,
                    descriptor: analyticsDescriptor,
                    source: analyticsSource
                )
            }
            self.downloadProgress = progress.fractionCompleted
            if updatesActiveModelState {
                self.isDownloadingModel = true
                self.isLoadingModel = false
            }
            if let fraction = progress.fractionCompleted {
                externalProgressHandler?(fraction)
            }
        case .optimizing:
            if let analyticsOperationID {
                self.finishModelDownloadAnalytics(operationID: analyticsOperationID, outcome: .succeeded)
            }
            self.downloadProgress = nil
            if updatesActiveModelState {
                self.isDownloadingModel = true
                self.isLoadingModel = false
            }
        case .loading:
            if let analyticsOperationID {
                self.finishModelDownloadAnalytics(operationID: analyticsOperationID, outcome: .succeeded)
            }
            self.downloadProgress = nil
            if updatesActiveModelState {
                self.isDownloadingModel = false
                self.isLoadingModel = true
            }
        }

        self.modelPreparationPhase = progress.phase
    }

    private struct ModelDownloadAnalyticsState {
        let descriptor: AnalyticsModelDescriptor
        let source: AnalyticsModelDownloadSource
        let startedAt: Date
    }

    private func beginModelDownloadAnalytics(
        operationID: UUID,
        descriptor: AnalyticsModelDescriptor,
        source: AnalyticsModelDownloadSource
    ) {
        guard self.modelDownloadAnalyticsStates[operationID] == nil else { return }
        self.modelDownloadAnalyticsStates[operationID] = ModelDownloadAnalyticsState(
            descriptor: descriptor,
            source: source,
            startedAt: Date()
        )
        AnalyticsService.shared.recordModelDownloadStarted(
            id: operationID,
            descriptor: descriptor,
            source: source
        )
    }

    private func finishModelDownloadAnalytics(
        operationID: UUID,
        outcome: AnalyticsModelDownloadOutcome
    ) {
        guard let state = self.modelDownloadAnalyticsStates.removeValue(forKey: operationID) else { return }
        AnalyticsService.shared.recordModelDownloadFinished(
            id: operationID,
            descriptor: state.descriptor,
            source: state.source,
            outcome: outcome,
            duration: Date().timeIntervalSince(state.startedAt)
        )
    }

    private func prepareProviderWithRecovery(
        provider: TranscriptionProvider,
        modelsAlreadyCached: Bool,
        progressHandler: @escaping (ModelPreparationProgress) -> Void
    ) async throws {
        let start = Date()
        var firstError: Error?
        do {
            try await provider.prepare(progressHandler: progressHandler)
            DebugLogger.shared.info(
                "ASRService: Provider '\(provider.name)' prepared successfully in \(String(format: "%.2f", Date().timeIntervalSince(start)))s",
                source: "ASRService"
            )
            return
        } catch {
            if Task.isCancelled || Self.isModelPreparationCancellation(error) {
                throw CancellationError()
            }
            firstError = error
            DebugLogger.shared.error("ASRService: First prepare attempt for \(provider.name) failed after \(String(format: "%.2f", Date().timeIntervalSince(start)))s", source: "ASRService")
            DebugLogger.shared.warning(
                "ASRService: First prepare failed for \(provider.name): \(error). " +
                    "Attempting a single recovery by clearing provider cache.",
                source: "ASRService"
            )
        }

        guard modelsAlreadyCached else {
            DebugLogger.shared.error(
                "ASRService: Provider cache was empty; recovery retry disabled after first failure for \(provider.name).",
                source: "ASRService"
            )
            throw NSError(
                domain: "ASRService",
                code: -2000,
                userInfo: [NSLocalizedDescriptionKey: "Provider preparation failed: \(self.errorSummary(from: firstError))"]
            )
        }

        try Task.checkCancellation()
        do {
            DebugLogger.shared.info("ASRService: Clearing provider cache before retry for \(provider.name)", source: "ASRService")
            try await provider.clearCache()
        } catch {
            DebugLogger.shared.warning(
                "ASRService: Provider cache clear failed for \(provider.name): \(error)",
                source: "ASRService"
            )
        }

        // One strict retry. If this fails, we let the caller handle the error.
        try Task.checkCancellation()
        do {
            try await provider.prepare(progressHandler: progressHandler)
        } catch {
            if Task.isCancelled || Self.isModelPreparationCancellation(error) {
                throw CancellationError()
            }
            throw error
        }
        DebugLogger.shared.info(
            "ASRService: Provider '\(provider.name)' prepared successfully after cache-clear retry",
            source: "ASRService"
        )
    }

    private func errorSummary(from error: Error?) -> String {
        if let error { return error.localizedDescription }
        return "Unknown error"
    }

    private nonisolated static func isModelPreparationCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    // MARK: - Model lifecycle helpers (parity with original API)

    func predownloadSelectedModel() {
        Task { [weak self] in
            guard let self = self else { return }
            DebugLogger.shared.info("Starting model predownload...", source: "ASRService")
            // ensureAsrReady handles setting the correct loading/downloading state
            do {
                try await self.ensureAsrReady()
                DebugLogger.shared.info("Model predownload completed successfully", source: "ASRService")
            } catch is CancellationError {
                DebugLogger.shared.info("Model predownload cancelled", source: "ASRService")
            } catch {
                DebugLogger.shared.error("Model predownload failed: \(error)", source: "ASRService")
                self.errorTitle = "Download Failed"
                self.errorMessage = error.localizedDescription
                self.showError = true
            }
        }
    }

    func preloadModelAfterSelection() async {
        // ensureAsrReady handles setting the correct loading/downloading state
        do {
            try await self.ensureAsrReady()
        } catch {
            DebugLogger.shared.error("Model preload failed: \(error)", source: "ASRService")
        }
    }

    // MARK: - Cache management

    func clearModelCache() async throws {
        DebugLogger.shared.debug("Clearing model cache via transcription provider", source: "ASRService")
        await self.transcriptionExecutor.cancelAndAwaitPending()
        try await self.transcriptionProvider.clearCache()
        self.isAsrReady = false
        self.modelsExistOnDisk = false
    }

    func clearModelCache(for model: SettingsStore.SpeechModel) async throws {
        DebugLogger.shared.debug("Clearing model cache for \(model.displayName)", source: "ASRService")
        if SettingsStore.shared.selectedSpeechModel == model {
            await self.transcriptionExecutor.cancelAndAwaitPending()
        }
        let provider = self.getProvider(for: model)
        try await provider.clearCache()

        if model.requiresExternalArtifacts {
            SettingsStore.shared.setExternalCoreMLArtifactsDirectory(nil, for: model)
        }

        guard SettingsStore.shared.selectedSpeechModel == model else { return }
        self.resetTranscriptionProvider()
        await self.checkIfModelsExistAsync()
    }

    // MARK: - Timer-based Streaming Transcription (No VAD)

    private func startStreamingTranscription() {
        self.streamingTask?.cancel()
        guard self.isAsrReady else { return }

        DebugLogger.shared.debug(
            "Starting streaming transcription task (interval: \(self.streamingChunkDurationSeconds)s, minSamples: \(self.minimumStreamingPreviewSamples))",
            source: "ASRService"
        )

        self.streamingTask = Task { [weak self] in
            await self?.runStreamingLoop()
        }
    }

    @MainActor
    private func runStreamingLoop() async {
        DebugLogger.shared.debug("🔄 runStreamingLoop() - ENTERED", source: "ASRService")
        var loopCount = 0
        var lastBufferCount = 0

        while !Task.isCancelled {
            DebugLogger.shared.debug("🔄 runStreamingLoop() - calling processStreamingChunk()", source: "ASRService")
            await self.processStreamingChunk()
            DebugLogger.shared.debug("🔄 runStreamingLoop() - processStreamingChunk() returned", source: "ASRService")

            if Task.isCancelled || self.isRunning == false {
                break
            }

            // Health check: detect if audio is not being captured
            loopCount += 1
            if loopCount >= 3 { // After 3 loops (~6 seconds with 2s interval)
                let currentBufferCount = self.audioBuffer.count
                if currentBufferCount == lastBufferCount, currentBufferCount < 16_000 {
                    DebugLogger.shared.warning(
                        "Audio buffer not growing after \(loopCount * 2) seconds (count: \(currentBufferCount)). " +
                            "Audio capture may have failed. Check if engine is running and tap is installed.",
                        source: "ASRService"
                    )
                }
                lastBufferCount = currentBufferCount
                loopCount = 0
            }

            do {
                try await Task.sleep(nanoseconds: UInt64(self.streamingChunkDurationSeconds * 1_000_000_000))
            } catch {
                DebugLogger.shared.debug("Streaming transcription task cancelled", source: "ASRService")
                break
            }
        }
    }

    @MainActor
    private func processStreamingChunk() async {
        guard self.isRunning else { return }
        self.benchmarkStreamingChunkIndex += 1
        let chunkIndex = self.benchmarkStreamingChunkIndex
        let chunkAgeMs = self.elapsedMilliseconds(since: self.benchmarkRecordingStartedAt)

        // Skip if already processing to prevent queue buildup
        guard !self.isProcessingChunk else {
            DebugLogger.shared.debug("⚠️ Skipping chunk - previous transcription still in progress", source: "ASRService")
            self.benchmarkLog("chunk_skip index=\(chunkIndex) reason=busy ageMs=\(chunkAgeMs)")
            self.skipNextChunk = true
            return
        }

        if self.skipNextChunk {
            DebugLogger.shared.debug("⚠️ Skipping chunk for ANE recovery", source: "ASRService")
            self.benchmarkLog("chunk_skip index=\(chunkIndex) reason=recovery ageMs=\(chunkAgeMs)")
            self.skipNextChunk = false
            return
        }

        guard self.isAsrReady, self.transcriptionProvider.isReady else {
            self.benchmarkLog("chunk_skip index=\(chunkIndex) reason=not_ready ageMs=\(chunkAgeMs) isAsrReady=\(self.isAsrReady) providerReady=\(self.transcriptionProvider.isReady)")
            return
        }

        // Thread-safe count check
        let currentSampleCount = self.audioBuffer.count
        // Most ASR models require at least 1 second of 16kHz audio (16,000 samples) to transcribe
        let minSamples = self.minimumStreamingPreviewSamples
        guard currentSampleCount >= minSamples else {
            // Only log once per recording session to avoid spam
            if currentSampleCount > 0, self.lastProcessedSampleCount == 0 {
                DebugLogger.shared.debug(
                    "Waiting for more audio data (\(currentSampleCount)/\(minSamples) samples)",
                    source: "ASRService"
                )
                self.benchmarkLog("chunk_wait index=\(chunkIndex) ageMs=\(chunkAgeMs) samples=\(currentSampleCount) minSamples=\(minSamples)")
            }
            return
        }

        // Once FluidAudio has an incremental session, copy only newly captured PCM.
        // Other providers and the first incremental preview still receive the full prefix.
        #if arch(arm64)
        let incrementalProvider = self.transcriptionProvider as? FluidAudioProvider
        let incrementalDeltaStart = incrementalProvider?.incrementalPreviewDeltaStart(
            totalSampleCount: currentSampleCount
        )
        #else
        let incrementalDeltaStart: Int? = nil
        #endif
        let chunk: [Float]
        if let incrementalDeltaStart {
            chunk = self.audioBuffer.getRange(
                startingAt: incrementalDeltaStart,
                count: currentSampleCount - incrementalDeltaStart
            )
        } else {
            chunk = self.audioBuffer.getPrefix(currentSampleCount)
        }

        // Validate chunk is not empty (defensive check)
        guard !chunk.isEmpty else {
            DebugLogger.shared.warning("Audio buffer returned empty chunk despite count > 0. Skipping transcription.", source: "ASRService")
            self.benchmarkLog("chunk_skip index=\(chunkIndex) reason=empty ageMs=\(chunkAgeMs)")
            return
        }

        self.isProcessingChunk = true
        defer { isProcessingChunk = false }

        let startTime = Date()
        let startedAt = startTime.timeIntervalSince1970
        let newSamples = max(0, currentSampleCount - self.benchmarkLastChunkSampleCount)
        self.benchmarkLastChunkSampleCount = currentSampleCount
        let audioMilliseconds = Int((Double(currentSampleCount) / 16_000.0 * 1000).rounded())
        self.benchmarkLog(
            "chunk_start index=\(chunkIndex) ageMs=\(chunkAgeMs) samples=\(currentSampleCount) " +
                "inputSamples=\(chunk.count) newSamples=\(newSamples) audioMs=\(audioMilliseconds) " +
                "provider=\(self.transcriptionProvider.name)"
        )

        do {
            DebugLogger.shared.debug("Streaming chunk starting transcription (samples: \(currentSampleCount), input: \(chunk.count)) using \(self.transcriptionProvider.name)", source: "ASRService")
            let result: ASRTranscriptionResult
            #if arch(arm64)
            if incrementalDeltaStart != nil, let incrementalProvider {
                do {
                    result = try await self.transcriptionExecutor.run {
                        try await incrementalProvider.transcribeStreamingDelta(
                            chunk,
                            totalSampleCount: currentSampleCount
                        )
                    }
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        throw CancellationError()
                    }
                    DebugLogger.shared.warning(
                        "Incremental delta preview failed; retrying with the full prefix",
                        source: "ASRService"
                    )
                    let fullPrefix = self.audioBuffer.getPrefix(currentSampleCount)
                    result = try await self.transcriptionExecutor.run { [provider = self.transcriptionProvider] in
                        try await provider.transcribeStreaming(fullPrefix)
                    }
                }
            } else {
                result = try await self.transcriptionExecutor.run { [provider = self.transcriptionProvider] in
                    try await provider.transcribeStreaming(chunk)
                }
            }
            #else
            result = try await self.transcriptionExecutor.run { [provider = self.transcriptionProvider] in
                try await provider.transcribeStreaming(chunk)
            }
            #endif

            let duration = Date().timeIntervalSince(startTime)
            DebugLogger.shared.debug(
                "Streaming chunk transcription finished in \(String(format: "%.2f", duration))s",
                source: "ASRService"
            )
            let rawText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let newText = ASRService.applySpokenPunctuationFormatting(
                ASRService.applyCustomDictionary(ASRService.removeFillerWords(rawText))
            )
            self.recordWordBoostHitIfAny(transcribedText: newText)
            self.benchmarkCompletedStreamingChunks += 1
            self.lastProcessedSampleCount = currentSampleCount

            // Mark first transcription as complete to clear loading state
            if !self.hasCompletedFirstTranscription {
                self.hasCompletedFirstTranscription = true
                DispatchQueue.main.async {
                    self.isLoadingModel = false
                    self.modelPreparationPhase = nil
                    DebugLogger.shared.info("✅ Model warmed up - first streaming transcription completed", source: "ASRService")
                }
            }

            if !newText.isEmpty {
                // Smart diff: only show truly new words
                let updatedText = self.smartDiffUpdate(previous: self.previousFullTranscription, current: newText)
                self.partialTranscription = updatedText
                self.previousFullTranscription = newText

                DebugLogger.shared.debug("✅ Streaming: '\(updatedText)' (\(String(format: "%.2f", duration))s)", source: "ASRService")
            }
            let rtf = duration / (Double(currentSampleCount) / 16_000.0)
            let chunkDoneAgeMs = self.elapsedMilliseconds(since: self.benchmarkRecordingStartedAt)
            self.benchmarkLog(
                "chunk_done index=\(chunkIndex) elapsedMs=\(self.elapsedMilliseconds(since: startedAt)) ageMs=\(chunkDoneAgeMs) " +
                    "samples=\(currentSampleCount) inputSamples=\(chunk.count) rawChars=\(rawText.count) cleanedChars=\(newText.count) rtf=\(String(format: "%.3f", rtf))"
            )

            // If transcription takes longer than the interval, skip next to prevent queue buildup
            // This allows slower machines to still work without overwhelming the system
            if duration > self.streamingChunkDurationSeconds {
                DebugLogger.shared.debug(
                    "⚠️ Transcription slow (\(String(format: "%.2f", duration))s > \(self.streamingChunkDurationSeconds)s), skipping next chunk",
                    source: "ASRService"
                )
                self.skipNextChunk = true
            }
        } catch {
            DebugLogger.shared.error("❌ Streaming failed: \(error)", source: "ASRService")
            self.benchmarkLog("chunk_fail index=\(chunkIndex) elapsedMs=\(self.elapsedMilliseconds(since: startedAt)) samples=\(currentSampleCount) inputSamples=\(chunk.count) error=\(error.localizedDescription)")
            self.skipNextChunk = true
        }
    }

    /// Smart diff to prevent text from jumping around
    private func smartDiffUpdate(previous: String, current: String) -> String {
        guard !previous.isEmpty else { return current }
        guard !current.isEmpty else { return previous }

        let prevWords = previous.split(separator: " ").map(String.init)
        let currWords = current.split(separator: " ").map(String.init)

        // Find longest common prefix
        var commonPrefixLength = 0
        for i in 0..<min(prevWords.count, currWords.count) {
            if prevWords[i].lowercased().trimmingCharacters(in: .punctuationCharacters) ==
                currWords[i].lowercased().trimmingCharacters(in: .punctuationCharacters)
            {
                commonPrefixLength = i + 1
            } else {
                break
            }
        }

        // If >50% overlap, keep stable prefix and add new words
        if commonPrefixLength > prevWords.count / 2 {
            let stableWords = Array(currWords[0..<min(commonPrefixLength, currWords.count)])
            let newWords = currWords.count > commonPrefixLength ? Array(currWords[commonPrefixLength...]) : []
            return (stableWords + newWords).joined(separator: " ")
        } else {
            return current // Significant change
        }
    }

    private let typingService = TypingService() // Reuse instance to avoid conflicts

    func typeTextToActiveField(_ text: String) {
        self.typeTextToActiveField(text, preferredTargetPID: nil, textReadyAt: nil)
    }

    func typeTextToActiveField(_ text: String, preferredTargetPID: pid_t?, textReadyAt: TimeInterval? = nil) {
        self.typeOutputPlanToActiveField(.plain(text), preferredTargetPID: preferredTargetPID, textReadyAt: textReadyAt)
    }

    func typeOutputPlanToActiveField(
        _ plan: DictationLiteralOutputPlan,
        preferredTargetPID: pid_t?,
        textReadyAt: TimeInterval? = nil,
        tracksDictionaryCorrections: Bool = false
    ) {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let textReadyAge = textReadyAt.map { Int(((requestedAt - $0) * 1000).rounded()) }
        let text = plan.plainText
        DebugLogger.shared.benchmark(
            "TYPING_BENCH",
            message: "asr_type_request chars=\(text.count) preferredPID=\(preferredTargetPID.map { String($0) } ?? "nil") textReadyAgeMs=\(textReadyAge.map { String($0) } ?? "nil")",
            source: "TypingBenchmark"
        )
        self.typingService.typeOutputPlanInstantly(
            plan,
            preferredTargetPID: preferredTargetPID,
            textReadyAt: textReadyAt,
            tracksDictionaryCorrections: tracksDictionaryCorrections
        )
        let dispatchedAt = ProcessInfo.processInfo.systemUptime
        let textReadyToDispatchMs = textReadyAt.map {
            String(Int(((dispatchedAt - $0) * 1000).rounded()))
        } ?? "nil"
        DebugLogger.shared.benchmark(
            "TYPING_BENCH",
            message: "asr_type_dispatched chars=\(text.count) preferredPID=\(preferredTargetPID.map { String($0) } ?? "nil") textReadyToDispatchMs=\(textReadyToDispatchMs)",
            source: "TypingBenchmark"
        )
    }

    func typeOutputPlanToActiveFieldAndWait(
        _ plan: DictationLiteralOutputPlan,
        preferredTargetPID: pid_t?,
        textReadyAt: TimeInterval? = nil,
        tracksDictionaryCorrections: Bool = false,
        postInsertionKey: SettingsStore.SpokenSendKey? = nil,
        requiredFocusTarget: TypingService.CapturedFocusTarget? = nil
    ) async -> TypingService.DeliveryOutcome {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let textReadyAge = textReadyAt.map { Int(((requestedAt - $0) * 1000).rounded()) }
        let text = plan.plainText
        DebugLogger.shared.benchmark(
            "TYPING_BENCH",
            message: "asr_type_request chars=\(text.count) preferredPID=\(preferredTargetPID.map { String($0) } ?? "nil") textReadyAgeMs=\(textReadyAge.map { String($0) } ?? "nil")",
            source: "TypingBenchmark"
        )
        let outcome = await withCheckedContinuation { continuation in
            self.typingService.typeOutputPlanInstantly(
                plan,
                preferredTargetPID: preferredTargetPID,
                textReadyAt: textReadyAt,
                tracksDictionaryCorrections: tracksDictionaryCorrections,
                postInsertionKey: postInsertionKey,
                requiredFocusTarget: requiredFocusTarget
            ) { outcome in
                continuation.resume(returning: outcome)
            }
        }
        let dispatchedAt = ProcessInfo.processInfo.systemUptime
        let textReadyToDispatchMs = textReadyAt.map {
            String(Int(((dispatchedAt - $0) * 1000).rounded()))
        } ?? "nil"
        DebugLogger.shared.benchmark(
            "TYPING_BENCH",
            message: "asr_type_dispatched chars=\(text.count) preferredPID=\(preferredTargetPID.map { String($0) } ?? "nil") textReadyToDispatchMs=\(textReadyToDispatchMs)",
            source: "TypingBenchmark"
        )
        return outcome
    }

    /// Removes filler sounds from transcribed text
    static func removeFillerWords(_ text: String) -> String {
        guard SettingsStore.shared.removeFillerWordsEnabled else { return text }

        let fillers = Set(SettingsStore.shared.fillerWords.map { $0.lowercased() })

        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        let filtered = words.filter { word in
            !fillers.contains(word.lowercased().trimmingCharacters(in: .punctuationCharacters))
        }

        return filtered.joined(separator: " ")
    }

    // MARK: - Custom Dictionary (Cached Regex)

    /// Cache for compiled custom dictionary regexes.
    /// Key: trigger word, Value: (compiled regex, escaped replacement template)
    /// Cleared when dictionary entries change.
    private static var cachedDictionaryPatterns: [(regex: NSRegularExpression, template: String)] = []
    private static var dictionaryCacheNeedsRebuild: Bool = true

    /// Rebuilds the regex cache if dictionary has changed.
    /// Called lazily on first apply after settings change.
    private static func rebuildDictionaryCache() {
        let entries = SettingsStore.shared.customDictionaryEntries
        var patterns: [(regex: NSRegularExpression, template: String)] = []

        for entry in entries {
            for trigger in entry.triggers {
                guard !trigger.isEmpty else { continue }

                let consumesHorizontalSeparators = !entry.replacement.isEmpty &&
                    entry.replacement.allSatisfy(\.isWhitespace)
                let escapedTrigger = self.dictionaryPattern(
                    for: trigger,
                    consumesHorizontalSeparators: consumesHorizontalSeparators
                )
                guard let regex = try? NSRegularExpression(
                    pattern: escapedTrigger,
                    options: .caseInsensitive
                ) else { continue }

                patterns.append((regex: regex, template: NSRegularExpression.escapedTemplate(for: entry.replacement)))
            }
        }

        self.cachedDictionaryPatterns = patterns.sorted {
            $0.regex.pattern.utf16.count > $1.regex.pattern.utf16.count
        }
        self.dictionaryCacheNeedsRebuild = false
    }

    private static func dictionaryPattern(
        for trigger: String,
        consumesHorizontalSeparators: Bool = false
    ) -> String {
        let escapedTrigger = NSRegularExpression.escapedPattern(for: trigger)
        let prefix = self.startsWithWordCharacter(trigger) ? "\\b" : ""
        let suffix = self.endsWithWordCharacter(trigger) ? "\\b" : ""
        let separator = consumesHorizontalSeparators ? "[ \\t]*" : ""
        return separator + prefix + escapedTrigger + suffix + separator
    }

    private static func startsWithWordCharacter(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first else { return false }
        return self.isWordCharacter(scalar)
    }

    private static func endsWithWordCharacter(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.last else { return false }
        return self.isWordCharacter(scalar)
    }

    private static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }

    /// Invalidates the dictionary cache. Called when settings change.
    static func invalidateDictionaryCache() {
        self.dictionaryCacheNeedsRebuild = true
    }

    /// Applies custom dictionary replacements to transcribed text.
    /// Replaces trigger words/phrases with their designated replacements.
    /// Uses case-insensitive matching with word boundaries.
    /// Optimized: caches compiled regexes to avoid per-call compilation overhead.
    static func applyCustomDictionary(_ text: String) -> String {
        // Fast path: no entries configured
        let entries = SettingsStore.shared.customDictionaryEntries
        guard !entries.isEmpty else { return text }

        // Rebuild cache if needed (lazy initialization)
        if self.dictionaryCacheNeedsRebuild {
            self.rebuildDictionaryCache()
        }

        guard !self.cachedDictionaryPatterns.isEmpty else {
            return text
        }

        var result = text

        // Apply cached regexes - O(n) where n = number of patterns
        for pattern in self.cachedDictionaryPatterns {
            result = pattern.regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: pattern.template
            )
        }

        return result
    }

    // MARK: - GAAV Mode Formatting

    /// Applies GAAV mode formatting: removes first letter capitalization and trailing period.
    /// This is useful for search queries, form fields, or casual text input.
    ///
    /// Feature requested by maxgaav – thank you for the suggestion!
    static func applyGAAVFormatting(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = text

        if SettingsStore.shared.gaavRemoveTrailingPeriodEnabled, result.hasSuffix(".") {
            result.removeLast()
        }

        if SettingsStore.shared.gaavLowercaseFirstLetterEnabled, let first = result.first, first.isUppercase {
            result = first.lowercased() + result.dropFirst()
        }

        return result
    }

    // MARK: - Continuous Dictation Mode Formatting

    /// Applies split continuous-dictation formatting so transcribed segments chain naturally.
    /// Spacing and context-aware capitalization are independently controlled.
    ///
    /// Implements the chaining behavior requested in GitHub issue #390.
    static func applyContinuousDictationFormatting(_ text: String, precedingText: String) -> String {
        guard !text.isEmpty else { return text }
        let spacingEnabled = SettingsStore.shared.continuousDictationSpacingEnabled
        let smartCapsEnabled = SettingsStore.shared.contextAwareCapitalizationEnabled
        guard spacingEnabled || smartCapsEnabled else { return text }

        var result = text

        if smartCapsEnabled {
            let precedingTrimmed = precedingText.trimmingCharacters(in: .whitespaces)
            let boundaryCharacter = self.lastCapitalizationBoundaryCharacter(in: precedingTrimmed)
            if boundaryCharacter == nil || boundaryCharacter?.isSentenceEndingPunctuation == true {
                result = self.replacingFirstLetter(in: result, transform: { $0.uppercased() })
            } else {
                result = self.replacingFirstLetter(in: result, transform: { $0.lowercased() })
            }
        }

        if spacingEnabled {
            if let lastPreceding = precedingText.last,
               !lastPreceding.isWhitespace,
               result.first?.isWhitespace != true
            {
                result = " " + result
            }

            if result.last?.isWhitespace != true {
                result += " "
            }
        }

        return result
    }

    private static func lastCapitalizationBoundaryCharacter(in text: String) -> Character? {
        for character in text.reversed() {
            if character.isNewline {
                return nil
            }
            if character.isHorizontalWhitespace || character.isClosingPunctuationWrapper {
                continue
            }
            return character
        }
        return nil
    }

    private static func replacingFirstLetter(in text: String, transform: (Character) -> String) -> String {
        guard let index = text.firstIndex(where: { $0.isLetter }) else { return text }
        let nextIndex = text.index(after: index)
        return String(text[..<index]) + transform(text[index]) + String(text[nextIndex...])
    }
}

private extension Character {
    var isSentenceEndingPunctuation: Bool {
        self == "." || self == "!" || self == "?"
    }

    var isHorizontalWhitespace: Bool {
        self.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) }
    }

    var isClosingPunctuationWrapper: Bool {
        switch self {
        case "\"", "'", "”", "’", "»", "›", ")", "]", "}", "」", "』":
            return true
        default:
            return false
        }
    }
}

// swiftlint:enable type_body_length

private extension SettingsStore.SpeechModel {
    var nemotronProviderMode: NemotronProvider.Mode {
        switch self {
        case .nemotronStreaming: return .streaming
        case .nemotronStreaming320: return .streaming320
        default: return .offline
        }
    }
}

private extension ASRService {
    /// Stops the streaming timer and waits for the task to complete.
    /// This prevents race conditions where the buffer is cleared while
    /// a transcription task is still running.
    func stopStreamingTimerAndAwait() async {
        guard let task = self.streamingTask else {
            self.benchmarkLog("streaming_timer_stop no_task=true")
            return
        }
        let startedAt = Date().timeIntervalSince1970
        self.benchmarkLog("streaming_timer_stop begin")
        task.cancel()
        // Wait for the task to actually finish - this is critical!
        // The task may be in the middle of processStreamingChunk()
        _ = await task.result
        self.streamingTask = nil
        self.benchmarkLog("streaming_timer_stop end elapsedMs=\(self.elapsedMilliseconds(since: startedAt)) completedChunks=\(self.benchmarkCompletedStreamingChunks)")
    }

    /// Legacy sync version for cases where we can't await (e.g., stopWithoutTranscription)
    /// WARNING: This can cause crashes if buffer is cleared immediately after!
    func stopStreamingTimer() {
        self.streamingTask?.cancel()
        self.streamingTask = nil
    }
}

// MARK: - Audio capture pipeline

//
// Audio callbacks are not main-actor isolated. Direct Core Audio arrives through
// a lock-free C ring. The AVAudioEngine implementation remains as legacy code but
// is no longer user-selectable. This pipeline owns timestamp trimming, 16 kHz
// conversion, levels, and session-safe delivery without touching ASRService from
// a realtime callback.

private final nonisolated class AudioCapturePipeline: @unchecked Sendable {
    private let audioBuffer: ThreadSafeAudioBuffer
    private let onFirstAudio: (Int, UInt64, Int, Int, Double, Int, Int) -> Void
    private let onLevel: (CGFloat) -> Void
    private let onCaptureHealth: (Int, UInt64, Int, Int, Float, Float) -> Void

    private let lock = NSLock()
    private var recordingEnabled: Bool = false
    private var levelMonitoringEnabled: Bool = false
    private var firstAudioReported: Bool = false
    private var recordingSessionID: Int = 0
    private var recordingAttemptID: UInt64 = 0
    private var recordingStartHostTime: UInt64 = 0
    private var recordingStopHostTime: UInt64?
    private var resampleSourceRate: Double = 0
    private var resampleSourceFrameCursor: Int64 = 0
    private var resampleNextSourcePosition: Double = 0
    private var resamplePreviousSample: Float?
    private var lastInputSampleEnd: Int64?
    private var captureHealthSampleCount: Int = 0
    private var captureHealthTotalSampleCount: Int = 0
    private var captureHealthSquareSum: Double = 0
    private var captureHealthPeak: Float = 0

    // Smoothing state (kept off ASRService/@MainActor)
    private var levelHistory: [CGFloat] = []
    private var smoothedLevel: CGFloat = 0.0
    private let historySize: Int = 2
    private let silenceThreshold: CGFloat = 0.04

    private static let hostTicksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.numer != 0 else { return 1_000_000_000 }
        return 1_000_000_000.0 * Double(info.denom) / Double(info.numer)
    }()

    init(
        audioBuffer: ThreadSafeAudioBuffer,
        onFirstAudio: @escaping (Int, UInt64, Int, Int, Double, Int, Int) -> Void,
        onLevel: @escaping (CGFloat) -> Void,
        onCaptureHealth: @escaping (Int, UInt64, Int, Int, Float, Float) -> Void
    ) {
        self.audioBuffer = audioBuffer
        self.onFirstAudio = onFirstAudio
        self.onLevel = onLevel
        self.onCaptureHealth = onCaptureHealth
    }

    func setRecordingEnabled(
        _ enabled: Bool,
        sessionID: Int = 0,
        attemptID: UInt64 = 0,
        startHostTime: UInt64 = 0
    ) {
        self.lock.lock()
        if enabled {
            self.firstAudioReported = false
            self.recordingSessionID = sessionID
            self.recordingAttemptID = attemptID
            self.recordingStartHostTime = startHostTime == 0 ? mach_absolute_time() : startHostTime
            self.recordingStopHostTime = nil
            self.resetResamplerLocked()
            self.lastInputSampleEnd = nil
            self.resetCaptureHealthLocked()
            self.recordingEnabled = true
        }
        if enabled == false {
            self.recordingEnabled = false
            self.recordingSessionID = 0
            self.recordingAttemptID = 0
            self.recordingStartHostTime = 0
            self.recordingStopHostTime = nil
            self.resetResamplerLocked()
            self.lastInputSampleEnd = nil
            self.resetCaptureHealthLocked()
            self.levelHistory.removeAll(keepingCapacity: true)
            self.smoothedLevel = 0.0
        }
        self.lock.unlock()
    }

    var isLevelMonitoringEnabled: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.levelMonitoringEnabled
    }

    func setLevelMonitoringEnabled(_ enabled: Bool) {
        self.lock.lock()
        self.levelMonitoringEnabled = enabled
        if enabled == false, self.recordingEnabled == false {
            self.levelHistory.removeAll(keepingCapacity: true)
            self.smoothedLevel = 0
        }
        self.lock.unlock()
        if enabled == false {
            self.onLevel(0)
        }
    }

    /// Sets the exact last acquisition time accepted for the current session.
    /// Capture remains enabled until the backend has stopped and drained.
    func markRecordingEnd(atHostTime hostTime: UInt64) {
        self.lock.lock()
        if self.recordingEnabled {
            self.recordingStopHostTime = hostTime
        }
        self.lock.unlock()
    }

    func finishRecording() {
        self.setRecordingEnabled(false)
        self.onLevel(0.0)
    }

    /// Compatibility for capture teardown paths. Session-scoped timestamps
    /// replace the old cross-session preroll buffer, so there is nothing to clear.
    func clearPreroll() {
        // Intentionally empty.
    }

    func handle(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let mono = Self.downmixToMono(buffer)
        guard mono.isEmpty == false else {
            self.onLevel(0.0)
            return
        }
        self.handleMonoSamples(
            mono,
            sampleRate: buffer.format.sampleRate,
            inputHostTime: time.isHostTimeValid ? time.hostTime : 0,
            inputSampleTime: time.isSampleTimeValid ? time.sampleTime : -1,
            originalFrameCount: Int(buffer.frameLength)
        )
    }

    func handle(
        samples: UnsafePointer<Float>,
        frameCount: Int,
        sampleRate: Double,
        inputHostTime: UInt64,
        inputSampleTime: Int64
    ) {
        guard frameCount > 0 else { return }
        self.handleMonoSamples(
            Array(UnsafeBufferPointer(start: samples, count: frameCount)),
            sampleRate: sampleRate,
            inputHostTime: inputHostTime,
            inputSampleTime: inputSampleTime,
            originalFrameCount: frameCount
        )
    }

    private func handleMonoSamples(
        _ samples: [Float],
        sampleRate: Double,
        inputHostTime: UInt64,
        inputSampleTime: Int64,
        originalFrameCount: Int
    ) {
        guard samples.isEmpty == false, sampleRate > 0 else {
            self.onLevel(0.0)
            return
        }

        self.lock.lock()
        let recordingEnabled = self.recordingEnabled
        let levelMonitoringEnabled = self.levelMonitoringEnabled
        guard recordingEnabled || levelMonitoringEnabled else {
            self.lock.unlock()
            return
        }
        if recordingEnabled == false {
            self.lock.unlock()
            self.onLevel(self.measureAudioLevel(samples).level)
            return
        }
        let startHostTime = self.recordingStartHostTime
        let stopHostTime = self.recordingStopHostTime
        let recordingSessionID = self.recordingSessionID
        let recordingAttemptID = self.recordingAttemptID
        self.lock.unlock()

        guard let acceptedRange = Self.acceptedFrameRange(
            frameCount: samples.count,
            sampleRate: sampleRate,
            packetHostTime: inputHostTime,
            startHostTime: startHostTime,
            stopHostTime: stopHostTime
        ) else {
            return
        }

        let acceptedSamples: [Float]
        if acceptedRange.lowerBound == 0, acceptedRange.upperBound == samples.count {
            acceptedSamples = samples
        } else {
            acceptedSamples = Array(samples[acceptedRange])
        }
        self.lock.lock()
        guard self.recordingEnabled,
              self.recordingSessionID == recordingSessionID,
              self.recordingAttemptID == recordingAttemptID
        else {
            self.lock.unlock()
            return
        }
        if inputSampleTime >= 0 {
            let acceptedSampleStart = inputSampleTime + Int64(acceptedRange.lowerBound)
            if let lastInputSampleEnd = self.lastInputSampleEnd,
               lastInputSampleEnd != acceptedSampleStart
            {
                // Do not interpolate across a hardware discontinuity or a
                // packet dropped under extreme consumer backpressure.
                self.resetResamplerLocked()
            }
            self.lastInputSampleEnd = inputSampleTime + Int64(acceptedRange.upperBound)
        }
        let mono16k = self.resampleTo16kLocked(
            acceptedSamples,
            sourceSampleRate: sampleRate
        )
        guard mono16k.isEmpty == false else {
            self.lock.unlock()
            return
        }
        let shouldReportFirstAudio = self.firstAudioReported == false
        if shouldReportFirstAudio {
            self.firstAudioReported = true
        }

        // Keep append and first-audio attribution inside the capture lock.
        // Disabling an attempt therefore returns only after every accepted
        // callback has committed its PCM and queued its attempt-scoped signal.
        self.audioBuffer.append(mono16k)
        if shouldReportFirstAudio {
            let acceptedHostTime = Self.hostTime(
                inputHostTime,
                advancedByFrames: acceptedRange.lowerBound,
                sampleRate: sampleRate
            )
            let acquisitionMs = Self.elapsedMilliseconds(
                from: startHostTime,
                to: acceptedHostTime
            )
            let deliveryMs = Self.elapsedMilliseconds(
                from: startHostTime,
                to: mach_absolute_time()
            )
            self.onFirstAudio(
                recordingSessionID,
                recordingAttemptID,
                Int(mono16k.count),
                originalFrameCount,
                sampleRate,
                acquisitionMs,
                deliveryMs
            )
        }
        self.lock.unlock()
        let measurement = self.measureAudioLevel(mono16k)
        self.onLevel(measurement.level)
        if let health = self.captureHealthDiagnostic(
            sampleCount: mono16k.count,
            rms: measurement.rms,
            peak: measurement.peak,
            sessionID: recordingSessionID,
            attemptID: recordingAttemptID
        ) {
            self.onCaptureHealth(
                recordingSessionID,
                recordingAttemptID,
                health.audioMs,
                health.sampleCount,
                health.rms,
                health.peak
            )
        }
    }

    private static func acceptedFrameRange(
        frameCount: Int,
        sampleRate: Double,
        packetHostTime: UInt64,
        startHostTime: UInt64,
        stopHostTime: UInt64?
    ) -> Range<Int>? {
        guard frameCount > 0 else { return nil }
        // AVAudioEngine can occasionally omit host time. It remains the
        // conservative fallback and accepts the whole callback in that case.
        guard packetHostTime > 0, startHostTime > 0 else { return 0..<frameCount }

        var lowerBound = 0
        if packetHostTime < startHostTime {
            let framesBeforeStart = Int(ceil(
                Double(startHostTime - packetHostTime) /
                    Self.hostTicksPerSecond * sampleRate
            ))
            lowerBound = min(max(framesBeforeStart, 0), frameCount)
        }

        var upperBound = frameCount
        if let stopHostTime {
            if stopHostTime <= packetHostTime {
                return nil
            }
            let framesBeforeStop = Int(floor(
                Double(stopHostTime - packetHostTime) /
                    Self.hostTicksPerSecond * sampleRate
            ))
            upperBound = min(max(framesBeforeStop, 0), frameCount)
        }

        guard lowerBound < upperBound else { return nil }
        return lowerBound..<upperBound
    }

    private static func hostTime(
        _ hostTime: UInt64,
        advancedByFrames frames: Int,
        sampleRate: Double
    ) -> UInt64 {
        guard hostTime > 0, frames > 0, sampleRate > 0 else { return hostTime }
        let ticks = Double(frames) / sampleRate * Self.hostTicksPerSecond
        return hostTime &+ UInt64(max(ticks.rounded(), 0))
    }

    private static func elapsedMilliseconds(from start: UInt64, to end: UInt64) -> Int {
        guard start > 0, end >= start else { return 0 }
        return Int((Double(end - start) / self.hostTicksPerSecond * 1000).rounded())
    }

    private func resetResamplerLocked() {
        self.resampleSourceRate = 0
        self.resampleSourceFrameCursor = 0
        self.resampleNextSourcePosition = 0
        self.resamplePreviousSample = nil
    }

    private func resetCaptureHealthLocked() {
        self.captureHealthSampleCount = 0
        self.captureHealthTotalSampleCount = 0
        self.captureHealthSquareSum = 0
        self.captureHealthPeak = 0
    }

    /// Stateful linear resampling keeps fractional phase across small hardware
    /// callbacks. Stateless per-packet conversion silently shortens 44.1 kHz
    /// recordings and introduces a discontinuity at every device cycle.
    private func resampleTo16kLocked(
        _ samples: [Float],
        sourceSampleRate: Double
    ) -> [Float] {
        guard samples.isEmpty == false else { return [] }
        if abs(self.resampleSourceRate - sourceSampleRate) > 0.5 {
            self.resetResamplerLocked()
            self.resampleSourceRate = sourceSampleRate
        }
        if sourceSampleRate == 16_000.0 {
            return samples
        }

        let chunkStart = Double(self.resampleSourceFrameCursor)
        let chunkEnd = chunkStart + Double(samples.count)
        let step = sourceSampleRate / 16_000.0
        var output: [Float] = []
        output.reserveCapacity(Int(ceil(Double(samples.count) / step)) + 1)

        while self.resampleNextSourcePosition < chunkEnd {
            let lowerFrame = Int64(floor(self.resampleNextSourcePosition))
            let fraction = Float(self.resampleNextSourcePosition - Double(lowerFrame))
            let localLower = lowerFrame - self.resampleSourceFrameCursor

            let lowerSample: Float
            let upperSample: Float
            if localLower < 0 {
                guard localLower == -1,
                      let previousSample = self.resamplePreviousSample
                else { break }
                lowerSample = previousSample
                upperSample = samples[0]
            } else {
                let index = Int(localLower)
                guard index < samples.count else { break }
                lowerSample = samples[index]
                if fraction == 0 {
                    upperSample = lowerSample
                } else {
                    guard index + 1 < samples.count else { break }
                    upperSample = samples[index + 1]
                }
            }

            output.append(lowerSample + (upperSample - lowerSample) * fraction)
            self.resampleNextSourcePosition += step
        }

        self.resampleSourceFrameCursor += Int64(samples.count)
        self.resamplePreviousSample = samples.last
        return output
    }

    private func measureAudioLevel(_ samples: [Float]) -> (level: CGFloat, rms: Float, peak: Float) {
        guard samples.isEmpty == false else { return (0, 0, 0) }

        var sum: Float = 0.0
        vDSP_svesq(samples, 1, &sum, vDSP_Length(samples.count))
        let rms = sqrt(sum / Float(samples.count))
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))

        // Noise gate
        if rms < 0.002 {
            return (self.applySmoothingAndThreshold(0), rms, peak)
        }

        // dB -> normalized [0, 1]
        let dbLevel = 20 * log10(max(rms, 1e-10))
        let normalizedLevel = max(0, min(1, (dbLevel + 55) / 55))
        return (self.applySmoothingAndThreshold(CGFloat(normalizedLevel)), rms, peak)
    }

    private func captureHealthDiagnostic(
        sampleCount: Int,
        rms: Float,
        peak: Float,
        sessionID: Int,
        attemptID: UInt64
    ) -> (audioMs: Int, sampleCount: Int, rms: Float, peak: Float)? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.recordingEnabled,
              self.recordingSessionID == sessionID,
              self.recordingAttemptID == attemptID
        else { return nil }

        self.captureHealthSampleCount += sampleCount
        self.captureHealthTotalSampleCount += sampleCount
        self.captureHealthSquareSum += Double(rms * rms) * Double(sampleCount)
        self.captureHealthPeak = max(self.captureHealthPeak, peak)
        guard self.captureHealthSampleCount >= 16_000 else { return nil }

        let windowSampleCount = self.captureHealthSampleCount
        let windowRMS = Float(sqrt(self.captureHealthSquareSum / Double(windowSampleCount)))
        let result = (
            audioMs: Int((Double(self.captureHealthTotalSampleCount) / 16_000 * 1000).rounded()),
            sampleCount: windowSampleCount,
            rms: windowRMS,
            peak: self.captureHealthPeak
        )
        self.captureHealthSampleCount = 0
        self.captureHealthSquareSum = 0
        self.captureHealthPeak = 0
        return result
    }

    private func applySmoothingAndThreshold(_ newLevel: CGFloat) -> CGFloat {
        self.lock.lock()
        defer { self.lock.unlock() }

        self.levelHistory.append(newLevel)
        if self.levelHistory.count > self.historySize {
            self.levelHistory.removeFirst()
        }

        let average = self.levelHistory.reduce(0, +) / CGFloat(self.levelHistory.count)
        let smoothingFactor: CGFloat = 0.7
        self.smoothedLevel = (smoothingFactor * newLevel) + ((1 - smoothingFactor) * average)

        if self.smoothedLevel < self.silenceThreshold {
            return 0.0
        }

        return self.smoothedLevel
    }

    private static func downmixToMono(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        if channels == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        }
        var mono = [Float](repeating: 0, count: frameCount)
        for c in 0..<channels {
            let src = channelData[c]
            vDSP_vadd(src, 1, mono, 1, &mono, 1, vDSP_Length(frameCount))
        }
        var div = Float(channels)
        vDSP_vsdiv(mono, 1, &div, &mono, 1, vDSP_Length(frameCount))
        return mono
    }
}
