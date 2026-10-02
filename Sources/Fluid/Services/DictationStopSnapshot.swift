import AppKit

/// One immutable decision for a normal dictation, made before awaiting ASR finalization.
struct DictationStopSnapshot {
    let target: TypingService.RecordingTargetContext?
    private(set) var appInfo: (name: String, bundleId: String, windowTitle: String)
    let route: DictationProviderRoute
    let usesAI: Bool
    let systemPrompt: String
    let hasCustomPrompt: Bool
    private(set) var precedingText: String
    /// True when the preceding text must be read from the field focused at
    /// stop rather than reused from recording start.
    let readsContextFromFocusedField: Bool

    /// Fills the fields that need WindowServer or Accessibility round-trips.
    /// Called after the microphone has stopped so they never delay it.
    mutating func completeContext(windowTitle: String?, precedingText: String?) {
        if let windowTitle { self.appInfo.windowTitle = windowTitle }
        if let precedingText { self.precedingText = precedingText }
    }

    var focusTarget: TypingService.CapturedFocusTarget? {
        guard let target, let element = target.element else { return nil }
        return .init(pid: target.pid, window: target.window, element: element)
    }

    static func selectTarget(
        current: TypingService.RecordingTargetContext?,
        original: TypingService.RecordingTargetContext?,
        returnToStartingField: Bool,
        ownOverlayFocused: Bool
    ) -> TypingService.RecordingTargetContext? {
        returnToStartingField || ownOverlayFocused ? original : current
    }

    /// A prompt picked in the overlay during this dictation is stored under
    /// the app that was frontmost at the time. It must win even when the text
    /// is delivered to the field the recording started in.
    @MainActor
    static func promptResolutionAppID(slot: SettingsStore.DictationShortcutSlot, targetBundleID: String) -> String {
        let session = DictationAppSession.shared
        guard let visitedAppID = session.appID, session.choice(for: slot, appID: visitedAppID) != nil else {
            return targetBundleID
        }
        return visitedAppID
    }

    @MainActor
    static func capture(
        target: TypingService.RecordingTargetContext?,
        appInfo: (name: String, bundleId: String, windowTitle: String),
        slot: SettingsStore.DictationShortcutSlot,
        precedingText: String,
        readsContextFromFocusedField: Bool = false
    ) -> Self {
        let settings = SettingsStore.shared
        let promptAppID = Self.promptResolutionAppID(slot: slot, targetBundleID: appInfo.bundleId)
        let customPrompt = settings.resolvedDictationPromptProfile(for: slot, appBundleID: promptAppID)
            .flatMap { settings.shortcutOverrideSystemPrompt(for: $0) }
        return Self(
            target: target,
            appInfo: appInfo,
            route: DictationProviderRoute.resolve(settings: settings, dictationSlot: slot, appBundleID: promptAppID),
            usesAI: target != nil && DictationAIPostProcessingGate.isConfigured(for: slot, appBundleID: promptAppID),
            systemPrompt: customPrompt ?? settings.effectiveDictationSystemPrompt(for: slot, appBundleID: promptAppID),
            hasCustomPrompt: customPrompt != nil,
            precedingText: precedingText,
            readsContextFromFocusedField: readsContextFromFocusedField
        )
    }

    @MainActor
    func prepareDelivery(_ text: String, keepBackup: Bool, isOutputValid: @escaping @MainActor () -> Bool = { true }) async -> Bool {
        guard let target else { return false }
        return await PasteDeliveryCoordinator.shared.prepareForDelivery(text, preserveTranscriptOnClipboard: keepBackup, isOutputValid: isOutputValid) {
            await TypingService.prepareTargetForDelivery(target, isOutputValid: isOutputValid).isReady
        }
    }
}
