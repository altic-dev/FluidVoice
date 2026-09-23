import Foundation

extension AppServices {
    /// Starts the same coordinator used by FluidMeet without posting a navigation request.
    func startMeetingRecordingFromMenuBar() async throws {
        let defaults = SettingsStore.shared.meetingRecordingDefaults
        let target = defaults.mode == .onlineCall ? self.meetingAutomaticTarget : nil
        let preferredInputUID = SettingsStore.shared.preferredInputDeviceUID
        let microphones = await MeetingCaptureSourceCatalog.microphoneSnapshot()
        let applications = try await target == nil ? [] : MeetingCaptureSourceCatalog.availableApplications()
        try Task.checkCancellation()
        // Never capture a replacement app when detection changed during source discovery.
        if let target, target != self.meetingAutomaticTarget {
            throw MeetingCaptureError.applicationUnavailable(target.bundleIdentifier)
        }
        let configuration = try Self.menuBarMeetingConfiguration(
            defaults: defaults,
            target: target,
            microphones: microphones,
            applications: applications,
            preferredInputUID: preferredInputUID
        )
        _ = try await self.meetingSessionCoordinator.startRecording(configuration: configuration)
    }

    static func menuBarMeetingConfiguration(
        defaults: MeetingRecordingDefaults,
        target: MeetingAutoDetector.ResolvedTarget?,
        microphones: MeetingMicrophoneCatalogSnapshot,
        applications: [MeetingApplicationIdentity],
        preferredInputUID: String?
    ) throws -> MeetingCaptureConfiguration {
        let savedMicrophone = defaults.savedMicrophone(in: microphones.identities)
        let selection = MeetingMicrophonePreselection.select(
            identities: microphones.identities,
            savedDeviceID: savedMicrophone?.captureDeviceID,
            savedRole: defaults.microphoneRole,
            systemDefaultUID: microphones.defaultCoreAudioUID,
            preferredInputUID: preferredInputUID,
            systemDefaultCaptureID: nil
        )
        guard var microphone = microphones.identities.first(where: { $0.captureDeviceID == selection.deviceID }) else {
            throw MeetingCaptureError.microphoneUnavailable
        }
        microphone.role = .unknown
        var application: MeetingApplicationIdentity?
        if defaults.mode == .onlineCall, let target {
            guard var match = applications.first(where: {
                $0.bundleIdentifier == target.bundleIdentifier && $0.processID == target.pid
            }) else {
                throw MeetingCaptureError.applicationUnavailable(target.bundleIdentifier)
            }
            match.windowID = target.windowID
            application = match
        }
        let mode: MeetingCaptureMode = application == nil ? .inRoom : .onlineCall
        return MeetingCaptureConfiguration(
            mode: mode,
            title: MeetingTranscriptionSetupDraft.defaultTitle(mode: mode, applicationDisplayName: application?.displayName),
            platform: application.map { MeetingPlatformProfile(identifier: $0.bundleIdentifier, displayName: $0.displayName) },
            application: application,
            microphone: microphone
        )
    }
}
