import SwiftUI

/// A compact transport aligned with the transcript row's trailing audio action.
struct MeetingSegmentAudioPlayer: View {
    let playback: MeetingSegmentPlayback
    let isLoading: Bool
    @ObservedObject private var progress: MeetingPlaybackProgress
    @Environment(\.theme) private var theme
    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0

    init(playback: MeetingSegmentPlayback, isLoading: Bool) {
        self.playback = playback
        self.isLoading = isLoading
        self.progress = playback.progress
    }

    var body: some View {
        VStack(spacing: self.theme.metrics.spacing.sm) {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                FluidGlassControlGroup {
                    HStack(spacing: self.theme.metrics.spacing.sm) {
                        self.action("Back 5 seconds", symbol: "gobackward.5") { self.playback.skip(by: -5) }
                        Button(action: self.playback.togglePause) {
                            Group {
                                if self.isLoading {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: self.progress.isPlaying ? "pause.fill" : "play.fill")
                                }
                            }
                            .frame(width: 16, height: 16)
                        }
                        .fluidGlassAction(circular: true)
                        .disabled(self.isLoading)
                        .accessibilityLabel(self.progress.isPlaying ? "Pause audio chunk" : "Play audio chunk")
                        self.action("Forward 5 seconds", symbol: "goforward.5") { self.playback.skip(by: 5) }
                    }
                }
                Spacer(minLength: self.theme.metrics.spacing.sm)
                Text(self.isLoading ? "Loading…" : "\(Self.time(self.isScrubbing ? self.scrubPosition : self.progress.elapsed)) / \(Self.time(self.progress.duration))")
                    .font(self.theme.typography.codeCaption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .monospacedDigit()
                    .fixedSize()
                    .accessibilityLabel("Playback time")
            }
            Slider(
                value: Binding(
                    get: { self.isScrubbing ? self.scrubPosition : self.progress.elapsed },
                    set: { value in
                        self.scrubPosition = value
                        // Keyboard and accessibility changes do not always begin a drag.
                        if !self.isScrubbing { self.playback.seek(to: value) }
                    }
                ),
                in: 0...max(self.progress.duration, 0.01),
                onEditingChanged: { editing in
                    if editing {
                        self.scrubPosition = self.progress.elapsed
                        self.isScrubbing = true
                    } else {
                        self.isScrubbing = false
                        self.playback.seek(to: self.scrubPosition)
                    }
                }
            )
            .tint(self.theme.palette.accent)
            .disabled(self.isLoading || self.progress.duration <= 0)
            .accessibilityLabel("Audio chunk position")
            .accessibilityValue(Self.time(self.isScrubbing ? self.scrubPosition : self.progress.elapsed))
        }
        .padding(.vertical, self.theme.metrics.spacing.sm)
        .frame(maxWidth: .infinity)
    }

    private func action(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .fluidGlassAction(circular: true)
            .disabled(self.isLoading)
            .help(title)
            .accessibilityLabel(title)
    }

    private static func time(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
