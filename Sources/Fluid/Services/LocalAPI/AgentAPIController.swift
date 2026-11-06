import Foundation

@MainActor
final class AgentAPIController: LocalAPIRouteHandler {
    private static let maxBodyBytes = 64 * 1024

    private struct PromptRequest: Decodable {
        let id: UUID
        let message: String
        let status: AgentPromptStatus?
    }

    private struct CancelRequest: Decodable {
        let id: UUID
    }

    private struct PromptResponse: Encodable {
        let text: String
    }

    private let bridge: any AgentPromptHandling
    private let isEnabled: @MainActor () -> Bool

    init(
        bridge: any AgentPromptHandling = AgentBridgeService.shared,
        isEnabled: @escaping @MainActor () -> Bool = { SettingsStore.shared.agentAPIEnabled }
    ) {
        self.bridge = bridge
        self.isEnabled = isEnabled
    }

    func handle(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        guard request.method == "POST" else { return LocalAPI.error("Method not allowed.", status: 405) }
        guard request.body.count <= Self.maxBodyBytes else {
            return LocalAPI.error("Request too large.", status: 413)
        }

        switch request.path {
        case "/v1/agent/prompt":
            return await self.prompt(request)
        case "/v1/agent/cancel":
            guard let payload = try? LocalAPI.decoder.decode(CancelRequest.self, from: request.body) else {
                return LocalAPI.error("A valid prompt ID is required.", status: 400)
            }
            self.bridge.cancelPrompt(id: payload.id)
            return LocalAPI.empty(status: 204)
        default:
            return LocalAPI.error("Route not found.", status: 404)
        }
    }

    private func prompt(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        guard self.isEnabled() else {
            return LocalAPI.error("Voice Agent API is disabled. Enable it in Settings → Experimental.", status: 503)
        }
        guard let payload = try? LocalAPI.decoder.decode(PromptRequest.self, from: request.body) else {
            return LocalAPI.error("Invalid JSON body.", status: 400)
        }
        let message = payload.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return LocalAPI.error("Field 'message' must be a non-empty string.", status: 400)
        }

        switch await self.bridge.prompt(id: payload.id, message: message, status: payload.status ?? .completed) {
        case let .replied(text):
            return LocalAPI.json(PromptResponse(text: text))
        case .cancelled:
            return LocalAPI.empty(status: 204)
        case .busy:
            return LocalAPI.error("Another agent prompt is already active.", status: 409)
        case let .unavailable(reason):
            return LocalAPI.error(reason, status: 503)
        }
    }
}
