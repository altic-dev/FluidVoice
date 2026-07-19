import Foundation

// MARK: - Errors

enum KinwardClientError: Error, LocalizedError {
    case notConfigured
    case invalidURL
    case invalidResponse
    case httpError(Int, String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Kinward isn't configured yet. Set the backend URL, token, and household user id in Settings > Kinward."
        case .invalidURL:
            return "Kinward backend URL is invalid."
        case .invalidResponse:
            return "Kinward backend returned an unreadable response."
        case let .httpError(code, message):
            return "Kinward backend error (HTTP \(code)): \(message.trimmingCharacters(in: .whitespacesAndNewlines))"
        case let .networkError(error):
            return "Kinward backend unreachable: \(error.localizedDescription)"
        }
    }
}

// MARK: - Wire types

/// Mirrors `services/kinward/src/kinward/api/integration.py` ConversationRequest/ConversationResponse.
struct KinwardConversationResponse: Decodable {
    let conversationId: String?
    let outcome: String
    let responseText: String
    let mapped: Bool

    enum CodingKeys: String, CodingKey {
        case conversationId
        case outcome
        case responseText
        case mapped
    }
}

/// Terminal (non-"completed") outcomes the backend can return for a mapped or unmapped caller.
/// See `handle_conversation_request` in kinward/application/conversation.py.
enum KinwardConversationOutcome: String {
    case completed
    case unmapped
    case assistantNotFound = "assistant_not_found"
    case accessDenied = "access_denied"
}

// MARK: - KinwardClient

/// Talks directly to the Kinward backend's `/api/v1/integration/conversation` endpoint —
/// the same endpoint the Home Assistant integration's `conversation.kinward` entity calls
/// (see custom_components/kinward/api.py:async_send_conversation_message). This client
/// authenticates with its own dedicated integration token rather than an HA session, but
/// resolves to the exact same Kinward person/assistant/memory, since identity is keyed off
/// the stable `ha_user_id` string already stored on the household's PersonRecord, not off a
/// live HA login.
@MainActor
final class KinwardClient {
    static let shared = KinwardClient()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    /// Sends one conversational turn and returns the backend's reply text.
    /// Persists the returned `conversationId` (via SettingsStore) so the next call continues
    /// the same Kinward topic instead of starting a new one every turn.
    func sendMessage(_ text: String) async throws -> KinwardConversationResponse {
        let settings = SettingsStore.shared

        let baseURL = settings.kinwardBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let haUserID = settings.kinwardHAUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty, !haUserID.isEmpty,
              let token = try? KeychainService.shared.fetchKey(for: Self.keychainProviderID),
              let token, !token.isEmpty
        else {
            throw KinwardClientError.notConfigured
        }

        let endpoint = baseURL.hasSuffix("/")
            ? "\(baseURL)api/v1/integration/conversation"
            : "\(baseURL)/api/v1/integration/conversation"
        guard let url = URL(string: endpoint) else {
            throw KinwardClientError.invalidURL
        }

        var body: [String: Any] = [
            "haUserId": haUserID,
            "text": text,
            "language": "en",
        ]
        let conversationID = settings.kinwardConversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !conversationID.isEmpty {
            body["conversationId"] = conversationID
        }
        let assistantID = settings.kinwardAssistantID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !assistantID.isEmpty {
            body["assistantId"] = assistantID
        }
        // Deliberately omitted: `deviceId`. It only feeds ADR-002's area-based "recent
        // reference" heuristic on the HA side, and a laptop that moves around the house
        // (and leaves it) has no stable area to report.

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.session.data(for: request)
        } catch {
            throw KinwardClientError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw KinwardClientError.invalidResponse
        }
        guard http.statusCode < 400 else {
            let text = String(data: data, encoding: .utf8) ?? "unknown error"
            throw KinwardClientError.httpError(http.statusCode, text)
        }

        let decoded: KinwardConversationResponse
        do {
            decoded = try JSONDecoder().decode(KinwardConversationResponse.self, from: data)
        } catch {
            throw KinwardClientError.invalidResponse
        }

        // A new topic only gets a conversationId once `outcome == "completed"`; unmapped/
        // denied/not-found responses return null and must not clobber a real in-progress topic.
        if let newConversationID = decoded.conversationId {
            settings.kinwardConversationID = newConversationID
        }

        return decoded
    }

    /// Clears local topic continuity, so the next turn starts a brand new Kinward topic.
    func startNewConversation() {
        SettingsStore.shared.kinwardConversationID = ""
    }

    static let keychainProviderID = "kinward-integration-token"
}
