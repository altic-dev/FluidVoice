import Foundation
import Security

/// Grok subscription authentication through xAI's public device flow.
///
/// FluidVoice stores sessions it creates in its own Keychain item. It can also reuse
/// the official Grok client's `auth.json` as a read-only fallback without modifying it.
enum GrokSubscriptionAuth {
    static let providerID = "xai-grok-subscription"
    static let proxyBaseURL = "https://cli-chat-proxy.grok.com/v1"
    static let supportsInAppSignIn = true

    private static let xAIIssuer = "https://auth.x.ai"
    private static let oauthClientID = "b1a00492-073a-47ea-816f-4c329264a828"
    static let deviceAuthorizationScopes = [
        "openid",
        "profile",
        "email",
        "offline_access",
        "grok-cli:access",
        "api:access",
        "conversations:read",
        "conversations:write",
        "workspaces:read",
        "workspaces:write",
    ]
    static let deviceAuthorizationReferrer = "grok-build"
    private static let oauthScopes = deviceAuthorizationScopes.joined(separator: " ")
    private static let oauthKeychainService = "com.fluidvoice.provider-oauth"
    private static let deviceGrantType = "urn:ietf:params:oauth:grant-type:device_code"
    private static let maximumAuthFileSize = 1_048_576
    private static let fallbackCredentialLifetime: TimeInterval = 30 * 24 * 60 * 60
    private static let expirySafetyWindow: TimeInterval = 60
    private static let fallbackClientVersion = "1.0.0"

    struct DeviceAuthorization: Equatable {
        let deviceCode: String
        let userCode: String
        let verificationURL: URL
        let verificationCompleteURL: URL?
        let pollingInterval: TimeInterval
        let expiresAt: Date

        var browserURL: URL {
            if let verificationCompleteURL {
                return verificationCompleteURL
            }
            guard var components = URLComponents(url: self.verificationURL, resolvingAgainstBaseURL: false) else {
                return self.verificationURL
            }
            var queryItems = components.queryItems ?? []
            queryItems.append(URLQueryItem(name: "user_code", value: self.userCode))
            components.queryItems = queryItems
            return components.url ?? self.verificationURL
        }
    }

    struct ResolvedCredential {
        let accessToken: String
        let baseURL: String
        let requestHeaders: [String: String]
        let accountLabel: String
    }

    struct OAuthSession: Codable, Equatable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date
        let scope: String
        let userID: String
        let email: String?

        var accountLabel: String {
            let trimmedEmail = self.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmedEmail.isEmpty ? "Grok account" : trimmedEmail
        }
    }

    struct Credential: Equatable {
        let accessToken: String
        let scope: String
        let userID: String
        let email: String?
        let expiresAt: Date
        let grokHome: URL

        var accountLabel: String {
            let trimmedEmail = self.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmedEmail.isEmpty ? "Grok account" : trimmedEmail
        }

        /// Stable across access-token refreshes, but changes if the imported account changes.
        var verificationIdentity: String {
            "grok-subscription|\(self.scope)|\(self.userID)"
        }

        var requestHeaders: [String: String] {
            GrokSubscriptionAuth.proxyRequestHeaders(userID: self.userID, grokHome: self.grokHome)
        }
    }

    enum AuthError: LocalizedError, Equatable {
        case authFileNotFound(String)
        case authFileTooLarge
        case unreadableAuthFile
        case invalidAuthFile
        case noSubscriptionSession
        case expiredSession
        case invalidOAuthResponse
        case invalidVerificationURL
        case oauthRequestFailed(Int)
        case authorizationDenied
        case authorizationExpired
        case keychainFailure(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .authFileNotFound(path):
                return "No Grok login was found at \(path). Sign in from FluidVoice, or run `grok login` to import an existing official-client session."
            case .authFileTooLarge:
                return "The Grok authentication file is unexpectedly large and was not read."
            case .unreadableAuthFile:
                return "The Grok authentication file could not be read. Check its permissions, then import again."
            case .invalidAuthFile:
                return "The Grok authentication file is invalid. Sign in from FluidVoice, or run `grok login` to recreate it."
            case .noSubscriptionSession:
                return "No Grok subscription login was found. Click Sign In with Grok, or run `grok login --oauth` to import an existing session."
            case .expiredSession:
                return "The Grok login has expired. Sign in with Grok again."
            case .invalidOAuthResponse:
                return "xAI returned an invalid OAuth response. Please try signing in again."
            case .invalidVerificationURL:
                return "xAI returned an unsafe sign-in URL, so FluidVoice did not open it."
            case let .oauthRequestFailed(statusCode):
                return statusCode == 0
                    ? "Could not reach xAI to complete sign-in. Check your connection and try again."
                    : "xAI sign-in failed (HTTP \(statusCode)). Please try again."
            case .authorizationDenied:
                return "Grok sign-in was denied in the browser."
            case .authorizationExpired:
                return "The Grok sign-in code expired. Please try again."
            case let .keychainFailure(status):
                return "FluidVoice could not access the Grok OAuth session in Keychain (status \(status))."
            }
        }
    }

    private struct DeviceAuthorizationResponse: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationURI: String
        let verificationURIComplete: String?
        let expiresIn: Double
        let interval: Double?

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case verificationURIComplete = "verification_uri_complete"
            case expiresIn = "expires_in"
            case interval
        }
    }

    private struct OAuthTokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double?
        let scope: String?
        let idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
            case idToken = "id_token"
        }
    }

    private struct OAuthErrorResponse: Decodable {
        let error: String?
    }

    private struct StoredCredential: Decodable {
        let key: String?
        let authMode: String?
        let createTime: String?
        let userID: String?
        let email: String?
        let expiresAt: String?
        let oidcIssuer: String?

        enum CodingKeys: String, CodingKey {
            case key
            case authMode = "auth_mode"
            case createTime = "create_time"
            case userID = "user_id"
            case email
            case expiresAt = "expires_at"
            case oidcIssuer = "oidc_issuer"
        }
    }

    static func isSubscriptionProvider(_ providerID: String) -> Bool {
        providerID.trimmingCharacters(in: .whitespacesAndNewlines) == self.providerID
    }

    static func isProxyBaseURL(_ value: String) -> Bool {
        guard let host = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))?.host else {
            return false
        }
        return host.caseInsensitiveCompare("cli-chat-proxy.grok.com") == .orderedSame
    }

    // MARK: - FluidVoice-owned OAuth

    static func requestDeviceAuthorization(
        session: URLSession = .shared,
        now: Date = Date()
    ) async throws -> DeviceAuthorization {
        guard let url = URL(string: "\(self.xAIIssuer)/oauth2/device/code") else {
            throw AuthError.invalidOAuthResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("FluidVoice", forHTTPHeaderField: "User-Agent")
        request.setValue("ui", forHTTPHeaderField: "x-grok-client-surface")
        request.setValue(self.fallbackClientVersion, forHTTPHeaderField: "x-grok-client-version")
        request.httpBody = self.formEncoded([
            "client_id": self.oauthClientID,
            "referrer": self.deviceAuthorizationReferrer,
            "scope": self.oauthScopes,
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AuthError.oauthRequestFailed(0)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AuthError.oauthRequestFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try self.decodeDeviceAuthorization(from: data, now: now)
    }

    static func decodeDeviceAuthorization(
        from data: Data,
        now: Date = Date()
    ) throws -> DeviceAuthorization {
        guard let response = try? JSONDecoder().decode(DeviceAuthorizationResponse.self, from: data),
              !response.deviceCode.isEmpty,
              response.userCode.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              response.expiresIn > 0,
              let verificationURL = URL(string: response.verificationURI),
              self.isAllowedVerificationURL(verificationURL)
        else {
            throw AuthError.invalidOAuthResponse
        }

        let completeURL: URL?
        if let value = response.verificationURIComplete {
            guard let url = URL(string: value), self.isAllowedVerificationURL(url) else {
                throw AuthError.invalidVerificationURL
            }
            completeURL = url
        } else {
            completeURL = nil
        }

        return DeviceAuthorization(
            deviceCode: response.deviceCode,
            userCode: response.userCode,
            verificationURL: verificationURL,
            verificationCompleteURL: completeURL,
            pollingInterval: min(max(response.interval ?? 5, 1), 30),
            expiresAt: now.addingTimeInterval(min(response.expiresIn, 30 * 60))
        )
    }

    static func completeDeviceAuthorization(
        _ authorization: DeviceAuthorization,
        session: URLSession = .shared,
        now: @escaping () -> Date = Date.init
    ) async throws -> OAuthSession {
        var pollingInterval = authorization.pollingInterval

        while now() < authorization.expiresAt {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))

            guard let url = URL(string: "\(self.xAIIssuer)/oauth2/token") else {
                throw AuthError.invalidOAuthResponse
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("FluidVoice", forHTTPHeaderField: "User-Agent")
            request.setValue("ui", forHTTPHeaderField: "x-grok-client-surface")
            request.setValue(self.fallbackClientVersion, forHTTPHeaderField: "x-grok-client-version")
            request.httpBody = self.formEncoded([
                "client_id": self.oauthClientID,
                "device_code": authorization.deviceCode,
                "grant_type": self.deviceGrantType,
            ])

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw AuthError.oauthRequestFailed(0)
            }

            guard let http = response as? HTTPURLResponse else {
                throw AuthError.invalidOAuthResponse
            }
            if (200..<300).contains(http.statusCode) {
                let oauthSession = try self.decodeOAuthSession(from: data, now: now())
                try self.storeOAuthSession(oauthSession)
                return oauthSession
            }

            let code = (try? JSONDecoder().decode(OAuthErrorResponse.self, from: data))?.error ?? ""
            switch code {
            case "authorization_pending":
                continue
            case "slow_down":
                pollingInterval = min(pollingInterval + 5, 60)
            case "access_denied", "authorization_denied":
                throw AuthError.authorizationDenied
            case "expired_token":
                throw AuthError.authorizationExpired
            default:
                throw AuthError.oauthRequestFailed(http.statusCode)
            }
        }

        throw AuthError.authorizationExpired
    }

    static func decodeOAuthSession(
        from data: Data,
        previousRefreshToken: String? = nil,
        previousUserID: String? = nil,
        previousEmail: String? = nil,
        now: Date = Date()
    ) throws -> OAuthSession {
        guard let response = try? JSONDecoder().decode(OAuthTokenResponse.self, from: data) else {
            throw AuthError.invalidOAuthResponse
        }
        let accessToken = response.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            throw AuthError.invalidOAuthResponse
        }

        let idClaims = response.idToken.map(self.jwtClaims) ?? [:]
        let accessClaims = self.jwtClaims(from: accessToken)
        let claims = idClaims.isEmpty ? accessClaims : idClaims
        let claimedUserID = (claims["sub"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let userID = claimedUserID.isEmpty ? (previousUserID ?? "") : claimedUserID
        let claimedEmail = (claims["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let email = claimedEmail.isEmpty ? previousEmail : claimedEmail
        let responseRefreshToken = response.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let refreshToken = responseRefreshToken?.isEmpty == false ? responseRefreshToken : previousRefreshToken
        let lifetime = min(max(response.expiresIn ?? 3600, 60), 24 * 60 * 60)

        return OAuthSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: now.addingTimeInterval(lifetime),
            scope: response.scope ?? self.oauthScopes,
            userID: userID,
            email: email?.isEmpty == false ? email : nil
        )
    }

    static func resolveCredential(
        now: Date = Date(),
        session: URLSession = .shared
    ) async throws -> ResolvedCredential {
        if var ownedSession = try self.loadOAuthSession() {
            if ownedSession.expiresAt.timeIntervalSince(now) <= self.expirySafetyWindow {
                ownedSession = try await self.refreshOAuthSession(ownedSession, now: now, session: session)
                try self.storeOAuthSession(ownedSession)
            }
            return ResolvedCredential(
                accessToken: ownedSession.accessToken,
                baseURL: self.proxyBaseURL,
                requestHeaders: self.proxyRequestHeaders(
                    userID: ownedSession.userID,
                    grokHome: self.defaultGrokHome()
                ),
                accountLabel: ownedSession.accountLabel
            )
        }

        let imported = try self.loadCredential(now: now)
        return ResolvedCredential(
            accessToken: imported.accessToken,
            baseURL: self.proxyBaseURL,
            requestHeaders: imported.requestHeaders,
            accountLabel: imported.accountLabel
        )
    }

    static func disconnectFluidVoiceSession() throws {
        let status = SecItemDelete(self.oauthKeychainQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthError.keychainFailure(status)
        }
    }

    static func defaultGrokHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let configured = environment["GROK_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty
        {
            let expanded = NSString(string: configured).expandingTildeInPath
            if expanded.hasPrefix("/") {
                return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
            }
            return homeDirectory.appendingPathComponent(expanded, isDirectory: true).standardizedFileURL
        }
        return homeDirectory.appendingPathComponent(".grok", isDirectory: true)
    }

    static func loadCredential(
        from authFileURL: URL? = nil,
        now: Date = Date()
    ) throws -> Credential {
        let fileURL = authFileURL ?? self.defaultGrokHome().appendingPathComponent("auth.json", isDirectory: false)
        let grokHome = fileURL.deletingLastPathComponent()

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AuthError.authFileNotFound(fileURL.path)
        }

        let values: URLResourceValues
        do {
            values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw AuthError.unreadableAuthFile
        }
        guard values.isRegularFile == true else {
            throw AuthError.unreadableAuthFile
        }
        guard (values.fileSize ?? 0) <= self.maximumAuthFileSize else {
            throw AuthError.authFileTooLarge
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            throw AuthError.unreadableAuthFile
        }

        return try self.decodeCredential(from: data, grokHome: grokHome, now: now)
    }

    static func decodeCredential(
        from data: Data,
        grokHome: URL,
        now: Date = Date()
    ) throws -> Credential {
        let store: [String: StoredCredential]
        do {
            store = try JSONDecoder().decode([String: StoredCredential].self, from: data)
        } catch {
            throw AuthError.invalidAuthFile
        }

        var foundSubscriptionSession = false
        var foundExpiredSession = false
        var candidates: [(credential: Credential, createdAt: Date)] = []

        for (scope, stored) in store {
            let mode = stored.authMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard mode == "oidc" || mode == "external" else { continue }

            let issuer = stored.oidcIssuer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let scopeIssuer = scope.components(separatedBy: "::").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard issuer == self.xAIIssuer || scopeIssuer == self.xAIIssuer else { continue }
            foundSubscriptionSession = true

            let token = stored.key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !token.isEmpty else { continue }

            let createdAt = stored.createTime.flatMap(self.parseRFC3339) ?? .distantPast
            let expiresAt = stored.expiresAt.flatMap(self.parseRFC3339)
                ?? createdAt.addingTimeInterval(self.fallbackCredentialLifetime)
            guard expiresAt.timeIntervalSince(now) > self.expirySafetyWindow else {
                foundExpiredSession = true
                continue
            }

            let storedUserID = stored.userID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let userID = !storedUserID.isEmpty ? storedUserID : (self.jwtSubject(from: token) ?? "")

            candidates.append((
                Credential(
                    accessToken: token,
                    scope: scope,
                    userID: userID,
                    email: stored.email,
                    expiresAt: expiresAt,
                    grokHome: grokHome
                ),
                createdAt
            ))
        }

        if let selected = candidates.max(by: { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.credential.expiresAt < rhs.credential.expiresAt
            }
            return lhs.createdAt < rhs.createdAt
        }) {
            return selected.credential
        }

        if foundExpiredSession {
            throw AuthError.expiredSession
        }
        if foundSubscriptionSession {
            throw AuthError.invalidAuthFile
        }
        throw AuthError.noSubscriptionSession
    }

    private static func refreshOAuthSession(
        _ oauthSession: OAuthSession,
        now: Date,
        session: URLSession
    ) async throws -> OAuthSession {
        guard let refreshToken = oauthSession.refreshToken, !refreshToken.isEmpty else {
            throw AuthError.expiredSession
        }
        guard let url = URL(string: "\(self.xAIIssuer)/oauth2/token") else {
            throw AuthError.invalidOAuthResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("FluidVoice", forHTTPHeaderField: "User-Agent")
        request.setValue("ui", forHTTPHeaderField: "x-grok-client-surface")
        request.setValue(self.fallbackClientVersion, forHTTPHeaderField: "x-grok-client-version")
        request.httpBody = self.formEncoded([
            "client_id": self.oauthClientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AuthError.oauthRequestFailed(0)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AuthError.oauthRequestFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try self.decodeOAuthSession(
            from: data,
            previousRefreshToken: refreshToken,
            previousUserID: oauthSession.userID,
            previousEmail: oauthSession.email,
            now: now
        )
    }

    private static func loadOAuthSession() throws -> OAuthSession? {
        var query = self.oauthKeychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw AuthError.keychainFailure(status)
        }
        guard let oauthSession = try? JSONDecoder().decode(OAuthSession.self, from: data) else {
            throw AuthError.invalidAuthFile
        }
        return oauthSession
    }

    private static func storeOAuthSession(_ oauthSession: OAuthSession) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(oauthSession)
        } catch {
            throw AuthError.invalidOAuthResponse
        }

        var attributes = self.oauthKeychainQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess {
            return
        }
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                self.oauthKeychainQuery() as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw AuthError.keychainFailure(updateStatus)
            }
            return
        }
        throw AuthError.keychainFailure(status)
    }

    private static func oauthKeychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.oauthKeychainService,
            kSecAttrAccount as String: self.providerID,
        ]
    }

    static func proxyRequestHeaders(userID: String, grokHome: URL) -> [String: String] {
        var headers = [
            "X-XAI-Token-Auth": "xai-grok-cli",
            "x-authenticateresponse": "authenticate-response",
            "x-grok-client-mode": "interactive",
            "x-grok-client-version": self.clientVersion(in: grokHome),
            "x-grok-client-identifier": "fluidvoice",
            "User-Agent": "FluidVoice",
        ]

        if !userID.isEmpty {
            // The models endpoint currently expects x-userid; inference requests
            // use x-grok-user-id. Supplying both matches the official client seams.
            headers["x-userid"] = userID
            headers["x-grok-user-id"] = userID
        }
        return headers
    }

    private static func isAllowedVerificationURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else { return false }
        return host == "x.ai" || host.hasSuffix(".x.ai")
    }

    private nonisolated static func jwtClaims(from token: String) -> [String: Any] {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return [:] }

        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload.append(String(repeating: "=", count: (4 - payload.count % 4) % 4))
        guard let data = Data(base64Encoded: payload) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func formEncoded(_ values: [String: String]) -> Data? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        let body = values.keys.sorted().compactMap { key -> String? in
            guard let value = values[key],
                  let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed),
                  let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed)
            else { return nil }
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return body.data(using: .utf8)
    }

    private nonisolated static func parseRFC3339(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    private static func jwtSubject(from token: String) -> String? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }

        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - payload.count % 4) % 4
        payload.append(String(repeating: "=", count: padding))

        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = object["sub"] as? String
        else { return nil }

        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func clientVersion(in grokHome: URL) -> String {
        let managedBinary = grokHome.appendingPathComponent("bin/grok", isDirectory: false)
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: managedBinary.path),
           let version = self.version(fromManagedBinaryName: URL(fileURLWithPath: destination).lastPathComponent)
        {
            return version
        }

        let versionFile = grokHome.appendingPathComponent("version.json", isDirectory: false)
        if let data = try? Data(contentsOf: versionFile),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = object["version"] as? String,
           !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return version.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return self.fallbackClientVersion
    }

    private static func version(fromManagedBinaryName name: String) -> String? {
        guard name.hasPrefix("grok-") else { return nil }
        let suffix = String(name.dropFirst("grok-".count))
        let components = suffix.split(separator: "-").map(String.init)
        let platformNames = Set(["macos", "linux", "darwin", "windows"])
        let endIndex = components.firstIndex(where: { platformNames.contains($0) }) ?? components.endIndex
        let version = components[..<endIndex].joined(separator: "-")
        guard !version.isEmpty, version.first?.isNumber == true else { return nil }
        return version
    }
}
