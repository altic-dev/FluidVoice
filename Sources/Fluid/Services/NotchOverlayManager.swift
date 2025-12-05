//
//  NotchOverlayManager.swift
//  Fluid
//
//  Created by Assistant
//

import DynamicNotchKit
import SwiftUI
import Combine
import AppKit

// MARK: - Overlay Mode
enum OverlayMode: String {
    case dictation = "Dictation"
    case rewrite = "Rewrite"
    case write = "Write"
    case command = "Command"
}

@MainActor
final class NotchOverlayManager {
    static let shared = NotchOverlayManager()

    // Bottom overlay for regular recording
    private let bottomOverlay = BottomOverlayWindowController.shared

    // DynamicNotchKit only used for expanded command output
    private var commandOutputNotch: DynamicNotch<NotchCommandOutputExpandedView, NotchCompactLeadingView, NotchCompactTrailingView>?
    private var currentMode: OverlayMode = .dictation

    // Store last audio publisher for re-showing during processing
    private var lastAudioPublisher: AnyPublisher<CGFloat, Never>?

    // Current audio publisher (can be updated for expanded notch recording)
    @Published private(set) var currentAudioPublisher: AnyPublisher<CGFloat, Never>?

    // State for bottom overlay
    private var isBottomOverlayVisible: Bool = false

    // State machine for command output notch
    private enum State {
        case idle
        case showing
        case visible
        case hiding
    }
    private var commandOutputState: State = .idle

    // Track if expanded command output is showing
    private(set) var isCommandOutputExpanded: Bool = false

    // Callbacks for command output interaction
    var onCommandOutputDismiss: (() -> Void)?
    var onCommandFollowUp: ((String) async -> Void)?
    var onNotchClicked: (() -> Void)?  // Called when regular notch is clicked in command mode

    // Callbacks for chat management
    var onNewChat: (() -> Void)?
    var onSwitchChat: ((String) -> Void)?
    var onClearChat: (() -> Void)?

    // Generation counter for command output notch
    private var commandOutputGeneration: UInt64 = 0

    // Escape key monitors for dismissing overlays
    private var globalEscapeMonitor: Any?
    private var localEscapeMonitor: Any?

    private init() {
        setupEscapeKeyMonitors()
    }

    deinit {
        if let monitor = globalEscapeMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localEscapeMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Setup escape key monitors - both global (other apps) and local (our app)
    private func setupEscapeKeyMonitors() {
        let escapeHandler: (NSEvent) -> NSEvent? = { [weak self] event in
            guard event.keyCode == 53 else { return event }  // Escape key

            Task { @MainActor in
                guard let self = self else { return }

                // If expanded command output is showing, hide it
                if self.isCommandOutputExpanded {
                    self.hideExpandedCommandOutput()
                    self.onCommandOutputDismiss?()
                }
                // Also hide bottom overlay if visible
                else if self.isBottomOverlayVisible {
                    self.hide()
                }
            }
            return nil  // Consume the event
        }

        // Global monitor - catches escape when OTHER apps have focus
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            _ = escapeHandler(event)
        }

        // Local monitor - catches escape when OUR app/notch has focus
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: escapeHandler)
    }

    func show(audioLevelPublisher: AnyPublisher<CGFloat, Never>, mode: OverlayMode) {
        // Don't show bottom overlay if expanded command output is visible
        if isCommandOutputExpanded {
            // Just store the publisher for later use
            lastAudioPublisher = audioLevelPublisher
            return
        }

        // Store for potential re-show during processing
        lastAudioPublisher = audioLevelPublisher
        currentMode = mode

        // Show bottom overlay
        bottomOverlay.show(audioPublisher: audioLevelPublisher, mode: mode)
        isBottomOverlayVisible = true
    }

    func hide() {
        // Safety: reset processing state when hiding
        NotchContentState.shared.setProcessing(false)

        // Hide bottom overlay
        bottomOverlay.hide()
        isBottomOverlayVisible = false
    }

    func setMode(_ mode: OverlayMode) {
        // Always update NotchContentState to ensure UI stays in sync
        // (can get out of sync during show/hide transitions)
        currentMode = mode
        NotchContentState.shared.mode = mode
    }

    func updateTranscriptionText(_ text: String) {
        NotchContentState.shared.updateTranscription(text)
    }

    func setProcessing(_ processing: Bool) {
        NotchContentState.shared.setProcessing(processing)

        // If expanded command output is showing, don't mess with bottom overlay
        if isCommandOutputExpanded {
            return
        }

        // Use bottom overlay for processing state
        bottomOverlay.setProcessing(processing)
    }

    // MARK: - Expanded Command Output

    /// Show expanded command output notch
    func showExpandedCommandOutput() {
        // Hide bottom overlay first if visible
        if isBottomOverlayVisible {
            hide()
        }

        // Wait a bit for cleanup
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            await self?.showExpandedCommandOutputInternal()
        }
    }

    private func showExpandedCommandOutputInternal() async {
        guard commandOutputState == .idle else { return }

        commandOutputGeneration &+= 1
        let currentGeneration = commandOutputGeneration

        commandOutputState = .showing
        isCommandOutputExpanded = true

        // Update content state
        NotchContentState.shared.mode = .command
        NotchContentState.shared.isExpandedForCommandOutput = true

        let publisher = lastAudioPublisher ?? Empty<CGFloat, Never>().eraseToAnyPublisher()

        let newNotch = DynamicNotch(
            hoverBehavior: [],  // No keepVisible - allows closing with X/Escape even when cursor is on notch
            style: .notch(topCornerRadius: 12, bottomCornerRadius: 16)
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
                    await self?.onCommandFollowUp?(text)
                },
                onNewChat: { [weak self] in
                    Task { @MainActor in
                        self?.onNewChat?()
                        // Refresh recent chats in notch state
                        NotchContentState.shared.refreshRecentChats()
                    }
                },
                onSwitchChat: { [weak self] chatID in
                    Task { @MainActor in
                        self?.onSwitchChat?(chatID)
                        // Refresh recent chats in notch state
                        NotchContentState.shared.refreshRecentChats()
                    }
                },
                onClearChat: { [weak self] in
                    Task { @MainActor in
                        self?.onClearChat?()
                    }
                }
            )
        } compactLeading: {
            NotchCompactLeadingView()
        } compactTrailing: {
            NotchCompactTrailingView()
        }

        self.commandOutputNotch = newNotch

        await newNotch.expand()

        guard self.commandOutputGeneration == currentGeneration else { return }
        self.commandOutputState = .visible
    }

    /// Hide expanded command output notch - force close regardless of hover state
    func hideExpandedCommandOutput() {
        commandOutputGeneration &+= 1
        let currentGeneration = commandOutputGeneration

        // Force cleanup state immediately
        isCommandOutputExpanded = false
        NotchContentState.shared.collapseCommandOutput()

        guard commandOutputState == .visible || commandOutputState == .showing,
              let currentNotch = commandOutputNotch else {
            commandOutputState = .idle
            return
        }

        commandOutputState = .hiding

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
        if isCommandOutputExpanded {
            hideExpandedCommandOutput()
        } else if NotchContentState.shared.commandConversationHistory.isEmpty == false {
            // Only show if there's history to show
            showExpandedCommandOutput()
        }
    }

    /// Check if any overlay (bottom or expanded command) is visible
    var isAnyNotchVisible: Bool {
        return isBottomOverlayVisible || isCommandOutputExpanded
    }

    /// Update audio publisher for expanded notch (when recording starts within it)
    func updateAudioPublisher(_ publisher: AnyPublisher<CGFloat, Never>) {
        lastAudioPublisher = publisher
        currentAudioPublisher = publisher
    }
}
