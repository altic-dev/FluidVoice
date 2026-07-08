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

/// Serializes all CoreML transcription operations to prevent concurrent access issues.
/// The actor ensures only one transcription runs at a time, preventing CoreML race conditions.
/// Serializes all CoreML transcription operations to prevent concurrent access issues.
/// This implementation enforces strict serialization (non-reentrant) using a task chain.
private actor TranscriptionExecutor {
    private var lastTask: Task<Void, Never>?
    private var currentOperationTask: Task<Any, Error>?

    func run<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        let previous = self.lastTask
        let task = Task<T, Error> {
            _ = await previous?.result
            return try await operation()
        }
        self.currentOperationTask = Task<Any, Error> { try await task.value }
        self.lastTask = Task { _ = try? await task.value }
        return try await task.value
    }

    /// Cancels any pending operations and waits for the current chain to complete.
    /// This ensures no in-flight transcription tasks can access deallocated memory.
    func cancelAndAwaitPending() async {
        // Cancel the current operation if running
        self.currentOperationTask?.cancel()
        // Wait for the last task in the chain to complete (or be cancelled)
        _ = await self.lastTask?.result
        self.lastTask = nil
        self.currentOperationTask = nil
    }
}

// swiftlint:disable type_body_length
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
/// ## Usage
/// ```swift
/// let asrService = ASRService()
/// await asrService.start() // Begin recording
/// // ... speak ...
/// let transcribedText = await asrService.stop() // Stop and get transcription
/// ```
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

    private var isStarting: Bool = false // Guard against re-entrant start() calls
    private var hasCompletedFirstTranscription: Bool = false // Track if model has warmed up with first transcription
    private var lastBoostHitTerm: String?
    private var hasPendingParakeetVocabularyReload: Bool = false
    private var vocabularyChangeObserver: NSObjectProtocol?

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

    private func streamingChunkErrorCategory(for error: Error) -> String {
        if error is CancellationError {
            return "cancelled"
        }

        let nsError = error as NSError
        switch nsError.domain {
        case AVFoundationErrorDomain:
            return "avfoundation"
        case NSOSStatusErrorDomain:
            return "osstatus"
        case NSCocoaErrorDomain:
            return "cocoa"
        default:
            return "other"
        }
    }

    private func shouldCaptureStreamingChunkAnalytics(success: Bool) -> Bool {
        if success {
            self.streamingChunkAnalyticsSuccessCount += 1
            if self.streamingChunkAnalyticsSuccessCount == 1 {
                return true
            }
            return self.streamingChunkAnalyticsSuccessCount % self.streamingChunkAnalyticsSuccessSampleRate == 0
        }

        let now = Date()
        guard let lastFailureCaptureAt = self.lastStreamingChunkFailureAnalyticsAt else {
            self.lastStreamingChunkFailureAnalyticsAt = now
            return true
        }

        guard now.timeIntervalSince(lastFailureCaptureAt) >= self.streamingChunkFailureMinIntervalSeconds else {
            return false
        }

        self.lastStreamingChunkFailureAnalyticsAt = now
        return true
    }

    private func captureStreamingChunkAnalytics(
        success: Bool,
        chunkSampleCount: Int,
        latencyMs: Int,
        error: Error? = nil
    ) {
        guard self.shouldCaptureStreamingChunkAnalytics(success: success) else { return }

        let dims = self.currentTranscriptionAnalyticsDimensions()
        var properties: [String: Any] = [
            "success": success,
            "latency_ms": latencyMs,
            "chunk_samples": chunkSampleCount,
            "chunk_audio_seconds": Double(chunkSampleCount) / 16_000.0,
            "transcription_provider": dims.provider,
            "transcription_model": dims.model,
            "success_sample_rate_chunks": self.streamingChunkAnalyticsSuccessSampleRate,
            "failure_min_interval_seconds": self.streamingChunkFailureMinIntervalSeconds,
        ]

        if let error {
            properties["error_category"] = self.streamingChunkErrorCategory(for: error)
        }

        AnalyticsService.shared.capture(
            .transcriptionChunkProcessed,
            properties: properties
        )
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
    func downloadModel(_ model: SettingsStore.SpeechModel, progressHandler: ((Double) -> Void)?) async throws {
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
                            externalProgressHandler: progressHandler
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

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
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

    private var directAudioInput: DirectCoreAudioInput?
    private var activeAudioCaptureBackend: AudioCaptureBackend = .none

    private var hasPreparedAudioCapture: Bool {
        self.directAudioInput != nil || self.hasWarmAudioEngine
    }

    private func retireAudioEngine(reason: String) {
        self.audioEngineStandbyTask?.cancel()
        self.audioEngineStandbyTask = nil

        if let directAudioInput = self.directAudioInput {
            directAudioInput.invalidate()
            self.directAudioInput = nil
        }
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

        let oldEngine = self.engineStorage
        self.engineStorage = nil
        if let oldEngine {
            DispatchQueue.global(qos: .utility).async { _ = oldEngine }
        }
        DebugLogger.shared.debug("Audio engine retired (\(reason))", source: "ASRService")
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
            self?.retireWarmAudioEngineIfIdle()
        }
    }

    private func retireWarmAudioEngineIfIdle() {
        guard self.isRunning == false, self.isStarting == false else { return }
        self.coolDownAudioEngineStandby(reason: "standby_timeout")
    }

    private func coolDownAudioEngineStandby(reason: String) {
        self.audioEngineStandbyTask?.cancel()
        self.audioEngineStandbyTask = nil

        if let directAudioInput = self.directAudioInput {
            directAudioInput.invalidate()
            self.directAudioInput = nil
        }
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
        self.benchmarkLog("audio_engine_standby cooled=true reason=\(reason)")
        DebugLogger.shared.debug("Audio engine cooled to stopped warm state (\(reason))", source: "ASRService")
    }

    private func prewarmAudioEngineIfPossible(reason: String) {
        guard self.micStatus == .authorized else {
            DebugLogger.shared.debug("Audio engine prewarm skipped - mic not authorized", source: "ASRService")
            return
        }
        guard self.isRunning == false, self.isStarting == false else {
            DebugLogger.shared.debug("Audio engine prewarm skipped - capture active", source: "ASRService")
            return
        }
        guard self.hasPreparedAudioCapture == false else {
            DebugLogger.shared.debug("Audio capture prewarm skipped - backend already prepared", source: "ASRService")
            return
        }

        let startedAt = Date().timeIntervalSince1970
        if SettingsStore.shared.experimentalDirectAudioCaptureEnabled,
           self.prepareDirectAudioInputIfPossible(reason: reason)
        {
            self.benchmarkLog("direct_audio_prewarm reason=\(reason) elapsedMs=\(self.elapsedMilliseconds(since: startedAt))")
            return
        }

        do {
            try self.configureSession()
            self.benchmarkLog("audio_engine_prewarm reason=\(reason) elapsedMs=\(self.elapsedMilliseconds(since: startedAt))")
        } catch {
            self.retireAudioEngine(reason: "prewarm_failed")
            DebugLogger.shared.warning("Audio engine prewarm failed: \(error.localizedDescription)", source: "ASRService")
        }
    }

    private func resolvedInputDeviceForCapture() -> AudioDevice.Device? {
        if SettingsStore.shared.syncAudioDevicesWithSystem == false,
           let preferredUID = SettingsStore.shared.preferredInputDeviceUID,
           preferredUID.isEmpty == false,
           let preferredDevice = AudioDevice.getInputDevice(byUID: preferredUID)
        {
            return preferredDevice
        }
        return AudioDevice.getDefaultInputDevice()
    }

    /// Prepares the direct device callback without starting hardware IO. This
    /// keeps the default idle state privacy-friendly while removing device and
    /// ring allocation from the hotkey path.
    @discardableResult
    private func prepareDirectAudioInputIfPossible(reason: String) -> Bool {
        guard self.micStatus == .authorized else { return false }
        guard let device = self.resolvedInputDeviceForCapture() else {
            DebugLogger.shared.warning("No input device is available for direct capture", source: "ASRService")
            return false
        }

        if let directAudioInput = self.directAudioInput,
           directAudioInput.deviceID == device.id
        {
            return true
        }

        self.directAudioInput?.invalidate()
        self.directAudioInput = nil

        let pipeline = self.audioCapturePipeline
        do {
            let directAudioInput = try DirectCoreAudioInput(deviceID: device.id) { samples, frameCount, sampleRate, inputHostTime, inputSampleTime in
                pipeline.handle(
                    samples: samples,
                    frameCount: frameCount,
                    sampleRate: sampleRate,
                    inputHostTime: inputHostTime,
                    inputSampleTime: inputSampleTime
                )
            }
            self.directAudioInput = directAudioInput
            DebugLogger.shared.info(
                "Prepared direct Core Audio input '\(device.name)' " +
                    "(\(Int(directAudioInput.sampleRate.rounded()))Hz, " +
                    "\(directAudioInput.hardwareBufferFrameSize) frames, reason=\(reason))",
                source: "ASRService"
            )
            return true
        } catch {
            DebugLogger.shared.warning(
                "Direct Core Audio input unavailable for '\(device.name)': \(error.localizedDescription). " +
                    "Falling back to AVAudioEngine.",
                source: "ASRService"
            )
            return false
        }
    }

    private func startPreferredAudioCapture() throws {
        let directCaptureEnabled = SettingsStore.shared.experimentalDirectAudioCaptureEnabled
        if directCaptureEnabled,
           self.prepareDirectAudioInputIfPossible(reason: "recording_start"),
           let directAudioInput = self.directAudioInput
        {
            do {
                try directAudioInput.start()
                self.activeAudioCaptureBackend = .directCoreAudio
                let callbackMs = Int(
                    (Double(directAudioInput.hardwareBufferFrameSize) /
                        directAudioInput.sampleRate * 1000).rounded()
                )
                self.benchmarkLog(
                    "audio_backend kind=direct_core_audio device=\(directAudioInput.deviceID) " +
                        "frames=\(directAudioInput.hardwareBufferFrameSize) callbackMs=\(callbackMs)"
                )
                return
            } catch {
                DebugLogger.shared.warning(
                    "Direct Core Audio start failed: \(error.localizedDescription). Falling back to AVAudioEngine.",
                    source: "ASRService"
                )
                directAudioInput.invalidate()
                self.directAudioInput = nil
            }
        }

        if directCaptureEnabled == false, let directAudioInput = self.directAudioInput {
            directAudioInput.invalidate()
            self.directAudioInput = nil
        }

        self.benchmarkLog(
            "audio_backend kind=av_audio_engine_fallback reason=" +
                (directCaptureEnabled ? "direct_unavailable" : "experimental_disabled")
        )
        try self.configureSession()
        try self.startEngine()
        try self.setupEngineTap()
        self.activeAudioCaptureBackend = .audioEngine
    }

    private func stopActiveAudioCapture() {
        switch self.activeAudioCaptureBackend {
        case .directCoreAudio:
            if let directAudioInput = self.directAudioInput {
                let status = directAudioInput.stop()
                if status != noErr {
                    DebugLogger.shared.warning(
                        "Direct Core Audio stop returned OSStatus \(status)",
                        source: "ASRService"
                    )
                }
                let droppedPackets = directAudioInput.droppedPacketCount
                if droppedPackets > 0 {
                    DebugLogger.shared.warning(
                        "Direct Core Audio dropped \(droppedPackets) packet(s)",
                        source: "ASRService"
                    )
                }
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

    /// Applies the experimental capture preference immediately when idle.
    /// If a recording transition is already underway, start() reads the latest
    /// persisted value and the following session will use it.
    func refreshAudioCaptureBackendPreference() {
        guard self.isRunning == false, self.isStarting == false else {
            DebugLogger.shared.debug(
                "Audio capture preference changed during a recording transition; deferring backend refresh",
                source: "ASRService"
            )
            return
        }

        self.retireAudioEngine(reason: "capture_preference_changed")
        self.prewarmAudioEngineIfPossible(reason: "capture_preference_changed")
    }

    private var inputFormat: AVAudioFormat?
    private var micPermissionGranted = false

    // Internal access for MeetingTranscriptionService to share models
    // Note: Only available when using FluidAudioProvider (Apple Silicon)
    #if arch(arm64)
    var asrManager: AsrManager? {
        (self.transcriptionProvider as? FluidAudioProvider)?.underlyingManager
    }
    #else
    var asrManager: Any? { nil }
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
    private let streamingChunkAnalyticsSuccessSampleRate: Int = 50
    private let streamingChunkFailureMinIntervalSeconds: TimeInterval = 15
    private var streamingChunkAnalyticsSuccessCount: Int = 0
    private var lastStreamingChunkFailureAnalyticsAt: Date?
    private let transcriptionExecutor = TranscriptionExecutor() // Serializes all CoreML access
    private var engineConfigurationChangeObserver: NSObjectProtocol?
    private var audioRouteRecoveryTask: Task<Void, Never>?
    private let audioRouteRecoveryDelayNanoseconds: UInt64 = 1_000_000_000
    private var audioEngineStandbyTask: Task<Void, Never>?
    private let audioEngineStandbyNanoseconds: UInt64 = 8_000_000_000
    private var isEngineTapInstalled = false
    private var isRecoveringAudioRoute = false

    /// Tracks whether we paused system media for this recording session.
    /// Used to resume playback only if we were the ones who paused it.
    private var didPauseMediaForThisSession: Bool = false

    private var audioLevelSubject = PassthroughSubject<CGFloat, Never>()
    var audioLevelPublisher: AnyPublisher<CGFloat, Never> { self.audioLevelSubject.eraseToAnyPublisher() }
    private var lastAudioLevelSentAt: TimeInterval = 0

    func consumeLastCompletedAudioSnapshot() -> DictationAudioSnapshot? {
        let snapshot = self.lastCompletedAudioSnapshot
        self.lastCompletedAudioSnapshot = nil
        return snapshot
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
    private lazy var audioCapturePipeline: AudioCapturePipeline = .init(
        audioBuffer: self.audioBuffer,
        onFirstAudio: { sessionID, sampleCount, frameLength, sampleRate, acquisitionMs, elapsedMs in
            DispatchQueue.main.async {
                let bufferMs = Int((Double(frameLength) / sampleRate * 1000).rounded())
                DebugLogger.shared.benchmark(
                    "ASR_BENCH",
                    message: "session=\(sessionID) first_audio sampleCount=\(sampleCount) frameLength=\(frameLength) sampleRate=\(Int(sampleRate.rounded())) bufferMs=\(bufferMs) acquisitionMs=\(acquisitionMs) elapsedMs=\(elapsedMs)",
                    source: "ASRBenchmark"
                )
            }
        },
        onLevel: { [weak self] level in
            // Keep Combine sends on the main queue.
            DispatchQueue.main.async { [weak self] in
                self?.audioLevelSubject.send(level)
            }
        }
    )

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
    }

    deinit {
        self.directAudioInput?.invalidate()
        if let observer = self.vocabularyChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = self.engineConfigurationChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
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
    func initialize() {
        // Check microphone permission (deferred from init to avoid AVFCapture race condition)
        self.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        self.micPermissionGranted = (self.micStatus == .authorized)

        self.registerDefaultDeviceChangeListener()
        self.registerEngineConfigurationChangeObserver()
        self.registerDeviceListChangeListener()

        // Initialize device list cache
        self.cacheCurrentDeviceList(AudioDevice.listInputDevices())

        // Register the input callback and allocate its fixed ring now. This
        // does not start the device or show the microphone privacy indicator.
        self.prewarmAudioEngineIfPossible(reason: "startup")

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
                    self.prewarmAudioEngineIfPossible(reason: "startup")
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
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard let self = self else { return }
            Task { @MainActor in
                self.micPermissionGranted = granted
                self.micStatus = granted ? .authorized : .denied
                if granted {
                    self.prewarmAudioEngineIfPossible(reason: "permission_granted")
                }
            }
        }
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
    func start(
        forDictionaryTraining: Bool = false,
        onCaptureStarted: (@MainActor () -> Void)? = nil
    ) async {
        DebugLogger.shared.info("🎤 START() called - beginning recording session", source: "ASRService")

        guard self.micStatus == .authorized else {
            DebugLogger.shared.error("❌ START() blocked - mic not authorized", source: "ASRService")
            return
        }
        guard self.isRunning == false, self.isStarting == false else {
            DebugLogger.shared.warning("⚠️ START() blocked - already running (started: \(self.isRunning), starting: \(self.isStarting))", source: "ASRService")
            return
        }

        // Reset media pause state for this session
        self.didPauseMediaForThisSession = false
        self.audioEngineStandbyTask?.cancel()
        self.audioEngineStandbyTask = nil
        self.audioRouteRecoveryTask?.cancel()
        self.audioRouteRecoveryTask = nil
        self.isRecoveringAudioRoute = false

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
        self.benchmarkRecordingStartedAt = Date().timeIntervalSince1970
        self.benchmarkStreamingChunkIndex = 0
        self.benchmarkCompletedStreamingChunks = 0
        self.benchmarkLastChunkSampleCount = 0
        self.streamingChunkAnalyticsSuccessCount = 0
        self.lastStreamingChunkFailureAnalyticsAt = nil
        (self.transcriptionProvider as? FluidAudioProvider)?.resetStreamingPreviewCache()
        self.audioCapturePipeline.setRecordingEnabled(
            true,
            sessionID: self.benchmarkSessionID,
            startHostTime: mach_absolute_time()
        )
        self.refreshWordBoostStatus()
        let dims = self.currentTranscriptionAnalyticsDimensions()
        self.benchmarkLog("recording_start model=\(dims.model) provider=\(dims.provider) supportsStreaming=\(SettingsStore.shared.selectedSpeechModel.supportsStreaming)")
        DebugLogger.shared.debug("✅ Buffers cleared", source: "ASRService")

        self.isStarting = true
        defer { self.isStarting = false }
        self.isDictionaryTrainingCaptureActive = false

        do {
            try self.startPreferredAudioCapture()
            self.isRunning = true
            self.isDictionaryTrainingCaptureActive = forDictionaryTraining
            DebugLogger.shared.info("✅ Audio capture running", source: "ASRService")
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
                    return
                }
                self.didPauseMediaForThisSession = didPause
                if didPause {
                    DebugLogger.shared.info("🎵 Paused system media for transcription", source: "ASRService")
                }
            }

            // Start monitoring the currently bound device for disconnection
            if let currentDevice = getCurrentlyBoundInputDevice() {
                DebugLogger.shared.debug("👀 Starting device monitoring for: \(currentDevice.name)", source: "ASRService")
                self.startMonitoringDevice(currentDevice.id)
            } else {
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
        } catch {
            self.isDictionaryTrainingCaptureActive = false
            self.audioCapturePipeline.setRecordingEnabled(false)
            self.isRunning = false
            self.stopActiveAudioCapture()
            self.retireAudioEngine(reason: "start_failed")
            DebugLogger.shared.error("Failed to start ASR session: \(error)", source: "ASRService")

            // Resume media if we paused it before the failure
            if self.didPauseMediaForThisSession {
                await MediaPlaybackService.shared.resumeIfWePaused(true)
                self.didPauseMediaForThisSession = false
                DebugLogger.shared.info("🎵 Resumed system media after start failure", source: "ASRService")
            }

            // Provide user-friendly error feedback
            let errorMessage: String
            if let nsError = error as NSError?, nsError.domain == "ASRService" {
                if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
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

            // Post notification for UI to display
            NotificationCenter.default.post(
                name: NSNotification.Name("ASRServiceStartFailed"),
                object: nil,
                userInfo: ["errorMessage": errorMessage]
            )
        }
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
        self.lastCompletedAudioSnapshot = nil
        let stopStartedAt = Date().timeIntervalSince1970
        self.benchmarkLog("stop_start ageMs=\(self.elapsedMilliseconds(since: self.benchmarkRecordingStartedAt)) bufferedSamples=\(self.audioBuffer.count)")

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

        self.audioRouteRecoveryTask?.cancel()
        self.audioRouteRecoveryTask = nil
        self.isRecoveringAudioRoute = false

        // Capture media pause state before we reset it, for resuming at the end
        let shouldResumeMedia = SettingsStore.shared.pauseMediaDuringTranscription && self.didPauseMediaForThisSession
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

        self.stopActiveAudioCapture()
        self.audioCapturePipeline.finishRecording()

        // A prepared direct IOProc owns only fixed memory and registration; it
        // does not run hardware, show the mic indicator, or hold Bluetooth in
        // headset mode. Keep it prepared across idle periods. The heavier
        // AVAudioEngine fallback retains its existing bounded timeout.
        if self.directAudioInput != nil {
            self.audioEngineStandbyTask?.cancel()
            self.audioEngineStandbyTask = nil
            DebugLogger.shared.debug("♻️ Direct audio capture remains prepared", source: "ASRService")
        } else {
            self.scheduleAudioEngineStandbyRetirement()
        }

        // Capture has fully ended — invoke the callback so callers can play a
        // stop cue or release capture-dependent UI without waiting on the
        // (potentially slow) final transcription pass.
        await MainActor.run { onCaptureStopped?() }

        self.benchmarkLog("audio_capture_prepared retained=\(self.directAudioInput != nil)")

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
        self.streamingChunkAnalyticsSuccessCount = 0
        self.lastStreamingChunkFailureAnalyticsAt = nil

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
                finalSource = "dictionaryTraining"
            } else {
                result = try await self.transcriptionExecutor.run { [provider] in
                    try await provider.transcribeFinal(pcm)
                }
                finalSource = "full"
            }
            let finalElapsedMs = self.elapsedMilliseconds(since: finalStartedAt)
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

            return outputText
        } catch {
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

        let estimatedSamples = try LocalAPIAudioDecoder.validateDurationWithinLimit(for: fileURL)

        try await self.ensureAsrReady()
        let provider = self.transcriptionProvider
        guard provider.isReady else {
            throw NSError(
                domain: "ASRService",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Transcription provider is not ready."]
            )
        }

        guard provider.prefersNativeFileTranscription else {
            let samples = try LocalAPIAudioDecoder.samples(from: fileURL)
            let result = try await self.transcribeSamplesForAPI(samples)
            return (result, samples.count)
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
        guard self.isRunning else { return }
        defer {
            self.applyPendingParakeetVocabularyReloadIfNeeded()
            self.isDictionaryTrainingCaptureActive = false
        }

        self.audioRouteRecoveryTask?.cancel()
        self.audioRouteRecoveryTask = nil
        self.isRecoveringAudioRoute = false

        // Capture media pause state before we reset it, for resuming at the end
        let shouldResumeMedia = SettingsStore.shared.pauseMediaDuringTranscription && self.didPauseMediaForThisSession
        self.didPauseMediaForThisSession = false // Reset for next session

        DebugLogger.shared.info("🛑 Stopping recording - releasing audio devices", source: "ASRService")

        // CRITICAL: Set isRunning to false FIRST to signal any in-flight chunks to abort early
        self.isRunning = false
        self.audioCapturePipeline.setRecordingEnabled(false)

        // Stop monitoring device
        self.stopMonitoringDevice()

        self.stopActiveAudioCapture()
        DebugLogger.shared.debug("Audio capture stopped", source: "ASRService")

        // Cancel/no-transcription paths stay conservative and retire the engine.
        self.retireAudioEngine(reason: "stop_without_transcription")

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
        self.streamingChunkAnalyticsSuccessCount = 0
        self.lastStreamingChunkFailureAnalyticsAt = nil
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

        guard SettingsStore.shared.syncAudioDevicesWithSystem == false else {
            DebugLogger.shared.info("Sync mode enabled - using system default input device", source: "ASRService")
            return true
        }

        guard let preferredUID = SettingsStore.shared.preferredInputDeviceUID, preferredUID.isEmpty == false else {
            DebugLogger.shared.info("No preferred input device set - using system default", source: "ASRService")
            return true
        }

        DebugLogger.shared.debug("Attempting to bind to preferred input device (uid: \(preferredUID))", source: "ASRService")

        guard let device = AudioDevice.getInputDevice(byUID: preferredUID) else {
            DebugLogger.shared.warning(
                "Preferred input device not found (uid: \(preferredUID)). Falling back to system default input.",
                source: "ASRService"
            )
            // Try to use system default as fallback
            return self.tryBindToSystemDefaultInput()
        }

        DebugLogger.shared.debug("Found preferred input device: '\(device.name)' (id: \(device.id))", source: "ASRService")

        let ok = self.setEngineInputDevice(deviceID: device.id, deviceUID: device.uid, deviceName: device.name)
        if ok == false {
            DebugLogger.shared.warning(
                "Failed to bind engine input to preferred device '\(device.name)' (uid: \(device.uid)). Trying system default input.",
                source: "ASRService"
            )
            // Try to use system default as fallback
            return self.tryBindToSystemDefaultInput()
        }

        DebugLogger.shared.info("✅ Successfully bound input to '\(device.name)'", source: "ASRService")
        return true
    }

    /// In independent mode, attempt to bind AVAudioEngine's output to the user's preferred output device.
    /// In sync-with-system mode, we intentionally do nothing so the engine follows macOS defaults.
    /// Returns true if binding succeeded or if no binding was needed, false if binding failed completely.
    @discardableResult
    private func bindPreferredOutputDeviceIfNeeded() -> Bool {
        DebugLogger.shared.debug("bindPreferredOutputDeviceIfNeeded() - Starting output device binding", source: "ASRService")

        guard SettingsStore.shared.syncAudioDevicesWithSystem == false else {
            DebugLogger.shared.info("Sync mode enabled - using system default output device", source: "ASRService")
            return true
        }

        guard let preferredUID = SettingsStore.shared.preferredOutputDeviceUID, preferredUID.isEmpty == false else {
            DebugLogger.shared.info("No preferred output device set - using system default", source: "ASRService")
            return true
        }

        DebugLogger.shared.debug("Attempting to bind to preferred output device (uid: \(preferredUID))", source: "ASRService")

        guard let device = AudioDevice.getOutputDevice(byUID: preferredUID) else {
            DebugLogger.shared.warning(
                "Preferred output device not found (uid: \(preferredUID)). Falling back to system default output.",
                source: "ASRService"
            )
            // Try to use system default as fallback
            return self.tryBindToSystemDefaultOutput()
        }

        DebugLogger.shared.debug("Found preferred output device: '\(device.name)' (id: \(device.id))", source: "ASRService")

        let ok = self.setEngineOutputDevice(deviceID: device.id, deviceUID: device.uid, deviceName: device.name)
        if ok == false {
            DebugLogger.shared.warning(
                "Failed to bind engine output to preferred device '\(device.name)' (uid: \(device.uid)). Trying system default output.",
                source: "ASRService"
            )
            // Try to use system default as fallback
            return self.tryBindToSystemDefaultOutput()
        }

        DebugLogger.shared.info("✅ Successfully bound output to '\(device.name)'", source: "ASRService")
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

    private func startEngine() throws {
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
                    self.retireAudioEngine(reason: "start_retry")
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

    private func scheduleAudioRouteRecovery(reason: String) {
        guard self.isRunning else {
            self.audioLevelSubject.send(0.0)
            if self.hasPreparedAudioCapture {
                self.retireAudioEngine(reason: "idle_route_change:\(reason)")
                self.prewarmAudioEngineIfPossible(reason: "idle_route_change")
            }
            return
        }
        guard self.isRecoveringAudioRoute == false else {
            DebugLogger.shared.debug("Ignoring audio route recovery request during active recovery (\(reason))", source: "ASRService")
            return
        }

        DebugLogger.shared.warning("Audio route changed while recording; scheduling recovery (\(reason))", source: "ASRService")
        self.audioCapturePipeline.setRecordingEnabled(false)
        self.audioLevelSubject.send(0.0)

        self.audioRouteRecoveryTask?.cancel()
        let recoveryDelayNanoseconds = self.audioRouteRecoveryDelayNanoseconds
        self.audioRouteRecoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: recoveryDelayNanoseconds)
            } catch {
                return
            }
            await self?.recoverAudioRoute(reason: reason)
        }
    }

    @MainActor
    private func recoverAudioRoute(reason: String) async {
        guard self.isRunning else { return }
        guard self.isRecoveringAudioRoute == false else { return }

        self.isRecoveringAudioRoute = true
        defer {
            self.isRecoveringAudioRoute = false
            self.audioRouteRecoveryTask = nil
        }

        DebugLogger.shared.info("Recovering audio route after \(reason)", source: "ASRService")
        self.audioCapturePipeline.setRecordingEnabled(false)

        self.stopMonitoringDevice()
        self.stopActiveAudioCapture()
        self.retireAudioEngine(reason: "audio_route_recovery")

        do {
            self.audioCapturePipeline.setRecordingEnabled(
                true,
                sessionID: self.benchmarkSessionID,
                startHostTime: mach_absolute_time()
            )
            try self.startPreferredAudioCapture()

            if let currentDevice = self.getCurrentlyBoundInputDevice() {
                self.startMonitoringDevice(currentDevice.id)
            }

            DebugLogger.shared.info("Audio route recovery succeeded", source: "ASRService")
        } catch {
            self.audioCapturePipeline.setRecordingEnabled(false)
            self.stopActiveAudioCapture()
            DebugLogger.shared.error("Audio route recovery failed: \(error)", source: "ASRService")
            await self.stopWithoutTranscription()
            NotificationCenter.default.post(
                name: NSNotification.Name("ASRServiceDeviceDisconnected"),
                object: nil,
                userInfo: ["errorMessage": "Recording stopped because the audio device changed."]
            )
        }
    }

    private func handleDefaultInputChanged() {
        // If we're not syncing with macOS system settings, ignore system-default changes.
        // In independent mode, we explicitly bind to `preferredInputDeviceUID` on start/restart.
        guard SettingsStore.shared.syncAudioDevicesWithSystem else {
            DebugLogger.shared.debug("Ignoring system default input change (sync disabled)", source: "ASRService")
            return
        }

        self.scheduleAudioRouteRecovery(reason: "default input changed")
    }

    private func handleDefaultOutputChanged() {
        guard SettingsStore.shared.syncAudioDevicesWithSystem else {
            DebugLogger.shared.debug("Ignoring system default output change (sync disabled)", source: "ASRService")
            return
        }

        // Input-only direct capture has no output device dependency.
        if self.directAudioInput != nil {
            return
        }

        self.scheduleAudioRouteRecovery(reason: "default output changed")
    }

    private func handleEngineConfigurationChanged(_ changedEngine: AVAudioEngine?) {
        guard let changedEngine,
              let currentEngine = self.engineStorage as? AVAudioEngine,
              changedEngine === currentEngine
        else { return }

        self.scheduleAudioRouteRecovery(reason: "engine configuration changed")
    }

    private func registerEngineConfigurationChangeObserver() {
        guard self.engineConfigurationChangeObserver == nil else { return }

        self.engineConfigurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let changedEngine = notification.object as? AVAudioEngine else { return }
            Task { @MainActor [weak self, weak changedEngine] in
                self?.handleEngineConfigurationChanged(changedEngine)
            }
        }
    }

    private var defaultInputListenerInstalled = false
    private var defaultInputListenerToken: AudioObjectPropertyListenerBlock?
    private var defaultOutputListenerToken: AudioObjectPropertyListenerBlock?
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
        let preferredUID = SettingsStore.shared.preferredInputDeviceUID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let currentDevices = AudioDevice.listInputDevices()
            let systemDefault = AudioDevice.getDefaultInputDevice()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let cachedUIDs = self.cachedDeviceUIDs

                DebugLogger.shared.debug("Current input devices: \(currentDevices.map { $0.name }.joined(separator: ", "))", source: "ASRService")

                // Check if preferred device is now available (for auto-switch)
                if let preferredUID,
                   let preferredDevice = currentDevices.first(where: { $0.uid == preferredUID })
                {
                    if let currentDevice = self.getCurrentlyBoundInputDevice(),
                       currentDevice.uid != preferredUID,
                       currentDevice.uid == systemDefault?.uid
                    {
                        DebugLogger.shared.info(
                            "🔌 Preferred device '\(preferredDevice.name)' reconnected. Auto-switching...",
                            source: "ASRService"
                        )

                        if self.isRunning {
                            DebugLogger.shared.info(
                                "Recording in progress - deferring preferred device switch until audio route recovery",
                                source: "ASRService"
                            )
                            self.scheduleAudioRouteRecovery(reason: "preferred input reconnected")
                        } else {
                            DebugLogger.shared.info("Not recording - updating binding for next session", source: "ASRService")
                            _ = self.setEngineInputDevice(
                                deviceID: preferredDevice.id,
                                deviceUID: preferredDevice.uid,
                                deviceName: preferredDevice.name
                            )
                        }
                    }
                }

                // Check for newly connected Bluetooth devices (auto-switch)
                for device in currentDevices {
                    if device.name.localizedCaseInsensitiveContains("airpods") ||
                        device.name.localizedCaseInsensitiveContains("bluetooth")
                    {
                        if !cachedUIDs.contains(device.uid) {
                            DebugLogger.shared.info(
                                "🎧 New Bluetooth device detected: '\(device.name)'. Auto-switching...",
                                source: "ASRService"
                            )

                            SettingsStore.shared.preferredInputDeviceUID = device.uid
                            DebugLogger.shared.debug("Updated preferred input device to: \(device.uid)", source: "ASRService")

                            if self.isRunning {
                                DebugLogger.shared.info(
                                    "Recording in progress - deferring Bluetooth switch until audio route recovery",
                                    source: "ASRService"
                                )
                                self.scheduleAudioRouteRecovery(reason: "bluetooth input connected")
                            } else {
                                DebugLogger.shared.info("Not recording - Bluetooth device will be used on next recording", source: "ASRService")
                            }
                        }
                    }
                }

                self.cacheCurrentDeviceList(currentDevices)
            }
        }
    }

    /// Handles device availability changes (device disconnected or reconnected)
    private func handleDeviceAvailabilityChanged(deviceID: AudioObjectID) {
        DebugLogger.shared.info("⚠️ Device availability changed for ID: \(deviceID)", source: "ASRService")

        // Check if device is still alive
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var isAlive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isAlive)

        DebugLogger.shared.debug("Device \(deviceID) alive status query: status=\(status), isAlive=\(isAlive)", source: "ASRService")

        if status == noErr, isAlive == 0 {
            // Device disconnected
            DebugLogger.shared.warning("❌ Monitored device (ID: \(deviceID)) DISCONNECTED", source: "ASRService")
            self.stopMonitoringDevice()

            if self.isRunning {
                DebugLogger.shared.info(
                    "Device changed during recording - deferring rebuild until audio route recovery",
                    source: "ASRService"
                )
                self.scheduleAudioRouteRecovery(reason: "monitored input disconnected")
            } else {
                DebugLogger.shared.info("Not recording - device disconnect handled gracefully", source: "ASRService")
            }
        } else if status == noErr, isAlive != 0 {
            DebugLogger.shared.info("✅ Device (ID: \(deviceID)) is still alive", source: "ASRService")
        }
    }

    /// Gets the currently bound input device (if determinable)
    private func getCurrentlyBoundInputDevice() -> AudioDevice.Device? {
        if let directAudioInput = self.directAudioInput {
            return AudioDevice.listInputDevices().first { $0.id == directAudioInput.deviceID }
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

    // Device caching for change detection
    private var cachedDeviceUIDs: Set<String> = []

    private func cacheCurrentDeviceList(_ devices: [AudioDevice.Device]) {
        self.cachedDeviceUIDs = Set(devices.map { $0.uid })
    }

    // Audio tap processing is handled by AudioCapturePipeline (thread-safe).

    /// Ensures that ASR models are downloaded and ready for transcription.
    ///
    /// This method handles the complete model lifecycle using the appropriate
    /// TranscriptionProvider based on CPU architecture:
    /// - Apple Silicon: FluidAudio (CoreML optimized)
    /// - Intel: SwiftWhisper (whisper.cpp)
    ///
    /// ## Performance
    /// - First run will download models (~100-500MB depending on provider)
    /// - Subsequent runs use cached models (much faster)
    /// - Model loading happens asynchronously to avoid blocking UI
    ///
    /// ## Errors
    /// Throws if model download or loading fails. Common causes:
    /// - Network connectivity issues
    /// - Insufficient disk space
    func ensureAsrReady() async throws {
        try await self.ensureAsrReady(progressHandler: nil)
    }

    /// Ensures ASR models are ready, with an optional external progress handler.
    /// - Parameter progressHandler: Optional callback for download progress (0.0 to 1.0)
    func ensureAsrReady(progressHandler: ((Double) -> Void)?) async throws {
        guard self.modelDownloadTask == nil else {
            throw NSError(
                domain: "ASRService",
                code: -2001,
                userInfo: [NSLocalizedDescriptionKey: "Another model download is already in progress."]
            )
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
                            externalProgressHandler: externalProgressHandler
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
        } catch is CancellationError {
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
        externalProgressHandler: ((Double) -> Void)?
    ) {
        switch progress.phase {
        case .preparingDownload:
            self.downloadProgress = nil
            if updatesActiveModelState {
                self.isDownloadingModel = true
                self.isLoadingModel = false
            }
        case .downloading:
            self.downloadProgress = progress.fractionCompleted
            if updatesActiveModelState {
                self.isDownloadingModel = true
                self.isLoadingModel = false
            }
            if let fraction = progress.fractionCompleted {
                externalProgressHandler?(fraction)
            }
        case .optimizing:
            self.downloadProgress = nil
            if updatesActiveModelState {
                self.isDownloadingModel = true
                self.isLoadingModel = false
            }
        case .loading:
            self.downloadProgress = nil
            if updatesActiveModelState {
                self.isDownloadingModel = false
                self.isLoadingModel = true
            }
        }

        self.modelPreparationPhase = progress.phase
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
        try await self.transcriptionProvider.clearCache()
        self.isAsrReady = false
        self.modelsExistOnDisk = false
    }

    func clearModelCache(for model: SettingsStore.SpeechModel) async throws {
        DebugLogger.shared.debug("Clearing model cache for \(model.displayName)", source: "ASRService")
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

        // Thread-safe copy of the data
        let chunk = self.audioBuffer.getPrefix(currentSampleCount)

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
        let newSamples = max(0, chunk.count - self.benchmarkLastChunkSampleCount)
        self.benchmarkLastChunkSampleCount = chunk.count
        self.benchmarkLog("chunk_start index=\(chunkIndex) ageMs=\(chunkAgeMs) samples=\(chunk.count) newSamples=\(newSamples) audioMs=\(Int((Double(chunk.count) / 16_000.0 * 1000).rounded())) provider=\(self.transcriptionProvider.name)")

        do {
            DebugLogger.shared.debug("Streaming chunk starting transcription (samples: \(chunk.count)) using \(self.transcriptionProvider.name)", source: "ASRService")
            let result = try await transcriptionExecutor.run { [provider = self.transcriptionProvider] in
                try await provider.transcribeStreaming(chunk)
            }

            let duration = Date().timeIntervalSince(startTime)
            let latencyMs = Int((duration * 1000).rounded())
            self.captureStreamingChunkAnalytics(
                success: true,
                chunkSampleCount: chunk.count,
                latencyMs: latencyMs
            )
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
            self.lastProcessedSampleCount = chunk.count

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
            let rtf = chunk.isEmpty ? 0 : duration / (Double(chunk.count) / 16_000.0)
            let chunkDoneAgeMs = self.elapsedMilliseconds(since: self.benchmarkRecordingStartedAt)
            self.benchmarkLog(
                "chunk_done index=\(chunkIndex) elapsedMs=\(self.elapsedMilliseconds(since: startedAt)) ageMs=\(chunkDoneAgeMs) " +
                    "samples=\(chunk.count) rawChars=\(rawText.count) cleanedChars=\(newText.count) rtf=\(String(format: "%.3f", rtf))"
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
            let duration = Date().timeIntervalSince(startTime)
            let latencyMs = Int((duration * 1000).rounded())
            self.captureStreamingChunkAnalytics(
                success: false,
                chunkSampleCount: chunk.count,
                latencyMs: latencyMs,
                error: error
            )
            DebugLogger.shared.error("❌ Streaming failed: \(error)", source: "ASRService")
            self.benchmarkLog("chunk_fail index=\(chunkIndex) elapsedMs=\(self.elapsedMilliseconds(since: startedAt)) samples=\(chunk.count) error=\(error.localizedDescription)")
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

    // MARK: - Typing convenience for compatibility

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
        textReadyAt: TimeInterval? = nil
    ) {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let textReadyAge = textReadyAt.map { Int(((requestedAt - $0) * 1000).rounded()) }
        let text = plan.plainText
        DebugLogger.shared.benchmark(
            "TYPING_BENCH",
            message: "asr_type_request chars=\(text.count) preferredPID=\(preferredTargetPID.map { String($0) } ?? "nil") textReadyAgeMs=\(textReadyAge.map { String($0) } ?? "nil")",
            source: "TypingBenchmark"
        )
        self.typingService.typeOutputPlanInstantly(plan, preferredTargetPID: preferredTargetPID, textReadyAt: textReadyAt)
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

                let escapedTrigger = NSRegularExpression.escapedPattern(for: trigger)
                guard let regex = try? NSRegularExpression(
                    pattern: "\\b" + escapedTrigger + "\\b",
                    options: .caseInsensitive
                ) else { continue }

                patterns.append((regex: regex, template: NSRegularExpression.escapedTemplate(for: entry.replacement)))
            }
        }

        self.cachedDictionaryPatterns = patterns
        self.dictionaryCacheNeedsRebuild = false
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
// a lock-free C ring; AVAudioEngine remains the compatibility fallback. This
// pipeline owns timestamp trimming, 16 kHz conversion, levels, and session-safe
// delivery without touching ASRService from a realtime callback.

private final nonisolated class AudioCapturePipeline: @unchecked Sendable {
    private let audioBuffer: ThreadSafeAudioBuffer
    private let onFirstAudio: (Int, Int, Int, Double, Int, Int) -> Void
    private let onLevel: (CGFloat) -> Void

    private let lock = NSLock()
    private var recordingEnabled: Bool = false
    private var firstAudioReported: Bool = false
    private var recordingSessionID: Int = 0
    private var recordingStartHostTime: UInt64 = 0
    private var recordingStopHostTime: UInt64?
    private var resampleSourceRate: Double = 0
    private var resampleSourceFrameCursor: Int64 = 0
    private var resampleNextSourcePosition: Double = 0
    private var resamplePreviousSample: Float?
    private var lastInputSampleEnd: Int64?

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
        onFirstAudio: @escaping (Int, Int, Int, Double, Int, Int) -> Void,
        onLevel: @escaping (CGFloat) -> Void
    ) {
        self.audioBuffer = audioBuffer
        self.onFirstAudio = onFirstAudio
        self.onLevel = onLevel
    }

    func setRecordingEnabled(
        _ enabled: Bool,
        sessionID: Int = 0,
        startHostTime: UInt64 = 0
    ) {
        self.lock.lock()
        if enabled {
            self.firstAudioReported = false
            self.recordingSessionID = sessionID
            self.recordingStartHostTime = startHostTime == 0 ? mach_absolute_time() : startHostTime
            self.recordingStopHostTime = nil
            self.resetResamplerLocked()
            self.lastInputSampleEnd = nil
            self.recordingEnabled = true
        }
        if enabled == false {
            self.recordingEnabled = false
            self.recordingSessionID = 0
            self.recordingStartHostTime = 0
            self.recordingStopHostTime = nil
            self.resetResamplerLocked()
            self.lastInputSampleEnd = nil
            self.levelHistory.removeAll(keepingCapacity: true)
            self.smoothedLevel = 0.0
        }
        self.lock.unlock()
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
        guard self.recordingEnabled else {
            self.lock.unlock()
            return
        }
        let startHostTime = self.recordingStartHostTime
        let stopHostTime = self.recordingStopHostTime
        let recordingSessionID = self.recordingSessionID
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
        guard self.recordingEnabled, self.recordingSessionID == recordingSessionID else {
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
        self.lock.unlock()

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
                Int(mono16k.count),
                originalFrameCount,
                sampleRate,
                acquisitionMs,
                deliveryMs
            )
        }
        let level = self.calculateAudioLevel(mono16k)
        self.onLevel(level)
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

    /// Stateful linear resampling keeps fractional phase across small hardware
    /// callbacks. Stateless per-packet conversion silently shortens 44.1 kHz
    /// recordings and introduces a discontinuity at every device cycle.
    private func resampleTo16kLocked(
        _ samples: [Float],
        sourceSampleRate: Double
    ) -> [Float] {
        guard samples.isEmpty == false else { return [] }
        if sourceSampleRate == 16_000.0 {
            return samples
        }

        if abs(self.resampleSourceRate - sourceSampleRate) > 0.5 {
            self.resetResamplerLocked()
            self.resampleSourceRate = sourceSampleRate
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

    private func calculateAudioLevel(_ samples: [Float]) -> CGFloat {
        guard samples.isEmpty == false else { return 0.0 }

        // RMS
        var sum: Float = 0.0
        vDSP_svesq(samples, 1, &sum, vDSP_Length(samples.count))
        let rms = sqrt(sum / Float(samples.count))

        // Noise gate
        if rms < 0.002 {
            return self.applySmoothingAndThreshold(0.0)
        }

        // dB -> normalized [0, 1]
        let dbLevel = 20 * log10(max(rms, 1e-10))
        let normalizedLevel = max(0, min(1, (dbLevel + 55) / 55))
        return self.applySmoothingAndThreshold(CGFloat(normalizedLevel))
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
