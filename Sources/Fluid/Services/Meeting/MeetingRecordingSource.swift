import Foundation

/// A chosen application is separate from an automatic suggestion. A missing suggestion
/// must never change an online call into a microphone-only recording.
nonisolated enum MeetingRecordingSource: Equatable, Sendable {
    case automatic
    case allInstances(bundleIdentifier: String, displayName: String)
    case application(bundleIdentifier: String, processID: Int32?, displayName: String)

    init(defaults: MeetingRecordingDefaults) {
        if defaults.isConfigured, let bundleIdentifier = defaults.applicationBundleIdentifier {
            self = .allInstances(
                bundleIdentifier: bundleIdentifier,
                displayName: defaults.applicationDisplayName ?? bundleIdentifier
            )
        } else {
            self = .automatic
        }
    }

    init(application: MeetingApplicationIdentity) {
        if application.capturesAllInstances == true {
            self = .allInstances(bundleIdentifier: application.bundleIdentifier, displayName: application.displayName)
            return
        }
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
        case let .allInstances(bundleIdentifier, displayName):
            guard !bundleIdentifier.isEmpty, let match = applications.first(where: {
                $0.bundleIdentifier == bundleIdentifier && (($0.processID ?? 0) > 0 || $0.capturesAllInstances == true)
            }) else { throw MeetingCaptureError.applicationUnavailable(displayName) }
            return self.applicationChoices(from: [match])[0]
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

    /// A small value snapshot for menus. Capture resolves the full process set again at start.
    static func applicationChoices(from applications: [MeetingApplicationIdentity]) -> [MeetingApplicationIdentity] {
        var seen = Set<String>()
        return applications.filter { !$0.bundleIdentifier.isEmpty && seen.insert($0.bundleIdentifier).inserted }.map {
            var app = $0
            app.processID = nil
            app.windowID = nil
            app.displayID = nil
            app.capturesAllInstances = true
            return app
        }
    }
}

nonisolated extension MeetingRecordingDefaults {
    /// Only explicit picker choices populate lastPicked. Suggestions never become defaults.
    func preferringLastPickedApplication(_ lastPicked: MeetingApplicationIdentity?) -> Self {
        var defaults = self
        // New recordings always include computer audio. Historical sessions retain their mode.
        if defaults.mode == .inRoom || defaults.mode == .systemAudio {
            defaults.mode = .systemAudio
            defaults.applicationBundleIdentifier = nil
            defaults.applicationDisplayName = nil
            return defaults
        }
        if let lastPicked, !lastPicked.bundleIdentifier.isEmpty {
            defaults.isConfigured = true
            defaults.applicationBundleIdentifier = lastPicked.bundleIdentifier
            defaults.applicationDisplayName = lastPicked.displayName
        }
        if !defaults.isConfigured || defaults.applicationBundleIdentifier == nil {
            defaults.mode = .systemAudio
        }
        return defaults
    }
}

extension Notification.Name {
    static let meetingRecordingSourceChoiceDidChange = Notification.Name("MeetingRecordingSourceChoiceDidChange")
}
