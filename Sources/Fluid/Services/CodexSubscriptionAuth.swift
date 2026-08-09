import Foundation
import Security

@MainActor
final class InFlightTaskCoalescer<Value> {
    private var flight: (id: UUID, task: Task<Value, Error>)?

    func value(operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let activeFlight: (id: UUID, task: Task<Value, Error>)
        if let flight {
            activeFlight = flight
        } else {
            let newFlight = (
                id: UUID(),
                task: Task { try await operation() }
            )
            self.flight = newFlight
            activeFlight = newFlight
        }

        do {
            let value = try await activeFlight.task.value
            if self.flight?.id == activeFlight.id {
                self.flight = nil
            }
            return value
        } catch {
            if self.flight?.id == activeFlight.id {
                self.flight = nil
            }
            throw error
        }
    }
}

/// ChatGPT subscription authentication compatible with the public Codex device flow.
///
/// FluidVoice stores its own access/refresh pair in a dedicated Keychain item.
/// The existing read-only Codex `auth.json` import remains available as a fallback.
enum CodexSubscriptionAuth {
    static let providerID = "openai-codex-subscription"
    static let baseURL = "https://chatgpt.com/backend-api/codex"
    static let supportsInAppSignIn = true

    private static let issuer = "https://auth.openai.com"
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let keychainService = "com.fluidvoice.provider-oauth"
    private static let expirySafetyWindow: TimeInterval = 120
    private static let refreshCoalescer = InFlightTaskCoalescer<OAuthSession>()

    struct DeviceAuthorization: Equatable {
        let deviceAuthID: String
        let userCode: String
        let pollingInterval: TimeInterval
        let expiresAt: Date

        var browserURL: URL {
            URL(string: "https://auth.openai.com/codex/device")!
        }
    }

    struct OAuthSession: Codable, Equatable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
        let accountID: String?
        let email: String?

        var accountLabel: String {
            let trimmedEmail = self.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedEmail.isEmpty {
                return trimmedEmail
            }
            let trimmedAccount = self.accountID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmedAccount.isEmpty ? "ChatGPT account" : trimmedAccount
        }
    }

    struct ResolvedCredential {
        let accessToken: String
        let accountID: String?
        let accountLabel: String
    }

    enum AuthError: LocalizedError, Equatable {
        case invalidOAuthResponse
        case requestFailed(Int)
        case authorizationDenied
        case authorizationExpired
        case keychainFailure(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidOAuthResponse:
                return "OpenAI returned an invalid sign-in response. Please try again."
            case let .requestFailed(statusCode):
                return statusCode == 0
                    ? "Could not reach OpenAI to complete sign-in. Check your connection and try again."
                    : "OpenAI sign-in failed (HTTP \(statusCode)). Please try again."
            case .authorizationDenied:
                return "ChatGPT sign-in was denied in the browser."
            case .authorizationExpired:
                return "The ChatGPT sign-in code expired. Please try again."
            case let .keychainFailure(status):
                return "FluidVoice could not access the ChatGPT OAuth session in Keychain (status \(status))."
            }
        }
    }

    private struct DeviceAuthorizationResponse: Decodable {
        let deviceAuthID: String
        let userCode: String
        let interval: String?

        enum CodingKeys: String, CodingKey {
            case deviceAuthID = "device_auth_id"
            case userCode = "user_code"
            case interval
        }
    }

    private struct DeviceTokenResponse: Decodable {
        let authorizationCode: String
        let codeVerifier: String

        enum CodingKeys: String, CodingKey {
            case authorizationCode = "authorization_code"
            case codeVerifier = "code_verifier"
        }
    }

    private struct OAuthTokenResponse: Decodable {
        let idToken: String?
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    static func requestDeviceAuthorization(
        session: URLSession = .shared,
        now: Date = Date()
    ) async throws -> DeviceAuthorization {
        guard let url = URL(string: "\(self.issuer)/api/accounts/deviceauth/usercode") else {
            throw AuthError.invalidOAuthResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("FluidVoice", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["client_id": self.clientID])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            try OfficialProviderAuth.rethrowCancellation(error)
            throw AuthError.requestFailed(0)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AuthError.requestFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try self.decodeDeviceAuthorization(from: data, now: now)
    }

    static func decodeDeviceAuthorization(
        from data: Data,
        now: Date = Date()
    ) throws -> DeviceAuthorization {
        guard let response = try? JSONDecoder().decode(DeviceAuthorizationResponse.self, from: data),
              !response.deviceAuthID.isEmpty,
              response.userCode.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else {
            throw AuthError.invalidOAuthResponse
        }
        let interval = min(max(Double(response.interval ?? "") ?? 5, 1), 30)
        return DeviceAuthorization(
            deviceAuthID: response.deviceAuthID,
            userCode: response.userCode,
            pollingInterval: interval,
            expiresAt: now.addingTimeInterval(15 * 60)
        )
    }

    static func completeDeviceAuthorization(
        _ authorization: DeviceAuthorization,
        session: URLSession = .shared,
        now: @escaping () -> Date = Date.init
    ) async throws -> OAuthSession {
        while now() < authorization.expiresAt {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64((authorization.pollingInterval + 3) * 1_000_000_000))

            guard let url = URL(string: "\(self.issuer)/api/accounts/deviceauth/token") else {
                throw AuthError.invalidOAuthResponse
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("FluidVoice", forHTTPHeaderField: "User-Agent")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "device_auth_id": authorization.deviceAuthID,
                "user_code": authorization.userCode,
            ])

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                try OfficialProviderAuth.rethrowCancellation(error)
                throw AuthError.requestFailed(0)
            }
            guard let http = response as? HTTPURLResponse else {
                throw AuthError.invalidOAuthResponse
            }
            if http.statusCode == 403 || http.statusCode == 404 {
                continue
            }
            guard (200..<300).contains(http.statusCode),
                  let deviceToken = try? JSONDecoder().decode(DeviceTokenResponse.self, from: data),
                  !deviceToken.authorizationCode.isEmpty,
                  !deviceToken.codeVerifier.isEmpty
            else {
                if http.statusCode == 401 {
                    throw AuthError.authorizationDenied
                }
                throw AuthError.requestFailed(http.statusCode)
            }

            let oauthSession = try await self.exchangeAuthorizationCode(
                deviceToken.authorizationCode,
                codeVerifier: deviceToken.codeVerifier,
                now: now(),
                session: session
            )
            try self.storeOAuthSession(oauthSession)
            return oauthSession
        }
        throw AuthError.authorizationExpired
    }

    static func decodeOAuthSession(
        from data: Data,
        previousRefreshToken: String? = nil,
        previousAccountID: String? = nil,
        previousEmail: String? = nil,
        now: Date = Date()
    ) throws -> OAuthSession {
        guard let response = try? JSONDecoder().decode(OAuthTokenResponse.self, from: data) else {
            throw AuthError.invalidOAuthResponse
        }
        let accessToken = response.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let responseRefresh = response.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let refreshToken = responseRefresh.isEmpty ? (previousRefreshToken ?? "") : responseRefresh
        guard !accessToken.isEmpty, !refreshToken.isEmpty else {
            throw AuthError.invalidOAuthResponse
        }

        let idClaims = response.idToken.map { self.jwtClaims(from: $0) } ?? [:]
        let accessClaims = self.jwtClaims(from: accessToken)
        let accountID = self.accountID(in: idClaims)
            ?? self.accountID(in: accessClaims)
            ?? previousAccountID
        let email = (idClaims["email"] as? String)
            ?? (accessClaims["email"] as? String)
            ?? previousEmail
        let lifetime = min(max(response.expiresIn ?? 3600, 60), 24 * 60 * 60)

        return OAuthSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: now.addingTimeInterval(lifetime),
            accountID: accountID,
            email: email
        )
    }

    static func resolveCredential(
        now: Date = Date(),
        session: URLSession = .shared
    ) async throws -> ResolvedCredential? {
        guard var oauthSession = try self.loadOAuthSession() else { return nil }
        if oauthSession.expiresAt.timeIntervalSince(now) <= self.expirySafetyWindow {
            let sessionToRefresh = oauthSession
            oauthSession = try await self.refreshCoalescer.value {
                let refreshed = try await self.refreshOAuthSession(sessionToRefresh, now: now, session: session)
                try self.storeOAuthSession(refreshed)
                return refreshed
            }
        }
        return ResolvedCredential(
            accessToken: oauthSession.accessToken,
            accountID: oauthSession.accountID,
            accountLabel: oauthSession.accountLabel
        )
    }

    static func disconnectFluidVoiceSession() throws {
        let status = SecItemDelete(self.keychainQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthError.keychainFailure(status)
        }
    }

    private static func exchangeAuthorizationCode(
        _ code: String,
        codeVerifier: String,
        now: Date,
        session: URLSession
    ) async throws -> OAuthSession {
        try await self.requestOAuthToken(
            parameters: [
                "client_id": self.clientID,
                "code": code,
                "code_verifier": codeVerifier,
                "grant_type": "authorization_code",
                "redirect_uri": "\(self.issuer)/deviceauth/callback",
            ],
            now: now,
            session: session
        )
    }

    private static func refreshOAuthSession(
        _ oauthSession: OAuthSession,
        now: Date,
        session: URLSession
    ) async throws -> OAuthSession {
        try await self.requestOAuthToken(
            parameters: [
                "client_id": self.clientID,
                "grant_type": "refresh_token",
                "refresh_token": oauthSession.refreshToken,
            ],
            previous: oauthSession,
            now: now,
            session: session
        )
    }

    private static func requestOAuthToken(
        parameters: [String: String],
        previous: OAuthSession? = nil,
        now: Date,
        session: URLSession
    ) async throws -> OAuthSession {
        guard let url = URL(string: "\(self.issuer)/oauth/token") else {
            throw AuthError.invalidOAuthResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("FluidVoice", forHTTPHeaderField: "User-Agent")
        request.httpBody = self.formEncoded(parameters)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            try OfficialProviderAuth.rethrowCancellation(error)
            throw AuthError.requestFailed(0)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AuthError.requestFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try self.decodeOAuthSession(
            from: data,
            previousRefreshToken: previous?.refreshToken,
            previousAccountID: previous?.accountID,
            previousEmail: previous?.email,
            now: now
        )
    }

    private static func loadOAuthSession() throws -> OAuthSession? {
        var query = self.keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let oauthSession = try? JSONDecoder().decode(OAuthSession.self, from: data)
        else {
            throw AuthError.keychainFailure(status)
        }
        return oauthSession
    }

    private static func storeOAuthSession(_ oauthSession: OAuthSession) throws {
        guard let data = try? JSONEncoder().encode(oauthSession) else {
            throw AuthError.invalidOAuthResponse
        }
        var attributes = self.keychainQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess {
            return
        }
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                self.keychainQuery() as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw AuthError.keychainFailure(updateStatus)
            }
            return
        }
        throw AuthError.keychainFailure(status)
    }

    private static func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.keychainService,
            kSecAttrAccount as String: self.providerID,
        ]
    }

    private static func accountID(in claims: [String: Any]) -> String? {
        if let direct = claims["chatgpt_account_id"] as? String, !direct.isEmpty {
            return direct
        }
        if let auth = claims["https://api.openai.com/auth"] as? [String: Any],
           let nested = auth["chatgpt_account_id"] as? String,
           !nested.isEmpty
        {
            return nested
        }
        if let organizations = claims["organizations"] as? [[String: Any]],
           let first = organizations.first?["id"] as? String,
           !first.isEmpty
        {
            return first
        }
        return nil
    }

    private static func jwtClaims(from token: String) -> [String: Any] {
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
}
