import Accelerate
import AVFoundation
import Combine
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
/// asrService.start() // Begin recording
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
    @Published var micStatus: AVAuthorizationStatus = .notDetermined
    @Published var isAsrReady: Bool = false
    @Published var isDownloadingModel: Bool = false
    @Published var isLoadingModel: Bool = false // True when loading cached model into memory (not downloading)
    @Published var modelsExistOnDisk: Bool = false

    // MARK: - Error Handling

    @Published var errorTitle: String = "Error"
    @Published var errorMessage: String = ""
    @Published var showError: Bool = false

    /// Returns a user-friendly status message for model loading state
    var modelStatusMessage: String {
        if self.isAsrReady { return "Model ready" }
        if self.isDownloadingModel { return "Downloading model..." }
        if self.isLoadingModel { return "Loading model into memory..." }
        if self.modelsExistOnDisk { return "Model cached, needs loading" }
        return "Model not downloaded"
    }

    // MARK: - Transcription Provider (Settable)

    /// Cached providers to avoid re-instantiation
    private var fluidAudioProvider: FluidAudioProvider?
    private var whisperProvider: WhisperProvider?
    private var appleSpeechProvider: AppleSpeechProvider?
    /// Stored as Any? because @available cannot be applied to stored properties
    private var _appleSpeechAnalyzerProvider: Any?

    /// Prevent concurrent provider.prepare() calls (download/load) from overlapping.
    /// Subsequent callers await the in-flight task.
    private var ensureReadyTask: Task<Void, Error>?
    private var ensureReadyProviderKey: String?

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
        default:
            return self.getWhisperProvider()
        }
    }

    private func getFluidAudioProvider() -> FluidAudioProvider {
        if let existing = fluidAudioProvider {
            return existing
        }
        let provider = FluidAudioProvider()
        self.fluidAudioProvider = provider
        DebugLogger.shared.info("ASRService: Created FluidAudio provider", source: "ASRService")
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

    /// Call this when the transcription provider setting changes to reset state
    func resetTranscriptionProvider() {
        let newModel = SettingsStore.shared.selectedSpeechModel
        DebugLogger.shared.info("ASRService: Switching to '\(newModel.displayName)', resetting provider state...", source: "ASRService")

        self.isAsrReady = false
        self.modelsExistOnDisk = false
        self.ensureReadyTask?.cancel()
        self.ensureReadyTask = nil
        self.ensureReadyProviderKey = nil

        // Reset cached providers to force re-initialization with new settings
        self.fluidAudioProvider = nil
        self.whisperProvider = nil
        self.appleSpeechProvider = nil
        self._appleSpeechAnalyzerProvider = nil

        // CRITICAL FIX: Check if the NEW model's files exist on disk
        // This prevents UI from showing "Download" when model is already downloaded
        // Use Task for async check to support providers like AppleSpeechAnalyzerProvider
        Task { [weak self] in
            guard let self = self else { return }
            await self.checkIfModelsExistAsync()
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

    // Streaming transcription state (no VAD)
    private var streamingTask: Task<Void, Never>?
    private var lastProcessedSampleCount: Int = 0
    private let chunkDurationSeconds: Double = 0.6 // Fast interval - TranscriptionExecutor actor handles CoreML serialization
    private var isProcessingChunk: Bool = false
    private var skipNextChunk: Bool = false
    private var previousFullTranscription: String = ""
    private let transcriptionExecutor = TranscriptionExecutor() // Serializes all CoreML access

    private var audioLevelSubject = PassthroughSubject<CGFloat, Never>()
    var audioLevelPublisher: AnyPublisher<CGFloat, Never> { self.audioLevelSubject.eraseToAnyPublisher() }
    private var lastAudioLevelSentAt: TimeInterval = 0

    /// Handles AVAudioEngine tap processing off the @MainActor to avoid touching main-actor state
    /// from CoreAudio's realtime callback thread.
    private lazy var audioCapturePipeline: AudioCapturePipeline = .init(
        audioBuffer: self.audioBuffer,
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
    }

    /// Call this AFTER the app has finished launching to complete ASR initialization.
    /// This must be called from onAppear or later, never during init.
    func initialize() {
        // Check microphone permission (deferred from init to avoid AVFCapture race condition)
        self.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        self.micPermissionGranted = (self.micStatus == .authorized)

        self.registerDefaultDeviceChangeListener()
        self.registerDeviceListChangeListener()

        // Initialize device list cache
        self.cacheCurrentDeviceList(AudioDevice.listInputDevices())

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
        self.modelsExistOnDisk = self.transcriptionProvider.modelsExistOnDisk()
        DebugLogger.shared.debug("Models exist on disk: \(self.modelsExistOnDisk)", source: "ASRService")
    }

    /// Check if models exist on disk without loading them (async).
    ///
    /// This method performs an accurate async check for providers that require it
    /// (e.g., `AppleSpeechAnalyzerProvider` uses `SpeechTranscriber.installedLocales`).
    func checkIfModelsExistAsync() async {
        let model = SettingsStore.shared.selectedSpeechModel

        // For Apple Speech Analyzer, use the async refresh method
        if model == .appleSpeechAnalyzer {
            if #available(macOS 26.0, *) {
                let provider = self.getAppleSpeechAnalyzerProvider()
                let isInstalled = await provider.refreshModelsExistOnDiskAsync()
                self.modelsExistOnDisk = isInstalled
                DebugLogger.shared.debug("Models exist on disk (async): \(self.modelsExistOnDisk)", source: "ASRService")
                return
            }
        }

        // For other providers, use the synchronous method
        self.modelsExistOnDisk = self.transcriptionProvider.modelsExistOnDisk()
        DebugLogger.shared.debug("Models exist on disk: \(self.modelsExistOnDisk)", source: "ASRService")
    }

    func requestMicAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard let self = self else { return }
            Task { @MainActor in
                self.micPermissionGranted = granted
                self.micStatus = granted ? .authorized : .denied
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
    func start() {
        DebugLogger.shared.info("🎤 START() called - beginning recording session", source: "ASRService")

        guard self.micStatus == .authorized else {
            DebugLogger.shared.error("❌ START() blocked - mic not authorized", source: "ASRService")
            return
        }
        guard self.isRunning == false else {
            DebugLogger.shared.warning("⚠️ START() blocked - already running", source: "ASRService")
            return
        }

        DebugLogger.shared.debug("🧹 Clearing buffers and state", source: "ASRService")
        self.finalText.removeAll()
        self.audioBuffer.clear(keepingCapacity: true) // specific optimization for restart
        self.partialTranscription.removeAll()
        self.previousFullTranscription.removeAll()
        self.lastProcessedSampleCount = 0
        self.isProcessingChunk = false
        self.skipNextChunk = false
        self.audioCapturePipeline.setRecordingEnabled(true)
        DebugLogger.shared.debug("✅ Buffers cleared", source: "ASRService")

        do {
            DebugLogger.shared.debug("⚙️ Calling configureSession()...", source: "ASRService")
            try self.configureSession()
            DebugLogger.shared.debug("✅ configureSession() completed", source: "ASRService")

            DebugLogger.shared.debug("🚀 Calling startEngine()...", source: "ASRService")
            try self.startEngine()
            DebugLogger.shared.debug("✅ startEngine() completed", source: "ASRService")

            DebugLogger.shared.debug("🎧 Setting up engine tap...", source: "ASRService")
            self.setupEngineTap()
            DebugLogger.shared.debug("✅ Engine tap setup complete", source: "ASRService")

            self.isRunning = true
            DebugLogger.shared.info("✅ isRunning set to TRUE", source: "ASRService")

            // Start monitoring the currently bound device for disconnection
            if let currentDevice = getCurrentlyBoundInputDevice() {
                DebugLogger.shared.debug("👀 Starting device monitoring for: \(currentDevice.name)", source: "ASRService")
                self.startMonitoringDevice(currentDevice.id)
            } else {
                DebugLogger.shared.debug("ℹ️ No device to monitor", source: "ASRService")
            }

            DebugLogger.shared.debug("📡 Starting streaming transcription...", source: "ASRService")
            self.startStreamingTranscription()
            DebugLogger.shared.info("✅ START() completed successfully", source: "ASRService")
        } catch {
            DebugLogger.shared.error("Failed to start ASR session: \(error)", source: "ASRService")

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
    func stop() async -> String {
        DebugLogger.shared.info("🛑 STOP() called - beginning shutdown sequence", source: "ASRService")

        guard self.isRunning else {
            DebugLogger.shared.warning("⚠️ STOP() - not running, returning empty string", source: "ASRService")
            return ""
        }

        DebugLogger.shared.debug("📍 Preparing final transcription", source: "ASRService")

        // CRITICAL: Set isRunning to false FIRST to signal any in-flight chunks to abort early
        DebugLogger.shared.debug("🚫 Setting isRunning = false...", source: "ASRService")
        self.isRunning = false
        DebugLogger.shared.debug("🚫 Setting audioCapturePipeline recording = false...", source: "ASRService")
        self.audioCapturePipeline.setRecordingEnabled(false)
        DebugLogger.shared.debug("✅ isRunning and capture pipeline disabled", source: "ASRService")

        // Stop monitoring device to prevent callbacks after stop
        DebugLogger.shared.debug("👁️ Stopping device monitoring...", source: "ASRService")
        self.stopMonitoringDevice()
        DebugLogger.shared.debug("✅ Device monitoring stopped", source: "ASRService")

        // Stop the audio engine to stop new audio from coming in
        DebugLogger.shared.debug("🎧 Removing engine tap...", source: "ASRService")
        self.removeEngineTap()
        DebugLogger.shared.debug("✅ Engine tap removed", source: "ASRService")

        DebugLogger.shared.debug("🛑 Calling engine.stop()...", source: "ASRService")
        self.engine.stop()
        DebugLogger.shared.debug("✅ Engine stopped", source: "ASRService")

        // Recreate the engine instance instead of calling reset() to prevent format corruption
        // VoiceInk approach: tearing down and rebuilding ensures fresh, valid audio format on restart
        DebugLogger.shared.debug("🗑️ Deallocating old engine and creating fresh instance...", source: "ASRService")
        self.engineStorage = nil // Explicitly release old engine
        // New engine will be lazily created on next access via computed property
        DebugLogger.shared.debug("✅ Engine instance recreated", source: "ASRService")

        // CRITICAL FIX: Await completion of streaming task AND any pending transcriptions
        // This prevents use-after-free crashes (EXC_BAD_ACCESS) when clearing buffer
        DebugLogger.shared.debug("⏳ Awaiting stopStreamingTimerAndAwait()...", source: "ASRService")
        await self.stopStreamingTimerAndAwait()
        DebugLogger.shared.debug("✅ stopStreamingTimerAndAwait() completed", source: "ASRService")

        self.isProcessingChunk = false
        self.skipNextChunk = false
        self.previousFullTranscription.removeAll()

        // NOW it's safe to access the buffer - all pending tasks have completed
        // Thread-safe copy of recorded audio
        let pcm = self.audioBuffer.getAll()
        self.audioBuffer.clear()

        do {
            DebugLogger.shared.debug("🔍 Calling ensureAsrReady()...", source: "ASRService")
            try await self.ensureAsrReady()
            DebugLogger.shared.debug("✅ ensureAsrReady() completed", source: "ASRService")

            guard self.transcriptionProvider.isReady else {
                DebugLogger.shared.error("Transcription provider is not ready", source: "ASRService")
                return ""
            }

            DebugLogger.shared.debug("Starting transcription with \(pcm.count) samples (\(Float(pcm.count) / 16_000.0) seconds)", source: "ASRService")
            DebugLogger.shared.debug("stop(): starting full transcription (samples: \(pcm.count)) using \(self.transcriptionProvider.name)", source: "ASRService")
            DebugLogger.shared.debug("📝 Starting transcription executor...", source: "ASRService")
            let result = try await transcriptionExecutor.run { [provider = self.transcriptionProvider] in
                DebugLogger.shared.debug("📝 Inside transcription executor closure", source: "ASRService")
                let transcriptionResult = try await provider.transcribe(pcm)
                DebugLogger.shared.debug("📝 Transcription provider returned", source: "ASRService")
                return transcriptionResult
            }
            DebugLogger.shared.debug("✅ Transcription executor completed", source: "ASRService")
            DebugLogger.shared.debug("stop(): full transcription finished", source: "ASRService")
            DebugLogger.shared.debug(
                "Transcription completed: '\(result.text)' (confidence: \(result.confidence))",
                source: "ASRService"
            )
            // Do not update self.finalText here to avoid instant binding insert in playground
            let cleanedText = ASRService.applyCustomDictionary(ASRService.removeFillerWords(result.text))
            DebugLogger.shared.debug("After post-processing: '\(cleanedText)'", source: "ASRService")
            return cleanedText
        } catch {
            DebugLogger.shared.error("ASR transcription failed: \(error)", source: "ASRService")
            DebugLogger.shared.error("Error details: \(error.localizedDescription)", source: "ASRService")
            let nsError = error as NSError
            DebugLogger.shared.error("Error domain: \(nsError.domain), code: \(nsError.code)", source: "ASRService")
            DebugLogger.shared.error("Error userInfo: \(nsError.userInfo)", source: "ASRService")

            // Note: We intentionally do NOT show an error popup here.
            // Common errors like "audio too short" are expected during normal use
            // (e.g., accidental hotkey press) and would disrupt the user's workflow.
            // Errors are logged for debugging purposes.

            return ""
        }
    }

    func stopWithoutTranscription() async {
        guard self.isRunning else { return }

        DebugLogger.shared.info("🛑 Stopping recording - releasing audio devices", source: "ASRService")

        // CRITICAL: Set isRunning to false FIRST to signal any in-flight chunks to abort early
        self.isRunning = false
        self.audioCapturePipeline.setRecordingEnabled(false)

        // Stop monitoring device
        self.stopMonitoringDevice()

        self.removeEngineTap()
        DebugLogger.shared.debug("Engine tap removed", source: "ASRService")

        self.engine.stop()
        DebugLogger.shared.debug("Engine stopped", source: "ASRService")

        // Recreate engine instance to release resources (same as stop())
        DebugLogger.shared.debug("🗑️ Deallocating old engine and creating fresh instance...", source: "ASRService")
        self.engineStorage = nil
        DebugLogger.shared.debug("✅ Engine instance recreated", source: "ASRService")

        // CRITICAL FIX: Await completion of streaming task AND any pending transcriptions
        // This prevents use-after-free crashes (EXC_BAD_ACCESS) when clearing buffer
        await self.stopStreamingTimerAndAwait()

        // NOW it's safe to clear the buffer
        self.audioBuffer.clear()
        self.partialTranscription.removeAll()
        self.previousFullTranscription.removeAll()
        self.lastProcessedSampleCount = 0
        self.isProcessingChunk = false
        self.skipNextChunk = false
    }

    private func configureSession() throws {
        DebugLogger.shared.debug("🔧 configureSession() - ENTERED", source: "ASRService")

        if self.engine.isRunning {
            DebugLogger.shared.debug("⚠️ Engine is running, stopping before configuration", source: "ASRService")
            self.engine.stop()
            DebugLogger.shared.debug("✅ Engine stopped", source: "ASRService")
        }

        // No need to call engine.reset() here - we created a fresh engine in stop()
        // Accessing the engine property will either return the existing fresh engine,
        // or create a new one if this is the first start
        DebugLogger.shared.debug("ℹ️ Using fresh engine instance (created lazily)", source: "ASRService")

        // Force input node instantiation (ensures the underlying AUHAL AudioUnit exists)
        DebugLogger.shared.debug("📍 Forcing input node instantiation...", source: "ASRService")
        _ = self.engine.inputNode
        DebugLogger.shared.debug("Input node instantiated", source: "ASRService")

        // Force output node instantiation for output device binding
        DebugLogger.shared.debug("📍 Forcing output node instantiation...", source: "ASRService")
        _ = self.engine.outputNode
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
                    self.engineStorage = nil // Deallocate failed engine
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
        self.engine.inputNode.removeTap(onBus: 0)
    }

    private func setupEngineTap() {
        DebugLogger.shared.debug("🎧 setupEngineTap() - ENTERED", source: "ASRService")
        let input = self.engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)

        // Validate format before installing tap (VoiceInk approach)
        // This prevents hanging if the format is invalid (0Hz/0ch)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            DebugLogger.shared.error(
                "❌ INVALID INPUT FORMAT: \(inFormat.sampleRate)Hz \(inFormat.channelCount)ch - Cannot install tap!",
                source: "ASRService"
            )
            fatalError("AVAudioEngine input format is invalid. This should never happen with fresh engine instance.")
        }

        DebugLogger.shared.debug(
            "✅ Valid input format: \(inFormat.sampleRate)Hz \(inFormat.channelCount)ch",
            source: "ASRService"
        )

        self.inputFormat = inFormat
        let pipeline = self.audioCapturePipeline
        DebugLogger.shared.debug("🎧 Installing tap on bus 0...", source: "ASRService")
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
            pipeline.handle(buffer: buffer)
        }
        DebugLogger.shared.debug("✅ setupEngineTap() - COMPLETED", source: "ASRService")
    }

    private func handleDefaultInputChanged() {
        // If we're not syncing with macOS system settings, ignore system-default changes.
        // In independent mode, we explicitly bind to `preferredInputDeviceUID` on start/restart.
        guard SettingsStore.shared.syncAudioDevicesWithSystem else {
            DebugLogger.shared.debug("Ignoring system default input change (sync disabled)", source: "ASRService")
            return
        }

        // Restart engine to bind to the new default input and resume level publishing
        if self.isRunning {
            self.removeEngineTap()
            self.engine.stop()
            // Recreate engine for system device change
            self.engineStorage = nil
            do {
                try self.configureSession()
                try self.startEngine()
                self.setupEngineTap()
            } catch {}
        }
        // Nudge visualizer
        DispatchQueue.main.async { self.audioLevelSubject.send(0.0) }
    }

    private var defaultInputListenerInstalled = false
    private var defaultInputListenerToken: AudioObjectPropertyListenerBlock?
    private func registerDefaultDeviceChangeListener() {
        guard self.defaultInputListenerInstalled == false else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let token: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultInputChanged()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            token
        )
        if status == noErr { self.defaultInputListenerInstalled = true }
        if status == noErr {
            self.defaultInputListenerToken = token
        } else {
            self.defaultInputListenerToken = nil
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
            self?.handleDeviceListChanged()
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
            self?.handleDeviceAvailabilityChanged(deviceID: deviceID)
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

        // Get current device list
        let currentDevices = AudioDevice.listInputDevices()
        DebugLogger.shared.debug("Current input devices: \(currentDevices.map { $0.name }.joined(separator: ", "))", source: "ASRService")

        // Check if preferred device is now available (for auto-switch)
        if let preferredUID = SettingsStore.shared.preferredInputDeviceUID,
           let preferredDevice = currentDevices.first(where: { $0.uid == preferredUID })
        {
            // If we're currently using a fallback (system default), switch to preferred device
            let systemDefault = AudioDevice.getDefaultInputDevice()
            if let currentDevice = getCurrentlyBoundInputDevice(),
               currentDevice.uid != preferredUID,
               currentDevice.uid == systemDefault?.uid
            {
                DebugLogger.shared.info(
                    "🔌 Preferred device '\(preferredDevice.name)' reconnected. Auto-switching...",
                    source: "ASRService"
                )

                // If recording, restart with new device
                if self.isRunning {
                    DebugLogger.shared.info("Recording in progress - restarting engine with preferred device", source: "ASRService")
                    self.restartEngineWithDevice(preferredDevice)
                } else {
                    // Just update the binding for next recording
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
                // Check if this is a newly appeared device
                let wasAvailable = self.checkDeviceWasAvailable(device.uid)
                if !wasAvailable {
                    DebugLogger.shared.info(
                        "🎧 New Bluetooth device detected: '\(device.name)'. Auto-switching...",
                        source: "ASRService"
                    )

                    // Update preferred device setting
                    SettingsStore.shared.preferredInputDeviceUID = device.uid
                    DebugLogger.shared.debug("Updated preferred input device to: \(device.uid)", source: "ASRService")

                    // If recording, restart with new device
                    if self.isRunning {
                        DebugLogger.shared.info("Recording in progress - restarting engine with new Bluetooth device", source: "ASRService")
                        self.restartEngineWithDevice(device)
                    } else {
                        DebugLogger.shared.info("Not recording - Bluetooth device will be used on next recording", source: "ASRService")
                    }
                }
            }
        }

        // Cache device list for next comparison
        self.cacheCurrentDeviceList(currentDevices)
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

            if self.isRunning {
                // Cancel recording if device disconnects during recording
                DebugLogger.shared.error(
                    "🛑 Recording CANCELLED: Audio device disconnected during recording",
                    source: "ASRService"
                )

                Task { @MainActor in
                    await self.stopWithoutTranscription()

                    // Notify user
                    NotificationCenter.default.post(
                        name: NSNotification.Name("ASRServiceDeviceDisconnected"),
                        object: nil,
                        userInfo: ["errorMessage": "Recording cancelled: Audio device disconnected"]
                    )
                }
            } else {
                DebugLogger.shared.info("Not recording - device disconnect handled gracefully", source: "ASRService")
                // Just stop monitoring - don't try to set engine device when engine may not exist
                self.stopMonitoringDevice()
                DebugLogger.shared.info("✅ Stopped monitoring disconnected device", source: "ASRService")
            }
        } else if status == noErr, isAlive != 0 {
            DebugLogger.shared.info("✅ Device (ID: \(deviceID)) is still alive", source: "ASRService")
        }
    }

    /// Restarts the engine with a new device (used for hot-swapping)
    private func restartEngineWithDevice(_ device: AudioDevice.Device) {
        guard self.isRunning else {
            DebugLogger.shared.warning("restartEngineWithDevice() called but not recording", source: "ASRService")
            return
        }

        DebugLogger.shared.info("🔄 HOT-SWAPPING device to: '\(device.name)' (uid: \(device.uid))", source: "ASRService")

        // Note: This will cause a brief interruption in recording
        // The user requested to cancel recording on device change, but we're allowing
        // auto-switch for convenience. If issues arise, we can make this stricter.

        DebugLogger.shared.debug("Removing engine tap...", source: "ASRService")
        self.removeEngineTap()

        DebugLogger.shared.debug("Stopping engine...", source: "ASRService")
        self.engine.stop()

        do {
            // Recreate engine for hot-swap instead of reset
            DebugLogger.shared.debug("Recreating engine for device switch...", source: "ASRService")
            self.engineStorage = nil
            _ = self.engine.inputNode // Create fresh engine with new node
            _ = self.setEngineInputDevice(deviceID: device.id, deviceUID: device.uid, deviceName: device.name)

            DebugLogger.shared.debug("Starting engine with new device...", source: "ASRService")
            try self.startEngine()

            DebugLogger.shared.debug("Setting up engine tap...", source: "ASRService")
            self.setupEngineTap()

            // Start monitoring the new device
            self.startMonitoringDevice(device.id)

            DebugLogger.shared.info("✅ HOT-SWAP successful - now recording with '\(device.name)'", source: "ASRService")
        } catch {
            DebugLogger.shared.error("❌ HOT-SWAP FAILED: \(error)", source: "ASRService")

            // Cancel recording on failure
            Task { @MainActor in
                await self.stopWithoutTranscription()
            }
        }
    }

    /// Gets the currently bound input device (if determinable)
    private func getCurrentlyBoundInputDevice() -> AudioDevice.Device? {
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

    private func checkDeviceWasAvailable(_ uid: String) -> Bool {
        return self.cachedDeviceUIDs.contains(uid)
    }

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
        let provider = self.transcriptionProvider
        let providerKey = "\(type(of: provider)):\(provider.name)"

        // Single-flight: if a prepare is already running for this provider, await it.
        if let task = ensureReadyTask, ensureReadyProviderKey == providerKey {
            try await task.value
            return
        }

        let task = Task { @MainActor in
            try await self.performEnsureAsrReady(provider: provider)
        }
        self.ensureReadyTask = task
        self.ensureReadyProviderKey = providerKey

        defer {
            if ensureReadyProviderKey == providerKey {
                ensureReadyTask = nil
                ensureReadyProviderKey = nil
            }
        }

        try await task.value
    }

    private func performEnsureAsrReady(provider: TranscriptionProvider) async throws {
        // Check if already ready
        if self.isAsrReady, provider.isReady {
            DebugLogger.shared.debug("ASR already ready with loaded models, skipping initialization", source: "ASRService")
            return
        }

        // If the flag is set but provider isn't ready (e.g., provider switch without reset), re-init.
        if self.isAsrReady, !provider.isReady {
            DebugLogger.shared.debug("ASR marked ready but provider not ready; re-initializing", source: "ASRService")
        }

        self.isAsrReady = false

        let totalStartTime = Date()
        do {
            DebugLogger.shared.info("=== ASR INITIALIZATION START ===", source: "ASRService")
            DebugLogger.shared.info("Using provider: \(provider.name)", source: "ASRService")

            let modelsAlreadyCached = provider.modelsExistOnDisk()
            DebugLogger.shared.info("Models already cached on disk: \(modelsAlreadyCached)", source: "ASRService")

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

            // Set correct loading state based on whether models are cached
            DispatchQueue.main.async {
                if modelsAlreadyCached {
                    self.isLoadingModel = true
                    self.isDownloadingModel = false
                    DebugLogger.shared.info("📦 LOADING cached model into memory...", source: "ASRService")
                } else {
                    self.isDownloadingModel = true
                    self.isLoadingModel = false
                    DebugLogger.shared.info("⬇️ DOWNLOADING model...", source: "ASRService")
                }
            }

            // Use the transcription provider to prepare models
            let downloadStartTime = Date()
            DebugLogger.shared.info("Calling transcriptionProvider.prepare()...", source: "ASRService")
            try await provider.prepare(progressHandler: nil)
            let downloadDuration = Date().timeIntervalSince(downloadStartTime)
            DebugLogger.shared.info("✓ Provider preparation completed in \(String(format: "%.1f", downloadDuration)) seconds", source: "ASRService")

            DispatchQueue.main.async {
                self.isDownloadingModel = false
                self.isLoadingModel = false
                self.modelsExistOnDisk = true
            }

            let totalDuration = Date().timeIntervalSince(totalStartTime)
            DebugLogger.shared.info("=== ASR INITIALIZATION COMPLETE ===", source: "ASRService")
            DebugLogger.shared.info("Total initialization time: \(String(format: "%.1f", totalDuration)) seconds", source: "ASRService")

            self.isAsrReady = true
        } catch {
            DebugLogger.shared.error("ASR initialization failed with error: \(error)", source: "ASRService")
            DebugLogger.shared.error("Error details: \(error.localizedDescription)", source: "ASRService")
            DispatchQueue.main.async {
                self.isDownloadingModel = false
                self.isLoadingModel = false
            }
            throw error
        }
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

    // MARK: - Timer-based Streaming Transcription (No VAD)

    private func startStreamingTranscription() {
        self.streamingTask?.cancel()
        guard self.isAsrReady else { return }

        DebugLogger.shared.debug("Starting streaming transcription task (interval: \(self.chunkDurationSeconds)s)", source: "ASRService")

        self.streamingTask = Task { [weak self] in
            await self?.runStreamingLoop()
        }
    }

    /// Stops the streaming timer and waits for the task to complete.
    /// This prevents race conditions where the buffer is cleared while
    /// a transcription task is still running.
    private func stopStreamingTimerAndAwait() async {
        guard let task = self.streamingTask else { return }
        task.cancel()
        // Wait for the task to actually finish - this is critical!
        // The task may be in the middle of processStreamingChunk()
        _ = await task.result
        self.streamingTask = nil

        // Also cancel and await any pending transcription in the executor
        // This prevents use-after-free when we clear the buffer
        await self.transcriptionExecutor.cancelAndAwaitPending()
    }

    /// Legacy sync version for cases where we can't await (e.g., stopWithoutTranscription)
    /// WARNING: This can cause crashes if buffer is cleared immediately after!
    private func stopStreamingTimer() {
        self.streamingTask?.cancel()
        self.streamingTask = nil
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
                try await Task.sleep(nanoseconds: UInt64(self.chunkDurationSeconds * 1_000_000_000))
            } catch {
                DebugLogger.shared.debug("Streaming transcription task cancelled", source: "ASRService")
                break
            }
        }
    }

    @MainActor
    private func processStreamingChunk() async {
        guard self.isRunning else { return }

        // Skip if already processing to prevent queue buildup
        guard !self.isProcessingChunk else {
            DebugLogger.shared.debug("⚠️ Skipping chunk - previous transcription still in progress", source: "ASRService")
            self.skipNextChunk = true
            return
        }

        if self.skipNextChunk {
            DebugLogger.shared.debug("⚠️ Skipping chunk for ANE recovery", source: "ASRService")
            self.skipNextChunk = false
            return
        }

        guard self.isAsrReady, self.transcriptionProvider.isReady else { return }

        // Thread-safe count check
        let currentSampleCount = self.audioBuffer.count
        // Most ASR models require at least 1 second of 16kHz audio (16,000 samples) to transcribe
        let minSamples = 16_000 // 1 second minimum required by transcription providers
        guard currentSampleCount >= minSamples else {
            // Only log once per recording session to avoid spam
            if currentSampleCount > 0, self.lastProcessedSampleCount == 0 {
                DebugLogger.shared.debug(
                    "Waiting for more audio data (\(currentSampleCount)/\(minSamples) samples)",
                    source: "ASRService"
                )
            }
            return
        }

        // Thread-safe copy of the data
        let chunk = self.audioBuffer.getPrefix(currentSampleCount)

        // Validate chunk is not empty (defensive check)
        guard !chunk.isEmpty else {
            DebugLogger.shared.warning("Audio buffer returned empty chunk despite count > 0. Skipping transcription.", source: "ASRService")
            return
        }

        self.isProcessingChunk = true
        defer { isProcessingChunk = false }

        let startTime = Date()

        do {
            DebugLogger.shared.debug("Streaming chunk starting transcription (samples: \(chunk.count)) using \(self.transcriptionProvider.name)", source: "ASRService")
            let result = try await transcriptionExecutor.run { [provider = self.transcriptionProvider] in
                try await provider.transcribe(chunk)
            }

            let duration = Date().timeIntervalSince(startTime)
            DebugLogger.shared.debug(
                "Streaming chunk transcription finished in \(String(format: "%.2f", duration))s",
                source: "ASRService"
            )
            let rawText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let newText = ASRService.applyCustomDictionary(ASRService.removeFillerWords(rawText))

            if !newText.isEmpty {
                // Smart diff: only show truly new words
                let updatedText = self.smartDiffUpdate(previous: self.previousFullTranscription, current: newText)
                self.partialTranscription = updatedText
                self.previousFullTranscription = newText

                DebugLogger.shared.debug("✅ Streaming: '\(updatedText)' (\(String(format: "%.2f", duration))s)", source: "ASRService")
            }

            // If transcription takes longer than the interval, skip next to prevent queue buildup
            // This allows slower machines to still work without overwhelming the system
            if duration > self.chunkDurationSeconds {
                DebugLogger.shared.debug("⚠️ Transcription slow (\(String(format: "%.2f", duration))s > \(self.chunkDurationSeconds)s), skipping next chunk", source: "ASRService")
                self.skipNextChunk = true
            }
        } catch {
            DebugLogger.shared.error("❌ Streaming failed: \(error)", source: "ASRService")
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
        self.typingService.typeTextInstantly(text)
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
    /// Key: trigger word, Value: (compiled regex, replacement text)
    /// Cleared when dictionary entries change.
    private static var cachedDictionaryPatterns: [(regex: NSRegularExpression, replacement: String)] = []
    private static var dictionaryCacheNeedsRebuild: Bool = true

    /// Rebuilds the regex cache if dictionary has changed.
    /// Called lazily on first apply after settings change.
    private static func rebuildDictionaryCache() {
        let entries = SettingsStore.shared.customDictionaryEntries
        var patterns: [(regex: NSRegularExpression, replacement: String)] = []

        for entry in entries {
            for trigger in entry.triggers {
                guard !trigger.isEmpty else { continue }

                let escapedTrigger = NSRegularExpression.escapedPattern(for: trigger)
                guard let regex = try? NSRegularExpression(
                    pattern: "\\b" + escapedTrigger + "\\b",
                    options: .caseInsensitive
                ) else { continue }

                patterns.append((regex: regex, replacement: entry.replacement))
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
                withTemplate: pattern.replacement
            )
        }

        return result
    }
}

// MARK: - Audio capture pipeline

//
// AVAudioEngine's tap runs on a realtime audio thread. ASRService is @MainActor, so we must NOT
// touch its state directly inside the tap callback. This pipeline keeps all tap-side state
// thread-safe and only calls back with derived values (audio level + captured samples).

private final class AudioCapturePipeline {
    private let audioBuffer: ThreadSafeAudioBuffer
    private let onLevel: (CGFloat) -> Void

    private let lock = NSLock()
    private var recordingEnabled: Bool = false

    // Smoothing state (kept off ASRService/@MainActor)
    private var levelHistory: [CGFloat] = []
    private var smoothedLevel: CGFloat = 0.0
    private let historySize: Int = 2
    private let silenceThreshold: CGFloat = 0.04

    init(audioBuffer: ThreadSafeAudioBuffer, onLevel: @escaping (CGFloat) -> Void) {
        self.audioBuffer = audioBuffer
        self.onLevel = onLevel
    }

    func setRecordingEnabled(_ enabled: Bool) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.recordingEnabled = enabled
        if enabled == false {
            self.levelHistory.removeAll(keepingCapacity: true)
            self.smoothedLevel = 0.0
        }
    }

    func handle(buffer: AVAudioPCMBuffer) {
        self.lock.lock()
        let enabled = self.recordingEnabled
        self.lock.unlock()

        guard enabled else {
            self.onLevel(0.0)
            return
        }

        let mono16k = Self.toMono16k(floatBuffer: buffer)
        guard mono16k.isEmpty == false else {
            self.onLevel(0.0)
            return
        }

        self.audioBuffer.append(mono16k)
        let level = self.calculateAudioLevel(mono16k)
        self.onLevel(level)
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

    private static func toMono16k(floatBuffer: AVAudioPCMBuffer) -> [Float] {
        if let format = floatBuffer.format as AVAudioFormat?,
           format.sampleRate == 16_000.0,
           format.commonFormat == .pcmFormatFloat32,
           format.channelCount == 1,
           let channelData = floatBuffer.floatChannelData
        {
            let frameCount = Int(floatBuffer.frameLength)
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        }
        let mono = self.downmixToMono(floatBuffer)
        return self.resampleTo16k(mono, sourceSampleRate: floatBuffer.format.sampleRate)
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

    private static func resampleTo16k(_ samples: [Float], sourceSampleRate: Double) -> [Float] {
        guard samples.isEmpty == false else { return [] }
        if sourceSampleRate == 16_000.0 { return samples }
        let ratio = 16_000.0 / sourceSampleRate
        let outCount = Int(Double(samples.count) * ratio)
        var output = [Float](repeating: 0, count: max(outCount, 0))
        if output.isEmpty { return [] }
        for i in 0..<outCount {
            let srcPos = Double(i) / ratio
            let idx = Int(srcPos)
            let frac = Float(srcPos - Double(idx))
            if idx + 1 < samples.count {
                let a = samples[idx]
                let b = samples[idx + 1]
                output[i] = a + (b - a) * frac
            } else if idx < samples.count {
                output[i] = samples[idx]
            }
        }
        return output
    }
}
