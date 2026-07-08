import CoreAudio
#if SWIFT_PACKAGE
import CoreAudioCaptureSupport
#endif
import Foundation

/// Prepared, input-only Core Audio capture.
///
/// `AudioDeviceIOProc` publishes native hardware-cycle PCM into a fixed SPSC
/// ring in C. This Swift wrapper drains that ring away from Core Audio's
/// realtime thread, so resampling, level calculation, logging, and ASR buffer
/// mutation never happen in the device callback.
final class DirectCoreAudioInput {
    typealias PacketHandler = @Sendable (
        _ samples: UnsafePointer<Float>,
        _ frameCount: Int,
        _ sampleRate: Double,
        _ inputHostTime: UInt64,
        _ inputSampleTime: Int64
    ) -> Void

    private struct SendableCaptureHandle: @unchecked Sendable {
        let rawValue: FVCoreAudioCaptureRef
    }

    let deviceID: AudioObjectID
    let sampleRate: Double
    let hardwareBufferFrameSize: UInt32

    private var capture: FVCoreAudioCaptureRef?
    private let packetHandler: PacketHandler
    private let workerQueue = DispatchQueue(
        label: "com.fluidvoice.audio.direct-input-consumer",
        qos: .userInteractive
    )
    private let workerGroup = DispatchGroup()

    init(deviceID: AudioObjectID, packetHandler: @escaping PacketHandler) throws {
        var capture: FVCoreAudioCaptureRef?
        let status = fv_core_audio_capture_create(deviceID, &capture)
        guard status == noErr, let capture else {
            throw Self.error(status: status, operation: "prepare direct Core Audio input")
        }

        self.deviceID = deviceID
        self.capture = capture
        self.sampleRate = fv_core_audio_capture_sample_rate(capture)
        self.hardwareBufferFrameSize = fv_core_audio_capture_buffer_frame_size(capture)
        self.packetHandler = packetHandler
    }

    deinit {
        self.invalidate()
    }

    var isRunning: Bool {
        guard let capture else { return false }
        return fv_core_audio_capture_is_running(capture)
    }

    var droppedPacketCount: UInt64 {
        guard let capture else { return 0 }
        return fv_core_audio_capture_dropped_packet_count(capture)
    }

    func start() throws {
        guard let capture else {
            throw Self.error(status: kAudioHardwareBadObjectError, operation: "start direct Core Audio input")
        }
        guard fv_core_audio_capture_is_running(capture) == false else { return }

        fv_core_audio_capture_clear(capture)
        let status = fv_core_audio_capture_start(capture)
        guard status == noErr else {
            throw Self.error(status: status, operation: "start direct Core Audio input")
        }

        let packetHandler = self.packetHandler
        let workerGroup = self.workerGroup
        let workerHandle = SendableCaptureHandle(rawValue: capture)
        workerGroup.enter()
        self.workerQueue.async {
            defer { workerGroup.leave() }
            Self.consumePackets(capture: workerHandle.rawValue, packetHandler: packetHandler)
        }
    }

    /// Stops hardware IO and synchronously drains every packet already published
    /// by the realtime callback before returning.
    @discardableResult
    func stop() -> OSStatus {
        guard let capture else { return noErr }
        let status = fv_core_audio_capture_stop(capture)
        fv_core_audio_capture_wake(capture)
        self.workerGroup.wait()
        return status
    }

    func invalidate() {
        guard let capture else { return }
        _ = self.stop()
        fv_core_audio_capture_destroy(capture)
        self.capture = nil
    }

    private nonisolated static func consumePackets(
        capture: FVCoreAudioCaptureRef,
        packetHandler: PacketHandler
    ) {
        while true {
            var packet = FVCoreAudioPacket()
            while fv_core_audio_capture_peek(capture, &packet) {
                if let samples = packet.samples, packet.frameCount > 0 {
                    packetHandler(
                        samples,
                        Int(packet.frameCount),
                        packet.sampleRate,
                        packet.inputHostTime,
                        packet.inputSampleTime
                    )
                }
                fv_core_audio_capture_consume(capture)
            }

            guard fv_core_audio_capture_is_running(capture) else {
                // AudioDeviceStop waits for the IOProc to leave. One final
                // acquire/drain above therefore captures the complete tail.
                return
            }
            _ = fv_core_audio_capture_wait(capture, 100)
        }
    }

    private static func error(status: OSStatus, operation: String) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [
                NSLocalizedDescriptionKey: "Failed to \(operation) (OSStatus \(status)).",
            ]
        )
    }
}
