import AudioToolbox
import Foundation

nonisolated enum MeetingAECOutputRouteDisposition: Equatable, Sendable {
    case physicallyClosed
    case supportedSpeaker
    case ambiguous
}

/// Stable output routes may attempt AEC regardless of transport. Admission still depends on real
/// PCM format/clock checks and warm-up; this classification alone never blesses processed audio.
nonisolated enum MeetingAECOutputRouteClassifier {
    static func classify(
        first: MeetingOutputRouteSnapshot,
        second: MeetingOutputRouteSnapshot,
        revisionStayedStable: Bool,
        debugDisabled: Bool = false
    ) -> MeetingAECOutputRouteDisposition {
        guard revisionStayedStable, first == second else { return .ambiguous }
        let route = second
        guard route.deviceExists else { return .ambiguous }
        // Acoustic closure is a property of the terminal, not its transport. Bluetooth alone is
        // ambiguous (it may be a room speaker), but a positively identified headphone terminal is
        // safe to admit without AEC.
        if (route.isBuiltIn && route.isHeadphonesDataSource)
            || route.terminalTypes.contains(kAudioStreamTerminalTypeHeadphones)
        {
            return .physicallyClosed
        }
        guard !debugDisabled else { return .ambiguous }
        return .supportedSpeaker
    }
}
