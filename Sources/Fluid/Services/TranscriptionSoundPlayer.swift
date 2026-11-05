import AVFoundation
import Foundation

final class TranscriptionSoundPlayer {
    static let shared = TranscriptionSoundPlayer()

    private let playbackQueue = DispatchQueue(label: "app.fluidvoice.transcription-sounds", qos: .userInteractive)
    private var players: [String: AVAudioPlayer] = [:]
    private var previewStop: DispatchWorkItem?

    private init() {}

    func playStartSound() {
        self.cancelPendingPreview()
        let settings = SettingsStore.shared
        guard settings.enableTranscriptionSounds else { return }
        let selected = settings.transcriptionStartSound
        guard let soundName = selected.startSoundFileName else { return }
        self.play(soundName: soundName, desiredVolume: settings.transcriptionSoundVolume)
    }

    func playStopSound() {
        self.cancelPendingPreview()
        let settings = SettingsStore.shared
        guard settings.enableTranscriptionSounds else { return }
        let selected = settings.transcriptionStartSound
        guard let soundName = selected.stopSoundFileName else { return }
        self.play(soundName: soundName, desiredVolume: settings.transcriptionSoundVolume)
    }

    /// Preview both cues, leaving enough time for the first sound to finish.
    func playPreview(sound: SettingsStore.TranscriptionStartSound) {
        let settings = SettingsStore.shared
        let volume = settings.transcriptionSoundVolume
        let startURL = sound.startSoundFileName.flatMap { Bundle.main.url(forResource: $0, withExtension: "m4a") }
        let stopURL = sound.stopSoundFileName.flatMap { Bundle.main.url(forResource: $0, withExtension: "m4a") }
        let startedAt = ProcessInfo.processInfo.systemUptime
        self.playbackQueue.async { [weak self] in
            guard let self else { return }
            self.previewStop?.cancel()
            self.previewStop = nil
            guard let name = sound.startSoundFileName, let startURL,
                  let duration = self.playOnPlaybackQueue(soundName: name, url: startURL, desiredVolume: volume, startedAt: startedAt),
                  let stopName = sound.stopSoundFileName, let stopURL else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.previewStop = nil
                _ = self.playOnPlaybackQueue(soundName: stopName, url: stopURL, desiredVolume: volume, startedAt: ProcessInfo.processInfo.systemUptime)
            }
            self.previewStop = work
            self.playbackQueue.asyncAfter(deadline: .now() + duration + 0.15, execute: work)
        }
    }

    /// Preview current sound at a specific volume (used when slider is released).
    func playPreviewAtVolume(_ volume: Float) {
        self.cancelPendingPreview()
        let selected = SettingsStore.shared.transcriptionStartSound
        guard let soundName = selected.startSoundFileName else { return }
        self.play(soundName: soundName, desiredVolume: volume)
    }

    private func cancelPendingPreview() {
        self.playbackQueue.async { [weak self] in
            self?.previewStop?.cancel()
            self?.previewStop = nil
        }
    }

    private func play(soundName: String, desiredVolume: Float) {
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
            self?.previewStop?.cancel()
            self?.previewStop = nil
            _ = self?.playOnPlaybackQueue(
                soundName: soundName,
                url: url,
                desiredVolume: desiredVolume,
                startedAt: startedAt
            )
        }
    }

    private func playOnPlaybackQueue(
        soundName: String,
        url: URL,
        desiredVolume: Float,
        startedAt: TimeInterval
    ) -> TimeInterval? {
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
            player.volume = desiredVolume
            player.play()
            DebugLogger.shared.benchmark(
                "APP_BENCH",
                message: "sound_play_dispatched sound=\(soundName) elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded()))",
                source: "AppBenchmark"
            )
            return player.duration
        } catch {
            DebugLogger.shared.error(
                "Failed to play sound \(soundName).m4a: \(error.localizedDescription)",
                source: "TranscriptionSoundPlayer"
            )
            return nil
        }
    }
}
