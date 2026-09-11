import AVFoundation
import CoreAudio
import Foundation

/// Owns the process tap and private aggregate input device used for system audio.
final class CallSystemAudioTap: @unchecked Sendable {
    let tapID: AudioObjectID
    let aggregateDeviceID: AudioObjectID

    private init(tapID: AudioObjectID, aggregateDeviceID: AudioObjectID) {
        self.tapID = tapID
        self.aggregateDeviceID = aggregateDeviceID
    }

    deinit {
        if self.aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(self.aggregateDeviceID)
        }
        if self.tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(self.tapID)
        }
    }

    static func create() async throws -> CallSystemAudioTap {
        let excludedProcesses = Self.currentProcessObjectID().map { [$0] } ?? []
        let tapDescription = CATapDescription(
            stereoGlobalTapButExcludeProcesses: excludedProcesses
        )
        tapDescription.name = "FluidVoice Call System Audio"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted
        tapDescription.uuid = UUID()

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard tapStatus == noErr, tapID != kAudioObjectUnknown else {
            throw CallTranscriptionError.systemAudioUnavailable(
                "Core Audio could not create a system-audio tap (OSStatus \(tapStatus))."
            )
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FluidVoice Call Audio",
            kAudioAggregateDeviceUIDKey: "com.fluidvoice.call-audio.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]

        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateDeviceID
        )
        guard aggregateStatus == noErr, aggregateDeviceID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            throw CallTranscriptionError.systemAudioUnavailable(
                "Core Audio could not create the private capture device (OSStatus \(aggregateStatus))."
            )
        }

        do {
            try await Self.waitUntilAlive(deviceID: aggregateDeviceID)
        } catch {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }

        return CallSystemAudioTap(tapID: tapID, aggregateDeviceID: aggregateDeviceID)
    }

    private static func waitUntilAlive(deviceID: AudioObjectID) async throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        for _ in 0..<30 {
            var isAlive: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                &isAlive
            )
            if status == noErr, isAlive != 0 {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        throw CallTranscriptionError.systemAudioUnavailable(
            "The Core Audio capture device did not become ready."
        )
    }

    private static func currentProcessObjectID() -> AudioObjectID? {
        var pid = getpid()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pid) { pidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPointer,
                &size,
                &processObjectID
            )
        }
        guard status == noErr, processObjectID != kAudioObjectUnknown else { return nil }
        return processObjectID
    }
}
