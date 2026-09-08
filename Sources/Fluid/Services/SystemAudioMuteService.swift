import AudioToolbox
import CoreAudio
import Foundation

/// Minimal CoreAudio surface used by ``SystemAudioMuteService``.
///
/// Extracted as a protocol so the service can be tested without touching the
/// user's real audio hardware.
@MainActor
protocol SystemAudioOutputControlling {
    func defaultOutputDeviceID() -> AudioObjectID?
    /// The device's stable identifier, which survives disconnect and reconnect
    /// unlike its `AudioObjectID`. `nil` for devices that publish no UID.
    func deviceUID(for deviceID: AudioObjectID) -> String?
    /// Resolves a stable identifier back to the device's current id, or `nil`
    /// while that device is disconnected.
    func deviceID(forUID deviceUID: String) -> AudioObjectID?
    /// `true` when the device exposes a writable mute switch on its main element.
    func supportsMute(on deviceID: AudioObjectID) -> Bool
    /// `nil` when the state cannot be read, which usually means the device is gone.
    func isMuted(on deviceID: AudioObjectID) -> Bool?
    @discardableResult
    func setMuted(_ muted: Bool, on deviceID: AudioObjectID) -> Bool
    func volume(on deviceID: AudioObjectID) -> Float?
    @discardableResult
    func setVolume(_ volume: Float, on deviceID: AudioObjectID) -> Bool
    /// Calls back when the default output changes or a device appears or
    /// disappears, so a disconnected device can be spotted coming back.
    func startObservingOutputDevices(_ onChange: @escaping @MainActor () -> Void)
    func stopObservingOutputDevices()
    /// Calls back when the device's own mute or volume changes, so a change made
    /// while it is held is seen as it happens rather than inferred afterwards.
    func startObservingSilenceState(on deviceID: AudioObjectID, _ onChange: @escaping @MainActor () -> Void)
    func stopObservingSilenceState(on deviceID: AudioObjectID)
}

/// Silences the default output device while a recording is in progress.
///
/// Unlike ``MediaPlaybackService``, which asks the frontmost Now Playing app to
/// pause, this works for any audio reaching the speakers — including browser
/// tabs, games, and conferencing apps that expose no media controls at all.
///
/// One rule keeps it honest: a record exists only while a device is silent
/// because of this service. Anything else, a device that was already quiet, one
/// that rejected the write, one that cannot be read, or one the user has since
/// changed, is not ours. Nothing is written to a device we do not hold, and a
/// device we fail to silence is re-attempted from scratch rather than
/// remembered, so a stale value can never be handed back later.
@MainActor
final class SystemAudioMuteService {
    /// Volumes at or below this are treated as already silent, matching the
    /// audibility check in ``TranscriptionSoundPlayer``.
    private static let silentVolumeThreshold: Float = 0.001

    /// How long to wait before re-attempting a device that would not be
    /// silenced. Long enough for hardware that is still initialising, short
    /// enough that little of the recording passes audible.
    private static let retryDelaySeconds: TimeInterval = 0.5

    typealias RetryScheduler = (
        _ delay: TimeInterval,
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> Void

    private static let productionRetryScheduler: RetryScheduler = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
    }

    static let shared = SystemAudioMuteService(
        outputController: CoreAudioOutputController(),
        retryScheduler: SystemAudioMuteService.productionRetryScheduler
    )

    /// How a device was silenced, and what to put back.
    private enum Intervention {
        case muteSwitch
        case zeroedVolume(previousVolume: Float)
    }

    /// A device that is silent right now because of this service.
    private struct Ownership {
        /// Stable across disconnect and reconnect, unlike the object id.
        let deviceUID: String
        /// The id the device currently has, refreshed when it reconnects.
        var deviceID: AudioObjectID
        let intervention: Intervention
        /// Set when the device has been seen absent since it was silenced.
        ///
        /// One of two signals that a device was recreated rather than changed by
        /// the user. This one catches a reconnect that kept the same object id;
        /// a changed id catches one whose disappearance was never observed,
        /// because the two notifications coalesced before the handler ran.
        var hasBeenDisconnected: Bool
    }

    private let outputController: any SystemAudioOutputControlling
    private let retryScheduler: RetryScheduler

    /// Devices silenced by this service and not yet handed back, keyed by UID so
    /// hardware that reconnects under a new object id resolves to the same entry.
    /// Switching output mid-recording adds an entry rather than replacing one.
    private var ownerships: [String: Ownership] = [:]

    /// `true` between ``muteIfAudible()`` and ``restoreIfMuted()``, meaning a
    /// recording still wants silence and output changes should follow it.
    ///
    /// Distinct from ``isHoldingMute``, which stays true for a device left owed
    /// a restore by an earlier recording. Only this one describes the recording
    /// in progress.
    private(set) var isSilencingForRecording = false

    /// Bounds the delayed re-attempts, so a device that simply will not take the
    /// write is not polled for the rest of the session.
    private static let maxRetryAttempts = 3

    private var hasScheduledRetry = false
    private var remainingRetryAttempts = 0

    /// Creates an isolated service with injectable dependencies for tests.
    init(
        outputController: any SystemAudioOutputControlling,
        retryScheduler: @escaping RetryScheduler
    ) {
        self.outputController = outputController
        self.retryScheduler = retryScheduler
    }

    /// `true` while this service is holding at least one device silent.
    var isHoldingMute: Bool {
        self.ownerships.isEmpty == false
    }

    // MARK: - Public API

    /// Silences the default output device if it is currently audible, and keeps
    /// following the default output until ``restoreIfMuted()`` is called.
    ///
    /// Does nothing to an output that is already silent, so a user who muted
    /// their Mac before recording is not unmuted when the recording ends.
    /// Prefers the device mute switch, which leaves the volume slider where the
    /// user put it, and falls back to dropping the volume to zero on devices
    /// without one.
    func muteIfAudible() {
        guard self.isSilencingForRecording == false else {
            DebugLogger.shared.debug(
                "SystemAudioMuteService: Already silencing output for this recording",
                source: "SystemAudioMuteService"
            )
            return
        }

        // Hand back anything an earlier recording could not restore before
        // taking new ownership, so a transient CoreAudio failure cannot strand a
        // device silent for the rest of the session.
        self.restoreOwnedDevices()

        self.isSilencingForRecording = true
        self.remainingRetryAttempts = Self.maxRetryAttempts

        // Observe before sampling the default output. CoreAudio does not replay a
        // change that happened before the listener existed, so registering after
        // the sample would miss a device that becomes the default in between and
        // leave it audible until the next topology event.
        self.updateOutputDeviceObservation()
        self.silenceCurrentDefaultOutput()
    }

    /// Re-registers the CoreAudio listeners this service depends on.
    ///
    /// A restart of the audio service discards every property listener, so
    /// without this a recording in progress would stop hearing about output
    /// changes and leave playback audible. Also re-checks the current output,
    /// since it may have come back reset while nothing was listening.
    func reestablishObserversAfterAudioServiceReset() {
        guard self.isSilencingForRecording || self.ownerships.isEmpty == false else { return }

        DebugLogger.shared.info(
            "SystemAudioMuteService: Re-registering listeners after an audio service restart",
            source: "SystemAudioMuteService"
        )

        self.outputController.stopObservingOutputDevices()
        for ownership in self.ownerships.values {
            self.outputController.stopObservingSilenceState(on: ownership.deviceID)
        }

        self.updateOutputDeviceObservation()
        for var ownership in self.ownerships.values {
            // Re-resolve every held device, not just the default output, or a
            // non-default one whose id changed across the restart would be
            // watched at an id that no longer refers to it.
            if let currentDeviceID = self.outputController.deviceID(forUID: ownership.deviceUID) {
                ownership.deviceID = currentDeviceID
            }

            // A restart can discard what we applied, the same way a reconnect
            // does, and the user has not touched anything. Treat every held
            // device as recreated so a state change is read as the system
            // resetting it rather than as their choice.
            ownership.hasBeenDisconnected = true
            self.takeRecord(ownership)
        }

        self.remainingRetryAttempts = Self.maxRetryAttempts
        self.handleOutputDevicesChanged()
    }

    /// Restores every device this service silenced.
    ///
    /// Safe to call on any teardown path, including ones where no recording ever
    /// silenced anything. A device that cannot be written to right now keeps its
    /// entry and is retried on the next call and at the start of the next
    /// recording.
    func restoreIfMuted() {
        self.isSilencingForRecording = false
        self.remainingRetryAttempts = Self.maxRetryAttempts
        self.restoreOwnedDevices()
        self.updateOutputDeviceObservation()
    }

    // MARK: - Observation

    /// Observation runs while a recording wants silence, and keeps running
    /// afterwards while any device is still owned, so one that was unplugged
    /// during teardown is restored as soon as it is plugged back in rather than
    /// waiting for the next recording.
    private func updateOutputDeviceObservation() {
        let shouldObserve = self.isSilencingForRecording || self.ownerships.isEmpty == false

        if shouldObserve {
            self.outputController.startObservingOutputDevices { [weak self] in
                self?.handleOutputDevicesChanged()
            }
        } else {
            self.outputController.stopObservingOutputDevices()
        }
    }

    private func handleOutputDevicesChanged() {
        DebugLogger.shared.debug(
            "SystemAudioMuteService: Output devices changed",
            source: "SystemAudioMuteService"
        )

        // A change of output is a fresh situation, so the new device gets its
        // own allowance rather than inheriting what an earlier one used up.
        self.remainingRetryAttempts = Self.maxRetryAttempts

        // Record which owned devices have gone away before reconciling, since
        // that is the evidence a later state change was a reconnect reset.
        self.markDisconnectedOwnedDevices()

        if self.isSilencingForRecording {
            // Everything owned is meant to stay silent, so only follow the new
            // output: connecting AirPods mid-recording makes a second device
            // audible, and it is kept alongside the first until the recording ends.
            self.silenceCurrentDefaultOutput()
        } else {
            // Idle, so anything still owned is a device that could not be handed
            // back earlier. It may have just been plugged in again.
            self.restoreOwnedDevices()
        }

        self.updateOutputDeviceObservation()
    }

    /// Releases a device the moment its mute or volume stops matching what we
    /// applied.
    ///
    /// Comparing only at teardown cannot see a round trip: a user who unmutes
    /// and mutes again leaves the device looking exactly as we left it, and
    /// undoing that would reverse their latest choice. Watching the device
    /// itself catches the first change and hands it back there and then.
    private func handleSilenceStateChanged(forDeviceUID deviceUID: String) {
        guard let ownership = self.ownerships[deviceUID] else { return }
        guard self.stillHoldsAppliedSilence(ownership) == false else { return }

        DebugLogger.shared.info(
            "SystemAudioMuteService: Device \(ownership.deviceID) was changed while held; releasing it",
            source: "SystemAudioMuteService"
        )
        self.releaseRecord(for: deviceUID)
    }

    /// Drops a record and stops watching the device it named.
    private func releaseRecord(for deviceUID: String) {
        guard let ownership = self.ownerships.removeValue(forKey: deviceUID) else { return }
        self.outputController.stopObservingSilenceState(on: ownership.deviceID)
    }

    /// Starts holding a device, watching it for changes made from elsewhere.
    private func takeRecord(_ ownership: Ownership) {
        self.releaseRecord(for: ownership.deviceUID)
        self.ownerships[ownership.deviceUID] = ownership
        self.outputController.startObservingSilenceState(on: ownership.deviceID) { [weak self] in
            self?.handleSilenceStateChanged(forDeviceUID: ownership.deviceUID)
        }
    }

    private func markDisconnectedOwnedDevices() {
        for deviceUID in Array(self.ownerships.keys)
            where self.outputController.deviceID(forUID: deviceUID) == nil
        {
            self.ownerships[deviceUID]?.hasBeenDisconnected = true
        }
    }

    /// Device notifications do not fire when a property merely becomes readable
    /// or writable again, so a device that was busy needs its own nudge, whether
    /// it is refusing to be silenced or refusing to be handed back.
    ///
    /// A bounded number of delayed attempts rather than a poll: hardware that is
    /// initialising settles quickly, and anything still refusing after that is
    /// left to the next output change or the next recording.
    private func scheduleRetry() {
        guard self.hasScheduledRetry == false, self.remainingRetryAttempts > 0 else { return }
        guard self.isSilencingForRecording || self.ownerships.isEmpty == false else { return }

        self.hasScheduledRetry = true
        self.remainingRetryAttempts -= 1

        self.retryScheduler(Self.retryDelaySeconds) { [weak self] in
            guard let self else { return }
            self.hasScheduledRetry = false

            if self.isSilencingForRecording {
                self.silenceCurrentDefaultOutput()
            } else {
                self.restoreOwnedDevices()
                self.updateOutputDeviceObservation()
            }
        }
    }

    // MARK: - Silencing

    private func silenceCurrentDefaultOutput() {
        guard let deviceID = self.outputController.defaultOutputDeviceID() else {
            DebugLogger.shared.warning(
                "SystemAudioMuteService: No default output device; leaving audio unchanged",
                source: "SystemAudioMuteService"
            )
            return
        }

        // Silencing is a promise to put the device back, which needs a stable
        // identity. Without a UID the object id is all there is, and CoreAudio
        // can hand it to different hardware once the original goes away, so a
        // later restore could unmute or re-level a device we never touched.
        guard let deviceUID = self.outputController.deviceUID(for: deviceID), deviceUID.isEmpty == false else {
            DebugLogger.shared.warning(
                "SystemAudioMuteService: Default output publishes no readable UID; leaving audio unchanged",
                source: "SystemAudioMuteService"
            )
            // A device that has only just appeared may not answer for its UID
            // yet, and that becoming readable raises no notification, so this is
            // worth another look rather than being taken as permanent.
            self.scheduleRetry()
            return
        }

        if let owned = self.ownerships[deviceUID] {
            self.reconcileOwnedDevice(owned, currentDeviceID: deviceID)
            return
        }

        guard let intervention = self.applySilence(on: deviceID) else { return }
        self.takeRecord(Ownership(
            deviceUID: deviceUID,
            deviceID: deviceID,
            intervention: intervention,
            hasBeenDisconnected: false
        ))
    }

    /// Decides what to do about a device we already hold that is the default again.
    ///
    /// The device is ours only while it still holds exactly what we applied.
    /// When it does not, the question is who changed it, and the answer is
    /// whether the device has been away: one that reconnected came back reset
    /// and is silenced again, while one that never left was changed by the user
    /// and that choice stands.
    private func reconcileOwnedDevice(_ ownership: Ownership, currentDeviceID: AudioObjectID) {
        // Either signal is proof on its own. A different object id means the
        // device was certainly recreated. Having been seen absent covers the
        // reconnect that came back under the same id.
        let wasRecreated = ownership.hasBeenDisconnected || ownership.deviceID != currentDeviceID

        var located = ownership
        located.deviceID = currentDeviceID

        switch self.stillHoldsAppliedSilence(located) {
        case .none:
            // Back but not answering yet. Keep it and look again shortly rather
            // than guess at what it is doing.
            self.takeRecord(located)
            self.scheduleRetry()

        case .some(true):
            located.hasBeenDisconnected = false
            self.takeRecord(located)

        case .some(false):
            guard wasRecreated else {
                DebugLogger.shared.info(
                    """
                    SystemAudioMuteService: User changed device \(currentDeviceID) during the \
                    recording; releasing it
                    """,
                    source: "SystemAudioMuteService"
                )
                self.releaseRecord(for: located.deviceUID)
                return
            }

            // Reaching here means the device does not hold what we applied, so
            // nothing of ours is in effect on it and the old record describes an
            // instance that is gone. Release it either way: keeping it would let
            // teardown mistake a silence the user creates later for our own and
            // undo it. Silencing again captures the value this device actually
            // has now.
            self.releaseRecord(for: located.deviceUID)

            guard let intervention = self.applySilence(on: currentDeviceID) else { return }

            self.takeRecord(Ownership(
                deviceUID: located.deviceUID,
                deviceID: currentDeviceID,
                intervention: intervention,
                hasBeenDisconnected: false
            ))
        }
    }

    /// Silences one device.
    ///
    /// - Returns: the intervention to undo later, or `nil` when the device is
    ///   not ours to hold: already silent, unreadable, or refusing the write. A
    ///   retry is scheduled for the last two, since both can be temporary.
    private func applySilence(on deviceID: AudioObjectID) -> Intervention? {
        self.outputController.supportsMute(on: deviceID)
            ? self.silenceUsingMuteSwitch(on: deviceID)
            : self.silenceUsingVolume(on: deviceID)
    }

    private func silenceUsingMuteSwitch(on deviceID: AudioObjectID) -> Intervention? {
        guard let isMuted = self.outputController.isMuted(on: deviceID) else {
            DebugLogger.shared.warning(
                "SystemAudioMuteService: Device \(deviceID) is not readable yet; will retry",
                source: "SystemAudioMuteService"
            )
            self.scheduleRetry()
            return nil
        }

        guard isMuted == false else {
            DebugLogger.shared.debug(
                "SystemAudioMuteService: Output already muted by the user, not taking it",
                source: "SystemAudioMuteService"
            )
            return nil
        }

        guard self.outputController.setMuted(true, on: deviceID) else {
            DebugLogger.shared.error(
                "SystemAudioMuteService: Device \(deviceID) rejected the mute; will retry",
                source: "SystemAudioMuteService"
            )
            self.scheduleRetry()
            return nil
        }

        DebugLogger.shared.info(
            "SystemAudioMuteService: Muted device \(deviceID) for recording",
            source: "SystemAudioMuteService"
        )
        return .muteSwitch
    }

    /// Fallback for outputs with no mute switch, which is common for USB and
    /// HDMI devices. The exact previous volume is restored afterwards.
    private func silenceUsingVolume(on deviceID: AudioObjectID) -> Intervention? {
        guard let volume = self.outputController.volume(on: deviceID) else {
            DebugLogger.shared.warning(
                "SystemAudioMuteService: Device \(deviceID) exposes neither mute nor volume; will retry",
                source: "SystemAudioMuteService"
            )
            self.scheduleRetry()
            return nil
        }

        guard volume > Self.silentVolumeThreshold else {
            DebugLogger.shared.debug(
                "SystemAudioMuteService: Output already silent, not taking it",
                source: "SystemAudioMuteService"
            )
            return nil
        }

        guard self.outputController.setVolume(0, on: deviceID) else {
            DebugLogger.shared.error(
                "SystemAudioMuteService: Device \(deviceID) rejected the volume change; will retry",
                source: "SystemAudioMuteService"
            )
            self.scheduleRetry()
            return nil
        }

        DebugLogger.shared.info(
            "SystemAudioMuteService: Zeroed volume on device \(deviceID) for recording (was \(volume))",
            source: "SystemAudioMuteService"
        )
        return .zeroedVolume(previousVolume: volume)
    }

    /// Whether the device still holds exactly what this service applied to it.
    ///
    /// `nil` when it cannot be read, which is indeterminate rather than an
    /// answer, so the caller waits instead of acting on it.
    private func stillHoldsAppliedSilence(_ ownership: Ownership) -> Bool? {
        switch ownership.intervention {
        case .muteSwitch:
            return self.outputController.isMuted(on: ownership.deviceID)
        case .zeroedVolume:
            return self.outputController.volume(on: ownership.deviceID).map { $0 <= Self.silentVolumeThreshold }
        }
    }

    // MARK: - Restoring

    /// Hands back every device this service holds, keeping the ones whose write
    /// fails so the next teardown, or the next recording, retries them.
    private func restoreOwnedDevices() {
        for deviceUID in Array(self.ownerships.keys) {
            guard let ownership = self.ownerships[deviceUID] else { continue }
            if self.releaseOwnership(of: ownership) {
                self.releaseRecord(for: deviceUID)
            }
        }
    }

    /// Hands one device back.
    ///
    /// - Returns: `true` when the record can be dropped, either because the
    ///   device was restored or because the user has already taken it over.
    ///   `false` keeps it so the next teardown retries, which matters when a
    ///   device is briefly unreachable while it is being unplugged.
    private func releaseOwnership(of ownership: Ownership) -> Bool {
        guard let deviceID = self.outputController.deviceID(forUID: ownership.deviceUID) else {
            DebugLogger.shared.info(
                "SystemAudioMuteService: Device \(ownership.deviceUID) is disconnected; keeping it until it returns",
                source: "SystemAudioMuteService"
            )
            return false
        }

        var located = ownership
        located.deviceID = deviceID

        // A device that came back under a new id leaves the record, and the
        // listener watching it, pointing at the old one. Move both before doing
        // anything else, or a change the user makes on the device that is
        // actually there would go unseen.
        if located.deviceID != ownership.deviceID {
            self.takeRecord(located)
        }

        switch self.stillHoldsAppliedSilence(located) {
        case .none:
            DebugLogger.shared.warning(
                "SystemAudioMuteService: Device \(deviceID) unreadable; keeping it to retry",
                source: "SystemAudioMuteService"
            )
            // Becoming readable raises no notification, so this needs the same
            // nudge a refused write gets.
            self.scheduleRetry()
            return false

        case .some(false):
            // Changed since we applied it, so the newer state is someone else's
            // and undoing it would override them.
            DebugLogger.shared.info(
                "SystemAudioMuteService: Device \(deviceID) was changed since we silenced it; leaving it alone",
                source: "SystemAudioMuteService"
            )
            return true

        case .some(true):
            switch located.intervention {
            case .muteSwitch:
                return self.reportRestore(
                    succeeded: self.outputController.setMuted(false, on: deviceID),
                    description: "unmuted device \(deviceID)"
                )
            case let .zeroedVolume(previousVolume):
                return self.reportRestore(
                    succeeded: self.outputController.setVolume(previousVolume, on: deviceID),
                    description: "restored volume \(previousVolume) on device \(deviceID)"
                )
            }
        }
    }

    private func reportRestore(succeeded: Bool, description: String) -> Bool {
        if succeeded {
            DebugLogger.shared.info(
                "SystemAudioMuteService: Restored audio after recording (\(description))",
                source: "SystemAudioMuteService"
            )
        } else {
            DebugLogger.shared.error(
                "SystemAudioMuteService: Failed to restore audio, will retry (\(description))",
                source: "SystemAudioMuteService"
            )
            self.scheduleRetry()
        }
        return succeeded
    }
}

@MainActor
final class CoreAudioOutputController: SystemAudioOutputControlling {
    private var outputDeviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var silenceStateListeners: [AudioObjectID: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)]] = [:]

    func defaultOutputDeviceID() -> AudioObjectID? {
        var address = Self.defaultOutputDeviceAddress
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    func deviceUID(for deviceID: AudioObjectID) -> String? {
        var address = Self.deviceUIDAddress
        // CoreAudio hands back a +1 retained CFString, so take ownership of it.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    func deviceID(forUID deviceUID: String) -> AudioObjectID? {
        AudioDevice.listOutputDevices().first { $0.uid == deviceUID }?.id
    }

    func supportsMute(on deviceID: AudioObjectID) -> Bool {
        var address = Self.muteAddress
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var isSettable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)
        return status == noErr && isSettable.boolValue
    }

    func isMuted(on deviceID: AudioObjectID) -> Bool? {
        var address = Self.muteAddress
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
        guard status == noErr else { return nil }
        return muted != 0
    }

    @discardableResult
    func setMuted(_ muted: Bool, on deviceID: AudioObjectID) -> Bool {
        var address = Self.muteAddress
        var value = UInt32(muted ? 1 : 0)
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
        guard status == noErr else {
            DebugLogger.shared.error(
                "CoreAudioOutputController: Failed to set mute: OSStatus \(status)",
                source: "SystemAudioMuteService"
            )
            return false
        }
        return true
    }

    func volume(on deviceID: AudioObjectID) -> Float? {
        var address = Self.volumeAddress
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else { return nil }
        return volume
    }

    @discardableResult
    func setVolume(_ volume: Float, on deviceID: AudioObjectID) -> Bool {
        var address = Self.volumeAddress
        var value = Float32(max(0, min(1, volume)))
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
        guard status == noErr else {
            DebugLogger.shared.error(
                "CoreAudioOutputController: Failed to set volume: OSStatus \(status)",
                source: "SystemAudioMuteService"
            )
            return false
        }
        return true
    }

    func startObservingOutputDevices(_ onChange: @escaping @MainActor () -> Void) {
        guard self.outputDeviceListeners.isEmpty else { return }

        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            // CoreAudio can hold an internal lock while delivering this callback,
            // and the handler queries CoreAudio synchronously. Defer to the next
            // run-loop pass so those queries cannot deadlock on the same lock.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onChange() }
            }
        }

        // The default output alone misses a device being plugged back in while
        // something else is already the default, so watch the device set too.
        for var address in [Self.defaultOutputDeviceAddress, Self.devicesAddress] {
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                listener
            )
            if status == noErr {
                self.outputDeviceListeners.append((address, listener))
            } else {
                DebugLogger.shared.error(
                    "CoreAudioOutputController: Failed to observe \(address.mSelector): OSStatus \(status)",
                    source: "SystemAudioMuteService"
                )
            }
        }
    }

    func startObservingSilenceState(on deviceID: AudioObjectID, _ onChange: @escaping @MainActor () -> Void) {
        guard self.silenceStateListeners[deviceID] == nil else { return }

        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            // CoreAudio can hold an internal lock while delivering this, and the
            // handler queries it, so defer to the next run-loop pass.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onChange() }
            }
        }

        // Either property can carry a change made from elsewhere, and which one
        // this device uses depends on whether it has a mute switch.
        var installed: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        for var address in [Self.muteAddress, Self.volumeAddress] {
            let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener)
            if status == noErr {
                installed.append((address, listener))
            }
        }

        guard installed.isEmpty == false else {
            DebugLogger.shared.warning(
                "CoreAudioOutputController: Could not observe device \(deviceID) for outside changes",
                source: "SystemAudioMuteService"
            )
            return
        }
        self.silenceStateListeners[deviceID] = installed
    }

    func stopObservingSilenceState(on deviceID: AudioObjectID) {
        guard let installed = self.silenceStateListeners.removeValue(forKey: deviceID) else { return }

        for (address, listener) in installed {
            var address = address
            _ = AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener)
        }
    }

    func stopObservingOutputDevices() {
        let listeners = self.outputDeviceListeners
        self.outputDeviceListeners.removeAll()

        for (address, listener) in listeners {
            var address = address
            let status = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                listener
            )
            if status != noErr {
                DebugLogger.shared.error(
                    "CoreAudioOutputController: Failed to stop observing \(address.mSelector): OSStatus \(status)",
                    source: "SystemAudioMuteService"
                )
            }
        }
    }

    // MARK: - Property Addresses

    private static let defaultOutputDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let deviceUIDAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
}
