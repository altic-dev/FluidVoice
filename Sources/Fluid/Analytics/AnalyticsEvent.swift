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
    case onboardingTryoutFinished = "onboarding_tryout_finished"
    case modelDownloadStarted = "model_download_started"
    case modelDownloadFinished = "model_download_finished"
    case dictationPerformanceDailySummary = "dictation_performance_daily_summary"
}

enum AnalyticsBuildPolicy {
    // Release artifacts identify the beta cohort in their installed version
    // (e.g. 1.6.10-beta.1). The updater preference only selects future updates;
    // enabling it on a stable installation must not turn on beta telemetry.
    static func automaticallyCollectsDictationPerformance(appVersion: String) -> Bool {
        appVersion
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .contains("beta")
    }
}

enum DictationPerformanceLogSummary {
    static func line(
        asrMilliseconds: Int?,
        aiMilliseconds: Int?,
        readyMilliseconds: Int,
        outcome: String
    ) -> String {
        let asr = asrMilliseconds ?? -1
        let ai = aiMilliseconds ?? -1
        let measured = max(asr, 0) + max(ai, 0)
        let appOverhead = max(readyMilliseconds - measured, 0)
        let slowest: String
        if ai >= asr, ai >= appOverhead, ai >= 0 {
            slowest = "ai"
        } else if asr >= appOverhead, asr >= 0 {
            slowest = "asr"
        } else {
            slowest = "app_overhead"
        }
        return "DICTATION_SUMMARY asrMs=\(asr) aiMs=\(ai) "
            + "appOverheadMs=\(appOverhead) readyMs=\(readyMilliseconds) "
            + "slowest=\(slowest) outcome=\(outcome)"
    }
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

enum AnalyticsFluidIntelligenceModel: String {
    case pico
    case mini

    init?(modelID: String?) {
        guard let modelID else { return nil }
        switch modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "fluid-1-pico-96k-dflash":
            self = .pico
        case "fluid-1-mini-96k-dflash":
            self = .mini
        default:
            return nil
        }
    }
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
    case noEditableTarget = "no_editable_target"
    case pasteNotLanded = "paste_not_landed"
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
}

enum AnalyticsOnboardingTryoutOutcome: String {
    case success
    case empty
    case error
    case cancelled
    case skippedBeforeAttempt = "skipped_before_attempt"
    case skippedAfterAttempt = "skipped_after_attempt"
}

enum AnalyticsOnboardingTryoutStartMethod: String {
    case hotkey
    case button
}

enum AnalyticsOnboardingTryoutFailureStage: String {
    case audioStart = "audio_start"
    case transcription
    case postProcessing = "post_processing"
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
