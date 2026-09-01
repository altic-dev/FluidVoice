//
//  NotchOverlayManager.swift
//  Fluid
//
//  Created by Assistant
//

import AppKit
import Combine
import DynamicNotchKit
import SwiftUI

// MARK: - Overlay Mode

enum OverlayMode: String {
    case dictation = "Dictation"
    case edit = "Edit"
    case rewrite = "Rewrite"
    case write = "Write"
    case command = "Command"
}

@MainActor
final class NotchOverlayManager {
    static let shared = NotchOverlayManager()

    private typealias RecordingNotch = DynamicNotch<
        NotchExpandedView,
        NotchCompactLeadingView,
        NotchCompactTrailingView,
        NotchCompactBottomView
    >

    struct NotchPresentationPolicy: Equatable {
        let usesCompactPresentation: Bool
        let showsPromptSelector: Bool
        let showsStreamingPreview: Bool
        let showsModeLabel: Bool
        let allowsCommandExpansion: Bool
        let allowsCommandActions: Bool
        let allowsExpandedCommandOutput: Bool
    }

    private var notch: RecordingNotch?
    private var commandOutputNotch: DynamicNotch<
        NotchCommandOutputExpandedView,
        NotchCompactLeadingView,
        NotchCompactTrailingView,
        EmptyView
    >?
    private var currentMode: OverlayMode = .dictation

    /// Store last audio publisher for re-showing during processing
    private var lastAudioPublisher: AnyPublisher<CGFloat, Never>?

    /// Current audio publisher (can be updated for expanded notch recording)
    @Published private(set) var currentAudioPublisher: AnyPublisher<CGFloat, Never>?

    /// State machine to prevent race conditions
    private enum State {
        case idle
        case showing
        case visible
        case hiding
    }

    private var state: State = .idle
    private var commandOutputState: State = .idle

    /// Track if expanded command output is showing
    private(set) var isCommandOutputExpanded: Bool = false

    /// Track if bottom overlay is visible
    private(set) var isBottomOverlayVisible: Bool = false
    var isOverlayVisible: Bool { self.state == .visible }

    // Callbacks for command output interaction
    var onCommandOutputDismiss: (() -> Void)?
    var onCommandFollowUp: ((String) async -> Void)?
    var onNotchClicked: (() -> Void)? // Called when regular notch is clicked in command mode

    // Callbacks for chat management
    var onNewChat: (() -> Void)?
    var onSwitchChat: ((String) -> Void)?
    var onClearChat: (() -> Void)?

    // Generation counter to track show/hide cycles and prevent race conditions
    // Uses UInt64 to avoid overflow concerns in long-running sessions
    private var generation: UInt64 = 0
    private var commandOutputGeneration: UInt64 = 0
    private var isHideInProgress = false
    private var activeHideGeneration: UInt64?
    private var hideWaiters: [CheckedContinuation<RecordingOverlayHideOutcome, Never>] = []
    private var notchAnimationTask: Task<Void, Never>?
    private var notchPresentationTask: Task<Void, Never>?

    // Cancel shortcut monitors for dismissing notch / overlay
    private var globalEscapeMonitor: Any?
    private var localEscapeMonitor: Any?

    private(set) var currentNotchPresentationMode: SettingsStore.NotchPresentationMode = .standard
    private(set) var currentNotchPresentationPolicy = NotchPresentationPolicy.standard
    private(set) var currentScreenSupportsCompactPresentation = false
    private var presentationPolicyScreen: NSScreen?
    private static let transientOverlayStatusTexts: Set<String> = [
        "Transcribing",
        "Refining",
        "Thinking",
        "Working",
        "Transcribing...",
        "Refining...",
        "Thinking...",
        "Working...",
        "Reprocessing...",
    ]

    private init() {
        self.refreshNotchPresentationPolicy()
        self.setupEscapeKeyMonitors()
    }

    deinit {
        if let monitor = globalEscapeMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localEscapeMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Setup cancel shortcut monitors - both global (other apps) and local (our app)
    private func setupEscapeKeyMonitors() {
        let escapeHandler: (NSEvent) -> NSEvent? = { [weak self] event in
            guard SettingsStore.shared.cancelRecordingHotkeyShortcut.matches(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags
            ) else { return event }

            Task { @MainActor in
                guard self != nil else { return }
                NotchContentState.shared.onCancelRequested?()
            }
            return nil // Consume the event
        }

        // Global monitor - catches the cancel shortcut when OTHER apps have focus
        self.globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            _ = escapeHandler(event)
        }
    }

    func show(audioLevelPublisher: AnyPublisher<CGFloat, Never>, mode: OverlayMode) {
        self.refreshNotchPresentationPolicy()
        Self.overlayBench("show_called mode=\(mode.rawValue) state=\(self.state) commandExpanded=\(self.isCommandOutputExpanded)")
        self.cancelInFlightHideForNewPresentation()

        // Don't show regular notch if expanded command output is visible
        if self.isCommandOutputExpanded {
            // Just store the publisher for later use
            self.lastAudioPublisher = audioLevelPublisher
            Self.overlayBench("show_return reason=command_output_expanded")
            return
        }

        // A rapid restart should never wait for the previous notch animation.
        // Remove the old panel from the screen synchronously, then let its
        // internal cleanup finish without blocking the new presentation.
        if self.notch != nil || self.state != .idle {
            Self.overlayBench("show_replace_existing state=\(self.state) notchExists=\(self.notch != nil)")
            self.generation &+= 1
            self.retireCurrentNotchImmediately(reason: "rapid_restart")
        }

        self.showInternal(audioLevelPublisher: audioLevelPublisher, mode: mode)
    }

    private func showInternal(audioLevelPublisher: AnyPublisher<CGFloat, Never>, mode: OverlayMode) {
        Self.overlayBench("show_internal_enter mode=\(mode.rawValue) state=\(self.state)")
        guard self.state == .idle else { return }

        // Store for potential re-show during processing
        self.lastAudioPublisher = audioLevelPublisher

        // Start monitoring active app changes (updates icon in real-time)
        ActiveAppMonitor.shared.startMonitoring()
        let targetScreen = OverlayScreenResolver.screenForCurrentPointer()

        // Route to bottom overlay if user preference is set
        if SettingsStore.shared.overlayPosition == .bottom {
            Self.overlayBench("show_internal_route target=bottom")
            self.showBottomOverlay(audioLevelPublisher: audioLevelPublisher, mode: mode)
            return
        }

        // Otherwise show notch overlay (original behavior)
        Self.overlayBench("show_internal_route target=notch")
        self.showNotchOverlay(audioLevelPublisher: audioLevelPublisher, mode: mode, screen: targetScreen)
    }

    /// Show bottom overlay (alternative to notch)
    private func showBottomOverlay(audioLevelPublisher: AnyPublisher<CGFloat, Never>, mode: OverlayMode) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        Self.overlayBench("bottom_route_start mode=\(mode.rawValue)")
        self.generation &+= 1

        self.lastAudioPublisher = audioLevelPublisher
        self.currentMode = self.normalizedOverlayMode(mode)

        BottomOverlayWindowController.shared.show(audioPublisher: audioLevelPublisher, mode: self.currentMode)
        self.isBottomOverlayVisible = true
        Self.overlayBench("bottom_route_return elapsedMs=\(Self.elapsedMs(since: startedAt))")
    }

    /// Show notch overlay (original behavior)
    private func showNotchOverlay(audioLevelPublisher: AnyPublisher<CGFloat, Never>, mode: OverlayMode, screen: NSScreen?) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let targetScreen = screen ?? self.preferredPresentationScreen()
        self.presentationPolicyScreen = targetScreen
        self.refreshNotchPresentationPolicy(for: targetScreen)
        self.currentAudioPublisher = audioLevelPublisher
        // Hide bottom overlay if it was visible
        if self.isBottomOverlayVisible {
            BottomOverlayWindowController.shared.hide()
            self.isBottomOverlayVisible = false
        }

        // Increment generation for this operation
        self.generation &+= 1
        let currentGeneration = self.generation

        self.state = .showing
        self.currentMode = self.normalizedOverlayMode(mode)

        // Update shared content state immediately
        NotchContentState.shared.mode = self.currentMode
        self.syncPromptPickerMode(for: self.currentMode)
        NotchContentState.shared.updateTranscription("")

        // Create notch with SwiftUI views
        let newNotch = DynamicNotch(
            hoverBehavior: [], // Recording overlays should dismiss even if hover state gets stale.
            style: .auto
        ) {
            NotchExpandedView(audioPublisher: audioLevelPublisher)
        } compactLeading: {
            NotchCompactLeadingView()
        } compactTrailing: {
            NotchCompactTrailingView(audioPublisher: audioLevelPublisher)
        } compactBottom: {
            NotchCompactBottomView()
        }
        newNotch.transitionConfiguration = .init(
            openingAnimation: .snappy(duration: 0.1),
            closingAnimation: .linear(duration: 0.02),
            conversionAnimation: .snappy(duration: 0.1),
            skipIntermediateHides: true
        )

        self.notch = newNotch
        let shouldUseCompactPresentation = self.currentNotchPresentationPolicy.usesCompactPresentation
        let presentation = shouldUseCompactPresentation ? "compact" : "expanded"
        Self.overlayBench("notch_task_scheduled mode=\(self.currentMode.rawValue) presentation=\(presentation) screen=\(targetScreen.localizedName)")

        // Resolve presentation from policy so future notch modes don't require call-site changes.
        let animationTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            if shouldUseCompactPresentation {
                await newNotch.compact(on: targetScreen)
            } else {
                await newNotch.expand(on: targetScreen)
            }
        }
        self.notchAnimationTask = animationTask

        self.notchPresentationTask = Task { [weak self] in
            Self.overlayBench("notch_animation_start presentation=\(presentation)")

            // DynamicNotchKit applies a fixed 150 ms window fade. The content
            // animation is already running before the panel is ordered front,
            // so make that panel opaque on its first run-loop opportunity.
            let windowDeadline = ProcessInfo.processInfo.systemUptime + 0.05
            while newNotch.windowController?.window == nil,
                  !Task.isCancelled,
                  !animationTask.isCancelled,
                  ProcessInfo.processInfo.systemUptime < windowDeadline
            {
                await Task.yield()
            }
            guard !Task.isCancelled, !animationTask.isCancelled else { return }
            if newNotch.windowController?.window == nil {
                await animationTask.value
            }
            guard let window = newNotch.windowController?.window else {
                Self.overlayBench("notch_visible_drop reason=no_window")
                return
            }
            window.alphaValue = 1
            Self.overlayBench("notch_window_visible elapsedMs=\(Self.elapsedMs(since: startedAt))")

            await animationTask.value
            guard !Task.isCancelled else { return }
            Self.overlayBench("notch_animation_complete presentation=\(presentation) elapsedMs=\(Self.elapsedMs(since: startedAt))")
            // Only update state if we're still the active generation
            guard let self = self, self.generation == currentGeneration else {
                Self.overlayBench("notch_visible_drop reason=stale_generation")
                return
            }
            self.state = .visible
            Self.overlayBench("state_visible target=notch presentation=\(presentation)")
        }
    }

    func hide() {
        guard !self.isHideInProgress else { return }
        self.isHideInProgress = true
        self.generation &+= 1
        let currentGeneration = self.generation
        self.activeHideGeneration = currentGeneration
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.performHideAndWait(generation: currentGeneration)
            self.completeHideOperation(generation: currentGeneration, outcome: outcome)
        }
    }

    /// Reports whether the active overlay finished hiding or a newer
    /// presentation superseded this request.
    func hideAndWait() async -> RecordingOverlayHideOutcome {
        if self.isHideInProgress {
            return await withCheckedContinuation { continuation in
                self.hideWaiters.append(continuation)
            }
        }

        self.isHideInProgress = true
        self.generation &+= 1
        let currentGeneration = self.generation
        self.activeHideGeneration = currentGeneration
        let outcome = await self.performHideAndWait(generation: currentGeneration)
        self.completeHideOperation(generation: currentGeneration, outcome: outcome)
        return outcome
    }

    private func performHideAndWait(generation currentGeneration: UInt64) async -> RecordingOverlayHideOutcome {
        let startedAt = ProcessInfo.processInfo.systemUptime
        Self.overlayBench("hide_called state=\(self.state) bottomVisible=\(self.isBottomOverlayVisible)")
        guard self.generation == currentGeneration else {
            Self.overlayBench("hide_return reason=stale_generation")
            return .superseded
        }

        // Stop monitoring active app changes
        ActiveAppMonitor.shared.stopMonitoring()

        // Hide bottom overlay if visible
        if self.isBottomOverlayVisible {
            let bottomOutcome = await BottomOverlayWindowController.shared.hideAndWait()
            guard bottomOutcome == .hidden else {
                Self.overlayBench("hide_return reason=bottom_superseded")
                return .superseded
            }
            guard self.generation == currentGeneration else {
                Self.overlayBench("hide_return reason=stale_generation")
                return .superseded
            }
            self.isBottomOverlayVisible = false
        }

        // Safety: reset processing state when hiding
        NotchContentState.shared.setProcessing(false)
        NotchContentState.shared.setSpokenSendIndicatorState(.hidden)

        // Handle visible or showing states (can hide while still expanding)
        guard self.state == .visible || self.state == .showing, self.notch != nil else {
            // A bottom overlay has already completed its dismissal. Clean up
            // any inconsistent notch state without scheduling another task.
            Self.overlayBench("hide_return reason=not_visible state=\(self.state) notchExists=\(self.notch != nil)")
            self.retireCurrentNotchImmediately(reason: "inconsistent_state")
            Self.overlayBench("hide_complete target=none elapsedMs=\(Self.elapsedMs(since: startedAt))")
            return .hidden
        }

        self.state = .hiding
        Self.overlayBench("hide_visual_start")
        self.retireCurrentNotchImmediately(reason: "hide")
        Self.overlayBench("hide_visual_complete elapsedMs=\(Self.elapsedMs(since: startedAt))")
        return .hidden
    }

    private func completeHideOperation(generation: UInt64, outcome: RecordingOverlayHideOutcome) {
        guard self.activeHideGeneration == generation else { return }
        self.activeHideGeneration = nil
        self.isHideInProgress = false
        let waiters = self.hideWaiters
        self.hideWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume(returning: outcome) }
    }

    private func cancelInFlightHideForNewPresentation() {
        guard self.isHideInProgress else { return }
        self.activeHideGeneration = nil
        self.isHideInProgress = false
        let waiters = self.hideWaiters
        self.hideWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume(returning: .superseded) }
        Self.overlayBench("hide_cancelled_for_new_presentation")
    }

    private func retireCurrentNotchImmediately(reason: String) {
        guard let existingNotch = self.notch else {
            self.state = .idle
            return
        }

        existingNotch.windowController?.window?.orderOut(nil)
        self.notchAnimationTask?.cancel()
        self.notchAnimationTask = nil
        self.notchPresentationTask?.cancel()
        self.notchPresentationTask = nil
        self.notch = nil
        self.state = .idle
        Self.overlayBench("notch_retired reason=\(reason)")

        Task {
            await existingNotch.hide()
            Self.overlayBench("notch_retire_cleanup_complete reason=\(reason)")
        }
    }

    func setMode(_ mode: OverlayMode) {
        self.refreshNotchPresentationPolicy()
        Self.overlayBench("set_mode mode=\(mode.rawValue)")

        // Always update NotchContentState to ensure UI stays in sync
        // (can get out of sync during show/hide transitions)
        let normalized = self.normalizedOverlayMode(mode)
        self.currentMode = normalized
        NotchContentState.shared.mode = normalized
        self.syncPromptPickerMode(for: normalized)
    }

    func switchLiveOverlayMode(to promptMode: SettingsStore.PromptMode) {
        guard !NotchContentState.shared.isProcessing else { return }
        switch promptMode.normalized {
        case .dictate:
            self.setMode(.dictation)
        case .edit:
            self.setMode(.edit)
        case .write, .rewrite:
            self.setMode(.edit)
        }
    }

    func updateTranscriptionText(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.isEmpty || Self.transientOverlayStatusTexts.contains(trimmedText) {
            Self.overlayBench("text_update status=\(trimmedText.isEmpty ? "empty" : trimmedText)")
        }

        guard self.shouldShowOrTrackLivePreviewText else {
            if trimmedText.isEmpty || Self.transientOverlayStatusTexts.contains(trimmedText) {
                NotchContentState.shared.updateTranscription(text)
            } else if !NotchContentState.shared.transcriptionText.isEmpty {
                NotchContentState.shared.updateTranscription("")
            }
            return
        }
        NotchContentState.shared.updateTranscription(text)
    }

    func setProcessing(_ processing: Bool) {
        Self.overlayBench("set_processing processing=\(processing) state=\(self.state) bottomVisible=\(self.isBottomOverlayVisible) commandExpanded=\(self.isCommandOutputExpanded)")
        NotchContentState.shared.setProcessing(processing)

        // If expanded command output is showing, don't mess with regular notch
        if self.isCommandOutputExpanded {
            Self.overlayBench("set_processing_return reason=command_output_expanded")
            return
        }

        // If bottom overlay is visible, update its processing state
        if self.isBottomOverlayVisible {
            BottomOverlayWindowController.shared.setProcessing(processing)
            Self.overlayBench("set_processing_forwarded target=bottom")
            return
        }

        if processing {
            // If notch isn't visible, re-show it for processing state
            if self.state == .idle || self.state == .hiding {
                Self.overlayBench("set_processing_reshow state=\(self.state)")
                // Use stored publisher or create empty one
                let publisher = self.lastAudioPublisher ?? Empty<CGFloat, Never>().eraseToAnyPublisher()
                self.show(audioLevelPublisher: publisher, mode: self.currentMode)
            }
        }
    }

    private static func overlayBench(_ message: String) {
        DebugLogger.shared.benchmark("OVERLAY_BENCH", message: "notch \(message)", source: "OverlayBenchmark")
    }

    private static func elapsedMs(since start: TimeInterval) -> Int {
        Int(((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded())
    }

    // MARK: - Expanded Command Output

    /// Show expanded command output notch
    func showExpandedCommandOutput() {
        guard self.canShowExpandedCommandOutput else { return }

        // Hide regular notch first if visible
        if self.notch != nil {
            self.hide()
        }

        // Wait a bit for cleanup
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            await self?.showExpandedCommandOutputInternal()
        }
    }

    private func showExpandedCommandOutputInternal() async {
        guard self.canShowExpandedCommandOutput else { return }
        guard self.commandOutputState == .idle else { return }

        self.commandOutputGeneration &+= 1
        let currentGeneration = self.commandOutputGeneration

        self.commandOutputState = .showing
        self.isCommandOutputExpanded = true

        // Update content state
        NotchContentState.shared.mode = .command
        NotchContentState.shared.isExpandedForCommandOutput = true

        let publisher = self.lastAudioPublisher ?? Empty<CGFloat, Never>().eraseToAnyPublisher()

        let newNotch = DynamicNotch(
            hoverBehavior: [], // No keepVisible - allows closing with X/Escape even when cursor is on notch
            style: .auto
        ) {
            NotchCommandOutputExpandedView(
                audioPublisher: publisher,
                onDismiss: { [weak self] in
                    Task { @MainActor in
                        self?.hideExpandedCommandOutput()
                        self?.onCommandOutputDismiss?()
                    }
                },
                onSubmit: { [weak self] text in
                    guard let self, self.allowsCommandNotchActions else { return }
                    await self.onCommandFollowUp?(text)
                },
                onNewChat: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.allowsCommandNotchActions else { return }
                        self.onNewChat?()
                        // Refresh recent chats in notch state
                        NotchContentState.shared.refreshRecentChats()
                    }
                },
                onSwitchChat: { [weak self] chatID in
                    Task { @MainActor in
                        guard let self, self.allowsCommandNotchActions else { return }
                        self.onSwitchChat?(chatID)
                        // Refresh recent chats in notch state
                        NotchContentState.shared.refreshRecentChats()
                    }
                },
                onClearChat: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.allowsCommandNotchActions else { return }
                        self.onClearChat?()
                    }
                }
            )
        } compactLeading: {
            NotchCompactLeadingView()
        } compactTrailing: {
            NotchCompactTrailingView(audioPublisher: publisher)
        } compactBottom: {
            EmptyView()
        }

        self.commandOutputNotch = newNotch

        if let screen = self.presentationPolicyScreen ?? OverlayScreenResolver.screenForCurrentPointer() {
            await newNotch.expand(on: screen)
        } else {
            await newNotch.expand()
        }

        guard self.commandOutputGeneration == currentGeneration else { return }
        self.commandOutputState = .visible
    }

    private func syncPromptPickerMode(for mode: OverlayMode) {
        switch mode {
        case .dictation:
            NotchContentState.shared.promptPickerMode = .dictate
        case .edit, .write, .rewrite:
            NotchContentState.shared.promptPickerMode = .edit
        case .command:
            break
        }
    }

    private func normalizedOverlayMode(_ mode: OverlayMode) -> OverlayMode {
        switch mode {
        case .write, .rewrite:
            return .edit
        case .dictation, .edit, .command:
            return mode
        }
    }

    /// Hide expanded command output notch - force close regardless of hover state
    func hideExpandedCommandOutput() {
        self.commandOutputGeneration &+= 1
        let currentGeneration = self.commandOutputGeneration

        // Force cleanup state immediately
        self.isCommandOutputExpanded = false
        NotchContentState.shared.collapseCommandOutput()

        guard self.commandOutputState == .visible || self.commandOutputState == .showing,
              let currentNotch = commandOutputNotch
        else {
            self.commandOutputState = .idle
            return
        }

        self.commandOutputState = .hiding

        // Store reference and nil out immediately to prevent hover from keeping it alive
        let notchToHide = currentNotch
        self.commandOutputNotch = nil

        Task { [weak self] in
            // Try to hide gracefully, but we've already removed our reference
            await notchToHide.hide()
            guard let self = self, self.commandOutputGeneration == currentGeneration else { return }
            self.commandOutputState = .idle
        }
    }

    /// Toggle expanded command output (for hotkey handling)
    func toggleExpandedCommandOutput() {
        if self.isCommandOutputExpanded {
            self.hideExpandedCommandOutput()
        } else if self.canShowExpandedCommandOutput,
                  NotchContentState.shared.commandConversationHistory.isEmpty == false
        {
            // Only show if there's history to show
            self.showExpandedCommandOutput()
        }
    }

    var canShowExpandedCommandOutput: Bool {
        self.refreshNotchPresentationPolicy()
        return self.currentNotchPresentationPolicy.allowsExpandedCommandOutput
    }

    var canHandleNotchCommandTap: Bool {
        self.refreshNotchPresentationPolicy()
        return self.currentNotchPresentationPolicy.allowsCommandExpansion &&
            self.currentNotchPresentationPolicy.allowsCommandActions
    }

    var allowsCommandNotchActions: Bool {
        self.refreshNotchPresentationPolicy()
        return self.currentNotchPresentationPolicy.allowsCommandActions
    }

    var supportsCommandNotchUI: Bool {
        self.refreshNotchPresentationPolicy()
        return self.currentNotchPresentationPolicy.allowsCommandExpansion ||
            self.currentNotchPresentationPolicy.allowsExpandedCommandOutput ||
            self.currentNotchPresentationPolicy.allowsCommandActions
    }

    var shouldShowOrTrackLivePreviewText: Bool {
        guard SettingsStore.shared.enableStreamingPreview else { return false }
        if SettingsStore.shared.overlayPosition == .bottom {
            return true
        }

        self.refreshNotchPresentationPolicy()
        return self.currentNotchPresentationPolicy.showsStreamingPreview
    }

    var shouldSyncCommandConversationToNotch: Bool {
        if SettingsStore.shared.overlayPosition == .bottom {
            return true
        }

        guard self.enableNotchFeatures else { return false }

        self.refreshNotchPresentationPolicy()
        return self.currentNotchPresentationPolicy.allowsExpandedCommandOutput ||
            self.currentNotchPresentationPolicy.allowsCommandActions
    }

    private var enableNotchFeatures: Bool {
        SettingsStore.shared.overlayPosition == .top || self.supportsCommandNotchUI
    }

    /// Check if any notch (regular or expanded) is visible
    var isAnyNotchVisible: Bool {
        return self.state == .visible || self.state == .showing || self.isCommandOutputExpanded
    }

    /// Update audio publisher for expanded notch (when recording starts within it)
    func updateAudioPublisher(_ publisher: AnyPublisher<CGFloat, Never>) {
        self.lastAudioPublisher = publisher
        self.currentAudioPublisher = publisher
    }

    private func preferredPresentationScreen() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        if let screenUnderMouse = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
            return screenUnderMouse
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    private func supportsCompactPresentation(on screen: NSScreen) -> Bool {
        screen.auxiliaryTopLeftArea?.width != nil && screen.auxiliaryTopRightArea?.width != nil
    }

    private func refreshNotchPresentationPolicy(for screen: NSScreen? = nil) {
        let mode = SettingsStore.shared.notchPresentationMode
        self.currentNotchPresentationMode = mode
        let resolvedScreen = screen ?? self.presentationPolicyScreen ?? self.preferredPresentationScreen()
        self.currentScreenSupportsCompactPresentation = self.supportsCompactPresentation(on: resolvedScreen)
        self.currentNotchPresentationPolicy = .forMode(
            mode,
            supportsCompactPresentation: self.currentScreenSupportsCompactPresentation
        )
    }
}

private extension NotchOverlayManager.NotchPresentationPolicy {
    static let standard = Self(
        usesCompactPresentation: false,
        showsPromptSelector: true,
        showsStreamingPreview: true,
        showsModeLabel: true,
        allowsCommandExpansion: true,
        allowsCommandActions: true,
        allowsExpandedCommandOutput: true
    )

    static let minimal = Self(
        usesCompactPresentation: true,
        showsPromptSelector: false,
        showsStreamingPreview: true,
        showsModeLabel: true,
        allowsCommandExpansion: false,
        allowsCommandActions: false,
        allowsExpandedCommandOutput: false
    )

    static func forMode(_ mode: SettingsStore.NotchPresentationMode, supportsCompactPresentation: Bool) -> Self {
        switch mode {
        case .standard:
            return .standard
        case .minimal:
            return supportsCompactPresentation ? .minimal : .standard
        }
    }
}
