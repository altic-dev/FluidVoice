import Combine
import Foundation

@MainActor
protocol AudioDeviceManaging {
    func listInputDevices() -> [AudioDevice.Device]
    func defaultInputDevice() -> AudioDevice.Device?
    @discardableResult func setDefaultInputDevice(uid: String) -> Bool
}

struct CoreAudioDeviceManager: AudioDeviceManaging {
    func listInputDevices() -> [AudioDevice.Device] {
        AudioDevice.listInputDevices()
    }

    func defaultInputDevice() -> AudioDevice.Device? {
        AudioDevice.getDefaultInputDevice()
    }

    @discardableResult
    func setDefaultInputDevice(uid: String) -> Bool {
        AudioDevice.setDefaultInputDevice(uid: uid)
    }
}

@MainActor
final class MicrophonePreferenceCoordinator: ObservableObject {
    enum EnforcementResult: Equatable {
        case skippedSystemMode
        case skippedNoPreferredInput
        case skippedPreferredUnavailable(String)
        case alreadyUsingPreferred(String)
        case applied(String)
        case failed(String)
    }

    @Published private(set) var lastResult: EnforcementResult?

    private let settings: SettingsStore
    private let devices: any AudioDeviceManaging
    private var stabilizationTask: Task<Void, Never>?

    init(
        settings: SettingsStore? = nil,
        devices: (any AudioDeviceManaging)? = nil
    ) {
        self.settings = settings ?? .shared
        self.devices = devices ?? CoreAudioDeviceManager()
    }

    @discardableResult
    func enforcePreferredInput(reason: String) -> EnforcementResult {
        guard self.settings.microphoneSelectionMode == .manual else {
            self.lastResult = .skippedSystemMode
            return .skippedSystemMode
        }

        guard let preferredUID = self.settings.preferredInputDeviceUID,
              preferredUID.isEmpty == false
        else {
            self.lastResult = .skippedNoPreferredInput
            return .skippedNoPreferredInput
        }

        let inputs = self.devices.listInputDevices()
        guard inputs.contains(where: { $0.uid == preferredUID }) else {
            let result = EnforcementResult.skippedPreferredUnavailable(preferredUID)
            self.lastResult = result
            DebugLogger.shared.warning(
                "Preferred microphone unavailable during \(reason): \(preferredUID)",
                source: "MicrophonePreferenceCoordinator"
            )
            return result
        }

        if self.devices.defaultInputDevice()?.uid == preferredUID {
            let result = EnforcementResult.alreadyUsingPreferred(preferredUID)
            self.lastResult = result
            return result
        }

        let didApply = self.devices.setDefaultInputDevice(uid: preferredUID)
        let result: EnforcementResult = didApply ? .applied(preferredUID) : .failed(preferredUID)
        self.lastResult = result

        if didApply {
            DebugLogger.shared.info(
                "Reasserted preferred microphone during \(reason): \(preferredUID)",
                source: "MicrophonePreferenceCoordinator"
            )
        } else {
            DebugLogger.shared.error(
                "Failed to reassert preferred microphone during \(reason): \(preferredUID)",
                source: "MicrophonePreferenceCoordinator"
            )
        }

        return result
    }

    func inputDeviceForCapture() -> AudioDevice.Device? {
        if self.settings.microphoneSelectionMode == .manual,
           let preferredUID = self.settings.preferredInputDeviceUID,
           preferredUID.isEmpty == false,
           let preferredDevice = self.devices.listInputDevices().first(where: { $0.uid == preferredUID })
        {
            return preferredDevice
        }

        return self.devices.defaultInputDevice()
    }

    func stabilizePreferredInputAfterHardwareChange(reason: String) {
        self.stabilizationTask?.cancel()
        self.stabilizationTask = Task { [weak self] in
            let delaysNanoseconds: [UInt64] = [
                250_000_000,
                750_000_000,
                1_500_000_000,
                2_500_000_000,
            ]

            for delay in delaysNanoseconds {
                try? await Task.sleep(nanoseconds: delay)
                guard Task.isCancelled == false else { return }
                _ = self?.enforcePreferredInput(reason: reason)
            }
        }
    }
}
