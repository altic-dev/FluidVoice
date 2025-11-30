import Foundation
import AVFoundation
import Combine
import Accelerate
import FluidAudio
import CoreAudio
import AppKit

/// Serializes all CoreML transcription operations to prevent concurrent access issues.
/// The actor ensures only one transcription runs at a time, preventing CoreML race conditions.
private actor TranscriptionExecutor {
    func run<T>(_ operation: @escaping () async throws -> T) async rethrows -> T {
        try await operation()
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
/// The service automatically detects and transcribes 25 European languages with Parakeet TDT v3:
/// Bulgarian, Croatian, Czech, Danish, Dutch, English, Estonian, Finnish, French, German, 
/// Greek, Hungarian, Italian, Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian, 
/// Slovak, Slovenian, Spanish, Swedish, Russian, and Ukrainian.
///
/// No manual language selection is required - the model automatically detects the spoken language.
/// ## Thread Safety
/// All public methods are marked with @MainActor to ensure thread safety.
/// Audio processing happens on background threads for optimal performance.
///
/// ## Model Management
/// The service automatically downloads and manages ASR models from Hugging Face.
/// Models are cached locally to avoid repeated downloads.
@MainActor
final class ASRService: ObservableObject
{
    @Published var isRunning: Bool = false
    @Published var finalText: String = ""
    @Published var partialTranscription: String = ""
    @Published var micStatus: AVAuthorizationStatus = .notDetermined
    @Published var isAsrReady: Bool = false
    @Published var isDownloadingModel: Bool = false
    @Published var isLoadingModel: Bool = false  // True when loading cached model into memory (not downloading)
    @Published var modelsExistOnDisk: Bool = false
    @Published var selectedModel: ModelOption = .parakeetTdt06bV3
    
    /// Returns a user-friendly status message for model loading state
    var modelStatusMessage: String {
        if isAsrReady { return "Model ready" }
        if isDownloadingModel { return "Downloading model..." }
        if isLoadingModel { return "Loading model into memory..." }
        if modelsExistOnDisk { return "Model cached, needs loading" }
        return "Model not downloaded"
    }

    enum ModelOption: String, CaseIterable, Identifiable, Hashable
    {
        case parakeetTdt06bV3 = "Parakeet TDT-0.6b v3"
        var id: String { rawValue }
        var displayName: String { rawValue }
    }


    private let engine = AVAudioEngine()
    private var inputFormat: AVAudioFormat?
    private var micPermissionGranted = false

    // Internal access for MeetingTranscriptionService to share models
    var asrManager: AsrManager?

    private var isRecordingWholeSession: Bool = false
    private var recordedPCM: [Float] = []

    // Streaming transcription state (no VAD)
    private var streamingTask: Task<Void, Never>?
    private var lastProcessedSampleCount: Int = 0
    private let chunkDurationSeconds: Double = 0.6  // Fast interval - TranscriptionExecutor actor handles CoreML serialization
    private var isProcessingChunk: Bool = false
    private var skipNextChunk: Bool = false
    private var previousFullTranscription: String = ""
    private let transcriptionExecutor = TranscriptionExecutor() // Serializes all CoreML access

    private var audioLevelSubject = PassthroughSubject<CGFloat, Never>()
    var audioLevelPublisher: AnyPublisher<CGFloat, Never> { audioLevelSubject.eraseToAnyPublisher() }
    private var lastAudioLevelSentAt: TimeInterval = 0
    
    // Audio smoothing properties - lighter smoothing for real-time response
    private var audioLevelHistory: [CGFloat] = []
    private var smoothedLevel: CGFloat = 0.0
    private let historySize = 2 // Reduced for faster response
    private let silenceThreshold: CGFloat = 0.04 // Reasonable default
    private let noiseGateThreshold: CGFloat = 0.06
    init()
    {
        self.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        self.micPermissionGranted = (self.micStatus == .authorized)
        registerDefaultDeviceChangeListener()
        checkIfModelsExist()
        
        // Auto-load models if they exist on disk to avoid "Downloaded but not loaded" state
        if modelsExistOnDisk {
            DebugLogger.shared.info("Models found on disk, auto-loading...", source: "ASRService")
            Task { [weak self] in
                guard let self = self else { return }
                do {
                    try await self.ensureAsrReady()
                    DebugLogger.shared.info("Models auto-loaded successfully on startup", source: "ASRService")
                } catch {
                    DebugLogger.shared.error("Failed to auto-load models on startup: \(error)", source: "ASRService")
                }
            }
        }
    }
    
    /// Check if models exist on disk without loading them
    func checkIfModelsExist() {
        let baseCacheDir = AsrModels.defaultCacheDirectory().deletingLastPathComponent()
        let v3CacheDir = baseCacheDir.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml")
        modelsExistOnDisk = FileManager.default.fileExists(atPath: v3CacheDir.path)
        DebugLogger.shared.debug("Models exist on disk: \(modelsExistOnDisk)", source: "ASRService")
    }


    func requestMicAccess()
    {
        AVCaptureDevice.requestAccess(for: .audio)
        { [weak self] granted in
            guard let self = self else { return }
            Task { @MainActor in
                self.micPermissionGranted = granted
                self.micStatus = granted ? .authorized : .denied
            }
        }
    }

    func openSystemSettingsForMic()
    {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        {
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
    func start()
    {
        guard micStatus == .authorized else { return }
        guard isRunning == false else { return }

        finalText.removeAll()
        recordedPCM.removeAll()
        partialTranscription.removeAll()
        previousFullTranscription.removeAll()
        lastProcessedSampleCount = 0
        isProcessingChunk = false
        skipNextChunk = false
        isRecordingWholeSession = true

        do
        {
            try configureSession()
            try startEngine()
            setupEngineTap()
            isRunning = true
            startStreamingTranscription()
        }
        catch
        {
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
    func stop() async -> String
    {
        guard isRunning else { return "" }
        
        DebugLogger.shared.debug("stop(): cancelling streaming and preparing final transcription", source: "ASRService")
        
        stopStreamingTimer()
        removeEngineTap()
        engine.stop()
        isRunning = false
        
        isProcessingChunk = false
        skipNextChunk = false
        previousFullTranscription.removeAll()

        // Thread-safe copy of recorded audio
        let pcm = recordedPCM
        recordedPCM.removeAll()
        isRecordingWholeSession = false

        do
        {
            try await self.ensureAsrReady()
            guard let manager = self.asrManager else { 
                DebugLogger.shared.error("ASR manager is nil", source: "ASRService")
                return "" 
            }
            
            DebugLogger.shared.debug("Starting transcription with \(pcm.count) samples (\(Float(pcm.count)/16000.0) seconds)", source: "ASRService")
            DebugLogger.shared.debug("stop(): starting full transcription (samples: \(pcm.count))", source: "ASRService")
            let result = try await transcriptionExecutor.run {
                try await manager.transcribe(pcm, source: AudioSource.microphone)
            }
            DebugLogger.shared.debug("stop(): full transcription finished", source: "ASRService")
            DebugLogger.shared.debug("Transcription completed: '\(result.text)' (confidence: \(result.confidence))", source: "ASRService")
            // Do not update self.finalText here to avoid instant binding insert in playground
            return result.text
        }
        catch
        {
            DebugLogger.shared.error("ASR transcription failed: \(error)", source: "ASRService")
            DebugLogger.shared.error("Error details: \(error.localizedDescription)", source: "ASRService")
            let nsError = error as NSError
            DebugLogger.shared.error("Error domain: \(nsError.domain), code: \(nsError.code)", source: "ASRService")
            DebugLogger.shared.error("Error userInfo: \(nsError.userInfo)", source: "ASRService")
            return ""
        }
    }





    func stopWithoutTranscription()
    {
        guard isRunning else { return }
        
        stopStreamingTimer()
        removeEngineTap()
        engine.stop()
        isRunning = false
        recordedPCM.removeAll()
        isRecordingWholeSession = false
        partialTranscription.removeAll()
        previousFullTranscription.removeAll()
        lastProcessedSampleCount = 0
        isProcessingChunk = false
        skipNextChunk = false
    }

    private func configureSession() throws
    {
        if engine.isRunning
        {
            engine.stop()
        }
        engine.reset()
        _ = engine.inputNode
    }

    private func startEngine() throws
    {
        engine.reset()
        var attempts = 0
        while attempts < 3
        {
            do
            {
                try engine.start()
                return
            }
            catch
            {
                attempts += 1
                Thread.sleep(forTimeInterval: 0.1)
                engine.reset()
            }
        }
        throw NSError(domain: "ASRService", code: -1)
    }

    private func removeEngineTap()
    {
        engine.inputNode.removeTap(onBus: 0)
    }

    private func setupEngineTap()
    {
        let input = engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        inputFormat = inFormat
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat)
        { [weak self] (buffer, _) in
            self?.processInputBuffer(buffer: buffer)
        }
    }

    private func handleDefaultInputChanged()
    {
        // Restart engine to bind to the new default input and resume level publishing
        if isRunning
        {
            removeEngineTap()
            engine.stop()
            do
            {
                try configureSession()
                try startEngine()
                setupEngineTap()
            }
            catch
            {
            }
        }
        // Nudge visualizer
        DispatchQueue.main.async { self.audioLevelSubject.send(0.0) }
    }

    private var defaultInputListenerInstalled = false
    private func registerDefaultDeviceChangeListener()
    {
        guard defaultInputListenerInstalled == false else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main)
        { [weak self] _, _ in
            self?.handleDefaultInputChanged()
        }
        if status == noErr { defaultInputListenerInstalled = true }
    }

    private func processInputBuffer(buffer: AVAudioPCMBuffer)
    {
        guard isRecordingWholeSession else
        {
            DispatchQueue.main.async { self.audioLevelSubject.send(0.0) }
            return
        }

        let mono16k = self.toMono16k(floatBuffer: buffer)
        if mono16k.isEmpty == false
        {
            recordedPCM.append(contentsOf: mono16k)

            // Publish audio level for visualization
            let audioLevel = self.calculateAudioLevel(mono16k)
            DispatchQueue.main.async { self.audioLevelSubject.send(audioLevel) }
        }
    }

    private func calculateAudioLevel(_ samples: [Float]) -> CGFloat
    {
        guard samples.isEmpty == false else { return 0.0 }
        
        // Calculate RMS
        var sum: Float = 0.0
        vDSP_svesq(samples, 1, &sum, vDSP_Length(samples.count))
        let rms = sqrt(sum / Float(samples.count))
        
        // Apply noise gate at RMS level
        if rms < 0.002 {
            return applySmoothingAndThreshold(0.0)
        }
        
        // Convert to dB with better scaling
        let dbLevel = 20 * log10(max(rms, 1e-10))
        let normalizedLevel = max(0, min(1, (dbLevel + 55) / 55))
        
        return applySmoothingAndThreshold(CGFloat(normalizedLevel))
    }
    
    private func applySmoothingAndThreshold(_ newLevel: CGFloat) -> CGFloat {
        // Minimal smoothing for real-time response
        audioLevelHistory.append(newLevel)
        if audioLevelHistory.count > historySize {
            audioLevelHistory.removeFirst()
        }
        
        // Light smoothing - mostly use current value
        let average = audioLevelHistory.reduce(0, +) / CGFloat(audioLevelHistory.count)
        let smoothingFactor: CGFloat = 0.7 // Much more responsive
        smoothedLevel = (smoothingFactor * newLevel) + ((1 - smoothingFactor) * average)
        
        // Simple threshold - just cut off below silence level
        if smoothedLevel < silenceThreshold {
            return 0.0
        }
        
        return smoothedLevel
    }

    private func toMono16k(floatBuffer: AVAudioPCMBuffer) -> [Float]
    {
        if let format = floatBuffer.format as AVAudioFormat?,
           format.sampleRate == 16000.0,
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

    private func downmixToMono(_ buffer: AVAudioPCMBuffer) -> [Float]
    {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        if channels == 1
        {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        }
        var mono = [Float](repeating: 0, count: frameCount)
        for c in 0..<channels
        {
            let src = channelData[c]
            vDSP_vadd(src, 1, mono, 1, &mono, 1, vDSP_Length(frameCount))
        }
        var div = Float(channels)
        vDSP_vsdiv(mono, 1, &div, &mono, 1, vDSP_Length(frameCount))
        return mono
    }

    private func resampleTo16k(_ samples: [Float], sourceSampleRate: Double) -> [Float]
    {
        guard samples.isEmpty == false else { return [] }
        if sourceSampleRate == 16000.0 { return samples }
        let ratio = 16000.0 / sourceSampleRate
        let outCount = Int(Double(samples.count) * ratio)
        var output = [Float](repeating: 0, count: max(outCount, 0))
        if output.isEmpty { return [] }
        for i in 0..<outCount
        {
            let srcPos = Double(i) / ratio
            let idx = Int(srcPos)
            let frac = Float(srcPos - Double(idx))
            if idx + 1 < samples.count
            {
                let a = samples[idx]
                let b = samples[idx + 1]
                output[i] = a + (b - a) * frac
            }
            else if idx < samples.count
            {
                output[i] = samples[idx]
            }
        }
        return output
    }

    /// Ensures that ASR models are downloaded and ready for transcription.
    ///
    /// This method handles the complete model lifecycle:
    /// 1. Checks if models are already available and loaded
    /// 2. Downloads models from Hugging Face if needed
    /// 3. Loads models into memory for inference
    /// 4. Initializes the ASR manager with loaded models
    ///
    /// ## Model Management
    /// - Models are downloaded from the configured Hugging Face repository
    /// - Downloads are cached to avoid repeated network requests
    /// - Download state is reported via `isDownloadingModel`
    /// - Models include: melspectrogram, encoder, decoder, joint, and token prediction
    ///
    /// ## Performance
    /// - First run will download ~100-500MB of models
    /// - Subsequent runs use cached models (much faster)
    /// - Model loading happens asynchronously to avoid blocking UI
    ///
    /// ## Errors
    /// Throws if model download or loading fails. Common causes:
    /// - Network connectivity issues
    /// - Insufficient disk space
    /// - Invalid model repository configuration
    ///
    /// ## Note
    /// This method is called automatically when starting transcription.
    /// Manual calls are typically not needed unless you want to preload models.
    func ensureAsrReady() async throws
    {
        // Check if we're already ready and models are loaded - avoid unnecessary flicker
        if isAsrReady && asrManager != nil {
            DebugLogger.shared.debug("ASR already ready with loaded models, skipping initialization", source: "ASRService")
            return
        }

        // CRITICAL FIX: Early return if already ready to prevent UI flicker and crashes
        // This prevents unnecessary state resets that can cause SwiftUI object deallocation
        if isAsrReady {
            DebugLogger.shared.debug("ASR already marked as ready, skipping state reset", source: "ASRService")
            return
        }

        // Force reinitialization for v3 models by resetting state
        isAsrReady = false
        asrManager = nil
        
        if isAsrReady == false
        {
            let totalStartTime = Date()
            do
            {
                DebugLogger.shared.info("=== ASR INITIALIZATION START ===", source: "ASRService")

                // Use separate cache directory for v3 models
                let baseCacheDir = AsrModels.defaultCacheDirectory().deletingLastPathComponent()
                let cacheDir = baseCacheDir.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml")
                let modelsAlreadyCached = FileManager.default.fileExists(atPath: cacheDir.path)
                
                DebugLogger.shared.info("Model cache directory: \(cacheDir.path)", source: "ASRService")
                DebugLogger.shared.info("Models already cached on disk: \(modelsAlreadyCached)", source: "ASRService")

                let originalStderr = dup(STDERR_FILENO)
                let devNull = open("/dev/null", O_WRONLY)
                dup2(devNull, STDERR_FILENO)
                close(devNull)

                // Force v3: remove any v2 cache directory so no fallback occurs
                let v2CacheDir = baseCacheDir.appendingPathComponent("parakeet-tdt-0.6b-v2-coreml")
                if FileManager.default.fileExists(atPath: v2CacheDir.path) {
                    try FileManager.default.removeItem(at: v2CacheDir)
                    DebugLogger.shared.debug("Removed v2 cache directory to force v3", source: "ASRService")
                }

                // Set correct loading state based on whether models are cached
                DispatchQueue.main.async {
                    if modelsAlreadyCached {
                        self.isLoadingModel = true
                        self.isDownloadingModel = false
                        DebugLogger.shared.info("📦 LOADING cached model into memory (this takes 30-60 sec)...", source: "ASRService")
                    } else {
                        self.isDownloadingModel = true
                        self.isLoadingModel = false
                        DebugLogger.shared.info("⬇️ DOWNLOADING model from Hugging Face...", source: "ASRService")
                    }
                }
                
                // This call either downloads (if needed) OR just loads from cache
                let downloadStartTime = Date()
                DebugLogger.shared.info("Calling AsrModels.downloadAndLoad()...", source: "ASRService")
                let models = try await AsrModels.downloadAndLoad()
                let downloadDuration = Date().timeIntervalSince(downloadStartTime)
                DebugLogger.shared.info("✓ AsrModels.downloadAndLoad() completed in \(String(format: "%.1f", downloadDuration)) seconds", source: "ASRService")
                
                DispatchQueue.main.async {
                    self.isDownloadingModel = false
                    self.isLoadingModel = false
                    self.modelsExistOnDisk = true
                }
                
                // Initialize AsrManager
                if self.asrManager == nil
                {
                    DebugLogger.shared.debug("Creating new AsrManager...", source: "ASRService")
                    self.asrManager = AsrManager(config: ASRConfig.default)
                }
                if let manager = self.asrManager
                {
                    let initStartTime = Date()
                    DebugLogger.shared.info("Initializing AsrManager with loaded models...", source: "ASRService")
                    try await manager.initialize(models: models)
                    let initDuration = Date().timeIntervalSince(initStartTime)
                    DebugLogger.shared.info("✓ AsrManager.initialize() completed in \(String(format: "%.1f", initDuration)) seconds", source: "ASRService")
                }

                dup2(originalStderr, STDERR_FILENO)
                close(originalStderr)

                let totalDuration = Date().timeIntervalSince(totalStartTime)
                DebugLogger.shared.info("=== ASR INITIALIZATION COMPLETE ===", source: "ASRService")
                DebugLogger.shared.info("Total initialization time: \(String(format: "%.1f", totalDuration)) seconds", source: "ASRService")
            }
            catch
            {
                DebugLogger.shared.error("ASR initialization failed with error: \(error)", source: "ASRService")
                DebugLogger.shared.error("Error details: \(error.localizedDescription)", source: "ASRService")
                DispatchQueue.main.async {
                    self.isDownloadingModel = false
                    self.isLoadingModel = false
                }
                throw error
            }
            isAsrReady = true
        }
        else
        {
            DebugLogger.shared.debug("ASR already ready, skipping initialization", source: "ASRService")
        }
    }

    // MARK: - Model lifecycle helpers (parity with original API)
    func predownloadSelectedModel()
    {
        Task
        { [weak self] in
            guard let self = self else { return }
            DebugLogger.shared.info("Starting model predownload...", source: "ASRService")
            // ensureAsrReady handles setting the correct loading/downloading state
            do
            {
                try await self.ensureAsrReady()
                DebugLogger.shared.info("Model predownload completed successfully", source: "ASRService")
            }
            catch
            {
                DebugLogger.shared.error("Model predownload failed: \(error)", source: "ASRService")
            }
        }
    }

    func preloadModelAfterSelection() async
    {
        // ensureAsrReady handles setting the correct loading/downloading state
        do
        {
            try await self.ensureAsrReady()
        }
        catch
        {
            DebugLogger.shared.error("Model preload failed: \(error)", source: "ASRService")
        }
    }


    // MARK: - Cache management
    func clearModelCache() async throws
    {
        DebugLogger.shared.debug("Clearing all model caches to force fresh download", source: "ASRService")

        // Clear v2 cache
        let baseCacheDir = AsrModels.defaultCacheDirectory().deletingLastPathComponent()
        let v2CacheDir = baseCacheDir.appendingPathComponent("parakeet-tdt-0.6b-v2-coreml")
        if FileManager.default.fileExists(atPath: v2CacheDir.path) {
            try FileManager.default.removeItem(at: v2CacheDir)
            DebugLogger.shared.debug("Removed v2 cache directory", source: "ASRService")
        }

        // Clear v3 cache
        let v3CacheDir = baseCacheDir.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml")
        if FileManager.default.fileExists(atPath: v3CacheDir.path) {
            try FileManager.default.removeItem(at: v3CacheDir)
            DebugLogger.shared.debug("Removed v3 cache directory", source: "ASRService")
        }

        // Force reinitialization
        isAsrReady = false
        asrManager = nil
        modelsExistOnDisk = false
    }

    // MARK: - Timer-based Streaming Transcription (No VAD)
    
    private func startStreamingTranscription() {
        streamingTask?.cancel()
        guard isAsrReady else { return }

        DebugLogger.shared.debug("Starting streaming transcription task (interval: \(chunkDurationSeconds)s)", source: "ASRService")

        streamingTask = Task { [weak self] in
            await self?.runStreamingLoop()
        }
    }

    private func stopStreamingTimer() {
        streamingTask?.cancel()
        streamingTask = nil
    }

    @MainActor
    private func runStreamingLoop() async {
        while !Task.isCancelled {
            await processStreamingChunk()

            if Task.isCancelled || isRunning == false {
                break
            }

            do {
                try await Task.sleep(nanoseconds: UInt64(chunkDurationSeconds * 1_000_000_000))
            } catch {
                DebugLogger.shared.debug("Streaming transcription task cancelled", source: "ASRService")
                break
            }
        }
    }
    
    @MainActor
    private func processStreamingChunk() async {
        guard isRunning else { return }
        
        // Skip if already processing to prevent queue buildup
        guard !isProcessingChunk else {
            DebugLogger.shared.debug("⚠️ Skipping chunk - previous transcription still in progress", source: "ASRService")
            skipNextChunk = true
            return
        }
        
        if skipNextChunk {
            DebugLogger.shared.debug("⚠️ Skipping chunk for ANE recovery", source: "ASRService")
            skipNextChunk = false
            return
        }
        
        guard isAsrReady, let manager = asrManager else { return }
        
        let currentSampleCount = recordedPCM.count
        let minSamples = 8000  // 0.5 second minimum for faster initial feedback
        guard currentSampleCount >= minSamples else { return }
        
        // Copy the audio data to prevent mutation during processing
        let chunk = Array(recordedPCM[0..<currentSampleCount])
        
        isProcessingChunk = true
        defer { isProcessingChunk = false }
        
        let startTime = Date()
        
        do {
            DebugLogger.shared.debug("Streaming chunk starting CoreML transcription (samples: \(chunk.count))", source: "ASRService")
            let result = try await transcriptionExecutor.run {
                try await manager.transcribe(chunk, source: AudioSource.microphone)
            }
            
            let duration = Date().timeIntervalSince(startTime)
            DebugLogger.shared.debug(
                "Streaming chunk CoreML transcription finished in \(String(format: "%.2f", duration))s",
                source: "ASRService"
            )
            let newText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if !newText.isEmpty {
                // Smart diff: only show truly new words
                let updatedText = smartDiffUpdate(previous: previousFullTranscription, current: newText)
                partialTranscription = updatedText
                previousFullTranscription = newText
                
                DebugLogger.shared.debug("✅ Streaming: '\(updatedText)' (\(String(format: "%.2f", duration))s)", source: "ASRService")
            }
            
            // If transcription takes longer than the interval, skip next to prevent queue buildup
            // This allows slower machines to still work without overwhelming the system
            if duration > chunkDurationSeconds {
                DebugLogger.shared.debug("⚠️ Transcription slow (\(String(format: "%.2f", duration))s > \(chunkDurationSeconds)s), skipping next chunk", source: "ASRService")
                skipNextChunk = true
            }
        } catch {
            DebugLogger.shared.error("❌ Streaming failed: \(error)", source: "ASRService")
            skipNextChunk = true
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
               currWords[i].lowercased().trimmingCharacters(in: .punctuationCharacters) {
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
            return current  // Significant change
        }
    }

    // MARK: - Typing convenience for compatibility
    private let typingService = TypingService() // Reuse instance to avoid conflicts

    func typeTextToActiveField(_ text: String)
    {
        typingService.typeTextInstantly(text)
    }
}

