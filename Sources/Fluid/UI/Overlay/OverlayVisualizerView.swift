//
//  OverlayVisualizerView.swift
//  Fluid
//
//  Dispatches the live level to the component that draws the selected style.
//

import SwiftUI

/// Renders the selected overlay style inside a fixed canvas.
///
/// The view is a pure consumer of state the dictation pipeline already owns: the
/// damped microphone level and the resolved lifecycle phase. It never starts
/// audio, never waits for the engine and never delays the pill.
struct OverlayVisualizerView: View {
    let style: OverlayVisualStyle
    let palette: OverlayPalette
    let glow: OverlayGlowIntensity
    let level: CGFloat
    let lifecycle: OverlayLifecycleState
    let isActive: Bool
    let reduceMotion: Bool
    let noiseThreshold: CGFloat
    let barCount: Int
    let barWidth: CGFloat
    let barSpacing: CGFloat
    let canvasSize: CGSize
    /// Resolved surface, so monochrome styles stay legible in Light mode.
    var surface: OverlaySurfaceStyle = .dark
    /// Seeded energy for offscreen previews and tests. Inert at runtime.
    var previewLevel: CGFloat? = nil
    /// Global movement budget, forwarded to the Aurora style.
    var motion: MotionIntensity = .normal
    /// Companion element (material/palette). Only read by the Companion style.
    var companionVariant: CompanionVariant = .standard
    /// Companion accessories. Only read by the Companion style.
    var companionAccessories: Set<CompanionAccessory> = []
    /// Whether a partial already exists. Feeds the Companion "typing" face.
    var hasTranscription: Bool = false

    var body: some View {
        Group {
            if self.style == .companion {
                // The Companion expresses the phase itself (listening, thinking,
                // completed, error), so it is drawn in every phase instead of
                // being replaced by the completion check or the processing ring.
                self.companionBody
                    .transition(.opacity)
            } else if self.lifecycle == .completed {
                OverlayCompletionCheck(glow: self.glow)
                    .frame(width: self.ringSide, height: self.ringSide)
                    .transition(.opacity)
            } else if self.lifecycle == .processing {
                OverlayProcessingRing(
                    palette: self.palette,
                    glow: self.glow,
                    isActive: self.isActive,
                    reduceMotion: self.reduceMotion,
                    isMonochrome: self.style == .minimal
                )
                .frame(width: self.ringSide, height: self.ringSide)
                .transition(.opacity)
            } else {
                self.styleBody
                    .transition(.opacity)
            }
        }
        .frame(width: self.canvasSize.width, height: self.canvasSize.height)
        .animation(self.reduceMotion ? nil : .easeInOut(duration: 0.22), value: self.lifecycle)
    }

    private var ringSide: CGFloat {
        max(self.canvasSize.height * 0.74, 12)
    }

    @ViewBuilder
    private var styleBody: some View {
        switch self.style {
        case .minimal:
            MinimalVisualizer(
                level: self.level,
                isActive: self.isActive,
                palette: self.palette,
                glow: self.glow,
                noiseThreshold: self.noiseThreshold,
                surface: self.surface,
                previewLevel: self.previewLevel
            )
        case .aurora:
            AuroraVisualizer(
                level: self.level,
                isActive: self.isActive,
                palette: self.palette,
                glow: self.glow,
                reduceMotion: self.reduceMotion,
                noiseThreshold: self.noiseThreshold,
                motion: self.motion,
                previewLevel: self.previewLevel
            )
        case .wave:
            WaveVisualizer(
                level: self.level,
                isActive: self.isActive,
                palette: self.palette,
                glow: self.glow,
                noiseThreshold: self.noiseThreshold,
                barCount: self.barCount,
                barWidth: self.barWidth,
                barSpacing: self.barSpacing,
                previewLevel: self.previewLevel
            )
        case .pulse:
            PulseVisualizer(
                level: self.level,
                isActive: self.isActive,
                palette: self.palette,
                glow: self.glow,
                noiseThreshold: self.noiseThreshold,
                reduceMotion: self.reduceMotion,
                previewLevel: self.previewLevel
            )
        case .companion:
            self.companionBody
        }
    }

    @ViewBuilder
    private var companionBody: some View {
        CompanionVisualizer(
            state: Self.companionState(for: self.lifecycle, hasTranscription: self.hasTranscription),
            variant: self.companionVariant,
            themePalette: self.palette,
            glow: self.glow,
            accessories: self.companionAccessories,
            level: self.level,
            isActive: self.isActive,
            reduceMotion: self.reduceMotion,
            motion: self.motion,
            // A seeded preview freezes the Companion's phase; at runtime it runs
            // from its own timeline.
            previewPhase: self.previewLevel == nil ? nil : 1.2
        )
    }

    /// Lifecycle to expression. The pipeline already publishes these phases, so
    /// the Companion needs no state of its own.
    static func companionState(
        for lifecycle: OverlayLifecycleState,
        hasTranscription: Bool
    ) -> CompanionState {
        switch lifecycle {
        case .hidden: return .idle
        case .recording: return hasTranscription ? .typing : .listening
        case .processing: return .thinking
        case .completed: return .completed
        case .error: return .error
        }
    }
}

/// Brief completion flash: a small white check inside a softly glowing disc.
///
/// It only appears on the success path, and the caller keeps the dwell bounded
/// and cancellable so it can never delay dictation or text delivery.
struct OverlayCompletionCheck: View {
    let glow: OverlayGlowIntensity

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle()
                    .fill(OverlayPalette.success)
                    .shadow(
                        color: OverlayPalette.success.opacity(0.5),
                        radius: 3.5 * CGFloat(self.glow.visualizerGlowScale)
                    )

                Image(systemName: "checkmark")
                    .font(.system(size: max(side * 0.54, 7), weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
