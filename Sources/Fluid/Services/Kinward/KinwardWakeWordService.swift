import AVFoundation
import CPorcupine
import Foundation

/// Always-on local wake-word listener for Kinward Mode, built directly on Picovoice's Porcupine
/// C API (via the vendored CPorcupine module - see Sources/PorcupineSupport). There is no
/// official Porcupine Swift package for macOS (only a CocoaPods iOS binding), so this wraps the
/// same C functions their iOS SDK wraps internally.
///
/// Marc must train his own custom keyword (e.g. "Hey Kinward") at
/// https://console.picovoice.ai and place the downloaded `*_mac.ppn` file at the path configured
/// in Settings > Kinward > Wake Word. Picovoice's stock keyword list (alexa, computer, etc.)
/// works too if a custom phrase isn't ready yet - point the same setting at one of the bundled
/// `resources/keyword_files/mac/*.ppn` files from the porcupine repo instead.
@MainActor
final class KinwardWakeWordService {
    static let shared = KinwardWakeWordService()

    private var porcupine: OpaquePointer?
    private let audioEngine = AVAudioEngine()
    private var isTapInstalled = false
    private var frameBuffer: [Int16] = []
    private var frameLength: Int32 = 0

    private init() {}

    var isRunning: Bool {
        self.porcupine != nil
    }

    /// Starts continuous listening. Safe to call repeatedly; no-ops if already running, not
    /// enabled in Settings, or not yet configured with an AccessKey + keyword file.
    func start() {
        guard SettingsStore.shared.kinwardWakeWordEnabled else { return }
        guard self.porcupine == nil else { return }

        let accessKey = SettingsStore.shared.kinwardWakeWordAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let keywordPath = SettingsStore.shared.kinwardWakeWordKeywordPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessKey.isEmpty, !keywordPath.isEmpty,
              FileManager.default.fileExists(atPath: keywordPath)
        else {
            DebugLogger.shared.warning("KinwardWakeWordService: not configured (AccessKey/keyword file missing)", source: "KinwardWakeWord")
            return
        }
        guard let modelPath = Self.locatePorcupineParamsFile() else {
            DebugLogger.shared.error(
                "KinwardWakeWordService: porcupine_params.pv not found in any bundle - if the FluidVoice Xcode target isn't picking up Package.swift's `resources:` declaration, add Sources/Fluid/Resources/porcupine_params.pv to its Copy Bundle Resources build phase manually",
                source: "KinwardWakeWord"
            )
            return
        }

        let sensitivity = Float(SettingsStore.shared.kinwardWakeWordSensitivity)
        var handle: OpaquePointer?
        let status = keywordPath.withCString { keywordPathC -> pv_status_t in
            var keywordPaths: [UnsafePointer<CChar>?] = [keywordPathC]
            var sensitivities: [Float32] = [sensitivity]
            return accessKey.withCString { accessKeyC in
                modelPath.withCString { modelPathC in
                    pv_porcupine_init(accessKeyC, modelPathC, "cpu", 1, &keywordPaths, &sensitivities, &handle)
                }
            }
        }
        guard status == PV_STATUS_SUCCESS, let handle else {
            DebugLogger.shared.error("KinwardWakeWordService: pv_porcupine_init failed (\(status))", source: "KinwardWakeWord")
            return
        }

        self.porcupine = handle
        self.frameLength = pv_porcupine_frame_length()
        self.frameBuffer.reserveCapacity(Int(self.frameLength))

        self.startAudioTap()
        DebugLogger.shared.info("KinwardWakeWordService: listening", source: "KinwardWakeWord")
    }

    func stop() {
        self.stopAudioTap()
        if let handle = self.porcupine {
            pv_porcupine_delete(handle)
            self.porcupine = nil
        }
    }

    // MARK: - Audio capture

    /// Runs a lightweight, independent 16kHz mono tap purely for wake-word scoring. Pauses
    /// itself whenever the main ASRService or KinwardModeService's own capture/speech is active,
    /// both to avoid device contention and so Kinward's own spoken replies can't self-trigger it.
    private func startAudioTap() {
        guard !self.isTapInstalled else { return }

        let inputNode = self.audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(pv_sample_rate()),
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            DebugLogger.shared.error("KinwardWakeWordService: failed to build audio converter", source: "KinwardWakeWord")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let ratio = targetFormat.sampleRate / inputFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }

            var error: NSError?
            converter.convert(to: outBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            guard error == nil, let channelData = outBuffer.int16ChannelData else { return }

            let samples = UnsafeBufferPointer(start: channelData[0], count: Int(outBuffer.frameLength))
            Task { @MainActor in
                self.consume(samples: samples)
            }
        }

        do {
            try self.audioEngine.start()
            self.isTapInstalled = true
        } catch {
            DebugLogger.shared.error("KinwardWakeWordService: audioEngine.start() failed - \(error.localizedDescription)", source: "KinwardWakeWord")
            inputNode.removeTap(onBus: 0)
        }
    }

    private func stopAudioTap() {
        guard self.isTapInstalled else { return }
        self.audioEngine.inputNode.removeTap(onBus: 0)
        self.audioEngine.stop()
        self.isTapInstalled = false
        self.frameBuffer.removeAll(keepingCapacity: true)
    }

    private func consume(samples: UnsafeBufferPointer<Int16>) {
        guard let handle = self.porcupine, self.frameLength > 0 else { return }

        // Don't score our own capture/speech, and don't fight ASRService for the mic.
        guard AppServices.shared.asr.isRunning == false,
              KinwardModeService.shared.isBusy == false
        else { return }

        self.frameBuffer.append(contentsOf: samples)

        while self.frameBuffer.count >= Int(self.frameLength) {
            let frame = Array(self.frameBuffer.prefix(Int(self.frameLength)))
            self.frameBuffer.removeFirst(Int(self.frameLength))

            var keywordIndex: Int32 = -1
            let status = frame.withUnsafeBufferPointer { pcm -> pv_status_t in
                pv_porcupine_process(handle, pcm.baseAddress, &keywordIndex)
            }
            guard status == PV_STATUS_SUCCESS else { continue }

            if keywordIndex == 0 {
                DebugLogger.shared.info("KinwardWakeWordService: wake word detected", source: "KinwardWakeWord")
                self.onWakeWordDetected()
                self.frameBuffer.removeAll(keepingCapacity: true)
                return
            }
        }
    }

    /// Xcode's own build (xcodebuild, per build.sh) may or may not honor Package.swift's
    /// SPM `resources:` declaration for a locally-integrated package target the way a plain
    /// `swift build` would - this repo's existing Resources/*.m4a assets aren't declared there
    /// at all, suggesting Xcode's project file manages Copy Bundle Resources directly instead.
    /// Try every plausible location rather than assuming one.
    private static func locatePorcupineParamsFile() -> String? {
        if let url = Bundle.module.url(forResource: "porcupine_params", withExtension: "pv") {
            return url.path
        }
        if let url = Bundle.main.url(forResource: "porcupine_params", withExtension: "pv") {
            return url.path
        }
        return nil
    }

    private func onWakeWordDetected() {
        Task { @MainActor in
            await KinwardModeService.shared.beginTurn()
            // v1 endpointing: fixed capture window rather than voice-activity detection.
            // Good enough to start talking today; a silence-based endpointer is a natural
            // follow-up once the always-on loop itself is proven on real hardware.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await KinwardModeService.shared.endTurnAndRespond()
        }
    }
}
