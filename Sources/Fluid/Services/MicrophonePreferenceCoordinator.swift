import Combine
import Foundation

@MainActor
protocol AudioDeviceManaging {
    var isClamshellClosed: Bool { get }
    func listInputDevices() -> [AudioDevice.Device]
    func defaultInputDevice() -> AudioDevice.Device?
    func isInputDeviceUsable(_ device: AudioDevice.Device) -> Bool
}

extension AudioDeviceManaging {
    var isClamshellClosed: Bool { false }
    func isInputDeviceUsable(_: AudioDevice.Device) -> Bool { true }
}

struct CoreAudioDeviceManager: AudioDeviceManaging {
    var isClamshellClosed: Bool {
        ClamshellState.isClosed
    }

    func listInputDevices() -> [AudioDevice.Device] {
        AudioDevice.listInputDevices()
    }

    func defaultInputDevice() -> AudioDevice.Device? {
        AudioDevice.getDefaultInputDevice()
    }

    func isInputDeviceUsable(_ device: AudioDevice.Device) -> Bool {
        AudioDevice.isInputDeviceAlive(device)
    }
}

@MainActor
final class MicrophonePreferenceCoordinator: ObservableObject {
    private let settings: SettingsStore
    private let devices: any AudioDeviceManaging
    private var lastResolvedInputUID: String?
    private var lastResolvedInputName: String?
    private var hasConfirmedActiveSelection = false
    private var lastConfirmedInputUID: String?
    private var lastConfirmedInputName: String?
    @Published private(set) var confirmedActiveInputUID: String?
    private var startupNoticeTask: Task<Void, Never>?
    private var startupNoticeEligibilityEnabled = false
    private var didPresentStartupNotice = false

    init(
        settings: SettingsStore? = nil,
        devices: (any AudioDeviceManaging)? = nil
    ) {
        self.settings = settings ?? .shared
        self.devices = devices ?? CoreAudioDeviceManager()
    }

    var needsMicrophonePriorityMigration: Bool {
        self.settings.microphoneSelectionMigrationVersion < SettingsStore.microphonePriorityMigrationVersion
    }

    func migrateMicrophonePriorityIfNeeded() {
        guard self.needsMicrophonePriorityMigration else { return }
        let inputs = self.devices.listInputDevices()
        let defaultInputUID = self.devices.defaultInputDevice()?.uid
        self.migrateMicrophonePriorityIfNeeded(
            availableInputs: inputs,
            defaultInputUID: defaultInputUID
        )
    }

    func migrateMicrophonePriorityIfNeeded(
        availableInputs: [AudioDevice.Device],
        defaultInputUID: String?
    ) {
        guard self.needsMicrophonePriorityMigration else {
            self.settings.reconcileMicrophonePriority(with: availableInputs)
            return
        }
        let migrationVersion = self.settings.microphoneSelectionMigrationVersion
        let clamshellClosed = self.devices.isClamshellClosed
        let usableInputs = availableInputs.filter {
            self.isInputDeviceAvailable($0, clamshellClosed: clamshellClosed)
        }
        let preferredInput = usableInputs.first { input in
            input.uid == self.settings.preferredInputDeviceUID
        }
        let enumeratedPreferredInput = availableInputs.first { input in
            input.uid == self.settings.preferredInputDeviceUID
        }
        let enumeratedDefaultInput = defaultInputUID.flatMap { uid in
            availableInputs.first { $0.uid == uid }
        }
        let defaultInput = defaultInputUID.flatMap { uid in
            usableInputs.first { $0.uid == uid }
        }
        let migrationInputs = enumeratedDefaultInput.map { input in
            [input] + availableInputs.filter { $0.uid != input.uid }
        } ?? availableInputs
        let previousMode = self.settings.storedMicSelectionModeForMigration
        let hasStoredMode = self.settings.hasStoredMicSelectionModeForMigration
        let preserveLegacyStoredSelection =
            migrationVersion == 0 &&
            hasStoredMode == false &&
            self.settings.preferredInputDeviceUID?.isEmpty == false &&
            self.settings.suppressedMicrophoneUIDs.contains(
                self.settings.preferredInputDeviceUID ?? ""
            ) == false
        if migrationVersion >= 2,
           let preferredUID = self.settings.preferredInputDeviceUID,
           preferredUID.isEmpty == false
        {
            let preferredName = preferredInput?.name ?? "Previously selected microphone"
            self.settings.recordInputDeviceSelection(preferredUID, name: preferredName)
            self.settings.reconcileMicrophonePriority(with: migrationInputs)
            self.settings.microphoneSelectionMode = .manual
            self.settings.microphoneSelectionMigrationVersion = SettingsStore.microphonePriorityMigrationVersion
            return
        }
        let preserveDisconnectedManualSelection =
            migrationVersion == 0 && previousMode == .manual
        let preserveDisconnectedVersionOneExternal =
            migrationVersion == 1 &&
            enumeratedPreferredInput?.isBuiltIn != true &&
            Self.isLikelyBuiltInMicrophoneUID(self.settings.preferredInputDeviceUID) == false
        if preferredInput == nil,
           preserveDisconnectedManualSelection ||
           preserveDisconnectedVersionOneExternal ||
           preserveLegacyStoredSelection,
           let preferredUID = self.settings.preferredInputDeviceUID,
           preferredUID.isEmpty == false
        {
            self.settings.recordInputDeviceSelection(
                preferredUID,
                name: "Previously selected microphone"
            )
            self.settings.reconcileMicrophonePriority(with: migrationInputs)
            self.settings.microphoneSelectionMode = .manual
            self.settings.microphoneSelectionMigrationVersion = SettingsStore.microphonePriorityMigrationVersion
            return
        }
        let selectedInput: AudioDevice.Device?
        if migrationVersion == 0,
           previousMode == .manual
        {
            selectedInput = preferredInput
                ?? defaultInput
                ?? self.fallbackInput(from: usableInputs, defaultInputUID: defaultInputUID)
        } else if preserveLegacyStoredSelection {
            selectedInput = preferredInput
                ?? defaultInput
                ?? self.fallbackInput(from: usableInputs, defaultInputUID: defaultInputUID)
        } else if migrationVersion == 0 {
            // A fresh install must mirror macOS's selected input, not permanently
            // promote whichever fallback happened to enumerate first at launch.
            // If HAL has not exposed the default yet, leave migration pending;
            // capture can still use a temporary fallback without saving it.
            selectedInput = enumeratedDefaultInput
        } else if migrationVersion == 1,
                  let preferredInput,
                  preferredInput.isBuiltIn,
                  defaultInput?.uid != preferredInput.uid
        {
            // Repair only the known v1 built-in-first migration. Runtime priority
            // resolution itself never ranks a device by transport type.
            selectedInput = defaultInput
                ?? self.fallbackInput(from: usableInputs, defaultInputUID: defaultInputUID)
        } else {
            selectedInput = preferredInput
                ?? defaultInput
                ?? self.fallbackInput(from: usableInputs, defaultInputUID: defaultInputUID)
        }
        guard let selectedInput else {
            if migrationVersion == 0,
               previousMode == .system
            {
                // Keep the visible priority list and removal bookkeeping useful
                // while HAL has not exposed its default input yet. Migration stays
                // pending, so a later default-input event can still promote the
                // actual macOS selection to first place.
                let preferredUIDBeforePendingReconciliation = self.settings.preferredInputDeviceUID
                self.settings.reconcileMicrophonePriority(with: availableInputs)
                self.settings.preferredInputDeviceUID = preferredUIDBeforePendingReconciliation
                return
            }
            self.settings.reconcileMicrophonePriority(with: migrationInputs)
            return
        }

        self.settings.recordInputDeviceSelection(selectedInput.uid, name: selectedInput.name)
        self.settings.reconcileMicrophonePriority(with: migrationInputs)
        self.settings.microphoneSelectionMode = .manual
        self.settings.microphoneSelectionMigrationVersion = SettingsStore.microphonePriorityMigrationVersion
        DebugLogger.shared.info(
            "Migrated FluidVoice microphone priority with '\(selectedInput.name)' first",
            source: "MicrophonePreferenceCoordinator"
        )
    }

    @discardableResult
    func reconcileMicrophoneSelection(
        availableInputs: [AudioDevice.Device],
        defaultInputUID: String?
    ) -> AudioDevice.Device? {
        self.migrateMicrophonePriorityIfNeeded(
            availableInputs: availableInputs,
            defaultInputUID: defaultInputUID
        )
        let selectedInput = self.inputDeviceForCapture(
            availableInputs: availableInputs,
            defaultInputUID: defaultInputUID
        )
        self.reportResolvedSelection(uid: selectedInput?.uid, name: selectedInput?.name)
        if let confirmedActiveInputUID,
           availableInputs.contains(where: { device in
               device.uid == confirmedActiveInputUID && self.isInputDeviceAvailable(device)
           }) == false
        {
            self.confirmedActiveInputUID = nil
        }
        return selectedInput
    }

    func reportResolvedSelection(uid: String?, name: String?) {
        let previousUID = self.lastResolvedInputUID
        let previousName = self.lastResolvedInputName
        self.lastResolvedInputUID = uid
        self.lastResolvedInputName = name

        // Onboarding owns microphone feedback inside its setup panel. A global
        // floating notice here would cover that flow and duplicate the picker.
        guard self.settings.shouldShowOnboarding == false else { return }

        guard previousUID != nil, uid != previousUID else {
            if self.startupNoticeEligibilityEnabled {
                self.scheduleStartupNoticeAfterSelectionSettles()
            }
            return
        }

        if self.startupNoticeEligibilityEnabled, self.didPresentStartupNotice == false {
            self.startupNoticeTask?.cancel()
            self.startupNoticeTask = nil
            self.didPresentStartupNotice = true
        }

        let notice = MicrophoneChangeNotice(
            previousName: previousName,
            currentName: name,
            presentation: .selectionChange
        )
        DebugLogger.shared.info(
            "Selected microphone changed from '\(notice.previousName ?? "none")' " +
                "to '\(notice.currentName ?? "none")' before capture confirmation",
            source: "MicrophonePreferenceCoordinator"
        )
        MicrophoneChangeOverlayController.shared.show(notice)
    }

    func confirmActiveSelection(uid: String?, name: String?) {
        let previousName = self.lastConfirmedInputName
        self.lastConfirmedInputUID = uid
        self.lastConfirmedInputName = name ?? previousName
        self.confirmedActiveInputUID = uid

        guard self.hasConfirmedActiveSelection else {
            self.hasConfirmedActiveSelection = true
            DebugLogger.shared.debug(
                "Confirmed active microphone as '\(name ?? "none")'",
                source: "MicrophonePreferenceCoordinator"
            )
            return
        }
    }

    func markActiveSelectionUnavailable() {
        guard self.hasConfirmedActiveSelection,
              self.lastConfirmedInputUID != nil
        else { return }

        let previousName = self.lastConfirmedInputName
        self.confirmedActiveInputUID = nil
        self.lastConfirmedInputUID = nil
        self.lastConfirmedInputName = nil
        MicrophoneChangeOverlayController.shared.show(
            MicrophoneChangeNotice(
                previousName: previousName,
                currentName: nil,
                presentation: .activeChange
            )
        )
    }

    func scheduleStartupNoticeIfEligible(
        microphoneAuthorized: Bool,
        launchAllowsPresentation: Bool
    ) {
        guard microphoneAuthorized,
              launchAllowsPresentation,
              self.settings.shouldShowOnboarding == false,
              self.lastResolvedInputUID != nil,
              self.lastResolvedInputName != nil
        else { return }

        self.startupNoticeEligibilityEnabled = true
        self.scheduleStartupNoticeAfterSelectionSettles()
    }

    private func scheduleStartupNoticeAfterSelectionSettles() {
        guard self.startupNoticeEligibilityEnabled,
              self.didPresentStartupNotice == false,
              self.lastResolvedInputUID != nil,
              self.lastResolvedInputName != nil
        else { return }

        let expectedUID = self.lastResolvedInputUID
        self.startupNoticeTask?.cancel()
        self.startupNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled,
                  let self,
                  self.settings.shouldShowOnboarding == false,
                  self.lastResolvedInputUID == expectedUID,
                  let currentName = self.lastResolvedInputName
            else { return }
            self.startupNoticeTask = nil
            self.didPresentStartupNotice = true
            MicrophoneChangeOverlayController.shared.show(
                MicrophoneChangeNotice(
                    previousName: nil,
                    currentName: currentName,
                    presentation: .startupSelection
                )
            )
        }
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
        excluding excludedUIDs: Set<String> = []
    ) -> AudioDevice.Device? {
        let clamshellClosed = self.devices.isClamshellClosed
        let usableInputs = availableInputs.filter { device in
            excludedUIDs.contains(device.uid) == false &&
                self.isInputDeviceAvailable(device, clamshellClosed: clamshellClosed)
        }
        guard usableInputs.isEmpty == false else { return nil }

        for entry in self.settings.microphonePriority {
            if let input = usableInputs.first(where: { $0.uid == entry.uid }) {
                return input
            }
        }

        if let preferredUID = self.settings.preferredInputDeviceUID,
           let preferredInput = usableInputs.first(where: { $0.uid == preferredUID })
        {
            return preferredInput
        }

        return self.fallbackInput(
            from: usableInputs,
            defaultInputUID: defaultInputUID
        )
    }

    func isInputDeviceAvailable(_ device: AudioDevice.Device) -> Bool {
        self.isInputDeviceAvailable(
            device,
            clamshellClosed: self.devices.isClamshellClosed
        )
    }

    func movePriority(fromOffsets: IndexSet, toOffset: Int) {
        self.settings.reorderMicrophonePriority(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    private func fallbackInput(
        from inputs: [AudioDevice.Device],
        defaultInputUID: String?
    ) -> AudioDevice.Device? {
        guard inputs.isEmpty == false else { return nil }
        if let defaultInput = self.device(uid: defaultInputUID, in: inputs) {
            return defaultInput
        }
        return inputs.first
    }

    private func device(
        uid: String?,
        in inputs: [AudioDevice.Device]
    ) -> AudioDevice.Device? {
        guard let uid else { return nil }
        return inputs.first { $0.uid == uid }
    }

    private static func isLikelyBuiltInMicrophoneUID(_ uid: String?) -> Bool {
        guard let uid else { return false }
        let normalized = uid.lowercased()
        return normalized.contains("builtin") ||
            normalized.contains("built-in") ||
            normalized.contains("internal")
    }

    private func isInputDeviceAvailable(
        _ device: AudioDevice.Device,
        clamshellClosed: Bool
    ) -> Bool {
        guard self.settings.suppressedMicrophoneUIDs.contains(device.uid) == false else { return false }
        guard clamshellClosed == false || device.isUnavailableWhenClamshellClosed == false else { return false }
        return self.devices.isInputDeviceUsable(device)
    }
}
