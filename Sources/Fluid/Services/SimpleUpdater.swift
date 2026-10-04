import AppKit
import Combine
import Foundation
import PromiseKit

enum SimpleUpdateError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case jsonDecoding
    case noSuitableRelease
    case noAsset
    case releaseChanged
    case updateAlreadyInProgress
    case downloadFailed
    case unzipFailed
    case notAnAppBundle
    case codesignMismatch
    case backupFailed
    case installedAppChanged
    case rollbackUnavailable
    case rollbackRestoreFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL."
        case .invalidResponse: return "Invalid HTTP response from GitHub."
        case .jsonDecoding: return "The data couldn’t be read because it isn’t in the correct format."
        case .noSuitableRelease: return "No suitable release found."
        case .releaseChanged: return "A different update is now available. Please review it before installing."
        case .noAsset: return "No matching asset found in the latest release."
        case .updateAlreadyInProgress: return "An update is already being installed."
        case .downloadFailed: return "Failed to download update."
        case .unzipFailed: return "Failed to extract the update archive."
        case .notAnAppBundle: return "Extracted content does not contain an app bundle."
        case .codesignMismatch: return "Downloaded app’s code signature does not match current app."
        case .backupFailed: return "The current app could not be backed up. Nothing was replaced."
        case .installedAppChanged: return "The installed app changed. Restart FluidVoice before trying the update again."
        case .rollbackUnavailable: return "No rollback backup is available."
        case .rollbackRestoreFailed: return "Failed to restore a previous version."
        }
    }
}

struct UpdateOperationGate {
    private(set) var isActive = false

    mutating func begin() -> Bool {
        guard !self.isActive else { return false }
        self.isActive = true
        return true
    }

    mutating func finish() {
        self.isActive = false
    }
}

struct GHRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let content_type: String
    }

    let tag_name: String
    let prerelease: Bool
    let assets: [Asset]
    let body: String?
    let name: String?
    let published_at: String?
    let html_url: URL?
}

private struct SemanticVersion: Comparable {
    enum Identifier: Equatable {
        case numeric(Int)
        case string(String)
    }

    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [Identifier]

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // Stable release has higher precedence than prerelease for same core version.
        if lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return false }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }

        let count = min(lhs.prerelease.count, rhs.prerelease.count)
        for index in 0..<count {
            let left = lhs.prerelease[index]
            let right = rhs.prerelease[index]
            if left == right { continue }

            switch (left, right) {
            case let (.numeric(a), .numeric(b)):
                return a < b
            case (.numeric, .string):
                return true
            case (.string, .numeric):
                return false
            case let (.string(a), .string(b)):
                return a < b
            }
        }

        // If all compared identifiers are equal, shorter prerelease has lower precedence.
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

@MainActor
final class SimpleUpdater: ObservableObject {
    struct ReleaseBuildOption {
        let version: String
        let url: URL
    }

    struct ReleaseNote: Codable, Hashable {
        let version: String
        let title: String
        let notes: String
        let publishedAt: Date?
        let url: URL?
        let isPrerelease: Bool
    }

    static let shared = SimpleUpdater()
    init(
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        promptPresenter: UpdatePromptPresenter = .shared
    ) {
        self.updateSession = session
        self.updateDefaults = defaults
        self.updatePrompts = promptPresenter
    }

    @Published private(set) var availableUpdateVersion: String?
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var isUpdateInProgress = false
    private let updateSession: URLSession
    private let updateDefaults: UserDefaults
    private let updatePrompts: UpdatePromptPresenter
    private var checkTask: Task<Void, Never>?
    private var checkID: UUID?
    private var checkIsExplicit = false
    private var checkChannelRevision: Int?
    private var availableChannelRevision: Int?
    #if DEBUG
    var simulationInstallHandler: (@MainActor () async throws -> Void)?
    var simulationHasUpdate = true
    #endif

    private var betaChannel: Bool {
        self.updateDefaults.bool(forKey: SettingsStore.UpdateKeys.betaReleasesEnabled)
    }

    private var channelRevision: Int {
        self.updateDefaults.integer(forKey: SettingsStore.UpdateKeys.channelPreferenceRevision)
    }

    private var popupRevision: Int {
        self.updateDefaults.integer(forKey: SettingsStore.UpdateKeys.popupPreferenceRevision)
    }

    private var popupsEnabled: Bool {
        self.updateDefaults.object(forKey: SettingsStore.UpdateKeys.showUpdatePopups) as? Bool ?? true
    }

    private let fileManager = FileManager.default
    private let maxRollbackBackups = 3
    private let rollbackBackupDirectoryName = "RollbackBackups"
    private var updateOperationGate = UpdateOperationGate()
    private var updateStatusWindow: NSWindow?

    private var installedAppName: String {
        return Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
    }

    private var currentAppVersion: String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    func hasRollbackBackup() -> Bool {
        return self.latestRollbackBackup() != nil
    }

    func latestRollbackVersion() -> String? {
        guard let latest = self.latestRollbackBackup() else { return nil }
        return self.versionString(for: latest)
    }

    func rollbackToLatestBackup() async throws {
        guard self.updateOperationGate.begin() else {
            throw SimpleUpdateError.updateAlreadyInProgress
        }

        self.isUpdateInProgress = true
        self.cancelUpdateCheck()
        self.availableUpdateVersion = nil
        self.availableChannelRevision = nil
        self.updatePrompts.dismissUpdateOffers()
        var shouldKeepOperationActive = false
        defer {
            if !shouldKeepOperationActive {
                self.resetUpdateOperation()
            }
        }

        guard let rollbackBundleURL = self.latestRollbackBackup() else {
            throw SimpleUpdateError.rollbackUnavailable
        }

        do {
            try await self.performSwapAndRelaunch(
                installedAppURL: Bundle.main.bundleURL,
                downloadedAppURL: rollbackBundleURL,
                expectedVersion: nil,
                isRollback: true
            )
            DebugLogger.shared.info(
                "SimpleUpdater: Rolled back to \(rollbackBundleURL.lastPathComponent)",
                source: "SimpleUpdater"
            )
            shouldKeepOperationActive = true
        } catch {
            throw SimpleUpdateError.rollbackRestoreFailed
        }
    }

    func fetchRecentReleaseBuildOptions(
        owner: String,
        repo: String,
        limit: Int = 3,
        includePrerelease: Bool = false
    ) async throws -> [ReleaseBuildOption] {
        let releases = try await self.fetchReleases(owner: owner, repo: repo)
        let count = max(1, limit)
        let candidates = self.sortedCandidateReleases(
            releases,
            includePrerelease: includePrerelease
        ).prefix(count)

        return candidates.map { entry in
            let release = entry.release
            let zipAsset = release.assets.first {
                $0.content_type == "application/zip" ||
                    $0.content_type == "application/x-zip-compressed" ||
                    $0.name.lowercased().hasSuffix(".zip")
            }
            let fallbackTagURL = URL(string: "https://github.com/\(owner)/\(repo)/releases/tag/\(release.tag_name)")
            let fallbackReleasesURL = URL(string: "https://github.com/\(owner)/\(repo)/releases")
            let url = zipAsset?.browser_download_url ??
                release.html_url ??
                fallbackTagURL ??
                fallbackReleasesURL ??
                URL(fileURLWithPath: "/")
            return ReleaseBuildOption(version: release.tag_name, url: url)
        }
    }

    func fetchRecentReleaseNotes(
        owner: String,
        repo: String,
        limit: Int = 6,
        includePrerelease: Bool = false
    ) async throws -> [ReleaseNote] {
        let releases = try await self.fetchReleases(owner: owner, repo: repo)
        let count = max(1, limit)

        return self.sortedCandidateReleases(
            releases,
            includePrerelease: includePrerelease
        )
        .prefix(count)
        .map { entry in
            let release = entry.release
            return ReleaseNote(
                version: release.tag_name,
                title: Self.nonEmpty(release.name) ?? release.tag_name,
                notes: Self.nonEmpty(release.body) ?? "No release notes available.",
                publishedAt: Self.parseGitHubDate(release.published_at),
                url: release.html_url,
                isPrerelease: release.prerelease
            )
        }
    }

    // Allowed Apple Developer Team IDs for code-sign validation
    // Restrict update transitions to FluidVoice's approved signing teams.
    private nonisolated static let allowedTeamIDs: Set<String> = [
        "V4J43B279J",
        "537RRRT57V",
    ]

    private static let githubDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let githubFractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func parseGitHubDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return self.githubDateFormatter.date(from: value) ??
            self.githubFractionalDateFormatter.date(from: value)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // Fetch latest release notes from GitHub
    func fetchLatestReleaseNotes(
        owner: String,
        repo: String,
        includePrerelease: Bool = false
    ) async throws -> (version: String, notes: String) {
        let releases = try await self.fetchReleases(owner: owner, repo: repo)

        guard let latest = self.selectLatestRelease(
            from: releases,
            includePrerelease: includePrerelease
        ) else {
            throw SimpleUpdateError.noSuitableRelease
        }

        let version = latest.tag_name
        let notes = latest.body ?? "No release notes available."

        return (version, notes)
    }

    // Silent check that returns update info without showing alerts or installing
    func checkForUpdate(
        owner: String,
        repo: String,
        includePrerelease: Bool = false
    ) async throws -> (hasUpdate: Bool, latestVersion: String) {
        guard !self.isUpdateInProgress else {
            throw SimpleUpdateError.updateAlreadyInProgress
        }

        #if DEBUG
        if self === Self.shared, UpdatePromptSimulation.isEnabled {
            return (self.simulationHasUpdate, "Simulation")
        }
        #endif

        let releases = try await self.fetchReleases(owner: owner, repo: repo)

        guard let latest = self.selectLatestRelease(
            from: releases,
            includePrerelease: includePrerelease
        ) else {
            throw SimpleUpdateError.noSuitableRelease
        }

        let currentVersionString = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let current = self.parseSemanticVersion(currentVersionString) ?? SemanticVersion(
            major: 0,
            minor: 0,
            patch: 0,
            prerelease: []
        )
        let latestTag = latest.tag_name
        guard let latestVersion = self.parseSemanticVersion(latestTag) else {
            throw SimpleUpdateError.noSuitableRelease
        }

        // Return whether update is available
        return (latestVersion > current, latestTag)
    }

    func checkForUpdatesAutomatically() {
        guard self.updateDefaults.object(forKey: SettingsStore.UpdateKeys.autoUpdateCheckEnabled) as? Bool ?? true else { return }
        self.startUpdateCheck(explicit: false)
    }

    func checkForUpdatesManually() {
        self.startUpdateCheck(explicit: true)
    }

    func showAvailableUpdate() {
        guard !self.isUpdateInProgress,
              let version = self.availableUpdateVersion,
              self.availableChannelRevision == self.channelRevision
        else { return }
        self.presentUpdateOffer(version: version, automatic: false)
    }

    func automaticUpdatePopupPreferenceDidChange(isEnabled _: Bool) {
        // The callback may arrive after another toggle. Read the current preference.
        if !self.popupsEnabled { self.updatePrompts.dismissAutomaticUpdateOffers() }
    }

    func updateChannelDidChange() {
        let revision = self.channelRevision
        if self.checkID != nil, self.checkChannelRevision != revision { self.cancelUpdateCheck() }
        if self.availableChannelRevision != revision {
            self.availableUpdateVersion = nil
            self.availableChannelRevision = nil
            self.updatePrompts.dismissUpdateOffers()
        }
    }

    private func startUpdateCheck(explicit: Bool) {
        guard !self.isUpdateInProgress else { return }
        if explicit { self.updatePrompts.dismissUpdateCheckResults() }
        self.updateChannelDidChange()
        if self.checkID != nil {
            self.checkIsExplicit = self.checkIsExplicit || explicit
            return
        }
        let requestID = UUID()
        let channel = self.betaChannel
        let channelRevision = self.channelRevision
        let popupRevision = self.popupRevision
        self.checkID = requestID
        self.checkChannelRevision = channelRevision
        self.checkIsExplicit = explicit
        self.isCheckingForUpdates = true
        self.checkTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.checkID == requestID { self.cancelUpdateCheck() }
            }
            do {
                let result = try await self.checkForUpdate(owner: "altic-dev", repo: "Fluid-oss", includePrerelease: channel)
                guard self.checkID == requestID, self.channelRevision == channelRevision, !self.isUpdateInProgress else { return }
                self.recordUpdateCheckDate()
                self.availableChannelRevision = channelRevision
                self.availableUpdateVersion = result.hasUpdate ? result.latestVersion : nil
                if result.hasUpdate {
                    if self.checkIsExplicit {
                        self.presentUpdateOffer(version: result.latestVersion, automatic: false)
                    } else if self.popupsEnabled, self.popupRevision == popupRevision,
                              self.updateDefaults.object(forKey: SettingsStore.UpdateKeys.autoUpdateCheckEnabled) as? Bool ?? true,
                              self.shouldShowUpdateOffer(version: result.latestVersion)
                    {
                        self.presentUpdateOffer(version: result.latestVersion, automatic: true)
                    }
                } else {
                    self.updatePrompts.dismissUpdateOffers()
                    if self.checkIsExplicit {
                        self.showUpdateCheckResult(title: channel ? "No Beta Updates" : "No Updates", message: "You're already running the latest available version of FluidVoice.")
                    }
                }
            } catch {
                guard self.checkID == requestID, self.channelRevision == channelRevision, !self.isUpdateInProgress else { return }
                self.recordUpdateCheckDate()
                self.availableUpdateVersion = nil
                self.availableChannelRevision = nil
                self.updatePrompts.dismissUpdateOffers()
                if self.checkIsExplicit {
                    self.showUpdateCheckResult(title: "Update Check Failed", message: "Unable to check for updates. Please try again later.\n\nError: \(error.localizedDescription)")
                } else {
                    DebugLogger.shared.debug("Automatic update check failed: \(error.localizedDescription)", source: "SimpleUpdater")
                }
            }
        }
    }

    private func recordUpdateCheckDate() {
        #if DEBUG
        if self === Self.shared, UpdatePromptSimulation.isEnabled { return }
        #endif
        self.updateDefaults.set(Date(), forKey: SettingsStore.UpdateKeys.lastUpdateCheckDate)
    }

    private func cancelUpdateCheck() {
        self.checkID = nil
        self.checkChannelRevision = nil
        self.checkTask?.cancel()
        self.checkTask = nil
        self.isCheckingForUpdates = false
        self.checkIsExplicit = false
    }

    private func shouldShowUpdateOffer(version: String) -> Bool {
        if let snoozed = self.updateDefaults.string(forKey: SettingsStore.UpdateKeys.snoozedUpdateVersion), snoozed != version { return true }
        guard let until = self.updateDefaults.object(forKey: SettingsStore.UpdateKeys.updatePromptSnoozedUntil) as? Date else { return true }
        return Date() >= until
    }

    private func presentUpdateOffer(version: String, automatic: Bool) {
        let channel = self.betaChannel
        let revision = self.channelRevision
        self.updatePrompts.presentFloatingPrompt(
            title: "Update Available",
            message: "FluidVoice \(version) is now available. The app will restart automatically after installation.",
            actions: [
                FloatingPromptAction(title: "Install Now") { [weak self] in
                    guard let self, self.availableUpdateVersion == version, self.channelRevision == revision, !self.isUpdateInProgress else { return }
                    self.installApprovedUpdate(version: version, channel: channel)
                },
                FloatingPromptAction(title: "Later") { [weak self] in
                    guard let self, self.availableUpdateVersion == version, self.channelRevision == revision else { return }
                    #if DEBUG
                    if self === Self.shared, UpdatePromptSimulation.isEnabled { return }
                    #endif
                    self.updateDefaults.set(version, forKey: SettingsStore.UpdateKeys.snoozedUpdateVersion)
                    self.updateDefaults.set(Date().addingTimeInterval(24 * 60 * 60), forKey: SettingsStore.UpdateKeys.updatePromptSnoozedUntil)
                },
            ],
            isAutomaticUpdateOffer: automatic
        )
    }

    private func installApprovedUpdate(version: String, channel: Bool) {
        Task {
            do {
                try await self.checkAndUpdate(owner: "altic-dev", repo: "Fluid-oss", includePrerelease: channel, expectedVersion: version)
            } catch SimpleUpdateError.releaseChanged {
                if self.availableUpdateVersion != nil, self.availableChannelRevision == self.channelRevision {
                    self.showAvailableUpdate()
                } else {
                    self.checkForUpdatesManually()
                }
            } catch SimpleUpdateError.updateAlreadyInProgress {
                return
            } catch {
                let cancelled = (error as? PMKError)?.isCancelled == true
                self.showUpdateCheckResult(
                    title: cancelled ? "No Updates" : "Update Failed",
                    message: cancelled ? "You're already running the latest available version of FluidVoice."
                        : "Unable to install the update. Please try again later.\n\nError: \(error.localizedDescription)"
                )
            }
        }
    }

    private func showUpdateCheckResult(title: String, message: String) {
        self.updatePrompts.presentFloatingPrompt(title: title, message: message, actions: [FloatingPromptAction(title: "OK") {}])
    }

    func checkAndUpdate(
        owner: String,
        repo: String,
        includePrerelease: Bool = false,
        expectedVersion: String? = nil
    ) async throws {
        guard self.updateOperationGate.begin() else {
            throw SimpleUpdateError.updateAlreadyInProgress
        }

        let approvedChannelRevision = self.channelRevision
        self.isUpdateInProgress = true
        self.cancelUpdateCheck()
        self.updatePrompts.dismissUpdateOffers()
        var shouldKeepOperationActive = false
        defer {
            if !shouldKeepOperationActive {
                self.resetUpdateOperation()
            }
        }

        #if DEBUG
        if self === Self.shared, UpdatePromptSimulation.isEnabled {
            self.showUpdateInstallStatus(version: "Simulation")
            shouldKeepOperationActive = true
            return
        }
        #endif

        let releases = try await self.fetchReleases(owner: owner, repo: repo)

        guard let latest = self.selectLatestRelease(
            from: releases,
            includePrerelease: includePrerelease
        ) else {
            throw SimpleUpdateError.noSuitableRelease
        }

        let currentVersionString = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let current = self.parseSemanticVersion(currentVersionString) ?? SemanticVersion(
            major: 0,
            minor: 0,
            patch: 0,
            prerelease: []
        )
        let latestTag = latest.tag_name
        guard let latestVersion = self.parseSemanticVersion(latestTag) else {
            throw SimpleUpdateError.noSuitableRelease
        }

        let currentBundle = Bundle.main
        // up to date
        if !(latestVersion > current) {
            self.availableUpdateVersion = nil
            self.availableChannelRevision = nil
            throw PMKError.cancelled // mimic AppUpdater semantics for up-to-date
        }

        if expectedVersion != nil, self.channelRevision != approvedChannelRevision {
            self.availableUpdateVersion = nil
            self.availableChannelRevision = nil
            throw SimpleUpdateError.releaseChanged
        }
        if let expectedVersion, expectedVersion != latestTag {
            self.availableChannelRevision = self.channelRevision
            self.availableUpdateVersion = latestTag
            throw SimpleUpdateError.releaseChanged
        }
        if expectedVersion != nil, self.betaChannel != includePrerelease {
            throw SimpleUpdateError.releaseChanged
        }
        self.updateDefaults.removeObject(forKey: SettingsStore.UpdateKeys.updatePromptSnoozedUntil)
        self.updateDefaults.removeObject(forKey: SettingsStore.UpdateKeys.snoozedUpdateVersion)
        #if DEBUG
        if let simulationInstallHandler {
            try await simulationInstallHandler()
            return
        }
        #endif

        // Find asset matching: "{repo-lower}-{version-from-tag}.*" and zip preferred
        let rawVersion = latestTag.hasPrefix("v") ? String(latestTag.dropFirst()) : latestTag
        let prefix = "\(repo.lowercased())-\(rawVersion)"
        let asset = latest.assets.first { asset in
            let base = (asset.name as NSString).deletingPathExtension.lowercased()
            return (base == prefix) &&
                (asset.content_type == "application/zip" || asset.content_type == "application/x-zip-compressed")
        } ?? latest.assets.first { asset in
            let base = (asset.name as NSString).deletingPathExtension.lowercased()
            return base == prefix
        }

        guard let asset = asset else { throw SimpleUpdateError.noAsset }

        self.showUpdateInstallStatus(version: rawVersion)

        let tempDir = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: Bundle.main.bundleURL,
            create: true
        )
        defer {
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: tempDir) }
        }
        let downloadURL = tempDir.appendingPathComponent(asset.browser_download_url.lastPathComponent)

        do {
            let (tmpFile, _) = try await URLSession.shared.download(from: asset.browser_download_url)
            try FileManager.default.moveItem(at: tmpFile, to: downloadURL)
        } catch {
            throw SimpleUpdateError.downloadFailed
        }

        // unzip
        let extractedBundleURL: URL
        do {
            extractedBundleURL = try await self.unzip(at: downloadURL)
        } catch {
            throw SimpleUpdateError.unzipFailed
        }

        guard extractedBundleURL.pathExtension == "app" else {
            throw SimpleUpdateError.notAnAppBundle
        }

        try await self.performSwapAndRelaunch(
            installedAppURL: currentBundle.bundleURL,
            downloadedAppURL: extractedBundleURL,
            expectedVersion: rawVersion,
            isRollback: false
        )
        shouldKeepOperationActive = true
    }

    // MARK: - Helpers

    func showUpdateInstallStatus(version: String) {
        self.updatePrompts.dismissAll()
        guard self.updateStatusWindow == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 132),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.title = "Installing FluidVoice \(version)"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 16
        content.layer?.masksToBounds = true
        content.autoresizingMask = [.width, .height]

        let icon = NSImageView(frame: NSRect(x: 22, y: 42, width: 52, height: 52))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(icon)

        let title = NSTextField(labelWithString: "Installing FluidVoice \(version)")
        title.frame = NSRect(x: 92, y: 76, width: 304, height: 24)
        title.font = .fluidSystemFont(ofSize: 16, weight: .semibold)
        content.addSubview(title)

        let detail = NSTextField(wrappingLabelWithString: "Downloading the update. FluidVoice will restart automatically.")
        detail.frame = NSRect(x: 92, y: 42, width: 304, height: 34)
        detail.font = .fluidSystemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        content.addSubview(detail)

        let progress = NSProgressIndicator(frame: NSRect(x: 92, y: 24, width: 304, height: 6))
        progress.style = .bar
        progress.isIndeterminate = true
        progress.controlSize = .small
        progress.startAnimation(nil)
        content.addSubview(progress)

        panel.contentView = content
        panel.center()
        panel.orderFrontRegardless()
        self.updateStatusWindow = panel
    }

    #if DEBUG
    func finishSimulatedUpdate() {
        guard UpdatePromptSimulation.isEnabled else { return }
        self.resetUpdateOperation()
    }
    #endif

    private func resetUpdateOperation() {
        self.updateOperationGate.finish()
        self.isUpdateInProgress = false
        self.dismissUpdateInstallStatus()
    }

    func dismissUpdateInstallStatus() {
        self.updateStatusWindow?.orderOut(nil)
        self.updateStatusWindow?.close()
        self.updateStatusWindow = nil
    }

    private func fetchReleases(owner: String, repo: String) async throws -> [GHRelease] {
        guard let releasesURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases") else {
            throw SimpleUpdateError.invalidURL
        }

        let (data, response) = try await self.updateSession.data(from: releasesURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SimpleUpdateError.invalidResponse
        }

        do {
            return try JSONDecoder().decode([GHRelease].self, from: data)
        } catch {
            throw SimpleUpdateError.jsonDecoding
        }
    }

    private func selectLatestRelease(from releases: [GHRelease], includePrerelease: Bool) -> GHRelease? {
        return self.sortedCandidateReleases(releases, includePrerelease: includePrerelease).first?.release
    }

    private func sortedCandidateReleases(
        _ releases: [GHRelease],
        includePrerelease: Bool
    ) -> [(release: GHRelease, version: SemanticVersion)] {
        return releases
            .compactMap { release in
                guard let version = self.parseSemanticVersion(release.tag_name) else {
                    return nil
                }
                let isPrerelease = self.isPrereleaseRelease(release)
                if !includePrerelease, isPrerelease {
                    return nil
                }
                return (release, version)
            }
            .sorted { lhs, rhs in
                if lhs.version != rhs.version {
                    return lhs.version > rhs.version
                }

                // Tie-break with publish date when tags map to same semantic version.
                let lhsPublished = lhs.release.published_at ?? ""
                let rhsPublished = rhs.release.published_at ?? ""
                return lhsPublished > rhsPublished
            }
    }

    private func isPrereleaseRelease(_ release: GHRelease) -> Bool {
        return release.prerelease || self.hasPrereleaseSuffix(in: release.tag_name)
    }

    private func hasPrereleaseSuffix(in version: String) -> Bool {
        var trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        if let plusIndex = trimmed.firstIndex(of: "+") {
            trimmed = String(trimmed[..<plusIndex])
        }

        guard let hyphenIndex = trimmed.firstIndex(of: "-") else {
            return false
        }

        let suffix = trimmed[trimmed.index(after: hyphenIndex)...]
        return suffix.isEmpty == false
    }

    private func rollbackRootDirectory() -> URL {
        let base = self.fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let support = base ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent("Fluid", isDirectory: true)
            .appendingPathComponent(self.rollbackBackupDirectoryName, isDirectory: true)
            .appendingPathComponent(self.installedAppName, isDirectory: true)
    }

    private func availableRollbackBackups() -> [URL] {
        let backupDir = self.rollbackRootDirectory()
        guard self.fileManager.fileExists(atPath: backupDir.path) else { return [] }

        let urls: [URL]
        do {
            urls = try self.fileManager.contentsOfDirectory(
                at: backupDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }

        return Self.sortedRollbackBackups(urls.filter { $0.pathExtension == "app" }) { url in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    }

    private func latestRollbackBackup() -> URL? {
        let currentVersion = self.currentAppVersion
        return self.availableRollbackBackups().first {
            Self.isRollbackVersion(self.versionString(for: $0), differentFrom: currentVersion)
        }
    }

    private func versionString(for appURL: URL) -> String? {
        guard let bundle = Bundle(url: appURL) else { return nil }
        return bundle.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private func sanitizeVersion(_ version: String) -> String {
        return version
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private func pruneRollbackBackups(preserving protectedURLs: Set<URL>) async {
        let root = self.rollbackRootDirectory()
        let limit = self.maxRollbackBackups
        let warnings = await Task.detached(priority: .utility) {
            let manager = FileManager.default
            guard let urls = try? manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return [String]() }
            let backups = Self.sortedRollbackBackups(urls.filter { $0.pathExtension == "app" }) {
                (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
            var retained = Set(backups.filter { protectedURLs.contains($0) })
            for backup in backups where retained.count < limit {
                retained.insert(backup)
            }
            var failures = [String]()
            for backup in backups where !retained.contains(backup) {
                do {
                    try manager.removeItem(at: backup)
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            return failures
        }.value
        for warning in warnings {
            DebugLogger.shared.warning("SimpleUpdater: Rollback cleanup failed: \(warning)", source: "SimpleUpdater")
        }
    }

    nonisolated static func sortedRollbackBackups(
        _ urls: [URL],
        modificationDate: (URL) -> Date?
    ) -> [URL] {
        return urls
            .compactMap { url -> (URL, Date)? in
                guard let createdAt = self.rollbackBackupCreationDate(
                    from: url,
                    fallbackModificationDate: modificationDate(url)
                ) else {
                    return nil
                }
                return (url, createdAt)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    static func isRollbackVersion(_ version: String?, differentFrom currentVersion: String) -> Bool {
        guard let version else { return false }
        return version != currentVersion
    }

    private nonisolated static func rollbackBackupCreationDate(
        from url: URL,
        fallbackModificationDate: Date?
    ) -> Date? {
        if let timestamp = self.rollbackBackupTimestamp(from: url) {
            return Date(timeIntervalSince1970: timestamp)
        }

        return fallbackModificationDate
    }

    private nonisolated static func rollbackBackupTimestamp(from url: URL) -> TimeInterval? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let suffix = name.split(separator: "-").last,
              let timestamp = TimeInterval(suffix)
        else {
            return nil
        }

        return timestamp
    }

    private func parseSemanticVersion(_ version: String) -> SemanticVersion? {
        var trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }

        // Ignore build metadata for precedence.
        if let plusIndex = trimmed.firstIndex(of: "+") {
            trimmed = String(trimmed[..<plusIndex])
        }

        let components = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard !components.isEmpty else { return nil }

        let coreComponents = components[0].split(separator: ".", omittingEmptySubsequences: false)
        guard coreComponents.count >= 2 else { return nil }
        guard let major = Int(coreComponents[0]), let minor = Int(coreComponents[1]) else { return nil }
        let patch: Int
        if coreComponents.count >= 3 {
            guard let parsedPatch = Int(coreComponents[2]) else { return nil }
            patch = parsedPatch
        } else {
            patch = 0
        }

        let prereleaseIdentifiers: [SemanticVersion.Identifier]
        if components.count > 1 {
            prereleaseIdentifiers = components[1]
                .split(separator: ".", omittingEmptySubsequences: false)
                .map { identifier in
                    if let numeric = Int(identifier) {
                        return .numeric(numeric)
                    }
                    return .string(identifier.lowercased())
                }
        } else {
            prereleaseIdentifiers = []
        }

        return SemanticVersion(
            major: major,
            minor: minor,
            patch: patch,
            prerelease: prereleaseIdentifiers
        )
    }

    private func unzip(at url: URL) async throws -> URL {
        let workDir = url.deletingLastPathComponent()
        let proc = Process()
        proc.currentDirectoryURL = workDir
        proc.launchPath = "/usr/bin/unzip"
        proc.arguments = [url.path]

        return try await withCheckedThrowingContinuation { cont in
            proc.terminationHandler = { _ in
                // Find first .app in workDir
                if let appURL = try? FileManager.default.contentsOfDirectory(
                    at: workDir,
                    includingPropertiesForKeys: [
                        .isDirectoryKey,
                    ],
                    options: [.skipsSubdirectoryDescendants]
                )
                .first(where: { $0.pathExtension == "app"
                }) {
                    cont.resume(returning: appURL)
                } else {
                    cont.resume(throwing: SimpleUpdateError.unzipFailed)
                }
            }
            do { try proc.run() } catch { cont.resume(throwing: error) }
        }
    }

    nonisolated struct PreparedInstallation: Sendable {
        let replacement: UpdateAppReplacement
        let backupURL: URL
    }

    /// Runs under the replacement's process-shared lock on a background task.
    nonisolated static func prepareValidatedInstallation(
        installedAppURL: URL,
        downloadedAppURL: URL,
        installedExpectation: UpdateBundleValidator.Expectation,
        expectedVersion: String?,
        backupURL: URL,
        isRollback: Bool
    ) throws -> PreparedInstallation {
        let teams = Self.allowedTeamIDs
        guard isRollback || expectedVersion != nil, installedExpectation.version != nil, installedExpectation.build != nil
        else { throw UpdateBundleValidator.ValidationError.invalidExpectation }
        try Task.checkCancellation()
        let replacement = try UpdateAppReplacement.prepare(
            installedAppURL: installedAppURL,
            replacementAppURL: downloadedAppURL,
            validateInstalledApp: { url in
                do {
                    _ = try UpdateBundleValidator.validate(
                        at: url,
                        expectation: installedExpectation,
                        policy: .installedApp(allowedTeamIDs: teams)
                    )
                } catch UpdateBundleValidator.ValidationError.versionMismatch {
                    throw SimpleUpdateError.installedAppChanged
                } catch UpdateBundleValidator.ValidationError.buildMismatch {
                    throw SimpleUpdateError.installedAppChanged
                }
            }
        )
        var backupCreated = false
        do {
            try Task.checkCancellation()
            _ = try UpdateBundleValidator.validate(
                at: replacement.stagedAppURL,
                expectation: .init(bundleIdentifier: installedExpectation.bundleIdentifier, version: expectedVersion),
                policy: isRollback ? .installedApp(allowedTeamIDs: teams) : .developerID(allowedTeamIDs: teams)
            )
            do {
                try UpdateRollbackBackup.create(installedAppURL: installedAppURL, backupURL: backupURL) { url in
                    _ = try UpdateBundleValidator.validate(
                        at: url,
                        expectation: installedExpectation,
                        policy: .installedApp(allowedTeamIDs: teams)
                    )
                }
                backupCreated = true
            } catch let failure as UpdateRollbackBackup.Failure where failure.retainedDirectoryURL != nil {
                throw failure
            } catch {
                throw SimpleUpdateError.backupFailed
            }
            try Task.checkCancellation()
            try replacement.commit()
            return PreparedInstallation(replacement: replacement, backupURL: backupURL)
        } catch {
            let originalError = error
            // A failed atomic exchange leaves the installed app untouched. The owned
            // duplicate backup is unnecessary until the exchange succeeds.
            var backupCleanupFailure: Error?
            if backupCreated {
                do {
                    try FileManager.default.removeItem(at: backupURL)
                } catch {
                    backupCleanupFailure = UpdateAppReplacement.Failure(
                        operation: .cleanup, recoveryDirectoryURL: backupURL, underlyingError: error
                    )
                }
            }
            do {
                try replacement.discardPrepared()
            } catch {
                throw error
            }
            if let backupCleanupFailure { throw backupCleanupFailure }
            throw originalError
        }
    }

    private func performSwapAndRelaunch(
        installedAppURL: URL,
        downloadedAppURL: URL,
        expectedVersion: String?,
        isRollback: Bool
    ) async throws {
        guard let identifier = Bundle.main.bundleIdentifier,
              let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        else { throw SimpleUpdateError.notAnAppBundle }
        let version = self.currentAppVersion
        let name = self.installedAppName
        let safeVersion = self.sanitizeVersion(version)
        let suffix = "\(isRollback ? "rollback-" : "")\(UUID().uuidString)-\(Int(Date().timeIntervalSince1970))"
        let backupURL = self.rollbackRootDirectory().appendingPathComponent("\(name)-\(safeVersion)-\(suffix).app")
        let preparation = Task.detached(priority: .utility) {
            try Self.prepareValidatedInstallation(
                installedAppURL: installedAppURL,
                downloadedAppURL: downloadedAppURL,
                installedExpectation: .init(bundleIdentifier: identifier, version: version, build: build),
                expectedVersion: expectedVersion,
                backupURL: backupURL,
                isRollback: isRollback
            )
        }
        let installation = try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: {
            preparation.cancel()
        }

        self.availableUpdateVersion = nil
        self.availableChannelRevision = nil
        self.dismissUpdateInstallStatus()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: installedAppURL, configuration: configuration) { application, error in
            Task { @MainActor in
                guard error == nil, let application else {
                    await self.recoverFailedRelaunch(installation, error: error)
                    return
                }
                // Keep the outgoing app and shared lock through the existing startup
                // grace period; a newly launched process must not start another swap.
                try? await Task.sleep(for: .seconds(2))
                guard !application.isTerminated else {
                    await self.recoverFailedRelaunch(installation, error: nil)
                    return
                }
                // Keep the shared lock while pruning so another process cannot
                // create a backup that this operation mistakes for an old one.
                var protected: Set<URL> = [installation.backupURL]
                if isRollback { protected.insert(downloadedAppURL) }
                await self.pruneRollbackBackups(preserving: protected)
                guard !application.isTerminated else {
                    await self.recoverFailedRelaunch(installation, error: nil)
                    return
                }
                let cleanupWarning = await Task.detached(priority: .utility) {
                    do {
                        try installation.replacement.finalize()
                        return String?.none
                    } catch {
                        return error.localizedDescription
                    }
                }.value
                if let cleanupWarning {
                    DebugLogger.shared.warning("SimpleUpdater: Update completed; cleanup failed: \(cleanupWarning)", source: "SimpleUpdater")
                }
                UpdateTerminationScheduler.requestTermination()
            }
        }
    }

    private func recoverFailedRelaunch(_ installation: PreparedInstallation, error: Error?) async {
        let recoveryWarning = await Task.detached(priority: .utility) {
            do {
                try installation.replacement.recover()
                return String?.none
            } catch {
                return error.localizedDescription
            }
        }.value
        self.resetUpdateOperation()
        if let error {
            DebugLogger.shared.error("SimpleUpdater: Relaunch failed: \(error.localizedDescription)", source: "SimpleUpdater")
        }
        if let recoveryWarning {
            DebugLogger.shared.error("SimpleUpdater: Recovery failed; saved app at \(installation.backupURL.path): \(recoveryWarning)", source: "SimpleUpdater")
        }
        self.showUpdateCheckResult(
            title: "Update Failed",
            message: recoveryWarning == nil
                ? "The new app could not start. Your previous version has been restored. Please try again."
                : "The app could not restart. Your previous version is saved at \(installation.backupURL.path)."
        )
    }
}
