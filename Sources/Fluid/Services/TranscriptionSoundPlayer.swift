import AVFoundation
import CoreAudio
import Foundation

final class TranscriptionSoundPlayer {
    static let shared = TranscriptionSoundPlayer()

    private let playbackQueue = DispatchQueue(label: "app.fluidvoice.transcription-sounds", qos: .userInteractive)
    private var players: [String: AVAudioPlayer] = [:]
    /// What a cue changed on one output and what to put back.
    private struct PendingVolumeRestore {
        /// The user's volume, from before any cue lowered it.
        let original: Float
        /// What the most recent cue set it to. A restore only happens while the
        /// device still reads this, so a volume chosen since is not overwritten.
        /// Updated by each cue, since overlapping cues can ask for different
        /// levels and only the latest describes the device.
        var applied: Float
        /// Identifies this run of cues on the output. A delayed callback carries
        /// the generation it was scheduled for, so one left over from a finished
        /// run cannot act on a later one and undo a cue that is still playing.
        let generation: UInt64
    }

    /// Volumes lowered for a cue and still owed back, keyed by the output's UID.
    ///
    /// Per device, because overlapping cues can straddle an output change and
    /// each device has to get its own value back. By UID rather than object id,
    /// because an id can be reissued to different hardware once the original is
    /// unplugged.
    private var pendingVolumeRestores: [String: PendingVolumeRestore] = [:] {
        didSet { self.updateOutputDeviceObservation() }
    }

    private var outputDeviceListener: AudioObjectPropertyListenerBlock?

    /// Bounded re-attempts for a device that will not take the volume back, one
    /// count per output. A device becoming writable again raises no
    /// notification of its own.
    private static let maxRestoreRetries = 3
    private static let restoreRetryDelay: TimeInterval = 0.5
    private var restoreRetriesRemaining: [String: Int] = [:]
    private var nextPendingGeneration: UInt64 = 0

    private init() {}

    @MainActor
    func playStartSound() {
        let settings = SettingsStore.shared
        guard settings.enableTranscriptionSounds else { return }
        // Ask whether this recording is silencing the output rather than
        // reading the setting. The cue fires after the mute has been applied and
        // the setting can change in between, so live state is what decides
        // whether the cue could be heard. It has to be the state of the current
        // recording, not whether any device is still owed a restore, or a
        // leftover from an earlier session would suppress this cue too. The stop
        // cue is unaffected: the output is restored before it plays.
        guard SystemAudioMuteService.shared.isSilencingForRecording == false else { return }
        let selected = settings.transcriptionStartSound
        guard let soundName = selected.startSoundFileName else { return }
        self.play(
            soundName: soundName,
            desiredVolume: settings.transcriptionSoundVolume,
            independentVolume: settings.transcriptionSoundIndependentVolume
        )
    }

    func playStopSound() {
        let settings = SettingsStore.shared
        guard settings.enableTranscriptionSounds else { return }
        let selected = settings.transcriptionStartSound
        guard let soundName = selected.stopSoundFileName else { return }
        self.play(
            soundName: soundName,
            desiredVolume: settings.transcriptionSoundVolume,
            independentVolume: settings.transcriptionSoundIndependentVolume
        )
    }

    /// Preview a specific sound at the current volume setting (used in Settings UI).
    func playPreview(sound: SettingsStore.TranscriptionStartSound) {
        guard let soundName = sound.startSoundFileName else { return }
        let settings = SettingsStore.shared
        self.play(
            soundName: soundName,
            desiredVolume: settings.transcriptionSoundVolume,
            independentVolume: settings.transcriptionSoundIndependentVolume
        )
    }

    /// Preview current sound at a specific volume (used when slider is released).
    func playPreviewAtVolume(_ volume: Float) {
        let selected = SettingsStore.shared.transcriptionStartSound
        guard let soundName = selected.startSoundFileName else { return }
        self.play(
            soundName: soundName,
            desiredVolume: volume,
            independentVolume: SettingsStore.shared.transcriptionSoundIndependentVolume
        )
    }

    /// Hands the system volume back now rather than when the cue finishes.
    ///
    /// A cue played with independent volume lowers the system volume and
    /// schedules the original to be put back once it has finished. Anything
    /// about to take the volume over has to let that land first: otherwise it
    /// captures the lowered value as the one to restore later, and the deferred
    /// write arrives mid-way and undoes what it did.
    func finishPendingVolumeRestore() {
        self.playbackQueue.sync {
            for deviceUID in Array(self.pendingVolumeRestores.keys) {
                self.restorePendingVolume(forDeviceUID: deviceUID)
            }
        }
    }

    /// Puts one output's saved volume back.
    ///
    /// The UID is resolved to a current object id here rather than reused from
    /// when the cue started, because that id can since have been reissued to
    /// other hardware. The record is kept unless the write lands, so a device
    /// that is unplugged or briefly rejecting writes is retried by the next cue
    /// or recording start rather than left at the cue's volume.
    /// Watches the device list only while a volume is owed back, so an output
    /// that was unplugged before its cue finished is restored when it returns
    /// rather than waiting for the next cue or recording.
    private func updateOutputDeviceObservation() {
        if self.pendingVolumeRestores.isEmpty {
            guard let listener = self.outputDeviceListener else { return }
            self.outputDeviceListener = nil
            var address = Self.devicesAddress
            _ = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                self.playbackQueue,
                listener
            )
            return
        }

        guard self.outputDeviceListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Already delivered on the playback queue, but CoreAudio can hold an
            // internal lock during the callback and the handler queries it, so
            // hop rather than query inline.
            self?.playbackQueue.async {
                guard let self else { return }
                for deviceUID in Array(self.pendingVolumeRestores.keys) {
                    self.restorePendingVolume(forDeviceUID: deviceUID)
                }
            }
        }

        var address = Self.devicesAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            self.playbackQueue,
            listener
        )
        if status == noErr {
            self.outputDeviceListener = listener
        } else {
            DebugLogger.shared.error(
                "Failed to observe output devices for a pending cue volume: OSStatus \(status)",
                source: "TranscriptionSoundPlayer"
            )
        }
    }

    /// - Parameter generation: when given, the run of cues this call was
    ///   scheduled for. A callback left over from a finished run does nothing,
    ///   rather than handing back a volume a newer cue is still using.
    private func restorePendingVolume(forDeviceUID deviceUID: String, generation: UInt64? = nil) {
        guard let pending = self.pendingVolumeRestores[deviceUID] else { return }
        if let generation, pending.generation != generation {
            return
        }

        guard let deviceID = AudioDevice.listOutputDevices().first(where: { $0.uid == deviceUID })?.id else {
            DebugLogger.shared.debug(
                "Cue output is not connected; keeping its volume to restore later",
                source: "TranscriptionSoundPlayer"
            )
            return
        }

        // Only undo what is still there. A device that reconnected reset, or one
        // the user has since adjusted, is no longer at the cue level, and writing
        // the old value would override that newer choice.
        guard let currentVolume = Self.volume(on: deviceID) else {
            // Connected but not answering yet. Keep the value and look again,
            // since becoming readable raises no notification of its own.
            self.scheduleRestoreRetry(forDeviceUID: deviceUID, generation: pending.generation)
            return
        }
        guard abs(currentVolume - pending.applied) < 0.001 else {
            DebugLogger.shared.debug(
                "Cue output volume changed since the cue played; leaving it alone",
                source: "TranscriptionSoundPlayer"
            )
            self.pendingVolumeRestores.removeValue(forKey: deviceUID)
            self.restoreRetriesRemaining.removeValue(forKey: deviceUID)
            return
        }

        guard Self.setVolume(pending.original, on: deviceID) else {
            DebugLogger.shared.error(
                "Failed to restore the cue output's volume; keeping it to retry",
                source: "TranscriptionSoundPlayer"
            )
            self.scheduleRestoreRetry(forDeviceUID: deviceUID, generation: pending.generation)
            return
        }

        self.pendingVolumeRestores.removeValue(forKey: deviceUID)
        self.restoreRetriesRemaining.removeValue(forKey: deviceUID)
    }

    /// A device that is connected but momentarily refusing the write produces no
    /// notification when it recovers, so it needs its own nudge.
    private func scheduleRestoreRetry(forDeviceUID deviceUID: String, generation: UInt64) {
        let remaining = self.restoreRetriesRemaining[deviceUID] ?? Self.maxRestoreRetries
        guard remaining > 0 else { return }
        self.restoreRetriesRemaining[deviceUID] = remaining - 1

        self.playbackQueue.asyncAfter(deadline: .now() + Self.restoreRetryDelay) { [weak self] in
            self?.restorePendingVolume(forDeviceUID: deviceUID, generation: generation)
        }
    }

    private func play(
        soundName: String,
        desiredVolume: Float,
        independentVolume: Bool
    ) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        DebugLogger.shared.benchmark(
            "APP_BENCH",
            message: "sound_play_request sound=\(soundName)",
            source: "AppBenchmark"
        )

        guard let url = Bundle.main.url(forResource: soundName, withExtension: "m4a") else {
            DebugLogger.shared.error("Missing sound resource: \(soundName).m4a", source: "TranscriptionSoundPlayer")
            return
        }

        self.playbackQueue.async { [weak self] in
            self?.playOnPlaybackQueue(
                soundName: soundName,
                url: url,
                desiredVolume: desiredVolume,
                independentVolume: independentVolume,
                startedAt: startedAt
            )
        }
    }

    private func playOnPlaybackQueue(
        soundName: String,
        url: URL,
        desiredVolume: Float,
        independentVolume: Bool,
        startedAt: TimeInterval
    ) {
        // Resolve the output once and use it for every step. Reading, lowering
        // and later restoring must all target the same device, or a route change
        // between separate lookups would read one device's volume and write it
        // to another. Taking the volume over is also a promise to put it back on
        // the same hardware, which needs a UID: without one, play at the
        // requested volume instead of risking a device stranded at the cue level.
        let cueOutput = independentVolume
            ? AudioDevice.getDefaultOutputDevice().flatMap { $0.uid.isEmpty ? nil : $0 }
            : nil
        var loweredSystemVolume = false

        if let cueOutput, let currentVolume = Self.volume(on: cueOutput.id) {
            // Silent already, so there is nothing to hear.
            guard currentVolume > 0.001 else { return }

            // Record only what the device actually took. A rejected write leaves
            // it where it was, so claiming the new level would make the restore
            // read the device as changed by someone else and abandon the user's
            // volume rather than put it back.
            if Self.setVolume(desiredVolume, on: cueOutput.id) {
                loweredSystemVolume = true
                self.restoreRetriesRemaining[cueOutput.uid] = Self.maxRestoreRetries

                // Read back what the device settled on. Outputs that quantise
                // the scalar can land somewhere other than what was asked for,
                // and the restore compares against this, so it has to be the
                // device's own value rather than the requested one.
                let appliedVolume = Self.volume(on: cueOutput.id) ?? desiredVolume

                // The first cue on an output records the user's volume; later
                // ones only update the level the device is now at, so the value
                // handed back stays the one from before any of them played.
                if self.pendingVolumeRestores[cueOutput.uid] == nil {
                    self.nextPendingGeneration &+= 1
                    self.pendingVolumeRestores[cueOutput.uid] = PendingVolumeRestore(
                        original: currentVolume,
                        applied: appliedVolume,
                        generation: self.nextPendingGeneration
                    )
                } else {
                    self.pendingVolumeRestores[cueOutput.uid]?.applied = appliedVolume
                }
            } else {
                DebugLogger.shared.error(
                    "Cue output would not take the system volume; playing at the requested level instead",
                    source: "TranscriptionSoundPlayer"
                )
            }
        } else if cueOutput != nil {
            // A fixed-volume output, such as many HDMI and digital ones, exposes
            // no volume to take over. The cue still plays, at the level asked
            // for, rather than being suppressed.
            DebugLogger.shared.debug(
                "Cue output has no volume control; playing at the requested level",
                source: "TranscriptionSoundPlayer"
            )
        }

        do {
            let player: AVAudioPlayer
            if let existing = self.players[soundName] {
                player = existing
            } else {
                player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                self.players[soundName] = player
            }

            player.currentTime = 0
            if loweredSystemVolume {
                player.volume = 1.0
            } else {
                player.volume = desiredVolume
            }
            player.play()
            DebugLogger.shared.benchmark(
                "APP_BENCH",
                message: "sound_play_dispatched sound=\(soundName) elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded()))",
                source: "AppBenchmark"
            )

            // Restore system volume after the sound finishes
            if let cueOutput, let pending = self.pendingVolumeRestores[cueOutput.uid] {
                let duration = player.duration
                let deviceUID = cueOutput.uid
                let generation = pending.generation
                self.playbackQueue.asyncAfter(deadline: .now() + duration + 0.05) { [weak self] in
                    // Restores this cue's own output. Whichever cue on that
                    // device finishes first puts back the value from before any
                    // of them played, and the rest find nothing pending and
                    // stand down.
                    self?.restorePendingVolume(forDeviceUID: deviceUID, generation: generation)
                }
            }
        } catch {
            // Restore system volume on error
            if let cueOutput {
                self.restorePendingVolume(forDeviceUID: cueOutput.uid)
            }
            DebugLogger.shared.error(
                "Failed to play sound \(soundName).m4a: \(error.localizedDescription)",
                source: "TranscriptionSoundPlayer"
            )
        }
    }

    // MARK: - System Volume via CoreAudio

    private static func volume(on deviceID: AudioObjectID) -> Float? {
        var address = Self.volumeAddress
        var volume: Float32 = 1.0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else { return nil }
        return volume
    }

    @discardableResult
    private static func setVolume(_ volume: Float, on deviceID: AudioObjectID) -> Bool {
        var address = Self.volumeAddress
        var vol = Float32(max(0, min(1, volume)))
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &vol)
        guard status == noErr else {
            DebugLogger.shared.error("Failed to set system volume: OSStatus \(status)", source: "TranscriptionSoundPlayer")
            return false
        }
        return true
    }

    private static let devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
}
