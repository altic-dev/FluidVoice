import AVFoundation
import Foundation

@MainActor
final class OnboardingSoundPlayer {
    static let shared = OnboardingSoundPlayer()

    private var welcomePlayer: AVAudioPlayer?

    private init() {}

    func playWelcomeSound() {
        let settings = SettingsStore.shared
        guard settings.enableTranscriptionSounds, settings.transcriptionStartSound != .none else { return }
        guard let url = Bundle.main.url(forResource: "onboarding_welcome", withExtension: "m4a") else {
            DebugLogger.shared.error("Missing sound resource: onboarding_welcome.m4a", source: "OnboardingSoundPlayer")
            return
        }

        let volume = min(settings.transcriptionSoundVolume, 0.55)
        guard volume > 0.001 else { return }

        do {
            let player: AVAudioPlayer
            if let existing = self.welcomePlayer {
                player = existing
            } else {
                player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                self.welcomePlayer = player
            }

            player.currentTime = 0
            player.volume = volume
            player.play()
        } catch {
            DebugLogger.shared.error(
                "Failed to play onboarding welcome sound: \(error.localizedDescription)",
                source: "OnboardingSoundPlayer"
            )
        }
    }
}
