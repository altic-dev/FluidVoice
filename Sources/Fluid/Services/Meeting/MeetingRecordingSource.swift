import Foundation

/// A chosen application is separate from an automatic suggestion. A missing suggestion
/// must never change an online call into a microphone-only recording.
nonisolated enum MeetingRecordingSource: Equatable, Sendable {
    case automatic
    case application(bundleIdentifier: String, processID: Int32?, displayName: String)

    init(defaults: MeetingRecordingDefaults) {
        if defaults.isConfigured, let bundleIdentifier = defaults.applicationBundleIdentifier {
            self = .application(
                bundleIdentifier: bundleIdentifier,
                processID: nil,
                displayName: defaults.applicationDisplayName ?? bundleIdentifier
            )
        } else {
            self = .automatic
        }
    }

    init(application: MeetingApplicationIdentity) {
        self = .application(
            bundleIdentifier: application.bundleIdentifier,
            processID: application.processID,
            displayName: application.displayName
        )
    }
}

nonisolated enum MeetingRecordingSourceResolver {
    static func resolve(
        mode: MeetingCaptureMode,
        source: MeetingRecordingSource,
        target: MeetingAutoDetector.ResolvedTarget?,
        applications: [MeetingApplicationIdentity]
    ) throws -> MeetingApplicationIdentity? {
        guard mode == .onlineCall else { return nil }
        switch source {
        case .automatic:
            guard let target else { throw MeetingCaptureError.applicationNotSelected }
            guard var application = applications.first(where: {
                $0.bundleIdentifier == target.bundleIdentifier && $0.processID == target.pid && target.pid > 0
            }) else {
                throw MeetingCaptureError.applicationUnavailable(target.bundleIdentifier)
            }
            application.windowID = target.windowID
            return application
        case let .application(bundleIdentifier, processID, displayName):
            let matches = applications.filter {
                $0.bundleIdentifier == bundleIdentifier && ($0.processID ?? 0) > 0
                    && (processID == nil || $0.processID == processID)
            }
            // Two running copies of an app require an explicit process choice.
            guard matches.count == 1, let application = matches.first else {
                throw MeetingCaptureError.applicationUnavailable(displayName)
            }
            return application
        }
    }
}
