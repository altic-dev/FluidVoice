import Combine
import Foundation

@MainActor
protocol AudioDeviceManaging {
    func listInputDevices() -> [AudioDevice.Device]
    func defaultInputDevice() -> AudioDevice.Device?
}

struct CoreAudioDeviceManager: AudioDeviceManaging {
    func listInputDevices() -> [AudioDevice.Device] {
        AudioDevice.listInputDevices()
    }

    func defaultInputDevice() -> AudioDevice.Device? {
        AudioDevice.getDefaultInputDevice()
    }
}

enum MicrophoneCaptureResolution: Equatable {
    case standard
    case clamshellSelectedExternal(AudioDevice.Device)
    case clamshellFallback(AudioDevice.Device)
    case clamshellRequiresExternalMicrophone
    case unavailable
}

@MainActor
final class MicrophonePreferenceCoordinator: ObservableObject {
    private static let appOnlyMigrationVersion = 1

    private let settings: SettingsStore
    private let devices: any AudioDeviceManaging

    init(
        settings: SettingsStore? = nil,
        devices: (any AudioDeviceManaging)? = nil
    ) {
        self.settings = settings ?? .shared
        self.devices = devices ?? CoreAudioDeviceManager()
    }

    var needsAppOnlySelectionMigration: Bool {
        self.settings.appMicSelectionMigrationVersion < Self.appOnlyMigrationVersion
    }

    func migrateToAppOnlySelectionIfNeeded() {
        guard self.needsAppOnlySelectionMigration else {
            self.settings.enforceAppOnlyMicrophoneSelection()
            return
        }
        let inputs = self.devices.listInputDevices()
        let defaultInputUID = self.devices.defaultInputDevice()?.uid
        self.migrateToAppOnlySelectionIfNeeded(
            availableInputs: inputs,
            defaultInputUID: defaultInputUID
        )
    }

    func migrateToAppOnlySelectionIfNeeded(
        availableInputs: [AudioDevice.Device],
        defaultInputUID: String?
    ) {
        guard self.needsAppOnlySelectionMigration else {
            self.settings.enforceAppOnlyMicrophoneSelection()
            return
        }
        let preferredInput = availableInputs.first { input in
            input.uid == self.settings.preferredInputDeviceUID
        }
        guard let selectedInput = availableInputs.first(where: \.isBuiltIn)
            ?? preferredInput
            ?? self.fallbackInput(from: availableInputs, defaultInputUID: defaultInputUID)
        else { return }

        self.settings.preferredInputDeviceUID = selectedInput.uid
        self.settings.enforceAppOnlyMicrophoneSelection()
        self.settings.appMicSelectionMigrationVersion = Self.appOnlyMigrationVersion
        DebugLogger.shared.info(
            "Migrated FluidVoice microphone selection to app-only input '\(selectedInput.name)'",
            source: "MicrophonePreferenceCoordinator"
        )
    }

    @discardableResult
    func reconcileAppOnlySelection(
        availableInputs: [AudioDevice.Device],
        defaultInputUID: String?
    ) -> AudioDevice.Device? {
        self.migrateToAppOnlySelectionIfNeeded(
            availableInputs: availableInputs,
            defaultInputUID: defaultInputUID
        )
        return self.inputDeviceForCapture(
            availableInputs: availableInputs,
            defaultInputUID: defaultInputUID,
            persistFallback: true
        )
    }

    func inputDeviceForCapture() -> AudioDevice.Device? {
        self.inputDeviceForCapture(
            availableInputs: self.devices.listInputDevices(),
            defaultInputUID: self.devices.defaultInputDevice()?.uid
        )
    }

    func inputDeviceForCapture(
        availableInputs: [AudioDevice.Device],
        defaultInputUID: String? = nil,
        persistFallback: Bool = false
    ) -> AudioDevice.Device? {
        if let preferredUID = self.settings.preferredInputDeviceUID,
           preferredUID.isEmpty == false,
           let preferredDevice = availableInputs.first(where: { $0.uid == preferredUID })
        {
            return preferredDevice
        }

        guard let fallback = self.fallbackInput(
            from: availableInputs,
            defaultInputUID: defaultInputUID
        ) else { return nil }
        if persistFallback {
            self.settings.preferredInputDeviceUID = fallback.uid
            DebugLogger.shared.info(
                "Selected fallback FluidVoice microphone '\(fallback.name)'",
                source: "MicrophonePreferenceCoordinator"
            )
        }
        return fallback
    }

    func captureResolution() -> MicrophoneCaptureResolution {
        let isLidClosed = MacLidState.isClosed()
        guard isLidClosed == true else { return .standard }

        let inputs = self.devices.listInputDevices()
        return self.captureResolution(
            availableInputs: inputs,
            defaultInputUID: self.devices.defaultInputDevice()?.uid,
            isLidClosed: isLidClosed
        )
    }

    func captureResolution(
        availableInputs: [AudioDevice.Device],
        defaultInputUID: String? = nil,
        isLidClosed: Bool?
    ) -> MicrophoneCaptureResolution {
        guard isLidClosed == true else { return .standard }

        guard let selectedInput = self.inputDeviceForCapture(
            availableInputs: availableInputs,
            defaultInputUID: defaultInputUID
        ) else {
            return .unavailable
        }
        guard selectedInput.isBuiltIn else {
            return .clamshellSelectedExternal(selectedInput)
        }

        let externalInputs = availableInputs.filter { $0.isBuiltIn == false }
        if let defaultInputUID,
           let defaultExternalInput = externalInputs.first(where: { $0.uid == defaultInputUID })
        {
            return .clamshellFallback(defaultExternalInput)
        }
        if let externalInput = externalInputs.first {
            return .clamshellFallback(externalInput)
        }
        return .clamshellRequiresExternalMicrophone
    }

    private func fallbackInput(
        from inputs: [AudioDevice.Device],
        defaultInputUID: String?
    ) -> AudioDevice.Device? {
        guard inputs.isEmpty == false else { return nil }
        if let builtInInput = inputs.first(where: \.isBuiltIn) {
            return builtInInput
        }
        if let defaultUID = defaultInputUID,
           let defaultInput = inputs.first(where: { $0.uid == defaultUID })
        {
            return defaultInput
        }
        return inputs.first
    }
}
