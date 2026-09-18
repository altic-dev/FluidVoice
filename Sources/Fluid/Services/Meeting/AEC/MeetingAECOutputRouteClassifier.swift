import AudioToolbox
import Foundation

nonisolated enum MeetingAECOutputRouteDisposition: Equatable, Sendable {
    case physicallyClosed
    case supportedSpeaker
    case ambiguous
}

/// Positive route classifier for the direct SCK microphone path. Absence of headphone evidence is
/// never sufficient to infer a speaker; the initial deployment supports only built-in speakers.
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
        guard !route.isBluetooth else { return .ambiguous }
        guard !debugDisabled,
              route.isBuiltIn,
              !route.isHeadphonesDataSource,
              !route.terminalTypes.contains(kAudioStreamTerminalTypeHeadphones)
        else { return .ambiguous }
        return .supportedSpeaker
    }
}
