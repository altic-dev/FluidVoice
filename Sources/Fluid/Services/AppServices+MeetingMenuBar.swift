import Foundation

extension AppServices {
    /// Starts the same coordinator used by FluidMeet without posting a navigation request.
    func startMeetingRecordingFromMenuBar() async throws {
        guard SettingsStore.shared.fluidMeetEnabled else { throw MeetingCoordinatorError.featureDisabled }
        let defaults = SettingsStore.shared.meetingRecordingDefaults
        let target = defaults.mode == .onlineCall ? self.meetingAutomaticTarget : nil
        let preferredInputUID = SettingsStore.shared.preferredInputDeviceUID
        let microphones = await MeetingCaptureSourceCatalog.microphoneSnapshot()
        let needsApplications = defaults.mode == .onlineCall && (target != nil || (defaults.isConfigured && defaults.applicationBundleIdentifier != nil))
        let applications = try await needsApplications ? MeetingCaptureSourceCatalog.availableApplications() : []
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
        guard SettingsStore.shared.fluidMeetEnabled else { throw MeetingCoordinatorError.featureDisabled }
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
        let application = try MeetingRecordingSourceResolver.resolve(
            mode: defaults.mode,
            source: MeetingRecordingSource(defaults: defaults),
            target: target,
            applications: applications
        )
        let mode = defaults.mode
        return MeetingCaptureConfiguration(
            mode: mode,
            title: MeetingTranscriptionSetupDraft.defaultTitle(mode: mode, applicationDisplayName: application?.displayName),
            languageCode: defaults.languageCode ?? "en",
            platform: application.map { MeetingPlatformProfile(identifier: $0.bundleIdentifier, displayName: $0.displayName) },
            application: application,
            microphone: microphone,
            timestampDefaultTitle: true
        )
    }
}
