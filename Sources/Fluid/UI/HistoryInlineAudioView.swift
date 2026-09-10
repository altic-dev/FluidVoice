import AVFoundation
import SwiftUI

/// Playback belongs only to this visible history entry, never to dictation capture.
struct HistoryInlineAudioView: View {
    @Environment(\.theme) private var theme
    let entry: TranscriptionHistoryEntry
    @State private var player: AVPlayer?
    @State private var errorMessage: String?
    @State private var elapsed: Double = 0
    @State private var duration: Double = 0
    @State private var isPlaying = false
    @State private var isSeeking = false
    @State private var timeObserver: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recording").font(self.theme.typography.bodyStrong).foregroundStyle(.secondary)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let player {
                HStack(spacing: 12) {
                    Button {
                        if self.isPlaying {
                            player.pause()
                            self.isPlaying = false
                        } else {
                            if self.elapsed >= self.duration - 0.1 {
                                player.seek(to: .zero)
                                self.elapsed = 0
                            }
                            player.play()
                            self.isPlaying = true
                        }
                    } label: {
                        Image(systemName: self.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .fluidGlassAction(circular: true)
                    .accessibilityLabel(self.isPlaying ? "Pause recording" : "Play recording")
                    Text(Self.timeLabel(self.elapsed)).monospacedDigit().frame(width: 42)
                    Slider(value: self.$elapsed, in: 0...max(self.duration, 0.01)) { editing in
                        self.isSeeking = editing
                        if !editing {
                            player.seek(to: CMTime(seconds: self.elapsed, preferredTimescale: 600))
                        }
                    }
                    .tint(self.theme.palette.accent)
                    .accessibilityLabel("Recording position")
                    Text(Self.timeLabel(self.duration)).monospacedDigit().frame(width: 42)
                }
                .font(self.theme.typography.caption)
                .foregroundStyle(.secondary)
                .frame(minHeight: 40)
            } else {
                ProgressView("Loading recording…").controlSize(.small)
            }
        }
        .task(id: self.entry.id) {
            do {
                let entry = self.entry
                // Resolve the saved path off the main thread, only on an explicit Audio click.
                let url = await Task.detached(priority: .userInitiated) {
                    DictationAudioHistoryStore.shared.audioFileURL(for: entry)
                }.value
                try Task.checkCancellation()
                guard let url else { throw DictationAudioHistoryError.audioMissing }
                let asset = AVURLAsset(url: url)
                let deadline = Task {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    asset.cancelLoading()
                }
                defer { deadline.cancel() }
                let (playable, mediaDuration) = try await withTaskCancellationHandler {
                    try await asset.load(.isPlayable, .duration)
                } onCancel: {
                    asset.cancelLoading()
                }
                guard playable else { throw DictationAudioHistoryError.audioMissing }
                try Task.checkCancellation()
                guard mediaDuration.seconds.isFinite, mediaDuration.seconds > 0 else { throw DictationAudioHistoryError.audioMissing }
                self.duration = mediaDuration.seconds
                let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                self.player = player
                self.timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak player] time in
                    Task { @MainActor in
                        guard let player, self.player === player, !self.isSeeking, time.seconds.isFinite else { return }
                        self.elapsed = min(max(time.seconds, 0), self.duration)
                    }
                }
                player.play()
                self.isPlaying = true
            } catch {
                // Disappearance is silent; a load cancelled by the deadline is a visible failure.
                guard !Task.isCancelled else { return }
                self.errorMessage = "This recording could not be played. It may have been removed."
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let item = notification.object as? AVPlayerItem, item === self.player?.currentItem else { return }
            self.isPlaying = false
            self.elapsed = self.duration
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { notification in
            guard let item = notification.object as? AVPlayerItem, item === self.player?.currentItem else { return }
            self.player?.pause()
            self.isPlaying = false
            self.errorMessage = "This recording could not be played."
        }
        .onDisappear {
            self.player?.pause()
            if let timeObserver { self.player?.removeTimeObserver(timeObserver) }
            self.timeObserver = nil
            self.player?.replaceCurrentItem(with: nil)
            self.player = nil
            self.isPlaying = false
        }
    }

    private static func timeLabel(_ seconds: Double) -> String {
        let value = Int(max(seconds, 0))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
