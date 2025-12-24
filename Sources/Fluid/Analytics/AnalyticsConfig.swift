import Foundation

struct AnalyticsConfig {
    let postHogApiKey: String
    let postHogHost: String

    /// Default EU ingestion host.
    static let defaultEUHost = "https://eu.i.posthog.com"

    static func fromBundle() -> AnalyticsConfig {
        let info = Bundle.main.infoDictionary ?? [:]
        let key = (info["POSTHOG_API_KEY"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let host = (info["POSTHOG_HOST"] as? String ?? AnalyticsConfig.defaultEUHost).trimmingCharacters(in: .whitespacesAndNewlines)
        return AnalyticsConfig(postHogApiKey: key, postHogHost: host.isEmpty ? AnalyticsConfig.defaultEUHost : host)
    }

    var isConfigured: Bool { !self.postHogApiKey.isEmpty }
}
