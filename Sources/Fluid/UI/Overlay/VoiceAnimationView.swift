import SwiftUI

struct VoiceAnimationView: View {
    let style: OverlayVisualStyle
    let level: CGFloat
    let isProcessing: Bool
    let isActive: Bool
    let size: CGSize
    var previewLevel: CGFloat? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        OverlayVisualizerView(
            style: self.style,
            palette: OverlayColorTheme.aurora.palette,
            glow: .subtle,
            level: self.level,
            lifecycle: self.isProcessing ? .processing : .recording,
            isActive: self.isActive,
            reduceMotion: self.reduceMotion,
            noiseThreshold: CGFloat(SettingsStore.shared.visualizerNoiseThreshold),
            barCount: 9,
            barWidth: 3,
            barSpacing: 3,
            canvasSize: self.size,
            previewLevel: self.previewLevel
        )
    }
}
