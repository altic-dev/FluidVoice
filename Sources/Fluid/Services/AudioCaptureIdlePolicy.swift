import CoreAudio

enum AudioCaptureIdlePolicy {
    struct CaptureAttemptIdentity: Equatable {
        let uid: String
        let name: String?
        let isBluetooth: Bool
        let isInternalMicrophone: Bool

        static func resolve(
            selectedInput: AudioDevice.Device?,
            forcingInputUID: String?,
            previous: Self?
        ) -> Self? {
            let uid = forcingInputUID ?? selectedInput?.uid
            guard let uid else { return nil }
            if let selectedInput, selectedInput.uid == uid {
                return Self(
                    uid: uid,
                    name: selectedInput.name,
                    isBluetooth: selectedInput.isBluetooth,
                    isInternalMicrophone: selectedInput.isUnavailableWhenClamshellClosed
                )
            }
            if previous?.uid == uid {
                return previous
            }
            return Self(
                uid: uid,
                name: nil,
                isBluetooth: false,
                isInternalMicrophone: false
            )
        }
    }

    enum BluetoothStartupRouteChangeDisposition: Equatable {
        case retryCurrentStart
        case preserveDeferredWork
        case ignore
    }

    struct DeferredBluetoothRouteRecovery {
        struct Request {
            let reason: String
            let requiresIdlePrewarm: Bool
            let reconcilesInputSelection: Bool
        }

        private var request: Request?

        mutating func preserve(
            reason: String,
            requiresIdlePrewarm: Bool,
            reconcilesInputSelection: Bool
        ) {
            guard requiresIdlePrewarm || reconcilesInputSelection else { return }
            self.request = Request(
                reason: self.request?.reason ?? reason,
                requiresIdlePrewarm: requiresIdlePrewarm || self.request?.requiresIdlePrewarm == true,
                reconcilesInputSelection: reconcilesInputSelection || self.request?.reconcilesInputSelection == true
            )
        }

        mutating func take() -> Request? {
            defer { self.request = nil }
            return self.request
        }
    }

    struct SilentPCMRecoveryWatchdog {
        static let requiredSilentWindows = 3
        static let maximumSilentRMS: Float = 0.00_001
        static let maximumSilentPeak: Float = 0.00_005

        private var hasSeenSignal = false
        private var consecutiveSilentWindows = 0
        private var hasRequestedRecovery = false

        mutating func shouldRecover(
            isInternalMicrophone: Bool,
            isDirectCapture: Bool,
            rms: Float,
            peak: Float
        ) -> Bool {
            guard isInternalMicrophone, isDirectCapture, self.hasRequestedRecovery == false else { return false }
            let isEffectivelySilent = rms <= Self.maximumSilentRMS && peak <= Self.maximumSilentPeak
            if isEffectivelySilent == false {
                self.hasSeenSignal = true
                self.consecutiveSilentWindows = 0
                return false
            }
            guard self.hasSeenSignal else { return false }
            self.consecutiveSilentWindows += 1
            guard self.consecutiveSilentWindows >= Self.requiredSilentWindows else { return false }
            self.hasRequestedRecovery = true
            return true
        }
    }

    struct BluetoothInputStabilization {
        /// New same-device retries may begin within this window. An admitted
        /// attempt still gets its normal readiness timeout so a nearly settled
        /// Bluetooth route is not cancelled at the deadline.
        static let retryAdmissionWindow: TimeInterval = 5

        private(set) var inputUID: String?
        private(set) var startedAt: TimeInterval?

        mutating func shouldRetry(
            inputUID: String,
            isBluetoothInput: Bool,
            now: TimeInterval
        ) -> Bool {
            guard isBluetoothInput || self.inputUID == inputUID else { return false }
            if self.inputUID != inputUID || self.startedAt == nil {
                self.inputUID = inputUID
                self.startedAt = now
            }
            return self.elapsed(at: now) < Self.retryAdmissionWindow
        }

        func elapsed(at now: TimeInterval) -> TimeInterval {
            guard let startedAt else { return 0 }
            return max(now - startedAt, 0)
        }
    }

    static func bluetoothInputAwaitingAvailability(
        priorityInputUIDs: [String],
        preferredInputUID: String?,
        resolvedInputUID: String?,
        allDevices: [AudioDevice.Device],
        excluding excludedUIDs: Set<String>
    ) -> AudioDevice.Device? {
        func settlingBluetoothDevice(uid: String) -> AudioDevice.Device? {
            guard let candidate = allDevices.first(where: { $0.uid == uid }),
                  candidate.isBluetooth,
                  candidate.hasInput == false,
                  candidate.isAlive
            else { return nil }
            return candidate
        }

        for uid in priorityInputUIDs where excludedUIDs.contains(uid) == false {
            if uid == resolvedInputUID { return nil }
            if let candidate = settlingBluetoothDevice(uid: uid) { return candidate }
        }
        guard let preferredInputUID,
              excludedUIDs.contains(preferredInputUID) == false,
              preferredInputUID != resolvedInputUID
        else { return nil }
        return settlingBluetoothDevice(uid: preferredInputUID)
    }

    static func shouldPrewarmCapture(experimentalDirectAudioCaptureEnabled: Bool) -> Bool {
        experimentalDirectAudioCaptureEnabled
    }

    static func didResolvedPriorityInputChange(
        priorityInputUIDs: [String],
        previousInputUIDs: Set<String>,
        currentInputUIDs: Set<String>
    ) -> Bool {
        let previousChoice = priorityInputUIDs.first(where: previousInputUIDs.contains)
        let currentChoice = priorityInputUIDs.first(where: currentInputUIDs.contains)
        return previousChoice != currentChoice
    }

    static func didResolvedPriorityInputIdentityChange(
        priorityInputUIDs: [String],
        previousInputDeviceIDsByUID: [String: AudioObjectID],
        currentInputDeviceIDsByUID: [String: AudioObjectID]
    ) -> Bool {
        let previousChoice = priorityInputUIDs.first { previousInputDeviceIDsByUID[$0] != nil }
        let currentChoice = priorityInputUIDs.first { currentInputDeviceIDsByUID[$0] != nil }
        guard previousChoice == currentChoice else { return true }
        guard let currentChoice else { return false }
        return previousInputDeviceIDsByUID[currentChoice] != currentInputDeviceIDsByUID[currentChoice]
    }

    static func shouldReconcileInputSelection(
        priorityInputUIDs: [String],
        migrationPending: Bool,
        previousInputUIDs: Set<String>,
        currentInputUIDs: Set<String>
    ) -> Bool {
        if currentInputUIDs.isEmpty {
            return previousInputUIDs.isEmpty == false && self.didResolvedPriorityInputChange(
                priorityInputUIDs: priorityInputUIDs,
                previousInputUIDs: previousInputUIDs,
                currentInputUIDs: currentInputUIDs
            )
        }
        return migrationPending || priorityInputUIDs.isEmpty || self.didResolvedPriorityInputChange(
            priorityInputUIDs: priorityInputUIDs,
            previousInputUIDs: previousInputUIDs,
            currentInputUIDs: currentInputUIDs
        )
    }

    static func shouldRecoverEngineConfigurationChange(
        isRunning: Bool,
        isStarting: Bool
    ) -> Bool {
        isRunning || isStarting
    }

    static func shouldDeferRouteRecoveryToBluetoothStart(
        directCaptureEnabled: Bool,
        isStarting: Bool,
        isRunning: Bool,
        attemptedInputIsBluetooth: Bool
    ) -> Bool {
        directCaptureEnabled && isStarting && isRunning == false && attemptedInputIsBluetooth
    }

    static func bluetoothStartupRouteChangeDisposition(
        invalidatesCurrentStart: Bool,
        requiresIdlePrewarm: Bool,
        reconcilesInputSelection: Bool
    ) -> BluetoothStartupRouteChangeDisposition {
        if invalidatesCurrentStart {
            return .retryCurrentStart
        }
        if requiresIdlePrewarm || reconcilesInputSelection {
            return .preserveDeferredWork
        }
        return .ignore
    }

    static func shouldRecoverAfterDeferredBluetoothReconciliation(
        isRunning: Bool,
        confirmedInputUID: String?,
        activeDeviceID: AudioObjectID?,
        resolvedInputUID: String?,
        resolvedDeviceID: AudioObjectID?,
        hasPreparedCapture: Bool,
        requiresIdlePrewarm: Bool
    ) -> Bool {
        if isRunning {
            return resolvedInputUID != confirmedInputUID || resolvedDeviceID != activeDeviceID
        }
        if hasPreparedCapture {
            return resolvedDeviceID != activeDeviceID
        }
        return requiresIdlePrewarm
    }
}
