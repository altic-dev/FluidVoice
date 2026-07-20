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
        case skippedFluidVoiceOnlyMode
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
        switch self.settings.microphoneSelectionMode {
        case .system:
            self.lastResult = .skippedSystemMode
            return .skippedSystemMode
        case .fluidVoiceOnly:
            // The whole point of FluidVoice-only mode: the preferred microphone is bound by the
            // direct capture path for this app only, so the macOS default is never touched.
            self.lastResult = .skippedFluidVoiceOnlyMode
            return .skippedFluidVoiceOnlyMode
        case .manual:
            break
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

    /// Switches between the two preferred-microphone modes and applies the system-default side
    /// effect that switch implies: leaving `.manual` hands the user's own input device back, and
    /// returning to `.manual` reasserts the preference onto the system default.
    ///
    /// Both entry points — the Settings switch and the menu-bar item — route through here so their
    /// behaviour cannot drift apart, and so the transition can be tested without driving the UI.
    /// Returns the mode actually applied, or nil if the current mode isn't a preferred-microphone
    /// mode (independence is only meaningful between `.manual` and `.fluidVoiceOnly`).
    @discardableResult
    func setFluidVoiceOnly(
        _ enabled: Bool,
        currentSystemInputUID: String?,
        availableInputUIDs: Set<String>
    ) -> SettingsStore.MicrophoneSelectionMode? {
        guard self.settings.microphoneSelectionMode.usesPreferredInputDevice else { return nil }

        let nextMode: SettingsStore.MicrophoneSelectionMode = enabled ? .fluidVoiceOnly : .manual
        let restoredSystemInputUID = self.settings.setMicrophoneSelectionMode(
            nextMode,
            currentSystemInputUID: currentSystemInputUID,
            availableInputUIDs: availableInputUIDs
        )

        // There has to be a device to capture from before we stop following the system default —
        // an empty preference would resolve back to the default and silently record the wrong mic.
        if (self.settings.preferredInputDeviceUID ?? "").isEmpty,
           let seed = currentSystemInputUID,
           seed.isEmpty == false
        {
            self.settings.recordInputDeviceSelection(seed)
        }

        if nextMode == .fluidVoiceOnly {
            if let restoredSystemInputUID {
                self.devices.setDefaultInputDevice(uid: restoredSystemInputUID)
            }
        } else {
            self.enforcePreferredInput(reason: "FluidVoice-only microphone mode disabled")
        }

        return nextMode
    }

    /// True when the user pinned FluidVoice to one specific microphone and that microphone is not
    /// currently connected.
    ///
    /// `inputDeviceForCapture()` deliberately falls back to the macOS default so `.manual` mode
    /// keeps working through a disconnect, but in `.fluidVoiceOnly` mode that same fallback would
    /// record the system microphone while Settings still shows the missing one. The recording path
    /// uses this to refuse rather than capture the wrong device.
    func preferredInputIsMissing() -> Bool {
        guard self.settings.microphoneSelectionMode == .fluidVoiceOnly,
              let preferredUID = self.settings.preferredInputDeviceUID,
              preferredUID.isEmpty == false
        else {
            return false
        }

        return self.devices.listInputDevices().contains(where: { $0.uid == preferredUID }) == false
    }

    func inputDeviceForCapture() -> AudioDevice.Device? {
        if self.settings.microphoneSelectionMode.usesPreferredInputDevice,
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
