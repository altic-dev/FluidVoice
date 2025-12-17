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
}

@MainActor
final class SimpleUpdater {
    static let shared = SimpleUpdater()
    private init() {}
    // Allowed Apple Developer Team IDs for code-sign validation
    // Configured per your request; restrict to your actual Team ID only.
    private let allowedTeamIDs: Set<String> = [
        "V4J43B279J",
    ]

    // Fetch latest release notes from GitHub
    func fetchLatestReleaseNotes(owner: String, repo: String) async throws -> (version: String, notes: String) {
        guard let releasesURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases") else {
            throw SimpleUpdateError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: releasesURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SimpleUpdateError.invalidResponse
        }

        let releases: [GHRelease]
        do {
            releases = try JSONDecoder().decode([GHRelease].self, from: data)
        } catch {
            throw SimpleUpdateError.jsonDecoding
        }

        // Get latest non-prerelease release
        guard let latest = releases.first(where: { !$0.prerelease }) else {
            throw SimpleUpdateError.noSuitableRelease
        }

        let version = latest.tag_name
        let notes = latest.body ?? "No release notes available."

        return (version, notes)
    }

    // Silent check that returns update info without showing alerts or installing
    func checkForUpdate(owner: String, repo: String) async throws -> (hasUpdate: Bool, latestVersion: String) {
        guard let releasesURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases") else {
            throw SimpleUpdateError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: releasesURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SimpleUpdateError.invalidResponse
        }

        let releases: [GHRelease]
        do {
            releases = try JSONDecoder().decode([GHRelease].self, from: data)
        } catch {
            throw SimpleUpdateError.jsonDecoding
        }

        // choose latest non-prerelease release
        guard let latest = releases.first(where: { !$0.prerelease }) else {
            throw SimpleUpdateError.noSuitableRelease
        }

        let currentVersionString = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let current = self.parseVersion(currentVersionString)
        let latestTag = latest.tag_name
        let latestVersion = self.parseVersion(latestTag)

        // Return whether update is available
        return (self.isVersion(latestVersion, greaterThan: current), latestTag)
    }

    func checkAndUpdate(owner: String, repo: String) async throws {
        guard let releasesURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases") else {
            throw SimpleUpdateError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: releasesURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SimpleUpdateError.invalidResponse
        }

        let releases: [GHRelease]
        do {
            releases = try JSONDecoder().decode([GHRelease].self, from: data)
        } catch {
            throw SimpleUpdateError.jsonDecoding
        }

        // choose latest non-prerelease release
        guard let latest = releases.first(where: { !$0.prerelease }) else {
            throw SimpleUpdateError.noSuitableRelease
        }

        let currentVersionString = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let current = self.parseVersion(currentVersionString)
        let latestTag = latest.tag_name
        let latestVersion = self.parseVersion(latestTag)

        // up to date
        if !self.isVersion(latestVersion, greaterThan: current) {
            throw PMKError.cancelled // mimic AppUpdater semantics for up-to-date
        }

        // Find asset matching: "{repo-lower}-{version-no-v}.*" and zip preferred
        let verString = self.versionString(latestVersion)
        let prefix = "\(repo.lowercased())-\(verString)"
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
        let currentBundle = Bundle.main
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
        let bothAllowed: Bool
        if let curTeam, let newTeam {
            bothAllowed = self.allowedTeamIDs.contains(curTeam) && self.allowedTeamIDs.contains(newTeam)
        } else {
            bothAllowed = false
        }

        guard sameIdentity || sameTeam || bothAllowed else {
            print("SimpleUpdater: Code-sign mismatch. Current=\(curID) New=\(newID)")
            print("SimpleUpdater: Current Team=\(curTeam ?? "none") New Team=\(newTeam ?? "none")")
            throw SimpleUpdateError.codesignMismatch
        }
        #endif

        // Replace and relaunch
        try self.performSwapAndRelaunch(installedAppURL: currentBundle.bundleURL, downloadedAppURL: extractedBundleURL)
    }

    // MARK: - Helpers

    private func parseVersion(_ s: String) -> [Int] {
        let t = s.hasPrefix("v") ? String(s.dropFirst()) : s
        let comps = t.split(separator: ".").map { Int($0) ?? 0 }
        return [comps[safe: 0] ?? 0, comps[safe: 1] ?? 0, comps[safe: 2] ?? 0]
    }

    private func versionString(_ v: [Int]) -> String {
        // Match asset naming that omits trailing .0
        if v[2] == 0 { return "\(v[0]).\(v[1])" }
        return "\(v[0]).\(v[1]).\(v[2])"
    }

    private func isVersion(_ a: [Int], greaterThan b: [Int]) -> Bool {
        if a[0] != b[0] { return a[0] > b[0] }
        if a[1] != b[1] { return a[1] > b[1] }
        return a[2] > b[2]
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

        print("SimpleUpdater: Installing app - Current: \(installedAppName), New: \(downloadedAppName)")

        let finalAppURL: URL
        if installedAppName != downloadedAppName {
            // App name changed - use the new name
            finalAppURL = installedAppURL.deletingLastPathComponent().appendingPathComponent(downloadedAppName)
            print("SimpleUpdater: App name changed, installing to: \(finalAppURL.path)")

            // Safety check: ensure we don't overwrite an existing app with the new name
            if FileManager.default.fileExists(atPath: finalAppURL.path) {
                print("SimpleUpdater: Removing existing app at new location: \(finalAppURL.path)")
                try FileManager.default.removeItem(at: finalAppURL)
            }

            // Remove old app if it exists
            if FileManager.default.fileExists(atPath: installedAppURL.path) {
                print("SimpleUpdater: Removing old app: \(installedAppURL.path)")
                try FileManager.default.removeItem(at: installedAppURL)
            }

            // Move new app to Applications with new name
            try FileManager.default.moveItem(at: downloadedAppURL, to: finalAppURL)
            print("SimpleUpdater: Successfully installed new app at: \(finalAppURL.path)")
        } else {
            // Same name - normal replacement
            print("SimpleUpdater: Same app name, performing normal replacement")
            if FileManager.default.fileExists(atPath: installedAppURL.path) {
                try FileManager.default.removeItem(at: installedAppURL)
            }
            try FileManager.default.moveItem(at: downloadedAppURL, to: installedAppURL)
            finalAppURL = installedAppURL
        }

        // Use modern NSWorkspace API for more reliable app launching
        DispatchQueue.main.async {
            print("SimpleUpdater: Attempting to relaunch app at: \(finalAppURL.path)")

            // Verify the app exists before trying to launch
            guard FileManager.default.fileExists(atPath: finalAppURL.path) else {
                print("SimpleUpdater: ERROR - App not found at expected location: \(finalAppURL.path)")
                // Don't terminate if we can't find the new app
                return
            }

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true

            NSWorkspace.shared.openApplication(at: finalAppURL, configuration: configuration) { _, error in
                if let error = error {
                    print("SimpleUpdater: Failed to relaunch app: \(error)")
                    print("SimpleUpdater: App location: \(finalAppURL.path)")
                    // Don't terminate if relaunch failed - let user manually restart
                    return
                }

                print("SimpleUpdater: Successfully relaunched app, terminating old instance")
                // Give the new instance time to fully start before terminating
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
