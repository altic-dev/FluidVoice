import AudioToolbox
import CoreAudio
import Foundation

enum CallTranscriptionError: LocalizedError {
    case noAudioCaptured
    case noSpeechRecognized
    case notRecording
    case microphoneUnavailable
    case systemAudioUnavailable(String)
    case audioCaptureInUse
    case audioWriterFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioCaptured:
            return "No call audio was captured."
        case .noSpeechRecognized:
            return "No speech was recognized in the call recording."
        case .notRecording:
            return "No call recording is active."
        case .microphoneUnavailable:
            return "No microphone is available for call recording."
        case let .systemAudioUnavailable(detail):
            return "System audio could not be captured. Allow FluidVoice to record system audio in Privacy & Security, then try again. \(detail)"
        case .audioCaptureInUse:
            return "Another FluidVoice audio capture is already active. Stop it before recording a call."
        case let .audioWriterFailed(message):
            return "Could not save call audio: \(message)"
        }
    }
}

/// Captures system audio and the selected microphone as aligned temporary source tracks.
final class CallCaptureSession: @unchecked Sendable {
    private let microphoneDevice: AudioDevice.Device
    private var systemTap: CallSystemAudioTap?
    private var systemCapture: DirectCoreAudioLifecycleController?
    private var microphoneCapture: DirectCoreAudioLifecycleController?
    private var systemWriter: CallPCMTrackWriter?
    private var microphoneWriter: CallPCMTrackWriter?
    private var directoryURL: URL?
    private var recordingStamp: String?

    init(microphoneDevice: AudioDevice.Device) {
        self.microphoneDevice = microphoneDevice
    }

    static func removeRecordingDirectory(at directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    func start() async throws {
        let stamp = Self.recordingStamp(for: Date())
        let directory = try Self.makeRecordingDirectory(stamp: stamp)
        let systemPCMURL = directory.appendingPathComponent("system.caf")
        let microphonePCMURL = directory.appendingPathComponent("microphone.caf")
        let captureStartedHostTime = AudioGetCurrentHostTime()

        let systemWriter = CallPCMTrackWriter(
            source: .system,
            url: systemPCMURL,
            captureStartedHostTime: captureStartedHostTime
        )
        let microphoneWriter = CallPCMTrackWriter(
            source: .microphone,
            url: microphonePCMURL,
            captureStartedHostTime: captureStartedHostTime
        )

        self.directoryURL = directory
        self.recordingStamp = stamp
        self.systemWriter = systemWriter
        self.microphoneWriter = microphoneWriter

        do {
            let tap = try await CallSystemAudioTap.create()
            self.systemTap = tap

            let systemCapture = DirectCoreAudioLifecycleController(
                packetHandler: { samples, frameCount, sampleRate, hostTime, _ in
                    do {
                        try systemWriter.append(
                            samples: samples,
                            frameCount: frameCount,
                            sampleRate: sampleRate,
                            hostTime: hostTime
                        )
                    } catch {
                        systemWriter.record(error: error)
                    }
                },
                installsHardwareListeners: false,
                onFormatInvalidated: { _ in }
            )
            self.systemCapture = systemCapture
            do {
                _ = try await systemCapture.start(
                    deviceID: tap.aggregateDeviceID,
                    deviceName: "FluidVoice System Audio",
                    reason: "call_recording"
                )
            } catch {
                throw CallTranscriptionError.systemAudioUnavailable(error.localizedDescription)
            }

            let microphoneCapture = DirectCoreAudioLifecycleController(
                packetHandler: { samples, frameCount, sampleRate, hostTime, _ in
                    do {
                        try microphoneWriter.append(
                            samples: samples,
                            frameCount: frameCount,
                            sampleRate: sampleRate,
                            hostTime: hostTime
                        )
                    } catch {
                        microphoneWriter.record(error: error)
                    }
                },
                installsHardwareListeners: true,
                onFormatInvalidated: { invalidation in
                    guard invalidation.wasRunning else { return }
                    microphoneWriter.record(error: CallTranscriptionError.audioWriterFailed(
                        "Microphone audio changed or became unavailable during the call."
                    ))
                    DebugLogger.shared.warning(
                        "Call microphone capture invalidated: \(invalidation.reason)",
                        source: "CallCaptureSession"
                    )
                }
            )
            self.microphoneCapture = microphoneCapture
            _ = try await microphoneCapture.start(
                deviceID: self.microphoneDevice.id,
                deviceName: self.microphoneDevice.name,
                reason: "call_recording"
            )
        } catch {
            await self.stopCaptureInfrastructure(reason: "call_start_failed")
            self.resetCaptureState()
            Self.removeRecordingDirectory(at: directory)
            throw error
        }
    }

    func stop() async throws -> CapturedCallAudio {
        guard let directory = self.directoryURL,
              let stamp = self.recordingStamp
        else {
            throw CallTranscriptionError.notRecording
        }

        await self.stopCaptureInfrastructure(reason: "call_stop")
        defer { self.resetCaptureState() }

        do {
            let tracks = try [
                self.systemWriter?.finish(),
                self.microphoneWriter?.finish(),
            ].compactMap { $0 }
            self.systemWriter = nil
            self.microphoneWriter = nil

            guard !tracks.isEmpty else {
                throw CallTranscriptionError.noAudioCaptured
            }

            return CapturedCallAudio(
                directoryURL: directory,
                fileName: "call-\(stamp)",
                tracks: tracks
            )
        } catch {
            Self.removeRecordingDirectory(at: directory)
            throw error
        }
    }

    private func stopCaptureInfrastructure(reason: String) async {
        if let microphoneCapture = self.microphoneCapture {
            _ = await microphoneCapture.stop(retainPrepared: false, reason: reason)
        }
        self.microphoneCapture = nil

        if let systemCapture = self.systemCapture {
            _ = await systemCapture.stop(retainPrepared: false, reason: reason)
        }
        self.systemCapture = nil
        self.systemTap = nil
    }

    private func resetCaptureState() {
        self.systemTap = nil
        self.systemCapture = nil
        self.microphoneCapture = nil
        self.systemWriter = nil
        self.microphoneWriter = nil
        self.directoryURL = nil
        self.recordingStamp = nil
    }

    private static func recordingStamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }

    private static func makeRecordingDirectory(stamp: String) throws -> URL {
        let suffix = String(UUID().uuidString.prefix(6))
        let directory = self.recordingRootURL.appendingPathComponent("\(stamp)-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static var recordingRootURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FluidVoice-Calls", isDirectory: true)
    }
}
