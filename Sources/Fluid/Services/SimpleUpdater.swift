import AppKit
import Foundation
import PromiseKit

enum SimpleUpdateError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case jsonDecoding
    case noSuitableRelease
    case noAsset
    case downloadFailed
    case unzipFailed
    case notAnAppBundle
    case codesignMismatch
    case rollbackUnavailable
    case rollbackRestoreFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL."
        case .invalidResponse: return "Invalid HTTP response from GitHub."
        case .jsonDecoding: return "The data couldn’t be read because it isn’t in the correct format."
        case .noSuitableRelease: return "No suitable release found."
        case .noAsset: return "No matching asset found in the latest release."
        case .downloadFailed: return "Failed to download update."
        case .unzipFailed: return "Failed to extract the update archive."
        case .notAnAppBundle: return "Extracted content does not contain an app bundle."
        case .codesignMismatch: return "Downloaded app’s code signature does not match current app."
        case .rollbackUnavailable: return "No rollback backup is available."
        case .rollbackRestoreFailed: return "Failed to restore a previous version."
        }
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
final class SimpleUpdater {
    struct ReleaseBuildOption {
        let version: String
        let url: URL
    }

    static let shared = SimpleUpdater()
    private init() {}

    private let fileManager = FileManager.default
    private let maxRollbackBackups = 3
    private let rollbackBackupDirectoryName = "RollbackBackups"

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
        guard let rollbackBundleURL = self.latestRollbackBackup() else {
            throw SimpleUpdateError.rollbackUnavailable
        }

        self.createRollbackBackup(beforeRollback: true)

        do {
            try self.performSwapAndRelaunch(
                installedAppURL: Bundle.main.bundleURL,
                downloadedAppURL: rollbackBundleURL
            )
            DebugLogger.shared.info(
                "SimpleUpdater: Rolled back to \(rollbackBundleURL.lastPathComponent)",
                source: "SimpleUpdater"
            )
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

    // Allowed Apple Developer Team IDs for code-sign validation
    // Configured per your request; restrict to your actual Team ID only.
    private let allowedTeamIDs: Set<String> = [
        "V4J43B279J",
    ]

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

    func checkAndUpdate(
        owner: String,
        repo: String,
        includePrerelease: Bool = false
    ) async throws {
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
            throw PMKError.cancelled // mimic AppUpdater semantics for up-to-date
        }

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

        let tempDir = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: Bundle.main.bundleURL,
            create: true
        )
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

        // Validate code signing identity matches (skip in DEBUG for easier local testing)
        #if DEBUG
        // In Debug builds the local app is typically signed with a development cert, while
        // releases are signed with Developer ID. Skip strict check to enable testing.
        _ = currentBundle // keep reference used in Release path
        #else
        let curID = try await codeSigningIdentity(for: currentBundle.bundleURL)
        let newID = try await codeSigningIdentity(for: extractedBundleURL)

        func teamID(from identity: String) -> String? {
            // Handle TeamIdentifier= format first
            if identity.hasPrefix("TeamIdentifier=") {
                return String(identity.dropFirst("TeamIdentifier=".count))
            }

            // Handle Authority= format (extract team ID from parentheses)
            guard let l = identity.lastIndex(of: "("), let r = identity.lastIndex(of: ")"), l < r else { return nil }
            let inside = identity[identity.index(after: l)..<r]
            return String(inside)
        }

        // Allow update if:
        // - full identity matches OR
        // - Team IDs match OR
        // - both current and new Team IDs are in the allowedTeamIDs set
        // This enables dev→prod updates across your two known Team IDs.
        let sameIdentity = curID == newID
        let curTeam = teamID(from: curID)
        let newTeam = teamID(from: newID)
        let sameTeam = (curTeam != nil && curTeam == newTeam)
        let bothAllowed: Bool = {
            guard let ct = curTeam, let nt = newTeam else { return false }
            return self.allowedTeamIDs.contains(ct) && self.allowedTeamIDs.contains(nt)
        }()

        guard sameIdentity || sameTeam || bothAllowed else {
            DebugLogger.shared.error("SimpleUpdater: Code-sign mismatch. Current=\(curID) New=\(newID)", source: "SimpleUpdater")
            DebugLogger.shared.error("SimpleUpdater: Current Team=\(curTeam ?? "none") New Team=\(newTeam ?? "none")", source: "SimpleUpdater")
            throw SimpleUpdateError.codesignMismatch
        }
        #endif

        self.createRollbackBackup(beforeRollback: false)

        // Replace and relaunch
        try self.performSwapAndRelaunch(installedAppURL: currentBundle.bundleURL, downloadedAppURL: extractedBundleURL)
    }

    // MARK: - Helpers

    private func fetchReleases(owner: String, repo: String) async throws -> [GHRelease] {
        guard let releasesURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases") else {
            throw SimpleUpdateError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: releasesURL)
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

    private func createRollbackBackup(beforeRollback: Bool) {
        let currentAppVersion = self.currentAppVersion
        let appURL = Bundle.main.bundleURL
        let backupRoot = self.rollbackRootDirectory()

        do {
            try self.fileManager.createDirectory(
                at: backupRoot,
                withIntermediateDirectories: true
            )
        } catch {
            DebugLogger.shared.warning("SimpleUpdater: Failed to create rollback backup folder: \(error.localizedDescription)", source: "SimpleUpdater")
            return
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let safeVersion = self.sanitizeVersion(currentAppVersion)
        let backupName = beforeRollback
            ? "\(self.installedAppName)-\(safeVersion)-rollback-\(timestamp).app"
            : "\(self.installedAppName)-\(safeVersion)-\(timestamp).app"
        let backupURL = backupRoot.appendingPathComponent(backupName)

        do {
            try self.fileManager.copyItem(at: appURL, to: backupURL)
            try? self.fileManager.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: backupURL.path
            )
            self.pruneRollbackBackups()
            DebugLogger.shared.info(
                "SimpleUpdater: Created rollback backup at \(backupURL.path)",
                source: "SimpleUpdater"
            )
        } catch {
            DebugLogger.shared.warning(
                "SimpleUpdater: Failed to create rollback backup: \(error.localizedDescription)",
                source: "SimpleUpdater"
            )
        }
    }

    private func pruneRollbackBackups() {
        let backups = self.availableRollbackBackups()
        guard backups.count > self.maxRollbackBackups else { return }

        for oldBackup in backups.dropFirst(self.maxRollbackBackups) {
            do {
                try self.fileManager.removeItem(at: oldBackup)
            } catch {
                DebugLogger.shared.warning(
                    "SimpleUpdater: Failed to remove old rollback backup \(oldBackup.lastPathComponent): \(error.localizedDescription)",
                    source: "SimpleUpdater"
                )
            }
        }
    }

    static func sortedRollbackBackups(
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

    private static func rollbackBackupCreationDate(
        from url: URL,
        fallbackModificationDate: Date?
    ) -> Date? {
        if let timestamp = self.rollbackBackupTimestamp(from: url) {
            return Date(timeIntervalSince1970: timestamp)
        }

        return fallbackModificationDate
    }

    private static func rollbackBackupTimestamp(from url: URL) -> TimeInterval? {
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

    private func codeSigningIdentity(for bundleURL: URL) async throws -> String {
        let proc = Process()
        proc.launchPath = "/usr/bin/codesign"
        proc.arguments = ["-dvvv", bundleURL.path]
        let pipe = Pipe()
        proc.standardError = pipe

        return try await withCheckedThrowingContinuation { cont in
            proc.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let s = String(data: data, encoding: .utf8) ?? ""

                // First try to get TeamIdentifier (most reliable)
                if let teamLine = s.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }) {
                    cont.resume(returning: String(teamLine))
                } else {
                    // Fallback to Authority line
                    let line = s.split(separator: "\n").first(where: { $0.hasPrefix("Authority=") })
                    cont.resume(returning: line.map(String.init) ?? "")
                }
            }
            do { try proc.run() } catch { cont.resume(throwing: error) }
        }
    }

    private func performSwapAndRelaunch(installedAppURL: URL, downloadedAppURL: URL) throws {
        // Handle app name changes: if the downloaded app has a different name,
        // we need to replace the old app and use the new name
        let installedAppName = installedAppURL.lastPathComponent
        let downloadedAppName = downloadedAppURL.lastPathComponent

        DebugLogger.shared.info("SimpleUpdater: Installing app - Current: \(installedAppName), New: \(downloadedAppName)", source: "SimpleUpdater")

        let finalAppURL: URL
        if installedAppName != downloadedAppName {
            // App name changed - use the new name
            finalAppURL = installedAppURL.deletingLastPathComponent().appendingPathComponent(downloadedAppName)
            DebugLogger.shared.info("SimpleUpdater: App name changed, installing to: \(finalAppURL.path)", source: "SimpleUpdater")

            // Safety check: ensure we don't overwrite an existing app with the new name
            if FileManager.default.fileExists(atPath: finalAppURL.path) {
                DebugLogger.shared.info("SimpleUpdater: Removing existing app at new location: \(finalAppURL.path)", source: "SimpleUpdater")
                try FileManager.default.removeItem(at: finalAppURL)
            }

            // Remove old app if it exists
            if FileManager.default.fileExists(atPath: installedAppURL.path) {
                DebugLogger.shared.info("SimpleUpdater: Removing old app: \(installedAppURL.path)", source: "SimpleUpdater")
                try FileManager.default.removeItem(at: installedAppURL)
            }

            // Move new app to Applications with new name
            try FileManager.default.moveItem(at: downloadedAppURL, to: finalAppURL)
            DebugLogger.shared.info("SimpleUpdater: Successfully installed new app at: \(finalAppURL.path)", source: "SimpleUpdater")
        } else {
            // Same name - normal replacement
            DebugLogger.shared.info("SimpleUpdater: Same app name, performing normal replacement", source: "SimpleUpdater")
            if FileManager.default.fileExists(atPath: installedAppURL.path) {
                try FileManager.default.removeItem(at: installedAppURL)
            }
            try FileManager.default.moveItem(at: downloadedAppURL, to: installedAppURL)
            finalAppURL = installedAppURL
        }

        // Use modern NSWorkspace API for more reliable app launching
        DispatchQueue.main.async {
            DebugLogger.shared.info("SimpleUpdater: Attempting to relaunch app at: \(finalAppURL.path)", source: "SimpleUpdater")

            // Verify the app exists before trying to launch
            guard FileManager.default.fileExists(atPath: finalAppURL.path) else {
                DebugLogger.shared.error("SimpleUpdater: ERROR - App not found at expected location: \(finalAppURL.path)", source: "SimpleUpdater")
                // Don't terminate if we can't find the new app
                return
            }

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true

            NSWorkspace.shared.openApplication(at: finalAppURL, configuration: configuration) { _, error in
                if let error = error {
                    DebugLogger.shared.error("SimpleUpdater: Failed to relaunch app: \(error)", source: "SimpleUpdater")
                    DebugLogger.shared.error("SimpleUpdater: App location: \(finalAppURL.path)", source: "SimpleUpdater")
                    // Don't terminate if relaunch failed - let user manually restart
                    return
                }

                DebugLogger.shared.info("SimpleUpdater: Successfully relaunched app, terminating old instance", source: "SimpleUpdater")
                // Give the new instance time to fully start before terminating
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
