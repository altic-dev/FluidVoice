import Foundation
import Security

/// Synchronous disk/security work. Call from the updater's background staging pipeline.
/// The caller must keep the validated bundle unchanged until the filesystem exchange.
nonisolated enum UpdateBundleValidator {
    struct Expectation: Sendable {
        let bundleIdentifier: String
        /// Exact approved release version. Nil is only for inspecting an installed/rollback bundle.
        let version: String?
        /// GitHub tags do not publish build numbers; nil still requires a valid numeric build.
        let build: String?

        init(bundleIdentifier: String, version: String?, build: String? = nil) {
            self.bundleIdentifier = bundleIdentifier
            self.version = version
            self.build = build
        }
    }

    enum SigningPolicy: Sendable {
        /// Downloaded releases must use this policy, including in Debug builds.
        case developerID(allowedTeamIDs: Set<String>)
        /// Only for local development builds and their rollback backups/tests.
        case appleDevelopment(allowedTeamIDs: Set<String>)
        /// Installed apps/rollback backups can use either approved signing certificate kind.
        /// Never use this broader policy for a downloaded release.
        case installedApp(allowedTeamIDs: Set<String>)

        var allowedTeamIDs: Set<String> {
            switch self {
            case let .developerID(teams), let .appleDevelopment(teams), let .installedApp(teams): return teams
            }
        }

        var certificateRequirement: String {
            switch self {
            case .developerID:
                return "certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            case .appleDevelopment:
                return "certificate leaf[field.1.2.840.113635.100.6.1.2] exists"
            case .installedApp:
                return "((certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists) or certificate leaf[field.1.2.840.113635.100.6.1.2] exists)"
            }
        }
    }

    struct ValidatedBundle: Equatable, Sendable {
        let bundleIdentifier: String
        let version: String
        let build: String
        let teamIdentifier: String
    }

    enum ValidationError: LocalizedError, Equatable {
        case invalidBundle
        case invalidExpectation
        case invalidSignature(OSStatus)
        case missingSigningMetadata
        case invalidBundleMetadata
        case identityMismatch
        case versionMismatch
        case buildMismatch

        var errorDescription: String? {
            switch self {
            case .invalidBundle: return "The update is not a valid application bundle."
            case .invalidExpectation: return "The update's expected identity or signing policy is invalid."
            case .invalidSignature: return "The update's signature or sealed contents could not be verified."
            case .missingSigningMetadata: return "The update has no trusted signing identity."
            case .invalidBundleMetadata: return "The update has invalid application metadata."
            case .identityMismatch: return "The update belongs to a different application."
            case .versionMismatch: return "The update does not match the selected release version."
            case .buildMismatch: return "The update does not match the expected build."
            }
        }
    }

    static func validate(
        at bundleURL: URL,
        expectation: Expectation,
        policy: SigningPolicy
    ) throws -> ValidatedBundle {
        guard self.validIdentifier(expectation.bundleIdentifier),
              !policy.allowedTeamIDs.isEmpty,
              policy.allowedTeamIDs.allSatisfy(self.validTeamIdentifier),
              expectation.version.map(self.validVersion) ?? true,
              expectation.build.map(self.validBuild) ?? true
        else { throw ValidationError.invalidExpectation }

        guard bundleURL.isFileURL, bundleURL.pathExtension.lowercased() == "app",
              let values = try? bundleURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true
        else { throw ValidationError.invalidBundle }

        // Read the staged file afresh; Bundle caches can retain metadata from an earlier
        // app at the same URL. Bound the read before passing the bundle to Security.
        let plist = try self.readInfoPlist(at: bundleURL.appendingPathComponent("Contents/Info.plist"))

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw ValidationError.invalidSignature(createStatus)
        }

        let teams = policy.allowedTeamIDs.sorted().map { "certificate leaf[subject.OU] = \"\($0)\"" }.joined(separator: " or ")
        let requirementText = "anchor apple generic and \(policy.certificateRequirement) and (\(teams))"
        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
        guard requirementStatus == errSecSuccess, let requirement else {
            throw ValidationError.invalidSignature(requirementStatus)
        }

        // No skip-resource/executable flags and no network access. One full check also
        // verifies nested code and every executable architecture; serialize resource work.
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate | kSecCSSingleThreaded)
        let validityStatus = SecStaticCodeCheckValidity(staticCode, flags, requirement)
        guard validityStatus == errSecSuccess else {
            throw ValidationError.invalidSignature(validityStatus)
        }

        var signingInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInformation)
        guard informationStatus == errSecSuccess, let information = signingInformation as? [String: Any],
              let identifier = information[kSecCodeInfoIdentifier as String] as? String,
              let team = information[kSecCodeInfoTeamIdentifier as String] as? String,
              policy.allowedTeamIDs.contains(team),
              let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate], !certificates.isEmpty,
              let cms = information[kSecCodeInfoCMS as String] as? Data, !cms.isEmpty,
              let signatureFlags = information[kSecCodeInfoFlags as String] as? NSNumber,
              signatureFlags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue == 0,
              let securedPlist = information[kSecCodeInfoPList as String] as? [String: Any]
        else { throw ValidationError.missingSigningMetadata }

        guard let bundleIdentifier = plist["CFBundleIdentifier"] as? String,
              let version = plist["CFBundleShortVersionString"] as? String, self.validVersion(version),
              let build = plist["CFBundleVersion"] as? String, self.validBuild(build),
              plist["CFBundlePackageType"] as? String == "APPL",
              let executable = plist["CFBundleExecutable"] as? String,
              !executable.isEmpty, executable != ".", executable != "..", !executable.contains("/"),
              securedPlist["CFBundleIdentifier"] as? String == bundleIdentifier,
              securedPlist["CFBundleShortVersionString"] as? String == version,
              securedPlist["CFBundleVersion"] as? String == build
        else { throw ValidationError.invalidBundleMetadata }
        guard identifier == expectation.bundleIdentifier, bundleIdentifier == expectation.bundleIdentifier else {
            throw ValidationError.identityMismatch
        }
        if let expectedVersion = expectation.version, version != expectedVersion {
            throw ValidationError.versionMismatch
        }
        if let expectedBuild = expectation.build, build != expectedBuild {
            throw ValidationError.buildMismatch
        }
        return ValidatedBundle(bundleIdentifier: bundleIdentifier, version: version, build: build, teamIdentifier: team)
    }

    private static func readInfoPlist(at url: URL) throws -> [String: Any] {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ValidationError.invalidBundleMetadata
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let maximumSize = 1024 * 1024
            guard let data = try handle.read(upToCount: maximumSize + 1), data.count <= maximumSize,
                  let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
            else { throw ValidationError.invalidBundleMetadata }
            return plist
        } catch {
            throw ValidationError.invalidBundleMetadata
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46
        }
    }

    private static func validTeamIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
    }

    private static func validVersion(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validBuild(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 32 else { return false }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return (1...3).contains(components.count) && components.allSatisfy {
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
        }
    }
}
