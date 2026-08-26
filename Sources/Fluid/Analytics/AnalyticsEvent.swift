import Foundation

/// Allowed analytics event names.
enum AnalyticsEvent: String {
    case activeUser = "active_user"
    case usageDailySummary = "usage_daily_summary"
    case modelUsageDailySummary = "model_usage_daily_summary"
    case insertionLatencyDailySummary = "insertion_latency_daily_summary"
    case onboardingStarted = "onboarding_started"
    case onboardingStepViewed = "onboarding_step_viewed"
    case onboardingStepCompleted = "onboarding_step_completed"
    case onboardingCompleted = "onboarding_completed"
    case modelDownloadStarted = "model_download_started"
    case modelDownloadFinished = "model_download_finished"
}

enum AnalyticsActivityKind: String {
    case app
    case coreAction = "core_action"
}

enum AnalyticsUsageMode: String {
    case dictation
    case command
    case edit
    case meeting
}

enum AnalyticsModelRole: String {
    case transcription
    case aiPostProcessing = "ai_post_processing"
}

enum AnalyticsInsertionPath: String {
    case clipboard
    case direct
    case clipboardFallback = "clipboard_fallback"
    case notAttempted = "not_attempted"
}

enum AnalyticsInsertionOutcome: String {
    case dispatched
    case emptyText = "empty_text"
    case accessibilityNotTrusted = "accessibility_not_trusted"
    case clipboardSnapshotFailed = "clipboard_snapshot_failed"
    case clipboardWriteFailed = "clipboard_write_failed"
    case pasteCommandFailed = "paste_command_failed"
    case targetUnavailable = "target_unavailable"
    case targetRestoreFailed = "target_restore_failed"
}

struct AnalyticsModelDescriptor: Equatable {
    let provider: String
    let model: String

    init(provider: String, model: String) {
        self.provider = Self.normalized(provider)
        self.model = Self.normalized(model)
    }

    private static func normalized(_ value: String) -> String {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        return normalized.isEmpty ? "unknown" : normalized
    }
}

enum AnalyticsOnboardingStep: String {
    case welcome
    case language
    case voiceModel = "voice_model"
    case permissions
    case playground
    case aiEnhancement = "ai_enhancement"
}

enum AnalyticsOnboardingOrigin: String {
    case firstRun = "first_run"
    case manualRestart = "manual_restart"
}

enum AnalyticsOnboardingOutcome: String {
    case continued
    case skipped
    case completed
    case openedSettings = "opened_settings"
}

enum AnalyticsModelDownloadSource: String {
    case onboarding
    case settings
    case automatic
}

enum AnalyticsModelDownloadOutcome: String {
    case succeeded
    case failed
    case cancelled
    case interrupted
}
