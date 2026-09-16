//
//  NotchStyleVisualizer.swift
//  Fluid
//
//  Bridges the notch presentation to the premium visual styles.
//

import Combine
import SwiftUI

/// Draws the selected overlay style inside the notch.
///
/// The notch has its own audio publisher and never feeds
/// `NotchContentState.bottomOverlayAudioLevel` (that value belongs to the
/// floating pill), so this small adapter subscribes to the publisher the notch
/// already receives. No second capture path is created: it is the same stream
/// `CompactNotchWaveformView` has always consumed.
///
/// The surface is always dark - the area around a hardware notch is black
/// whatever the system appearance is - so the styles keep their contrast.
struct NotchStyleVisualizer: View {
    let audioPublisher: AnyPublisher<CGFloat, Never>
    let canvasSize: CGSize

    @StateObject private var data: AudioVisualizationData
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var contentState = NotchContentState.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(audioPublisher: AnyPublisher<CGFloat, Never>, canvasSize: CGSize) {
        self.audioPublisher = audioPublisher
        self.canvasSize = canvasSize
        _data = StateObject(wrappedValue: AudioVisualizationData(audioLevelPublisher: audioPublisher))
    }

    var body: some View {
        OverlayVisualizerView(
            style: self.settings.overlayVisualStyle,
            palette: self.settings.overlayColorTheme.palette,
            glow: self.settings.overlayGlowIntensity,
            level: self.data.audioLevel,
            lifecycle: self.lifecycle,
            isActive: true,
            reduceMotion: self.reduceMotion,
            noiseThreshold: 0.05,
            barCount: Self.barCount(forWidth: self.canvasSize.width),
            barWidth: Self.barWidth,
            barSpacing: Self.barSpacing,
            canvasSize: self.canvasSize,
            surface: .dark,
            motion: self.settings.overlayMotionIntensity,
            companionVariant: self.settings.companionVariant,
            companionAccessories: self.settings.companionAccessories,
            hasTranscription: !self.contentState.cachedPreviewText.isEmpty
        )
        .frame(width: self.canvasSize.width, height: self.canvasSize.height)
        .background(
            NotchHaloRim(
                palette: self.settings.overlayColorTheme.palette,
                glow: self.settings.overlayGlowIntensity,
                level: self.data.audioLevel
            )
            .padding(.horizontal, -3)
            .padding(.bottom, -2)
        )
    }

    /// The notch is only on screen while a session runs, so it shows the
    /// recording styles and, once the microphone stops, the same processing ring
    /// the floating pill uses.
    private var lifecycle: OverlayLifecycleState {
        self.contentState.isProcessing ? .processing : .recording
    }

    /// Notch canvas the compact body reserves for the visualizer.
    static let canvasWidth: CGFloat = 48
    static let canvasHeight: CGFloat = 18
    /// Eight bars at this width and spacing stay inside the canvas above; a wider
    /// row would overflow the notch body.
    static let barCount = 8

    /// Bars that suit a canvas, so the compact row and the wider Ambient Glow
    /// body both read as a full row instead of a lonely cluster.
    static func barCount(forWidth width: CGFloat) -> Int {
        let fitted = Int((width / 4.5).rounded(.down))
        return min(max(fitted, 6), 16)
    }
    static let barWidth: CGFloat = 2.5
    static let barSpacing: CGFloat = 2.0

    /// Width the Wave style needs for the parameters above.
    static var waveRowWidth: CGFloat {
        CGFloat(Self.barCount) * Self.barWidth + CGFloat(max(Self.barCount - 1, 0)) * Self.barSpacing
    }
}
