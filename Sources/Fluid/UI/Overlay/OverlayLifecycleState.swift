//
//  OverlayLifecycleState.swift
//  Fluid
//
//  Overlay lifecycle derived from signals the dictation pipeline already publishes.
//

import Foundation

/// Visual phase of the floating overlay.
///
/// Every case maps onto a state the pipeline genuinely reports. Nothing here is
/// driven by an artificial timer, so the overlay can never claim to be
/// "processing" while the engine is idle, or "done" before text was injected.
enum OverlayLifecycleState: Equatable {
    /// No overlay on screen.
    case hidden
    /// The microphone is live and the visualizer tracks the real input level.
    case recording
    /// Capture stopped and the engine is still refining or delivering the text.
    case processing
    /// The existing error surface is showing; the accent turns warm red.
    case error
    /// The pipeline confirmed delivery and a short completion flash is playing.
    case completed

    /// Resolves the phase from the published overlay state.
    ///
    /// - Parameters:
    ///   - isPresented: the overlay panel is on screen.
    ///   - isReleaseTransitioning: the hotkey was released and the final pass is running.
    ///   - isProcessing: the pipeline reports AI or transcription post-processing.
    ///   - hasProcessingFailure: the existing AI failure surface is visible.
    ///   - isDeliveryCompleted: the pipeline confirmed the text was delivered.
    static func resolve(
        isPresented: Bool,
        isReleaseTransitioning: Bool,
        isProcessing: Bool,
        hasProcessingFailure: Bool,
        isDeliveryCompleted: Bool = false
    ) -> OverlayLifecycleState {
        guard isPresented else { return .hidden }
        if isDeliveryCompleted {
            return .completed
        }
        if hasProcessingFailure, !isProcessing {
            return .error
        }
        if isProcessing || isReleaseTransitioning {
            return .processing
        }
        return .recording
    }

    /// True while the audio-reactive visualizer should be drawn.
    var showsVisualizer: Bool {
        switch self {
        case .recording, .hidden: return true
        case .processing, .error, .completed: return false
        }
    }
}
