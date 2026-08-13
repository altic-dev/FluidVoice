import CoreAudio

enum AudioCaptureIdlePolicy {
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
}
