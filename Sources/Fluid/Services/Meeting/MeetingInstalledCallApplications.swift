import AppKit
import Foundation

nonisolated struct MeetingInstalledCallApplication: Sendable {
    let bundleIdentifier: String
    let displayName: String
    var isRunning = false
}

nonisolated struct MeetingAppPickerEntry: Identifiable, Sendable {
    let bundleIdentifier: String
    let displayName: String
    let application: MeetingApplicationIdentity?
    var isRunning = false

    var id: String { "\(self.bundleIdentifier)-\(self.application?.processID ?? 0)" }
    var unavailableLabel: String { "\(self.displayName) · \(self.isRunning ? "Not available" : "Not running")" }

    static func entries(
        applications: [MeetingApplicationIdentity],
        installed: [MeetingInstalledCallApplication]
    ) -> [Self] {
        var entries = applications.map {
            Self(bundleIdentifier: $0.bundleIdentifier, displayName: $0.displayName, application: $0, isRunning: true)
        }
        var availableBundles = Set(applications.map(\.bundleIdentifier))
        for app in installed where availableBundles.insert(app.bundleIdentifier).inserted {
            entries.append(Self(bundleIdentifier: app.bundleIdentifier, displayName: app.displayName, application: nil, isRunning: app.isRunning))
        }
        return entries
    }
}

nonisolated enum MeetingInstalledCallApplications {
    /// A bounded snapshot once per picker opening. No app or disk discovery runs in view rendering.
    static func snapshot() async -> [MeetingInstalledCallApplication] {
        await Task.detached(priority: .utility) {
            let workspace = NSWorkspace.shared
            let running = Set(workspace.runningApplications.compactMap(\.bundleIdentifier))
            return MeetingAppRegistry.commonPickerBundleIdentifiers.compactMap { bundle in
                guard let url = workspace.urlForApplication(withBundleIdentifier: bundle),
                      FileManager.default.fileExists(atPath: url.path)
                else { return nil }
                let info = Bundle(url: url)
                let name = (info?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (info?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                return MeetingInstalledCallApplication(bundleIdentifier: bundle, displayName: name, isRunning: running.contains(bundle))
            }
        }.value
    }
}
