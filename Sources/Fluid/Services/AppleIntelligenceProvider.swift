import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device system language model as a built-in AI enhancement provider.
/// Every other file refers to the provider through these constants.
enum AppleIntelligenceProvider {
    static let providerID = "apple-intelligence"
    /// Placeholder ID that pre-#604 builds stored for pickers that could not use the provider.
    static let retiredDisabledProviderID = "apple-intelligence-disabled"
    static let displayName = "Apple Intelligence"
    static let modelID = "apple-system-model"
    static let modelDisplayName = "System Language Model"
    static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")

    /// Tests replace this; production asks the system model on every call because the user
    /// can turn Apple Intelligence off, or the model can finish downloading, at any time.
    static var availabilityProvider: @MainActor () -> AppleIntelligenceAvailability = { AppleIntelligenceProvider.systemAvailability() }

    static var availability: AppleIntelligenceAvailability {
        self.availabilityProvider()
    }

    static var isSupportedOS: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return true
        }
        #endif
        return false
    }

    static func matches(_ providerID: String) -> Bool {
        providerID.trimmingCharacters(in: .whitespacesAndNewlines) == self.providerID
    }

    private static func systemAvailability() -> AppleIntelligenceAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return AppleIntelligenceAvailability(AppleIntelligenceTextEngine.makeModel().availability)
        }
        #endif
        return .unsupportedOS
    }
}

nonisolated enum AppleIntelligenceAvailability: Equatable {
    case available
    case unsupportedOS
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unavailable

    var isAvailable: Bool {
        self == .available
    }

    var unavailableReason: String? {
        switch self {
        case .available:
            return nil
        case .unsupportedOS:
            return "Apple Intelligence requires macOS 26 or later"
        case .deviceNotEligible:
            return "This Mac doesn't support Apple Intelligence"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is turned off. Turn it on in System Settings > Apple Intelligence & Siri"
        case .modelNotReady:
            return "Apple Intelligence is still downloading its model"
        case .unavailable:
            return "Apple Intelligence is unavailable"
        }
    }

    var shortStatus: String {
        switch self {
        case .available: "On-device, ready"
        case .unsupportedOS: "Requires macOS 26"
        case .deviceNotEligible: "Not supported on this Mac"
        case .appleIntelligenceNotEnabled: "Turned off in System Settings"
        case .modelNotReady: "Model downloading"
        case .unavailable: "Unavailable"
        }
    }

    var logValue: String {
        switch self {
        case .available: "available"
        case .unsupportedOS: "unsupportedOS"
        case .deviceNotEligible: "deviceNotEligible"
        case .appleIntelligenceNotEnabled: "appleIntelligenceNotEnabled"
        case .modelNotReady: "modelNotReady"
        case .unavailable: "unavailable"
        }
    }
}

nonisolated enum AppleIntelligenceFailure: Equatable {
    case unavailable(AppleIntelligenceAvailability)
    case contextWindowExceeded
    case guardrailViolation
    case refusal
    case unsupportedLanguage
    case assetsUnavailable
    case rateLimited
    case concurrentRequests
    case unknown(String)

    var message: String {
        switch self {
        case let .unavailable(availability):
            return availability.unavailableReason ?? "Apple Intelligence is unavailable"
        case .contextWindowExceeded:
            return "This text is too long for Apple Intelligence's on-device model"
        case .guardrailViolation:
            return "Apple Intelligence's safety guardrails blocked this text"
        case .refusal:
            return "Apple Intelligence declined to process this text"
        case .unsupportedLanguage:
            return "Apple Intelligence doesn't support this language"
        case .assetsUnavailable:
            return "Apple Intelligence's on-device model isn't ready yet. Try again after it finishes downloading"
        case .rateLimited:
            return "Apple Intelligence is busy. Try again in a moment"
        case .concurrentRequests:
            return "Apple Intelligence is still processing another request"
        case let .unknown(details):
            return "Apple Intelligence failed: \(details)"
        }
    }

    var logValue: String {
        switch self {
        case let .unavailable(availability): "unavailable(\(availability.logValue))"
        case .contextWindowExceeded: "contextWindowExceeded"
        case .guardrailViolation: "guardrailViolation"
        case .refusal: "refusal"
        case .unsupportedLanguage: "unsupportedLanguage"
        case .assetsUnavailable: "assetsUnavailable"
        case .rateLimited: "rateLimited"
        case .concurrentRequests: "concurrentRequests"
        case .unknown: "unknown"
        }
    }
}

/// What the on-device model receives, kept free of FoundationModels types so it can be tested anywhere.
struct AppleIntelligenceRequest: Equatable {
    struct Turn: Equatable {
        let prompt: String
        let response: String
    }

    let instructions: String
    var history: [Turn] = []
    let prompt: String
}

/// The single call into FoundationModels, replaceable in tests.
protocol AppleIntelligenceGenerating {
    func respond(to request: AppleIntelligenceRequest) async throws -> String
}

enum AppleIntelligenceService {
    static func transform(_ request: AppleIntelligenceRequest) async throws -> String {
        try await self.transform(request, generator: AppleIntelligenceSystemGenerator())
    }

    /// Returns sanitized model output, or throws an `AIProcessingError` so callers keep their
    /// raw-transcript fallback. Model text never reaches the caller when generation fails.
    static func transform(
        _ request: AppleIntelligenceRequest,
        generator: any AppleIntelligenceGenerating
    ) async throws -> String {
        let startedAt = ProcessInfo.processInfo.systemUptime
        func elapsedMilliseconds() -> Int {
            Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded())
        }

        let output: String
        do {
            output = try await generator.respond(to: request)
        } catch {
            let mapped = AppleIntelligenceErrorMapping.map(error)
            let reason = if case let .appleIntelligence(failure)? = mapped as? AIProcessingError {
                failure.logValue
            } else {
                String(describing: type(of: mapped))
            }
            DebugLogger.shared.info(
                "Apple Intelligence request failed reason=\(reason) latencyMs=\(elapsedMilliseconds()) promptChars=\(request.prompt.count)",
                source: "AppleIntelligence"
            )
            throw mapped
        }

        let sanitized = AppleIntelligencePrompt.sanitize(output)
        guard !sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            DebugLogger.shared.info(
                "Apple Intelligence returned no usable text latencyMs=\(elapsedMilliseconds()) outputChars=\(output.count)",
                source: "AppleIntelligence"
            )
            throw AIProcessingError.emptyResponse
        }
        DebugLogger.shared.info(
            "Apple Intelligence request finished availability=available latencyMs=\(elapsedMilliseconds()) " +
                "instructionChars=\(request.instructions.count) promptChars=\(request.prompt.count) " +
                "historyTurns=\(request.history.count) outputChars=\(sanitized.count)",
            source: "AppleIntelligence"
        )
        return sanitized
    }
}

struct AppleIntelligenceSystemGenerator: AppleIntelligenceGenerating {
    func respond(to request: AppleIntelligenceRequest) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return try await AppleIntelligenceTextEngine().respond(to: request)
        }
        #endif
        throw AIProcessingError.appleIntelligence(.unavailable(.unsupportedOS))
    }
}

enum AppleIntelligenceErrorMapping {
    static func map(_ error: Error) -> Error {
        if error is CancellationError || error is AIProcessingError {
            return error
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), let failure = self.failure(forFoundationModelsError: error) {
            return AIProcessingError.appleIntelligence(failure)
        }
        #endif
        return AIProcessingError.appleIntelligence(.unknown(error.localizedDescription))
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
extension AppleIntelligenceAvailability {
    init(_ availability: SystemLanguageModel.Availability) {
        switch availability {
        case .available:
            self = .available
        case let .unavailable(reason):
            switch reason {
            case .deviceNotEligible:
                self = .deviceNotEligible
            case .appleIntelligenceNotEnabled:
                self = .appleIntelligenceNotEnabled
            case .modelNotReady:
                self = .modelNotReady
            @unknown default:
                self = .unavailable
            }
        }
    }
}

@available(macOS 26.0, *)
extension AppleIntelligenceErrorMapping {
    static func failure(forFoundationModelsError error: Error) -> AppleIntelligenceFailure? {
        #if compiler(>=6.4)
        if #available(macOS 27.0, *), let failure = self.failure(forMacOS27Error: error) {
            return failure
        }
        #endif
        guard let error = error as? LanguageModelSession.GenerationError else { return nil }
        switch error {
        case .exceededContextWindowSize:
            return .contextWindowExceeded
        case .guardrailViolation:
            return .guardrailViolation
        case .refusal:
            return .refusal
        case .unsupportedLanguageOrLocale:
            return .unsupportedLanguage
        case .assetsUnavailable:
            return .assetsUnavailable
        case .rateLimited:
            return .rateLimited
        case .concurrentRequests:
            return .concurrentRequests
        case .unsupportedGuide, .decodingFailure:
            return .unknown(error.localizedDescription)
        @unknown default:
            return .unknown(error.localizedDescription)
        }
    }

    #if compiler(>=6.4)
    /// macOS 27 reports generation failures through these types instead of `GenerationError`.
    @available(macOS 27.0, *)
    private static func failure(forMacOS27Error error: Error) -> AppleIntelligenceFailure? {
        if let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded:
                return .contextWindowExceeded
            case .guardrailViolation:
                return .guardrailViolation
            case .refusal:
                return .refusal
            case .unsupportedLanguageOrLocale:
                return .unsupportedLanguage
            case .rateLimited:
                return .rateLimited
            case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide, .timeout:
                return .unknown(error.localizedDescription)
            @unknown default:
                return .unknown(error.localizedDescription)
            }
        }
        if let error = error as? SystemLanguageModel.Error, case .assetsUnavailable = error {
            return .assetsUnavailable
        }
        if let error = error as? LanguageModelSession.Error, case .concurrentRequests = error {
            return .concurrentRequests
        }
        return nil
    }
    #endif
}

@available(macOS 26.0, *)
struct AppleIntelligenceTextEngine: AppleIntelligenceGenerating {
    private static let temperature = 0.2

    static func makeModel() -> SystemLanguageModel {
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }

    func respond(to request: AppleIntelligenceRequest) async throws -> String {
        let model = Self.makeModel()
        let availability = AppleIntelligenceAvailability(model.availability)
        guard availability.isAvailable else {
            throw AIProcessingError.appleIntelligence(.unavailable(availability))
        }

        let entries = Self.transcriptEntries(for: request)
        try await Self.checkContextBudget(model: model, entries: entries, prompt: request.prompt)

        // A new session per request keeps history explicit and means no session ever
        // receives overlapping requests.
        let session = request.history.isEmpty
            ? LanguageModelSession(model: model, instructions: Instructions(request.instructions))
            : LanguageModelSession(model: model, transcript: Transcript(entries: entries))
        let response = try await session.respond(
            to: Prompt(request.prompt),
            options: GenerationOptions(temperature: Self.temperature)
        )
        return response.content
    }

    static func transcriptEntries(for request: AppleIntelligenceRequest) -> [Transcript.Entry] {
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(segments: [Self.textSegment(request.instructions)], toolDefinitions: [])),
        ]
        for turn in request.history {
            entries.append(.prompt(Transcript.Prompt(segments: [Self.textSegment(turn.prompt)])))
            entries.append(.response(Transcript.Response(assetIDs: [], segments: [Self.textSegment(turn.response)])))
        }
        return entries
    }

    private static func textSegment(_ content: String) -> Transcript.Segment {
        .text(Transcript.TextSegment(content: content))
    }

    /// Fails before generating when the request cannot fit, instead of letting the model run
    /// out of room mid-answer. Output is assumed to be about as long as the bounded prompt.
    private static func checkContextBudget(
        model: SystemLanguageModel,
        entries: [Transcript.Entry],
        prompt: String
    ) async throws {
        #if compiler(>=6.3)
        guard #available(macOS 26.4, *) else { return }
        let inputTokens: Int
        let promptTokens: Int
        do {
            let promptEntry = Transcript.Entry.prompt(Transcript.Prompt(segments: [Self.textSegment(prompt)]))
            inputTokens = try await model.tokenCount(for: entries + [promptEntry])
            promptTokens = try await model.tokenCount(for: Prompt(prompt))
        } catch {
            DebugLogger.shared.debug(
                "Apple Intelligence token count unavailable; relying on generation errors: \(error.localizedDescription)",
                source: "AppleIntelligence"
            )
            return
        }
        guard inputTokens + promptTokens <= model.contextSize else {
            DebugLogger.shared.info(
                "Apple Intelligence request exceeds context inputTokens=\(inputTokens) reservedOutputTokens=\(promptTokens) contextSize=\(model.contextSize)",
                source: "AppleIntelligence"
            )
            throw AIProcessingError.appleIntelligence(.contextWindowExceeded)
        }
        #endif
    }
}
#endif
