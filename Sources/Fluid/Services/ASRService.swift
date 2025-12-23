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

    private var isRecordingWholeSession: Bool = false
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

    // Audio smoothing properties - lighter smoothing for real-time response
    private var audioLevelHistory: [CGFloat] = []
    private var smoothedLevel: CGFloat = 0.0
    private let historySize = 2 // Reduced for faster response
    private let silenceThreshold: CGFloat = 0.04 // Reasonable default
    private let noiseGateThreshold: CGFloat = 0.06
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
        guard self.micStatus == .authorized else { return }
        guard self.isRunning == false else { return }

        self.finalText.removeAll()
        self.audioBuffer.clear(keepingCapacity: true) // specific optimization for restart
        self.partialTranscription.removeAll()
        self.previousFullTranscription.removeAll()
        self.lastProcessedSampleCount = 0
        self.isProcessingChunk = false
        self.skipNextChunk = false
        self.isRecordingWholeSession = true

        do {
            try self.configureSession()
            try self.startEngine()
            self.setupEngineTap()
            self.isRunning = true
            self.startStreamingTranscription()
        } catch {
            // TODO: Add proper error handling and user notification
            // For now, errors are logged but the UI doesn't show them
            DebugLogger.shared.error("Failed to start ASR session: \(error)", source: "ASRService")
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
        guard self.isRunning else { return "" }

        DebugLogger.shared.debug("stop(): cancelling streaming and preparing final transcription", source: "ASRService")

        // CRITICAL: Set isRunning to false FIRST to signal any in-flight chunks to abort early
        self.isRunning = false

        // Stop the audio engine to stop new audio from coming in
        self.removeEngineTap()
        self.engine.stop()
        self.engine.reset() // Reset engine state to fully release Bluetooth mic

        // CRITICAL FIX: Await completion of streaming task AND any pending transcriptions
        // This prevents use-after-free crashes (EXC_BAD_ACCESS) when clearing buffer
        await self.stopStreamingTimerAndAwait()

        self.isProcessingChunk = false
        self.skipNextChunk = false
        self.previousFullTranscription.removeAll()

        // NOW it's safe to access the buffer - all pending tasks have completed
        // Thread-safe copy of recorded audio
        let pcm = self.audioBuffer.getAll()
        self.audioBuffer.clear()
        self.isRecordingWholeSession = false

        do {
            try await self.ensureAsrReady()
            guard self.transcriptionProvider.isReady else {
                DebugLogger.shared.error("Transcription provider is not ready", source: "ASRService")
                return ""
            }

            DebugLogger.shared.debug("Starting transcription with \(pcm.count) samples (\(Float(pcm.count) / 16_000.0) seconds)", source: "ASRService")
            DebugLogger.shared.debug("stop(): starting full transcription (samples: \(pcm.count)) using \(self.transcriptionProvider.name)", source: "ASRService")
            let result = try await transcriptionExecutor.run { [provider = self.transcriptionProvider] in
                try await provider.transcribe(pcm)
            }
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

        // CRITICAL: Set isRunning to false FIRST to signal any in-flight chunks to abort early
        self.isRunning = false

        self.removeEngineTap()
        self.engine.stop()
        self.engine.reset() // Reset engine state to fully release Bluetooth mic

        // CRITICAL FIX: Await completion of streaming task AND any pending transcriptions
        // This prevents use-after-free crashes (EXC_BAD_ACCESS) when clearing buffer
        await self.stopStreamingTimerAndAwait()

        // NOW it's safe to clear the buffer
        self.audioBuffer.clear()
        self.isRecordingWholeSession = false
        self.partialTranscription.removeAll()
        self.previousFullTranscription.removeAll()
        self.lastProcessedSampleCount = 0
        self.isProcessingChunk = false
        self.skipNextChunk = false
    }

    private func configureSession() throws {
        if self.engine.isRunning {
            self.engine.stop()
        }
        self.engine.reset()
        // Force input node instantiation (ensures the underlying AUHAL AudioUnit exists)
        _ = self.engine.inputNode

        // If we're running in "independent" mode, bind the engine to the preferred input device
        // instead of inheriting macOS' current system-default input.
        self.bindPreferredInputDeviceIfNeeded()
    }

    /// In independent mode, attempt to bind AVAudioEngine's input to the user's preferred input device.
    /// In sync-with-system mode, we intentionally do nothing so the engine follows macOS defaults.
    private func bindPreferredInputDeviceIfNeeded() {
        guard SettingsStore.shared.syncAudioDevicesWithSystem == false else { return }
        guard let preferredUID = SettingsStore.shared.preferredInputDeviceUID, preferredUID.isEmpty == false else { return }

        guard let device = AudioDevice.getInputDevice(byUID: preferredUID) else {
            DebugLogger.shared.warning(
                "Preferred input device not found (uid: \(preferredUID)). Falling back to system default input.",
                source: "ASRService"
            )
            return
        }

        let ok = self.setEngineInputDevice(deviceID: device.id, deviceUID: device.uid, deviceName: device.name)
        if ok == false {
            DebugLogger.shared.warning(
                "Failed to bind engine input to preferred device '\(device.name)' (uid: \(device.uid)). Using system default input.",
                source: "ASRService"
            )
        }
    }

    /// Selects a specific CoreAudio device for AVAudioEngine's input node without changing system defaults.
    /// This uses the AUHAL AudioUnit backing `engine.inputNode` on macOS.
    @discardableResult
    private func setEngineInputDevice(deviceID: AudioObjectID, deviceUID: String, deviceName: String) -> Bool {
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
            DebugLogger.shared.error(
                "AudioUnitSetProperty(CurrentDevice) failed for '\(deviceName)' (uid: \(deviceUID), id: \(deviceID)) with status \(status)",
                source: "ASRService"
            )
            return false
        }

        DebugLogger.shared.info("Bound ASR input to '\(deviceName)' (uid: \(deviceUID))", source: "ASRService")
        return true
    }

    private func startEngine() throws {
        self.engine.reset()
        var attempts = 0
        while attempts < 3 {
            do {
                try self.engine.start()
                return
            } catch {
                attempts += 1
                Thread.sleep(forTimeInterval: 0.1)
                self.engine.reset()
                // After a reset, the underlying AUHAL unit may revert to system-default input.
                // Re-create the input node and re-bind the preferred device (independent mode).
                _ = self.engine.inputNode
                self.bindPreferredInputDeviceIfNeeded()
            }
        }
        throw NSError(domain: "ASRService", code: -1)
    }

    private func removeEngineTap() {
        self.engine.inputNode.removeTap(onBus: 0)
    }

    private func setupEngineTap() {
        let input = self.engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        self.inputFormat = inFormat
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.processInputBuffer(buffer: buffer)
        }
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
    private func registerDefaultDeviceChangeListener() {
        guard self.defaultInputListenerInstalled == false else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { [weak self] _, _ in
            self?.handleDefaultInputChanged()
        }
        if status == noErr { self.defaultInputListenerInstalled = true }
    }

    private func processInputBuffer(buffer: AVAudioPCMBuffer) {
        guard self.isRecordingWholeSession else {
            DispatchQueue.main.async { self.audioLevelSubject.send(0.0) }
            return
        }

        let mono16k = self.toMono16k(floatBuffer: buffer)
        if mono16k.isEmpty == false {
            // Thread-safe append
            self.audioBuffer.append(mono16k)

            // Publish audio level for visualization
            let audioLevel = self.calculateAudioLevel(mono16k)
            DispatchQueue.main.async { self.audioLevelSubject.send(audioLevel) }
        }
    }

    private func calculateAudioLevel(_ samples: [Float]) -> CGFloat {
        guard samples.isEmpty == false else { return 0.0 }

        // Calculate RMS
        var sum: Float = 0.0
        vDSP_svesq(samples, 1, &sum, vDSP_Length(samples.count))
        let rms = sqrt(sum / Float(samples.count))

        // Apply noise gate at RMS level
        if rms < 0.002 {
            return self.applySmoothingAndThreshold(0.0)
        }

        // Convert to dB with better scaling
        let dbLevel = 20 * log10(max(rms, 1e-10))
        let normalizedLevel = max(0, min(1, (dbLevel + 55) / 55))

        return self.applySmoothingAndThreshold(CGFloat(normalizedLevel))
    }

    private func applySmoothingAndThreshold(_ newLevel: CGFloat) -> CGFloat {
        // Minimal smoothing for real-time response
        self.audioLevelHistory.append(newLevel)
        if self.audioLevelHistory.count > self.historySize {
            self.audioLevelHistory.removeFirst()
        }

        // Light smoothing - mostly use current value
        let average = self.audioLevelHistory.reduce(0, +) / CGFloat(self.audioLevelHistory.count)
        let smoothingFactor: CGFloat = 0.7 // Much more responsive
        self.smoothedLevel = (smoothingFactor * newLevel) + ((1 - smoothingFactor) * average)

        // Simple threshold - just cut off below silence level
        if self.smoothedLevel < self.silenceThreshold {
            return 0.0
        }

        return self.smoothedLevel
    }

    private func toMono16k(floatBuffer: AVAudioPCMBuffer) -> [Float] {
        if let format = floatBuffer.format as AVAudioFormat?,
           format.sampleRate == 16_000.0,
           format.commonFormat == .pcmFormatFloat32,
           format.channelCount == 1,
           let channelData = floatBuffer.floatChannelData
        {
            let frameCount = Int(floatBuffer.frameLength)
            let ptr = channelData[0]
            return Array(UnsafeBufferPointer(start: ptr, count: frameCount))
        }
        let mono = self.downmixToMono(floatBuffer)
        return self.resampleTo16k(mono, sourceSampleRate: floatBuffer.format.sampleRate)
    }

    private func downmixToMono(_ buffer: AVAudioPCMBuffer) -> [Float] {
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

    private func resampleTo16k(_ samples: [Float], sourceSampleRate: Double) -> [Float] {
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
        while !Task.isCancelled {
            await self.processStreamingChunk()

            if Task.isCancelled || self.isRunning == false {
                break
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
        let minSamples = 8000 // 0.5 second minimum for faster initial feedback
        guard currentSampleCount >= minSamples else { return }

        // Thread-safe copy of the data
        let chunk = self.audioBuffer.getPrefix(currentSampleCount)

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
