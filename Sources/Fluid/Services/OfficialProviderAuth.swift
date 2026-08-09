import CryptoKit
import Foundation
import Security

/// Adapters for subscription sessions created by first-party AI clients.
///
/// Grok and ChatGPT additionally support public device authorization flows and
/// store FluidVoice-owned tokens in dedicated Keychain items. Other providers
/// remain read-only imports; FluidVoice never writes to another app's credentials.
enum OfficialProviderAuth {
    static let codexProviderID = CodexSubscriptionAuth.providerID
    static let claudeProviderID = "anthropic-claude-subscription"
    static let geminiProviderID = "google-gemini-subscription"

    static let providerIDs: Set<String> = [
        codexProviderID,
        claudeProviderID,
        geminiProviderID,
        GrokSubscriptionAuth.providerID,
    ]

    enum WireProtocol: Equatable {
        case responses
        case anthropicMessages
        case geminiCodeAssist
    }

    struct Session {
        let providerID: String
        let accessToken: String
        let baseURL: String
        let wireProtocol: WireProtocol
        let headers: [String: String]
        let accountLabel: String
        let project: String?
    }

    struct ProviderInfo {
        let displayName: String
        let setupURL: String
        let setupLabel: String
        let setupCommand: String
        let detail: String
    }

    enum AuthError: LocalizedError {
        case credentialNotFound(String)
        case invalidCredential(String)
        case expiredCredential(String)
        case keychainFailure(String)
        case refreshFailed(String)
        case geminiNotOnboarded

        var errorDescription: String? {
            switch self {
            case let .credentialNotFound(message),
                 let .invalidCredential(message),
                 let .expiredCredential(message),
                 let .keychainFailure(message),
                 let .refreshFailed(message):
                return message
            case .geminiNotOnboarded:
                return "The Gemini login has not finished Code Assist setup. Run `gemini`, choose Sign in with Google, and complete setup before verifying again."
            }
        }
    }

    private static let expirySafetyWindow: TimeInterval = 60
    private static let maximumCredentialFileSize = 1_048_576
    struct CodexCredential: Equatable {
        let accessToken: String
        let accountID: String?
        let accountLabel: String
        let expiresAt: Date?
    }

    struct ClaudeCredential: Equatable {
        let accessToken: String
        let accountLabel: String
        let expiresAt: Date?
    }

    struct GeminiCredential: Equatable {
        let accessToken: String
        let accountLabel: String
        let expiresAt: Date?
    }

    static func isOfficialProvider(_ providerID: String) -> Bool {
        self.providerIDs.contains(providerID.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func supportsInAppSignIn(_ providerID: String) -> Bool {
        providerID == CodexSubscriptionAuth.providerID || providerID == GrokSubscriptionAuth.providerID
    }

    /// The ChatGPT Codex backend only accepts Responses requests over SSE.
    /// Normalize this centrally so verification and non-streaming dictation paths
    /// cannot accidentally send `stream: false` to the subscription endpoint.
    static func requiresStreamingRequests(_ providerID: String) -> Bool {
        providerID == CodexSubscriptionAuth.providerID
    }

    static func inAppSignInLabel(for providerID: String) -> String? {
        switch providerID {
        case CodexSubscriptionAuth.providerID:
            return "Sign In with ChatGPT"
        case GrokSubscriptionAuth.providerID:
            return "Sign In with Grok"
        default:
            return nil
        }
    }

    static func info(for providerID: String) -> ProviderInfo? {
        switch providerID {
        case self.codexProviderID:
            return ProviderInfo(
                displayName: "ChatGPT (Codex Login)",
                setupURL: "https://developers.openai.com/codex/auth/",
                setupLabel: "Codex login guide",
                setupCommand: "codex login",
                detail: "Sign in directly with ChatGPT, or reuse a session owned by the official Codex client."
            )
        case self.claudeProviderID:
            return ProviderInfo(
                displayName: "Claude Subscription",
                setupURL: "https://code.claude.com/docs/en/authentication",
                setupLabel: "Claude login guide",
                setupCommand: "claude",
                detail: "Uses the subscription session owned by the official Claude client."
            )
        case self.geminiProviderID:
            return ProviderInfo(
                displayName: "Gemini Subscription",
                setupURL: "https://github.com/google-gemini/gemini-cli#authentication-options",
                setupLabel: "Gemini login guide",
                setupCommand: "gemini",
                detail: "Uses the Google session owned by the official Gemini CLI."
            )
        case GrokSubscriptionAuth.providerID:
            return ProviderInfo(
                displayName: "Grok Subscription",
                setupURL: "https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-pager/docs/user-guide/02-authentication.md",
                setupLabel: "Grok login guide",
                setupCommand: "grok login --oauth",
                detail: "Sign in directly with xAI, or reuse a session owned by the official Grok client."
            )
        default:
            return nil
        }
    }

    /// Verification records the selected login adapter, not an access token.
    /// Tokens are intentionally never copied into UserDefaults and may rotate at any time.
    static func verificationFingerprint(for providerID: String) -> String? {
        guard self.isOfficialProvider(providerID) else { return nil }
        return self.sha256("official-oauth-provider|\(providerID)")
    }

    static func configurationFingerprint(providerID: String, baseURL: String, apiKey: String) -> String? {
        if let official = self.verificationFingerprint(for: providerID) {
            return official
        }

        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else { return nil }
        return self.sha256("\(trimmedBase)|\(trimmedKey)")
    }

    static func resolve(
        providerID: String,
        now: Date = Date(),
        session: URLSession = .shared
    ) async throws -> Session {
        switch providerID {
        case self.codexProviderID:
            if let owned = try await CodexSubscriptionAuth.resolveCredential(now: now, session: session) {
                var headers = [
                    "originator": "fluidvoice",
                    "User-Agent": "FluidVoice",
                ]
                if let accountID = owned.accountID, !accountID.isEmpty {
                    headers["ChatGPT-Account-ID"] = accountID
                }
                return Session(
                    providerID: providerID,
                    accessToken: owned.accessToken,
                    baseURL: CodexSubscriptionAuth.baseURL,
                    wireProtocol: .responses,
                    headers: headers,
                    accountLabel: owned.accountLabel,
                    project: nil
                )
            }
            let credential = try self.loadCodexCredential(now: now)
            var headers = [
                "originator": "fluidvoice",
                "User-Agent": "FluidVoice",
            ]
            if let accountID = credential.accountID, !accountID.isEmpty {
                headers["ChatGPT-Account-ID"] = accountID
            }
            return Session(
                providerID: providerID,
                accessToken: credential.accessToken,
                baseURL: "https://chatgpt.com/backend-api/codex",
                wireProtocol: .responses,
                headers: headers,
                accountLabel: credential.accountLabel,
                project: nil
            )

        case self.claudeProviderID:
            let credential = try self.loadClaudeCredential(now: now)
            return Session(
                providerID: providerID,
                accessToken: credential.accessToken,
                baseURL: "https://api.anthropic.com/v1",
                wireProtocol: .anthropicMessages,
                headers: [
                    "anthropic-version": "2023-06-01",
                    "anthropic-beta": "oauth-2025-04-20,claude-code-20250219",
                    "User-Agent": "FluidVoice",
                ],
                accountLabel: credential.accountLabel,
                project: nil
            )

        case self.geminiProviderID:
            let stored = try self.loadGeminiCredential()
            let credential = try self.validGeminiCredential(stored, now: now)
            let project = try await self.loadGeminiProject(accessToken: credential.accessToken, session: session)
            return Session(
                providerID: providerID,
                accessToken: credential.accessToken,
                baseURL: "https://cloudcode-pa.googleapis.com/v1internal",
                wireProtocol: .geminiCodeAssist,
                headers: ["User-Agent": "FluidVoice"],
                accountLabel: credential.accountLabel,
                project: project
            )

        case GrokSubscriptionAuth.providerID:
            let credential = try await GrokSubscriptionAuth.resolveCredential(now: now, session: session)
            return Session(
                providerID: providerID,
                accessToken: credential.accessToken,
                baseURL: credential.baseURL,
                wireProtocol: .responses,
                headers: credential.requestHeaders,
                accountLabel: credential.accountLabel,
                project: nil
            )

        default:
            throw AuthError.invalidCredential("Unknown official login provider: \(providerID)")
        }
    }

    // MARK: - Codex

    static func decodeCodexCredential(from data: Data) throws -> CodexCredential {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any]
        else {
            throw AuthError.invalidCredential("The Codex authentication file is invalid. Run `codex login` to recreate it.")
        }

        let authMode = (root["auth_mode"] as? String)?.lowercased() ?? "chatgpt"
        guard authMode == "chatgpt" else {
            throw AuthError.invalidCredential("Codex is configured with an API key, not a ChatGPT login. Run `codex login` and choose ChatGPT.")
        }

        let accessToken = (tokens["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !accessToken.isEmpty else {
            throw AuthError.invalidCredential("The Codex ChatGPT session has no access token. Run `codex login` again.")
        }

        let idToken = tokens["id_token"] as? String
        let accessClaims = self.jwtClaims(from: accessToken)
        let idClaims = idToken.flatMap(self.jwtClaims)
        let accountID = (tokens["account_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = self.firstString(in: [idClaims, accessClaims], keys: ["email"])
        let subject = self.firstString(in: [idClaims, accessClaims], keys: ["sub"])
        let label = [email, accountID, subject].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.first ?? "ChatGPT account"

        return CodexCredential(
            accessToken: accessToken,
            accountID: accountID,
            accountLabel: label,
            expiresAt: self.jwtExpiry(from: accessClaims)
        )
    }

    private static func loadCodexCredential(now: Date) throws -> CodexCredential {
        let environment = ProcessInfo.processInfo.environment
        let codexHome: URL
        if let configured = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
            codexHome = URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath, isDirectory: true)
        } else {
            codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        }
        let fileURL = codexHome.appendingPathComponent("auth.json", isDirectory: false)
        let data = try self.readCredentialFile(
            fileURL,
            missingMessage: "No Codex ChatGPT login was found at \(fileURL.path). Run `codex login`, then verify again."
        )
        let credential = try self.decodeCodexCredential(from: data)
        if let expiresAt = credential.expiresAt, expiresAt.timeIntervalSince(now) <= self.expirySafetyWindow {
            throw AuthError.expiredCredential("The Codex ChatGPT session has expired. Run `codex` once so the official client can refresh it, then verify again.")
        }
        return credential
    }

    // MARK: - Claude

    static func decodeClaudeCredential(from data: Data, accountLabel: String = "Claude account") throws -> ClaudeCredential {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.invalidCredential("The Claude authentication data is invalid. Run `claude` and sign in again.")
        }
        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
        let accessToken = ((oauth["accessToken"] as? String) ?? (oauth["access_token"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !accessToken.isEmpty else {
            throw AuthError.invalidCredential("The Claude subscription session has no access token. Run `claude` and sign in again.")
        }

        let label = (oauth["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let expiresAt = self.dateFromMillisecondsOrSeconds(oauth["expiresAt"] ?? oauth["expires_at"])
            ?? self.jwtExpiry(from: self.jwtClaims(from: accessToken))
        return ClaudeCredential(
            accessToken: accessToken,
            accountLabel: (label?.isEmpty == false ? label! : accountLabel),
            expiresAt: expiresAt
        )
    }

    private static func loadClaudeCredential(now: Date) throws -> ClaudeCredential {
        if let token = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
        {
            let credential = ClaudeCredential(
                accessToken: token,
                accountLabel: "Claude setup token",
                expiresAt: self.jwtExpiry(from: self.jwtClaims(from: token))
            )
            return try self.validateClaudeExpiry(credential, now: now)
        }

        #if os(macOS)
        if let keychainItem = try self.readGenericPassword(service: "Claude Code-credentials") {
            let credential = try self.decodeClaudeCredential(
                from: keychainItem.data,
                accountLabel: keychainItem.account.isEmpty ? "Claude account" : keychainItem.account
            )
            return try self.validateClaudeExpiry(credential, now: now)
        }
        #endif

        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent(".credentials.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AuthError.credentialNotFound(
                "No Claude subscription login was found. Run `claude` and sign in, or launch FluidVoice with `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`."
            )
        }
        let data = try self.readCredentialFile(fileURL, missingMessage: "No Claude login was found.")
        return try self.validateClaudeExpiry(self.decodeClaudeCredential(from: data), now: now)
    }

    private static func validateClaudeExpiry(_ credential: ClaudeCredential, now: Date) throws -> ClaudeCredential {
        if let expiresAt = credential.expiresAt, expiresAt.timeIntervalSince(now) <= self.expirySafetyWindow {
            throw AuthError.expiredCredential("The Claude subscription session has expired. Run `claude` so the official client can refresh it, then verify again.")
        }
        return credential
    }

    // MARK: - Gemini

    static func decodeGeminiCredential(from data: Data, accountLabel: String = "Google account") throws -> GeminiCredential {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.invalidCredential("The Gemini authentication data is invalid. Run `gemini` and sign in again.")
        }
        let token = (root["token"] as? [String: Any]) ?? root
        let accessToken = ((token["accessToken"] as? String) ?? (token["access_token"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !accessToken.isEmpty else {
            throw AuthError.invalidCredential("The Gemini login contains no usable access token. Run `gemini` and sign in again.")
        }

        let expiresAt = self.dateFromMillisecondsOrSeconds(
            token["expiresAt"] ?? token["expiry_date"] ?? token["expires_at"]
        )
        return GeminiCredential(
            accessToken: accessToken,
            accountLabel: accountLabel,
            expiresAt: expiresAt
        )
    }

    private static func loadGeminiCredential() throws -> GeminiCredential {
        let accountLabel = self.geminiAccountLabel()

        #if os(macOS)
        if let keychainItem = try self.readGenericPassword(service: "gemini-cli-oauth", account: "main-account") {
            return try self.decodeGeminiCredential(from: keychainItem.data, accountLabel: accountLabel)
        }
        #endif

        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("oauth_creds.json", isDirectory: false)
        let data = try self.readCredentialFile(
            fileURL,
            missingMessage: "No Gemini CLI login was found at \(fileURL.path). Run `gemini` and choose Sign in with Google, then verify again."
        )
        return try self.decodeGeminiCredential(from: data, accountLabel: accountLabel)
    }

    private static func validGeminiCredential(
        _ credential: GeminiCredential,
        now: Date
    ) throws -> GeminiCredential {
        if !credential.accessToken.isEmpty,
           credential.expiresAt?.timeIntervalSince(now) ?? 300 > self.expirySafetyWindow
        {
            return credential
        }
        // FluidVoice imports the official client's access token but never copies
        // or refreshes its refresh token. That keeps credential ownership with
        // Gemini CLI and avoids shipping another application's OAuth client secret.
        throw AuthError.expiredCredential(
            "The Gemini subscription session has expired. Run `gemini` so the official client can refresh it, then verify again."
        )
    }

    private static func loadGeminiProject(accessToken: String, session: URLSession) async throws -> String {
        guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist") else {
            throw AuthError.geminiNotOnboarded
        }
        let configuredProject = try self.configuredGeminiProject()
        let projectValue: Any = configuredProject.map { $0 as Any } ?? NSNull()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("FluidVoice", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "cloudaicompanionProject": projectValue,
            "metadata": [
                "ideType": "IDE_UNSPECIFIED",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI",
                "duetProject": projectValue,
            ],
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AuthError.refreshFailed("Gemini Code Assist setup check failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw AuthError.geminiNotOnboarded
        }
        if let project = root["cloudaicompanionProject"] as? String, !project.isEmpty {
            return project
        }
        if let projectObject = root["cloudaicompanionProject"] as? [String: Any],
           let project = (projectObject["id"] as? String) ?? (projectObject["name"] as? String),
           !project.isEmpty
        {
            return project
        }
        if let configuredProject {
            return configuredProject
        }
        throw AuthError.geminiNotOnboarded
    }

    static func configuredGeminiProject(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String? {
        let project = [environment["GOOGLE_CLOUD_PROJECT"], environment["GOOGLE_CLOUD_PROJECT_ID"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let project else { return nil }
        guard !project.allSatisfy(\.isNumber) else {
            throw AuthError.invalidCredential(
                "Gemini requires a string Google Cloud project ID, not the numeric project number in GOOGLE_CLOUD_PROJECT."
            )
        }
        return project
    }

    private static func geminiAccountLabel() -> String {
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("google_accounts.json", isDirectory: false)
        guard let data = try? Data(contentsOf: fileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let active = root["active"] as? String,
              !active.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return "Google account" }
        return active.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Shared helpers

    private struct GenericPasswordItem {
        let account: String
        let data: Data
    }

    private static func readGenericPassword(service: String, account: String? = nil) throws -> GenericPasswordItem? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let dictionary = item as? [String: Any],
              let data = dictionary[kSecValueData as String] as? Data
        else {
            throw AuthError.keychainFailure("The official client's Keychain credential could not be read (status \(status)). Open the client and sign in again.")
        }
        return GenericPasswordItem(
            account: dictionary[kSecAttrAccount as String] as? String ?? account ?? "",
            data: data
        )
    }

    private static func readCredentialFile(_ fileURL: URL, missingMessage: String) throws -> Data {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AuthError.credentialNotFound(missingMessage)
        }
        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) <= self.maximumCredentialFileSize,
              let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe])
        else {
            throw AuthError.invalidCredential("The authentication file at \(fileURL.path) could not be read safely.")
        }
        return data
    }

    private static func jwtClaims(from token: String) -> [String: Any]? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }
        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload.append(String(repeating: "=", count: (4 - payload.count % 4) % 4))
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func jwtExpiry(from claims: [String: Any]?) -> Date? {
        guard let timestamp = (claims?["exp"] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private static func firstString(in objects: [[String: Any]?], keys: [String]) -> String? {
        for object in objects {
            for key in keys {
                if let value = object?[key] as? String,
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    return value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }

    private static func dateFromMillisecondsOrSeconds(_ value: Any?) -> Date? {
        let number: Double?
        if let value = value as? NSNumber {
            number = value.doubleValue
        } else if let value = value as? String {
            number = Double(value)
        } else {
            number = nil
        }
        guard var timestamp = number, timestamp > 0 else { return nil }
        if timestamp > 10_000_000_000 { timestamp /= 1000 }
        return Date(timeIntervalSince1970: timestamp)
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
