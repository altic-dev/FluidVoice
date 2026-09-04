//
//  BottomOverlayView.swift
//  Fluid
//
//  Bottom overlay for transcription (alternative to notch overlay)
//

import AppKit
import Combine
import QuartzCore
import SwiftUI

private enum OverlayShortcutResolver {
    static func shortcutDisplay(for mode: OverlayMode, settings: SettingsStore = .shared) -> String {
        switch mode {
        case .dictation:
            return settings.primaryDictationShortcutDisplayString
        case .edit, .write, .rewrite:
            return settings.rewriteModeHotkeyShortcut.displayString
        case .command:
            return settings.commandModeHotkeyShortcut?.displayString ?? "Not set"
        }
    }
}

enum RecordingOverlayHideOutcome: Equatable {
    case hidden
    case superseded
}

private final class BottomOverlayPanel: NSPanel {
    var allowsOffscreenParking = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        self.allowsOffscreenParking ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

// MARK: - Bottom Overlay Window Controller

@MainActor
final class BottomOverlayWindowController {
    static let shared = BottomOverlayWindowController()

    private var window: NSPanel?
    private var audioSubscription: AnyCancellable?
    private var pendingResizeWorkItem: DispatchWorkItem?
    private var pendingReleaseTransitionResetWorkItem: DispatchWorkItem?
    private var localMouseDownMonitor: Any?
    private var globalMouseDownMonitor: Any?
    private var targetScreen: NSScreen?
    private var releaseTransitionActiveUntil: Date?
    private var deferredResizePending = false
    private var presentationGeneration: UInt64 = 0
    private let dismissalDuration: TimeInterval = 0.02
    private var isHideInProgress = false
    private var activeHideGeneration: UInt64?
    private var hideWaiters: [CheckedContinuation<RecordingOverlayHideOutcome, Never>] = []

    private init() {
        NotificationCenter.default.addObserver(forName: NSNotification.Name("OverlayOffsetChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.positionWindow()
            }
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("OverlaySizeChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleSizeAndPositionUpdate(after: 0)
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.targetScreen = OverlayScreenResolver.screenForCurrentPointer()
                if NotchContentState.shared.isBottomOverlayPresented {
                    self.positionWindow()
                } else {
                    self.parkWindowOffscreen()
                }
            }
        }
    }

    /// Pay the one-time SwiftUI/WindowServer surface cost after launch and keep
    /// the static panel outside the entire desktop so its surface is not evicted.
    func prepare() {
        guard self.window == nil else { return }
        self.createWindow()
        self.targetScreen = OverlayScreenResolver.screenForCurrentPointer()
        guard let window else { return }

        self.parkWindowOffscreen()
        window.alphaValue = 1
        window.orderFrontRegardless()
        CATransaction.flush()
        Self.overlayBench("bottom_prepared")
    }

    func show(audioPublisher: AnyPublisher<CGFloat, Never>, mode: OverlayMode) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        Self.overlayBench("bottom_show_start mode=\(mode.rawValue) windowExists=\(self.window != nil)")
        self.cancelInFlightHideForNewPresentation()
        self.presentationGeneration &+= 1

        self.endReleaseTransition(flushDeferredUpdate: false)
        self.pendingResizeWorkItem?.cancel()
        self.pendingResizeWorkItem = nil
        BottomOverlayPromptMenuController.shared.hide()
        BottomOverlayModeMenuController.shared.hide()
        BottomOverlayActionsMenuController.shared.hide()
        self.ensureMouseDownMonitors()

        // Create window if needed
        if self.window == nil {
            self.createWindow()
        }

        // Prepare the complete first frame while the cached panel is still
        // offscreen. Revealing the neutral shell first causes a visible flash
        // that reads as the overlay appearing twice.
        NotchContentState.shared.setBottomOverlayPresented(true)
        NotchContentState.shared.setSpokenSendIndicatorState(.hidden)
        NotchContentState.shared.mode = mode
        switch mode {
        case .dictation: NotchContentState.shared.promptPickerMode = .dictate
        case .edit, .write, .rewrite: NotchContentState.shared.promptPickerMode = .edit
        case .command: break
        }
        NotchContentState.shared.updateTranscription("")
        NotchContentState.shared.bottomOverlayAudioLevel = 0
        NotchContentState.shared.setBottomOverlayDismissOffsetY(8)
        NotchContentState.shared.setBottomOverlayDismissing(false)

        self.targetScreen = OverlayScreenResolver.screenForCurrentPointer()
        self.positionWindow()

        // Submit one complete frame to WindowServer.
        self.window?.setAccessibilityChildren(nil)
        self.window?.setAccessibilityElement(true)
        self.window?.alphaValue = 1
        self.window?.orderFrontRegardless()
        self.window?.contentView?.displayIfNeeded()
        self.window?.displayIfNeeded()
        CATransaction.flush()
        Self.overlayBench("bottom_order_front elapsedMs=\(Self.elapsedMs(since: startedAt))")
        Self.overlayBench("bottom_visible elapsedMs=\(Self.elapsedMs(since: startedAt))")

        self.audioSubscription?.cancel()
        self.audioSubscription = audioPublisher
            .receive(on: DispatchQueue.main)
            .sink { level in
                NotchContentState.shared.bottomOverlayAudioLevel = level
            }
    }

    func hide() {
        guard !self.isHideInProgress else { return }
        self.isHideInProgress = true
        self.presentationGeneration &+= 1
        let currentGeneration = self.presentationGeneration
        self.activeHideGeneration = currentGeneration
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.performHideAndWait(generation: currentGeneration)
            self.completeHideOperation(generation: currentGeneration, outcome: outcome)
        }
    }

    /// Returns whether the panel finished hiding or a newer presentation
    /// superseded this request.
    func hideAndWait() async -> RecordingOverlayHideOutcome {
        if self.isHideInProgress {
            return await withCheckedContinuation { continuation in
                self.hideWaiters.append(continuation)
            }
        }

        self.isHideInProgress = true
        self.presentationGeneration &+= 1
        let currentGeneration = self.presentationGeneration
        self.activeHideGeneration = currentGeneration
        let outcome = await self.performHideAndWait(generation: currentGeneration)
        self.completeHideOperation(generation: currentGeneration, outcome: outcome)
        return outcome
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
        Self.overlayBench("bottom_hide_cancelled_for_new_presentation")
    }

    private func performHideAndWait(generation currentGeneration: UInt64) async -> RecordingOverlayHideOutcome {
        let startedAt = ProcessInfo.processInfo.systemUptime
        Self.overlayBench("bottom_hide_start windowExists=\(self.window != nil)")
        guard self.presentationGeneration == currentGeneration else {
            Self.overlayBench("bottom_hide_return reason=stale_generation")
            return .superseded
        }

        guard let window = self.window, NotchContentState.shared.isBottomOverlayPresented else {
            self.clearPresentationResources()
            self.endReleaseTransition(flushDeferredUpdate: false)
            NotchContentState.shared.setBottomOverlayDismissing(false)
            NotchContentState.shared.targetAppIcon = nil
            Self.overlayBench("bottom_hide_return reason=no_window")
            return .hidden
        }

        NotchContentState.shared.setBottomOverlayReleaseTransitioning(true)
        NotchContentState.shared.setBottomOverlayDismissOffsetY(8)
        NotchContentState.shared.setBottomOverlayDismissing(true)

        // SwiftUI owns the dismissal animation. Keeping AppKit alpha at 1
        // prevents an old implicit window animation from hiding a rapid restart.
        Self.overlayBench("bottom_hide_animation_start")
        await Task.yield()
        guard self.presentationGeneration == currentGeneration else {
            Self.overlayBench("bottom_hide_return reason=stale_generation")
            return .superseded
        }
        self.clearPresentationResources()

        try? await Task.sleep(nanoseconds: UInt64(self.dismissalDuration * 1_000_000_000))

        guard self.presentationGeneration == currentGeneration else {
            Self.overlayBench("bottom_hide_return reason=stale_generation")
            return .superseded
        }

        self.parkWindowOffscreen()
        window.alphaValue = 1
        NotchContentState.shared.setBottomOverlayPresented(false)
        self.endReleaseTransition(flushDeferredUpdate: false)
        NotchContentState.shared.setBottomOverlayDismissing(false)
        NotchContentState.shared.targetAppIcon = nil
        Self.overlayBench("bottom_hide_complete elapsedMs=\(Self.elapsedMs(since: startedAt))")
        return .hidden
    }

    private func clearPresentationResources() {
        self.audioSubscription?.cancel()
        self.audioSubscription = nil
        self.pendingResizeWorkItem?.cancel()
        self.pendingResizeWorkItem = nil
        self.pendingReleaseTransitionResetWorkItem?.cancel()
        self.targetScreen = nil
        self.removeMouseDownMonitors()
        BottomOverlayPromptMenuController.shared.hide()
        BottomOverlayModeMenuController.shared.hide()
        BottomOverlayActionsMenuController.shared.hide()
        NotchContentState.shared.setProcessing(false)
        NotchContentState.shared.bottomOverlayAudioLevel = 0
    }

    func setProcessing(_ processing: Bool) {
        Self.overlayBench("bottom_set_processing processing=\(processing)")
        NotchContentState.shared.setProcessing(processing)
    }

    func refreshSizeForContent() {
        self.scheduleSizeAndPositionUpdate()
    }

    func beginReleaseTransition(duration: TimeInterval = 0.28) {
        let now = Date()
        let deadline = now.addingTimeInterval(max(duration, 0.12))
        if let existingDeadline = self.releaseTransitionActiveUntil, existingDeadline > deadline {
            self.releaseTransitionActiveUntil = existingDeadline
        } else {
            self.releaseTransitionActiveUntil = deadline
        }

        self.pendingReleaseTransitionResetWorkItem?.cancel()

        guard let activeDeadline = self.releaseTransitionActiveUntil else { return }
        let resetWorkItem = DispatchWorkItem { [weak self] in
            self?.endReleaseTransition()
        }
        self.pendingReleaseTransitionResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(activeDeadline.timeIntervalSince(now), 0), execute: resetWorkItem)

        self.audioSubscription?.cancel()
        self.audioSubscription = nil
        NotchContentState.shared.bottomOverlayAudioLevel = 0
        NotchContentState.shared.setBottomOverlayReleaseTransitioning(true)
    }

    func endReleaseTransition(flushDeferredUpdate: Bool = true) {
        self.pendingReleaseTransitionResetWorkItem?.cancel()
        self.pendingReleaseTransitionResetWorkItem = nil
        self.releaseTransitionActiveUntil = nil
        NotchContentState.shared.setBottomOverlayReleaseTransitioning(false)

        let shouldFlush = flushDeferredUpdate && self.deferredResizePending
        self.deferredResizePending = false

        if shouldFlush, self.window?.isVisible == true {
            self.scheduleSizeAndPositionUpdate(after: 0)
        }
    }

    private static func overlayBench(_ message: String) {
        DebugLogger.shared.benchmark("OVERLAY_BENCH", message: message, source: "OverlayBenchmark")
    }

    private static func elapsedMs(since start: TimeInterval) -> Int {
        Int(((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded())
    }

    private func scheduleSizeAndPositionUpdate(after delay: TimeInterval = 0.08) {
        if self.isReleaseTransitionActive {
            self.deferredResizePending = true
            return
        }

        self.pendingResizeWorkItem?.cancel()

        // Debounce rapid streaming updates to avoid resize thrash.
        let resizeWorkItem = DispatchWorkItem { [weak self] in
            self?.updateSizeAndPosition()
        }
        self.pendingResizeWorkItem = resizeWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: resizeWorkItem)
    }

    /// Update window size based on current SwiftUI content and re-position
    private func updateSizeAndPosition() {
        if self.isReleaseTransitionActive {
            self.deferredResizePending = true
            return
        }

        guard let window = window, let hostingView = window.contentView as? NSHostingView<BottomOverlayView> else { return }

        // Re-calculate fitting size for the new layout constants
        let newSize = hostingView.fittingSize

        // Avoid redundant content-size updates while AppKit is already resolving constraints.
        // Re-applying the same size can trigger unnecessary update-constraints churn.
        let currentSize = window.contentView?.frame.size ?? window.frame.size
        let widthChanged = abs(currentSize.width - newSize.width) > 0.5
        let heightChanged = abs(currentSize.height - newSize.height) > 0.5

        if widthChanged || heightChanged {
            // Resize from the current origin to avoid AppKit's default top-left anchoring,
            // which can visually push the overlay down before we re-position it.
            let currentOrigin = window.frame.origin
            let resizedFrame = NSRect(origin: currentOrigin, size: newSize)
            window.setFrame(resizedFrame, display: false)
        }

        // Re-position
        self.positionWindow()
    }

    private func createWindow() {
        let panel = BottomOverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // SwiftUI handles shadow
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let contentView = BottomOverlayView()
        let hostingView = BottomOverlayHostingView(rootView: contentView)

        // Let SwiftUI determine the size
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)

        // Make hosting view fully transparent
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        panel.setContentSize(fittingSize)
        panel.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        hostingView.display()

        self.window = panel
    }

    private var isReleaseTransitionActive: Bool {
        guard let deadline = self.releaseTransitionActiveUntil else { return false }
        if deadline > Date() {
            return true
        }

        self.releaseTransitionActiveUntil = nil
        return false
    }

    private func ensureMouseDownMonitors() {
        if self.localMouseDownMonitor == nil {
            self.localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                let clickPoint: NSPoint
                if let window = event.window {
                    clickPoint = window.convertPoint(toScreen: event.locationInWindow)
                } else {
                    clickPoint = NSEvent.mouseLocation
                }

                Task { @MainActor [weak self] in
                    self?.dismissMenusForClick(screenPoint: clickPoint)
                }
                return event
            }
        }

        if self.globalMouseDownMonitor == nil {
            self.globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                let clickPoint = NSEvent.mouseLocation
                Task { @MainActor [weak self] in
                    self?.dismissMenusForClick(screenPoint: clickPoint)
                }
            }
        }
    }

    private func removeMouseDownMonitors() {
        if let monitor = self.localMouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            self.localMouseDownMonitor = nil
        }
        if let monitor = self.globalMouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            self.globalMouseDownMonitor = nil
        }
    }

    @MainActor
    private func dismissMenusForClick(screenPoint: NSPoint) {
        guard self.window?.isVisible == true else { return }
        BottomOverlayPromptMenuController.shared.dismissIfNeeded(for: screenPoint)
        BottomOverlayModeMenuController.shared.dismissIfNeeded(for: screenPoint)
        BottomOverlayActionsMenuController.shared.dismissIfNeeded(for: screenPoint)
    }

    private func positionWindow() {
        // Safe check for window and screen availability
        guard let window = window else { return }
        guard NotchContentState.shared.isBottomOverlayPresented else {
            self.parkWindowOffscreen()
            return
        }
        (window as? BottomOverlayPanel)?.allowsOffscreenParking = false

        let screen = self.targetScreen ?? window.screen ?? OverlayScreenResolver.screenForCurrentPointer()
        guard let screen = screen else { return }

        let fullFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let windowSize = window.frame.size

        // Horizontal centering
        let x = fullFrame.midX - windowSize.width / 2

        // Vertical positioning with safety clamping
        let offset = SettingsStore.shared.overlayBottomOffset

        // Calculate raw position
        var y = visibleFrame.minY + CGFloat(offset)

        // Safety Clamping:
        // 1. Min: Ensure it's at least visibleFrame.minY (not below the dock/visible area)
        // 2. Max: Ensure it doesn't cross the top of the visible frame minus its own height
        let minY = visibleFrame.minY + 10 // Small buffer from absolute bottom
        let maxY = visibleFrame.maxY - windowSize.height - 40 // Buffer from top

        y = max(min(y, maxY), minY)

        // Apply position directly to avoid implicit frame animations during hover-driven resizes.
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func parkWindowOffscreen() {
        guard let window else { return }
        window.setAccessibilityChildren([])
        window.setAccessibilityElement(false)
        (window as? BottomOverlayPanel)?.allowsOffscreenParking = true
        let desktopFrame = NSScreen.screens.reduce(NSRect.null) { partial, screen in
            partial.union(screen.frame)
        }
        let edge = desktopFrame.isNull ? NSPoint(x: 100_000, y: 100_000) : NSPoint(
            x: desktopFrame.maxX + window.frame.width + 1024,
            y: desktopFrame.maxY + window.frame.height + 1024
        )
        window.setFrameOrigin(edge)
    }
}

@MainActor
final class BottomOverlayPromptMenuController {
    static let shared = BottomOverlayPromptMenuController()

    private var menuWindow: NSPanel?
    private var hostingView: NSHostingView<BottomOverlayPromptMenuView>?
    private var selectorFrameInScreen: CGRect = .zero
    private weak var parentWindow: NSWindow?
    private var menuMaxWidth: CGFloat = 220
    private var menuGap: CGFloat = 6

    private var isHoveringSelector = false
    private var isHoveringMenu = false
    private var pendingShowWorkItem: DispatchWorkItem?
    private var pendingHideWorkItem: DispatchWorkItem?
    private var pendingPositionWorkItem: DispatchWorkItem?

    private init() {}

    func updateAnchor(selectorFrameInScreen: CGRect, parentWindow: NSWindow?, maxWidth: CGFloat, menuGap: CGFloat) {
        guard selectorFrameInScreen.width > 0, selectorFrameInScreen.height > 0 else { return }

        let resolvedMaxWidth = max(maxWidth, 120)
        let widthChanged = abs(self.menuMaxWidth - resolvedMaxWidth) > 0.5

        self.selectorFrameInScreen = selectorFrameInScreen
        self.parentWindow = parentWindow
        self.menuMaxWidth = resolvedMaxWidth
        self.menuGap = max(menuGap, 0)

        if self.menuWindow?.isVisible == true {
            if widthChanged {
                self.updateMenuContent()
            }
            self.attachToParentWindowIfNeeded()
            self.scheduleMenuPositionUpdate()
        }
    }

    func selectorHoverChanged(_ hovering: Bool) {
        // Hover-open disabled: menu is click/tap driven.
    }

    func menuHoverChanged(_ hovering: Bool) {
        // Hover-open disabled: menu is click/tap driven.
    }

    func toggleFromTap() {
        if self.menuWindow?.isVisible == true {
            self.hide()
            return
        }
        self.showMenuIfPossible()
    }

    func hide() {
        self.pendingShowWorkItem?.cancel()
        self.pendingShowWorkItem = nil
        self.pendingHideWorkItem?.cancel()
        self.pendingHideWorkItem = nil
        self.pendingPositionWorkItem?.cancel()
        self.pendingPositionWorkItem = nil

        self.isHoveringSelector = false
        self.isHoveringMenu = false

        if let menuWindow = self.menuWindow, let parent = menuWindow.parent {
            parent.removeChildWindow(menuWindow)
        }
        self.menuWindow?.orderOut(nil)
    }

    func dismissIfNeeded(for screenPoint: NSPoint) {
        guard self.menuWindow?.isVisible == true else { return }
        let insideMenu = self.menuWindow?.frame.contains(screenPoint) ?? false
        let insideSelector = self.selectorFrameInScreen.contains(screenPoint)
        if !insideMenu, !insideSelector {
            self.hide()
        }
    }

    private func updateVisibility() {
        let shouldShow = self.isHoveringSelector || self.isHoveringMenu

        if shouldShow {
            self.pendingHideWorkItem?.cancel()
            self.pendingHideWorkItem = nil

            if self.menuWindow?.isVisible == true {
                self.scheduleMenuPositionUpdate()
                return
            }

            self.pendingShowWorkItem?.cancel()
            let showTask = DispatchWorkItem { [weak self] in
                self?.showMenuIfPossible()
            }
            self.pendingShowWorkItem = showTask
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: showTask)
            return
        }

        self.pendingShowWorkItem?.cancel()
        self.pendingShowWorkItem = nil

        self.pendingHideWorkItem?.cancel()
        let hideTask = DispatchWorkItem { [weak self] in
            self?.hideIfNotHovered()
        }
        self.pendingHideWorkItem = hideTask
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: hideTask)
    }

    private func hideIfNotHovered() {
        guard !self.isHoveringSelector, !self.isHoveringMenu else { return }
        self.pendingPositionWorkItem?.cancel()
        self.pendingPositionWorkItem = nil
        if let menuWindow = self.menuWindow, let parent = menuWindow.parent {
            parent.removeChildWindow(menuWindow)
        }
        self.menuWindow?.orderOut(nil)
    }

    private func scheduleMenuPositionUpdate() {
        guard self.pendingPositionWorkItem == nil else { return }

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPositionWorkItem = nil
            self.updateMenuSizeAndPosition()
        }

        self.pendingPositionWorkItem = task
        DispatchQueue.main.async(execute: task)
    }

    private func showMenuIfPossible() {
        guard self.selectorFrameInScreen.width > 0, self.selectorFrameInScreen.height > 0 else { return }

        self.createWindowIfNeeded()
        self.updateMenuContent()
        self.attachToParentWindowIfNeeded()
        self.updateMenuSizeAndPosition()
        self.menuWindow?.orderFrontRegardless()
    }

    private func createWindowIfNeeded() {
        guard self.menuWindow == nil else { return }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let contentView = BottomOverlayPromptMenuView(
            promptMode: self.resolvedPromptMode(),
            maxWidth: self.menuMaxWidth,
            onHoverChanged: { [weak self] hovering in
                self?.menuHoverChanged(hovering)
            },
            onDismissRequested: { [weak self] in
                self?.hide()
            }
        )

        let hostingView = NSHostingView(rootView: contentView)
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        panel.setContentSize(fittingSize)
        panel.contentView = hostingView

        self.hostingView = hostingView
        self.menuWindow = panel
    }

    private func updateMenuContent() {
        let rootView = BottomOverlayPromptMenuView(
            promptMode: self.resolvedPromptMode(),
            maxWidth: self.menuMaxWidth,
            onHoverChanged: { [weak self] hovering in
                self?.menuHoverChanged(hovering)
            },
            onDismissRequested: { [weak self] in
                self?.hide()
            }
        )
        self.hostingView?.rootView = rootView
    }

    private func resolvedPromptMode() -> SettingsStore.PromptMode {
        switch NotchContentState.shared.mode {
        case .dictation:
            return .dictate
        case .edit, .write, .rewrite:
            return .edit
        case .command:
            return NotchContentState.shared.promptPickerMode.normalized
        }
    }

    private func attachToParentWindowIfNeeded() {
        guard let menuWindow = self.menuWindow else { return }

        if let currentParent = menuWindow.parent, currentParent !== self.parentWindow {
            currentParent.removeChildWindow(menuWindow)
        }

        if let parentWindow = self.parentWindow, menuWindow.parent !== parentWindow {
            parentWindow.addChildWindow(menuWindow, ordered: .above)
        }
    }

    private func updateMenuSizeAndPosition() {
        guard let menuWindow = self.menuWindow, let hostingView = self.hostingView else { return }
        guard self.selectorFrameInScreen.width > 0, self.selectorFrameInScreen.height > 0 else { return }

        let fittingSize = hostingView.fittingSize
        guard fittingSize.width > 0, fittingSize.height > 0 else { return }

        let preferredX = self.selectorFrameInScreen.midX - (fittingSize.width / 2)
        let preferredY = self.selectorFrameInScreen.maxY + self.menuGap

        let screen = self.parentWindow?.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: self.selectorFrameInScreen.midX, y: self.selectorFrameInScreen.midY)) })
            ?? NSScreen.main

        var targetX = preferredX
        var targetY = preferredY

        if let screen {
            let visible = screen.visibleFrame
            let horizontalInset: CGFloat = 8
            let verticalInset: CGFloat = 8

            if fittingSize.width < visible.width - (horizontalInset * 2) {
                targetX = max(visible.minX + horizontalInset, min(preferredX, visible.maxX - fittingSize.width - horizontalInset))
            } else {
                targetX = visible.minX + horizontalInset
            }

            if fittingSize.height < visible.height - (verticalInset * 2) {
                targetY = max(visible.minY + verticalInset, min(preferredY, visible.maxY - fittingSize.height - verticalInset))
            } else {
                targetY = visible.minY + verticalInset
            }
        }

        let targetFrame = NSRect(x: targetX, y: targetY, width: fittingSize.width, height: fittingSize.height)
        let currentFrame = menuWindow.frame
        let frameTolerance: CGFloat = 0.5
        let isSameFrame =
            abs(currentFrame.origin.x - targetFrame.origin.x) <= frameTolerance &&
            abs(currentFrame.origin.y - targetFrame.origin.y) <= frameTolerance &&
            abs(currentFrame.size.width - targetFrame.size.width) <= frameTolerance &&
            abs(currentFrame.size.height - targetFrame.size.height) <= frameTolerance

        if !isSameFrame {
            menuWindow.setFrame(targetFrame, display: false)
        }
    }
}

@MainActor
final class BottomOverlayModeMenuController {
    static let shared = BottomOverlayModeMenuController()

    private var menuWindow: NSPanel?
    private var hostingView: NSHostingView<BottomOverlayModeMenuView>?
    private var selectorFrameInScreen: CGRect = .zero
    private weak var parentWindow: NSWindow?
    private var menuMaxWidth: CGFloat = 220
    private var menuGap: CGFloat = 6

    private var isHoveringSelector = false
    private var isHoveringMenu = false
    private var pendingShowWorkItem: DispatchWorkItem?
    private var pendingHideWorkItem: DispatchWorkItem?
    private var pendingPositionWorkItem: DispatchWorkItem?

    private init() {}

    func updateAnchor(selectorFrameInScreen: CGRect, parentWindow: NSWindow?, maxWidth: CGFloat, menuGap: CGFloat) {
        guard selectorFrameInScreen.width > 0, selectorFrameInScreen.height > 0 else { return }

        let resolvedMaxWidth = max(maxWidth, 120)
        let widthChanged = abs(self.menuMaxWidth - resolvedMaxWidth) > 0.5

        self.selectorFrameInScreen = selectorFrameInScreen
        self.parentWindow = parentWindow
        self.menuMaxWidth = resolvedMaxWidth
        self.menuGap = max(menuGap, 0)

        if self.menuWindow?.isVisible == true {
            if widthChanged {
                self.updateMenuContent()
            }
            self.attachToParentWindowIfNeeded()
            self.scheduleMenuPositionUpdate()
        }
    }

    func selectorHoverChanged(_ hovering: Bool) {
        // Hover-open disabled: menu is click/tap driven.
    }

    func menuHoverChanged(_ hovering: Bool) {
        // Hover-open disabled: menu is click/tap driven.
    }

    func toggleFromTap() {
        if self.menuWindow?.isVisible == true {
            self.hide()
            return
        }
        self.showMenuIfPossible()
    }

    func hide() {
        self.pendingShowWorkItem?.cancel()
        self.pendingShowWorkItem = nil
        self.pendingHideWorkItem?.cancel()
        self.pendingHideWorkItem = nil
        self.pendingPositionWorkItem?.cancel()
        self.pendingPositionWorkItem = nil

        self.isHoveringSelector = false
        self.isHoveringMenu = false

        if let menuWindow = self.menuWindow, let parent = menuWindow.parent {
            parent.removeChildWindow(menuWindow)
        }
        self.menuWindow?.orderOut(nil)
    }

    func dismissIfNeeded(for screenPoint: NSPoint) {
        guard self.menuWindow?.isVisible == true else { return }
        let insideMenu = self.menuWindow?.frame.contains(screenPoint) ?? false
        let insideSelector = self.selectorFrameInScreen.contains(screenPoint)
        if !insideMenu, !insideSelector {
            self.hide()
        }
    }

    private func updateVisibility() {
        let shouldShow = self.isHoveringSelector || self.isHoveringMenu

        if shouldShow {
            self.pendingHideWorkItem?.cancel()
            self.pendingHideWorkItem = nil

            if self.menuWindow?.isVisible == true {
                self.scheduleMenuPositionUpdate()
                return
            }

            self.pendingShowWorkItem?.cancel()
            let showTask = DispatchWorkItem { [weak self] in
                self?.showMenuIfPossible()
            }
            self.pendingShowWorkItem = showTask
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: showTask)
            return
        }

        self.pendingShowWorkItem?.cancel()
        self.pendingShowWorkItem = nil

        self.pendingHideWorkItem?.cancel()
        let hideTask = DispatchWorkItem { [weak self] in
            self?.hideIfNotHovered()
        }
        self.pendingHideWorkItem = hideTask
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: hideTask)
    }

    private func hideIfNotHovered() {
        guard !self.isHoveringSelector, !self.isHoveringMenu else { return }
        self.pendingPositionWorkItem?.cancel()
        self.pendingPositionWorkItem = nil
        if let menuWindow = self.menuWindow, let parent = menuWindow.parent {
            parent.removeChildWindow(menuWindow)
        }
        self.menuWindow?.orderOut(nil)
    }

    private func scheduleMenuPositionUpdate() {
        guard self.pendingPositionWorkItem == nil else { return }

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPositionWorkItem = nil
            self.updateMenuSizeAndPosition()
        }

        self.pendingPositionWorkItem = task
        DispatchQueue.main.async(execute: task)
    }

    private func showMenuIfPossible() {
        guard self.selectorFrameInScreen.width > 0, self.selectorFrameInScreen.height > 0 else { return }

        self.createWindowIfNeeded()
        self.updateMenuContent()
        self.attachToParentWindowIfNeeded()
        self.updateMenuSizeAndPosition()
        self.menuWindow?.orderFrontRegardless()
    }

    private func createWindowIfNeeded() {
        guard self.menuWindow == nil else { return }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let contentView = BottomOverlayModeMenuView(
            maxWidth: self.menuMaxWidth,
            onHoverChanged: { [weak self] hovering in
                self?.menuHoverChanged(hovering)
            },
            onDismissRequested: { [weak self] in
                self?.hide()
            }
        )

        let hostingView = NSHostingView(rootView: contentView)
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        panel.setContentSize(fittingSize)
        panel.contentView = hostingView

        self.hostingView = hostingView
        self.menuWindow = panel
    }

    private func updateMenuContent() {
        let rootView = BottomOverlayModeMenuView(
            maxWidth: self.menuMaxWidth,
            onHoverChanged: { [weak self] hovering in
                self?.menuHoverChanged(hovering)
            },
            onDismissRequested: { [weak self] in
                self?.hide()
            }
        )
        self.hostingView?.rootView = rootView
    }

    private func attachToParentWindowIfNeeded() {
        guard let menuWindow = self.menuWindow else { return }

        if let currentParent = menuWindow.parent, currentParent !== self.parentWindow {
            currentParent.removeChildWindow(menuWindow)
        }

        if let parentWindow = self.parentWindow, menuWindow.parent !== parentWindow {
            parentWindow.addChildWindow(menuWindow, ordered: .above)
        }
    }

    private func updateMenuSizeAndPosition() {
        guard let menuWindow = self.menuWindow, let hostingView = self.hostingView else { return }
        guard self.selectorFrameInScreen.width > 0, self.selectorFrameInScreen.height > 0 else { return }

        let fittingSize = hostingView.fittingSize
        guard fittingSize.width > 0, fittingSize.height > 0 else { return }

        let preferredX = self.selectorFrameInScreen.midX - (fittingSize.width / 2)
        let preferredY = self.selectorFrameInScreen.maxY + self.menuGap

        let screen = self.parentWindow?.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: self.selectorFrameInScreen.midX, y: self.selectorFrameInScreen.midY)) })
            ?? NSScreen.main

        var targetX = preferredX
        var targetY = preferredY

        if let screen {
            let visible = screen.visibleFrame
            let horizontalInset: CGFloat = 8
            let verticalInset: CGFloat = 8

            if fittingSize.width < visible.width - (horizontalInset * 2) {
                targetX = max(visible.minX + horizontalInset, min(preferredX, visible.maxX - fittingSize.width - horizontalInset))
            } else {
                targetX = visible.minX + horizontalInset
            }

            if fittingSize.height < visible.height - (verticalInset * 2) {
                targetY = max(visible.minY + verticalInset, min(preferredY, visible.maxY - fittingSize.height - verticalInset))
            } else {
                targetY = visible.minY + verticalInset
            }
        }

        let targetFrame = NSRect(x: targetX, y: targetY, width: fittingSize.width, height: fittingSize.height)
        let currentFrame = menuWindow.frame
        let frameTolerance: CGFloat = 0.5
        let isSameFrame =
            abs(currentFrame.origin.x - targetFrame.origin.x) <= frameTolerance &&
            abs(currentFrame.origin.y - targetFrame.origin.y) <= frameTolerance &&
            abs(currentFrame.size.width - targetFrame.size.width) <= frameTolerance &&
            abs(currentFrame.size.height - targetFrame.size.height) <= frameTolerance

        if !isSameFrame {
            menuWindow.setFrame(targetFrame, display: false)
        }
    }
}

@MainActor
final class BottomOverlayActionsMenuController {
    static let shared = BottomOverlayActionsMenuController()

    private var menuWindow: NSPanel?
    private var hostingView: NSHostingView<BottomOverlayActionsMenuView>?
    private var selectorFrameInScreen: CGRect = .zero
    private weak var parentWindow: NSWindow?
    private var menuMaxWidth: CGFloat = 220
    private var menuGap: CGFloat = 6

    private var isHoveringSelector = false
    private var isHoveringMenu = false
    private var pendingShowWorkItem: DispatchWorkItem?
    private var pendingHideWorkItem: DispatchWorkItem?
    private var pendingPositionWorkItem: DispatchWorkItem?

    private init() {}

    func updateAnchor(selectorFrameInScreen: CGRect, parentWindow: NSWindow?, maxWidth: CGFloat, menuGap: CGFloat) {
        guard selectorFrameInScreen.width > 0, selectorFrameInScreen.height > 0 else { return }

        let resolvedMaxWidth = max(maxWidth, 120)
        let widthChanged = abs(self.menuMaxWidth - resolvedMaxWidth) > 0.5

        self.selectorFrameInScreen = selectorFrameInScreen
        self.parentWindow = parentWindow
        self.menuMaxWidth = resolvedMaxWidth
        self.menuGap = max(menuGap, 0)

        if self.menuWindow?.isVisible == true {
            if widthChanged {
                self.updateMenuContent()
            }
            self.attachToParentWindowIfNeeded()
            self.scheduleMenuPositionUpdate()
        }
    }

    func selectorHoverChanged(_ hovering: Bool) {
        // Hover-open disabled: menu is click/tap driven.
    }

    func menuHoverChanged(_ hovering: Bool) {
        // Hover-open disabled: menu is click/tap driven.
    }

    func toggleFromTap() {
        if self.menuWindow?.isVisible == true {
            self.hide()
            return
        }
        self.showMenuIfPossible()
    }

    func hide() {
        self.pendingShowWorkItem?.cancel()
        self.pendingShowWorkItem = nil
        self.pendingHideWorkItem?.cancel()
        self.pendingHideWorkItem = nil
        self.pendingPositionWorkItem?.cancel()
        self.pendingPositionWorkItem = nil

        self.isHoveringSelector = false
        self.isHoveringMenu = false

        if let menuWindow = self.menuWindow, let parent = menuWindow.parent {
            parent.removeChildWindow(menuWindow)
        }
        self.menuWindow?.orderOut(nil)
    }

    func dismissIfNeeded(for screenPoint: NSPoint) {
        guard self.menuWindow?.isVisible == true else { return }
        let insideMenu = self.menuWindow?.frame.contains(screenPoint) ?? false
        let insideSelector = self.selectorFrameInScreen.contains(screenPoint)
        if !insideMenu, !insideSelector {
            self.hide()
        }
    }

    private func updateVisibility() {
        let shouldShow = self.isHoveringSelector || self.isHoveringMenu

        if shouldShow {
            self.pendingHideWorkItem?.cancel()
            self.pendingHideWorkItem = nil

            if self.menuWindow?.isVisible == true {
                self.scheduleMenuPositionUpdate()
                return
            }

            self.pendingShowWorkItem?.cancel()
            let showTask = DispatchWorkItem { [weak self] in
                self?.showMenuIfPossible()
            }
            self.pendingShowWorkItem = showTask
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: showTask)
            return
        }

        self.pendingShowWorkItem?.cancel()
        self.pendingShowWorkItem = nil

        self.pendingHideWorkItem?.cancel()
        let hideTask = DispatchWorkItem { [weak self] in
            self?.hideIfNotHovered()
        }
        self.pendingHideWorkItem = hideTask
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: hideTask)
    }

    private func hideIfNotHovered() {
        guard !self.isHoveringSelector, !self.isHoveringMenu else { return }
        self.pendingPositionWorkItem?.cancel()
        self.pendingPositionWorkItem = nil
        if let menuWindow = self.menuWindow, let parent = menuWindow.parent {
            parent.removeChildWindow(menuWindow)
        }
        self.menuWindow?.orderOut(nil)
    }

    private func scheduleMenuPositionUpdate() {
        guard self.pendingPositionWorkItem == nil else { return }

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPositionWorkItem = nil
            self.updateMenuSizeAndPosition()
        }

        self.pendingPositionWorkItem = task
        DispatchQueue.main.async(execute: task)
    }

    private func showMenuIfPossible() {
        guard self.selectorFrameInScreen.width > 0, self.selectorFrameInScreen.height > 0 else { return }

        self.createWindowIfNeeded()
        self.updateMenuContent()
        self.attachToParentWindowIfNeeded()
        self.updateMenuSizeAndPosition()
        self.menuWindow?.orderFrontRegardless()
    }

    private func createWindowIfNeeded() {
        guard self.menuWindow == nil else { return }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let contentView = BottomOverlayActionsMenuView(
            maxWidth: self.menuMaxWidth,
            onHoverChanged: { [weak self] hovering in
                self?.menuHoverChanged(hovering)
            },
            onDismissRequested: { [weak self] in
                self?.hide()
            }
        )

        let hostingView = NSHostingView(rootView: contentView)
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        panel.setContentSize(fittingSize)
        panel.contentView = hostingView

        self.hostingView = hostingView
        self.menuWindow = panel
    }

    private func updateMenuContent() {
        let rootView = BottomOverlayActionsMenuView(
            maxWidth: self.menuMaxWidth,
            onHoverChanged: { [weak self] hovering in
                self?.menuHoverChanged(hovering)
            },
            onDismissRequested: { [weak self] in
                self?.hide()
            }
        )
        self.hostingView?.rootView = rootView
    }

    private func attachToParentWindowIfNeeded() {
        guard let menuWindow = self.menuWindow else { return }

        if let currentParent = menuWindow.parent, currentParent !== self.parentWindow {
            currentParent.removeChildWindow(menuWindow)
        }

        if let parentWindow = self.parentWindow, menuWindow.parent !== parentWindow {
            parentWindow.addChildWindow(menuWindow, ordered: .above)
        }
    }

    private func updateMenuSizeAndPosition() {
        guard let menuWindow = self.menuWindow, let hostingView = self.hostingView else { return }
        guard self.selectorFrameInScreen.width > 0, self.selectorFrameInScreen.height > 0 else { return }

        let fittingSize = hostingView.fittingSize
        guard fittingSize.width > 0, fittingSize.height > 0 else { return }

        let preferredX = self.selectorFrameInScreen.midX - (fittingSize.width / 2)
        let preferredY = self.selectorFrameInScreen.maxY + self.menuGap

        let screen = self.parentWindow?.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: self.selectorFrameInScreen.midX, y: self.selectorFrameInScreen.midY)) })
            ?? NSScreen.main

        var targetX = preferredX
        var targetY = preferredY

        if let screen {
            let visible = screen.visibleFrame
            let horizontalInset: CGFloat = 8
            let verticalInset: CGFloat = 8

            if fittingSize.width < visible.width - (horizontalInset * 2) {
                targetX = max(visible.minX + horizontalInset, min(preferredX, visible.maxX - fittingSize.width - horizontalInset))
            } else {
                targetX = visible.minX + horizontalInset
            }

            if fittingSize.height < visible.height - (verticalInset * 2) {
                targetY = max(visible.minY + verticalInset, min(preferredY, visible.maxY - fittingSize.height - verticalInset))
            } else {
                targetY = visible.minY + verticalInset
            }
        }

        let targetFrame = NSRect(x: targetX, y: targetY, width: fittingSize.width, height: fittingSize.height)
        let currentFrame = menuWindow.frame
        let frameTolerance: CGFloat = 0.5
        let isSameFrame =
            abs(currentFrame.origin.x - targetFrame.origin.x) <= frameTolerance &&
            abs(currentFrame.origin.y - targetFrame.origin.y) <= frameTolerance &&
            abs(currentFrame.size.width - targetFrame.size.width) <= frameTolerance &&
            abs(currentFrame.size.height - targetFrame.size.height) <= frameTolerance

        if !isSameFrame {
            menuWindow.setFrame(targetFrame, display: false)
        }
    }
}

private struct BottomOverlayModeMenuView: View {
    @ObservedObject private var contentState = NotchContentState.shared
    @ObservedObject private var settings = SettingsStore.shared

    let maxWidth: CGFloat
    let onHoverChanged: (Bool) -> Void
    let onDismissRequested: () -> Void

    @State private var hoveredRowID: String?

    private var normalizedOverlayMode: OverlayMode {
        switch self.contentState.mode {
        case .dictation:
            return .dictation
        case .edit, .write, .rewrite:
            return .edit
        case .command:
            return .command
        }
    }

    private func rowBackground(isSelected: Bool, rowID: String) -> some View {
        let isHovered = self.hoveredRowID == rowID
        let fillColor: Color
        if isSelected {
            fillColor = Color.white.opacity(0.28)
        } else if isHovered {
            fillColor = Color.white.opacity(0.20)
        } else {
            fillColor = Color.clear
        }

        let strokeColor: Color
        if isSelected {
            strokeColor = Color.white.opacity(0.38)
        } else if isHovered {
            strokeColor = Color.white.opacity(0.24)
        } else {
            strokeColor = Color.clear
        }

        return RoundedRectangle(cornerRadius: 7)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(strokeColor, lineWidth: 1)
            )
    }

    @ViewBuilder
    private func modeRow(_ title: String, mode: OverlayMode, rowID: String) -> some View {
        let isSelected = self.normalizedOverlayMode == mode
        let shortcut = OverlayShortcutResolver.shortcutDisplay(for: mode, settings: self.settings)

        Button(action: {
            guard !self.contentState.isProcessing else { return }
            self.contentState.onOverlayModeSwitchRequested?(mode)
            self.onDismissRequested()
        }) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if !shortcut.isEmpty {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(self.rowBackground(isSelected: isSelected, rowID: rowID))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            self.hoveredRowID = hovering ? rowID : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.modeRow("Dictate", mode: .dictation, rowID: "dictate")
            self.modeRow("Edit", mode: .edit, rowID: "edit")

            Divider()
                .padding(.vertical, 4)

            self.modeRow("Command", mode: .command, rowID: "command")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .frame(maxWidth: self.maxWidth)
        .preferredColorScheme(.dark)
        .onHover { hovering in
            self.onHoverChanged(hovering)
        }
    }
}

private struct BottomOverlayPromptMenuView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var contentState = NotchContentState.shared

    let promptMode: SettingsStore.PromptMode
    let maxWidth: CGFloat
    let onHoverChanged: (Bool) -> Void
    let onDismissRequested: () -> Void
    @State private var hoveredRowID: String?

    private func rowBackground(isSelected: Bool, rowID: String) -> some View {
        let isHovered = self.hoveredRowID == rowID
        let fillColor: Color
        if isSelected {
            fillColor = Color.white.opacity(0.28)
        } else if isHovered {
            fillColor = Color.white.opacity(0.20)
        } else {
            fillColor = Color.clear
        }

        let strokeColor: Color
        if isSelected {
            strokeColor = Color.white.opacity(0.38)
        } else if isHovered {
            strokeColor = Color.white.opacity(0.24)
        } else {
            strokeColor = Color.clear
        }

        return RoundedRectangle(cornerRadius: 7)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(strokeColor, lineWidth: 1)
            )
    }

    private func shortcutDisplay(for selection: SettingsStore.DictationPromptSelection) -> String? {
        guard self.promptMode.normalized == .dictate else { return nil }

        var displays: [String] = []
        if self.settings.dictationPromptSelection(for: .primary) == selection {
            displays.append(self.settings.primaryDictationShortcutDisplayString)
        }
        if self.settings.promptModeShortcutEnabled,
           self.settings.dictationPromptSelection(for: .secondary) == selection
        {
            displays.append(self.settings.promptModeHotkeyShortcut.displayString)
        }
        if let shortcut = self.settings.dictationPromptConfiguration(for: selection).shortcut {
            displays.append(shortcut.displayString)
        }

        let uniqueDisplays = displays.reduce(into: [String]()) { result, display in
            let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !result.contains(trimmed) {
                result.append(trimmed)
            }
        }
        return uniqueDisplays.isEmpty ? nil : uniqueDisplays.joined(separator: " · ")
    }

    @ViewBuilder
    private func shortcutBadge(for selection: SettingsStore.DictationPromptSelection) -> some View {
        if let shortcut = self.shortcutDisplay(for: selection) {
            Text(shortcut)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 82)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private func offRow() -> some View {
        let activeSlot = self.contentState.activeDictationShortcutSlot ?? .primary
        let isSelected = self.settings.dictationPromptSelection(for: activeSlot) == .off
        Button(action: {
            if self.promptMode.normalized == .dictate {
                self.contentState.onDictationPromptSelectionRequested?(.off)
            } else {
                self.settings.setDictationPromptSelection(.off)
            }
            self.restoreTypingTargetApp()
            self.onDismissRequested()
        }) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Fast")
                Spacer(minLength: 12)
                Text("No cleanup")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                self.shortcutBadge(for: .off)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(self.rowBackground(isSelected: isSelected, rowID: "off"))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            self.hoveredRowID = hovering ? "off" : nil
        }
    }

    @ViewBuilder
    private func defaultRow(selectedID: String?) -> some View {
        let activeSlot = self.contentState.activeDictationShortcutSlot ?? .primary
        let isSelected = (
            self.promptMode.normalized == .dictate
                ? (self.settings.dictationPromptSelection(for: activeSlot) == .default)
                : (selectedID == nil)
        )
        Button(action: {
            if self.promptMode.normalized == .dictate {
                self.contentState.onDictationPromptSelectionRequested?(.default)
            } else {
                self.settings.setSelectedPromptID(nil, for: self.promptMode)
            }
            self.restoreTypingTargetApp()
            self.onDismissRequested()
        }) {
            HStack {
                Text("Cleanup")
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                self.shortcutBadge(for: .default)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(self.rowBackground(isSelected: isSelected, rowID: "default"))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            self.hoveredRowID = hovering ? "default" : nil
        }
    }

    @ViewBuilder
    private func privateAIRow() -> some View {
        let activeSlot = self.contentState.activeDictationShortcutSlot ?? .primary
        let isAvailable = PrivateAIProviderPromptFormat.isAvailable(settings: self.settings)
        let isSelected = self.settings.dictationPromptSelection(for: activeSlot) == .privateAI
        Button(action: {
            guard isAvailable else { return }
            self.contentState.onDictationPromptSelectionRequested?(.privateAI)
            self.restoreTypingTargetApp()
            self.onDismissRequested()
        }) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Cleanup")
                Spacer(minLength: 12)
                Text("Fluid-1")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                self.shortcutBadge(for: .privateAI)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(self.rowBackground(isSelected: isSelected, rowID: PrivateAIProviderFeature.shared.providerID))
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.45)
        .help(isAvailable ? "Use \(PrivateAIProviderFeature.displayName)" : "Select \(PrivateAIProviderFeature.displayName) to enable this prompt")
        .onHover { hovering in
            self.hoveredRowID = hovering && isAvailable ? PrivateAIProviderFeature.shared.providerID : nil
        }
    }

    @ViewBuilder
    private func profileRow(_ profile: SettingsStore.DictationPromptProfile, selectedID: String?) -> some View {
        let activeSlot = self.contentState.activeDictationShortcutSlot ?? .primary
        let isSelected = (
            self.promptMode.normalized == .dictate
                ? (self.settings.dictationPromptSelection(for: activeSlot) == .profile(profile.id))
                : (selectedID == profile.id)
        )
        Button(action: {
            if self.promptMode.normalized == .dictate {
                self.contentState.onDictationPromptSelectionRequested?(.profile(profile.id))
            } else {
                self.settings.setSelectedPromptID(profile.id, for: self.promptMode)
            }
            self.restoreTypingTargetApp()
            self.onDismissRequested()
        }) {
            HStack {
                Text(profile.name.isEmpty ? "Untitled" : profile.name)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                self.shortcutBadge(for: .profile(profile.id))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(self.rowBackground(isSelected: isSelected, rowID: profile.id))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            self.hoveredRowID = hovering ? profile.id : nil
        }
    }

    var body: some View {
        let selectedID = self.settings.selectedPromptID(for: self.promptMode)
        let profiles = self.settings.promptProfiles(for: self.promptMode)

        VStack(alignment: .leading, spacing: 0) {
            if self.promptMode.normalized == .dictate {
                Text("ON-DEVICE")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 3)

                self.offRow()

                if PrivateFeatures.privateAIProvider {
                    self.privateAIRow()
                }
            }

            if self.promptMode.normalized == .dictate {
                Divider()
                    .padding(.vertical, 4)
            }

            Text("EXTERNAL")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 8)
                .padding(.top, self.promptMode.normalized == .dictate ? 0 : 4)
                .padding(.bottom, 3)

            self.defaultRow(selectedID: selectedID)

            if !profiles.isEmpty {
                ForEach(profiles) { profile in
                    self.profileRow(profile, selectedID: selectedID)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .frame(width: min(self.maxWidth, 250), alignment: .leading)
        .preferredColorScheme(.dark)
        .onHover { hovering in
            self.onHoverChanged(hovering)
        }
    }

    private func restoreTypingTargetApp() {
        let pid = NotchContentState.shared.recordingTargetPID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let pid { _ = TypingService.activateApp(pid: pid) }
        }
    }
}

private struct BottomOverlayActionsMenuView: View {
    @ObservedObject private var contentState = NotchContentState.shared
    @ObservedObject private var historyStore = TranscriptionHistoryStore.shared
    @ObservedObject private var settings = SettingsStore.shared

    let maxWidth: CGFloat
    let onHoverChanged: (Bool) -> Void
    let onDismissRequested: () -> Void

    @State private var hoveredRowID: String?

    private var normalizedOverlayMode: OverlayMode {
        switch self.contentState.mode {
        case .dictation:
            return .dictation
        case .edit, .write, .rewrite:
            return .edit
        case .command:
            return .command
        }
    }

    private var canReprocessLast: Bool {
        !self.historyStore.entries.isEmpty && !self.contentState.isProcessing
    }

    private var latestEntry: TranscriptionHistoryEntry? {
        self.historyStore.entries.first
    }

    private var canCopyLast: Bool {
        guard !self.contentState.isProcessing else { return false }
        return self.latestEntry?.clipboardText != nil
    }

    private var canPasteLast: Bool {
        self.canCopyLast
    }

    private var canUndoLastAI: Bool {
        guard !self.contentState.isProcessing else { return false }
        guard let latest = self.latestEntry else { return false }
        let raw = latest.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return latest.wasAIProcessed && !raw.isEmpty
    }

    private func rowBackground(isSelected: Bool, rowID: String) -> some View {
        let isHovered = self.hoveredRowID == rowID
        let fillColor: Color
        if isSelected {
            fillColor = Color.white.opacity(0.28)
        } else if isHovered {
            fillColor = Color.white.opacity(0.20)
        } else {
            fillColor = Color.clear
        }

        let strokeColor: Color
        if isSelected {
            strokeColor = Color.white.opacity(0.38)
        } else if isHovered {
            strokeColor = Color.white.opacity(0.24)
        } else {
            strokeColor = Color.clear
        }

        return RoundedRectangle(cornerRadius: 7)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(strokeColor, lineWidth: 1)
            )
    }

    private func actionRow(
        title: String,
        icon: String,
        rowID: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            guard enabled else { return }
            action()
            self.onDismissRequested()
        }) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(self.rowBackground(isSelected: false, rowID: rowID))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering in
            guard enabled else {
                self.hoveredRowID = nil
                return
            }
            self.hoveredRowID = hovering ? rowID : nil
        }
    }

    private func modeRow(_ title: String, mode: OverlayMode, rowID: String) -> some View {
        let isSelected = self.normalizedOverlayMode == mode
        let shortcut = OverlayShortcutResolver.shortcutDisplay(for: mode, settings: self.settings)
        return Button(action: {
            guard !self.contentState.isProcessing else { return }
            self.contentState.onOverlayModeSwitchRequested?(mode)
            self.onDismissRequested()
        }) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if !shortcut.isEmpty {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(self.rowBackground(isSelected: isSelected, rowID: rowID))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            self.hoveredRowID = hovering ? rowID : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MODE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 3)

            self.modeRow("Dictate", mode: .dictation, rowID: "mode_dictate")
            self.modeRow("Edit", mode: .edit, rowID: "mode_edit")
            self.modeRow("Command", mode: .command, rowID: "mode_command")

            Divider()
                .padding(.vertical, 4)

            Text("ACTIONS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 8)
                .padding(.bottom, 3)

            self.actionRow(
                title: "Process Again",
                icon: "arrow.clockwise",
                rowID: "reprocess_last",
                enabled: self.canReprocessLast
            ) {
                self.contentState.onReprocessLastRequested?()
            }

            self.actionRow(
                title: "Copy Last",
                icon: "doc.on.doc",
                rowID: "copy_last",
                enabled: self.canCopyLast
            ) {
                self.contentState.onCopyLastRequested?()
            }

            self.actionRow(
                title: "Insert Last",
                icon: "arrow.down.doc",
                rowID: "paste_last",
                enabled: self.canPasteLast
            ) {
                self.contentState.onPasteLastRequested?()
            }

            self.actionRow(
                title: "Use Raw Text",
                icon: "arrow.uturn.backward",
                rowID: "undo_ai_last",
                enabled: self.canUndoLastAI
            ) {
                self.contentState.onUndoLastAIRequested?()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .frame(maxWidth: self.maxWidth)
        .preferredColorScheme(.dark)
        .onHover { hovering in
            self.onHoverChanged(hovering)
        }
    }
}

private struct PromptSelectorAnchorReader: NSViewRepresentable {
    let onFrameChange: (CGRect, NSWindow?) -> Void

    func makeNSView(context: Context) -> AnchorReportingView {
        let view = AnchorReportingView()
        view.onFrameChange = self.onFrameChange
        return view
    }

    func updateNSView(_ nsView: AnchorReportingView, context: Context) {
        nsView.onFrameChange = self.onFrameChange
        nsView.reportFrame(force: true)
    }

    final class AnchorReportingView: NSView {
        var onFrameChange: ((CGRect, NSWindow?) -> Void)?
        private var windowObservers: [NSObjectProtocol] = []
        private var lastReportedFrameInScreen: CGRect = .null
        private weak var lastReportedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            self.installWindowObservers()
            self.reportFrame(force: true)
        }

        override func layout() {
            super.layout()
            self.reportFrame()
        }

        deinit {
            self.cleanup()
        }

        func cleanup() {
            for observer in self.windowObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            self.windowObservers.removeAll()
        }

        private func installWindowObservers() {
            self.cleanup()
            guard let window = self.window else { return }

            let center = NotificationCenter.default
            self.windowObservers.append(
                center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                    self?.reportFrame()
                }
            )
            self.windowObservers.append(
                center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                    self?.reportFrame()
                }
            )
            self.windowObservers.append(
                center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
                    self?.reportFrame()
                }
            )
        }

        func reportFrame(force: Bool = false) {
            guard let window = self.window else {
                if force || !self.lastReportedFrameInScreen.isNull {
                    self.lastReportedFrameInScreen = .null
                    self.lastReportedWindow = nil
                    self.onFrameChange?(CGRect.zero, nil)
                }
                return
            }

            let frameInWindow = self.convert(self.bounds, to: nil)
            let frameInScreen = window.convertToScreen(frameInWindow)
            let frameTolerance: CGFloat = 0.5
            let hasLastFrame = !self.lastReportedFrameInScreen.isNull
            let frameChanged = !hasLastFrame ||
                abs(frameInScreen.origin.x - self.lastReportedFrameInScreen.origin.x) > frameTolerance ||
                abs(frameInScreen.origin.y - self.lastReportedFrameInScreen.origin.y) > frameTolerance ||
                abs(frameInScreen.size.width - self.lastReportedFrameInScreen.size.width) > frameTolerance ||
                abs(frameInScreen.size.height - self.lastReportedFrameInScreen.size.height) > frameTolerance
            let windowChanged = self.lastReportedWindow !== window

            guard force || frameChanged || windowChanged else { return }

            self.lastReportedFrameInScreen = frameInScreen
            self.lastReportedWindow = window
            self.onFrameChange?(frameInScreen, window)
        }
    }
}

private enum PillShadowMetrics {
    // Keep in sync with the pill shadow in BottomOverlayView.body.
    static let radius: CGFloat = 10
    static let yOffset: CGFloat = 4
    /// Hit-test inset must cover the visible shadow extent (radius + |offset|)
    /// plus a small margin so the shadow region doesn't intercept clicks.
    static let hitTestInset: CGFloat = radius + abs(yOffset) + 12
}

private final class BottomOverlayHostingView: NSHostingView<BottomOverlayView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        if SettingsStore.shared.overlaySize == .pill {
            let visibleOverlayBounds = self.bounds.insetBy(
                dx: PillShadowMetrics.hitTestInset,
                dy: PillShadowMetrics.hitTestInset
            )
            guard visibleOverlayBounds.contains(point) else { return nil }
        }
        return super.hitTest(point)
    }
}

private struct DynamicPreviewHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

// MARK: - Bottom Overlay SwiftUI View

struct BottomOverlayView: View {
    @ObservedObject private var contentState = NotchContentState.shared
    @ObservedObject private var appServices = AppServices.shared
    @ObservedObject private var activeAppMonitor = ActiveAppMonitor.shared
    @ObservedObject private var historyStore = TranscriptionHistoryStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringModeChip = false
    @State private var isHoveringPromptChip = false
    @State private var isHoveringActionsChip = false
    @State private var isHoveringSettingsChip = false
    @State private var modeSelectorFrameInScreen: CGRect = .zero
    @State private var modeSelectorWindow: NSWindow?
    @State private var promptSelectorFrameInScreen: CGRect = .zero
    @State private var promptSelectorWindow: NSWindow?
    @State private var actionsSelectorFrameInScreen: CGRect = .zero
    @State private var actionsSelectorWindow: NSWindow?
    @State private var dynamicPreviewMeasuredHeight: CGFloat = 0
    @State private var frozenDynamicPreviewHeight: CGFloat?
    @State private var dynamicPreviewResizeBucket: Int = 0
    @State private var processingStatusVisible = false
    @State private var processingStatusCycleID = 0
    @State private var lastResolvedAppIcon: NSImage?
    @State private var borderAnimationStartedAt: Date?

    struct LayoutConstants {
        let hPadding: CGFloat
        let vPadding: CGFloat
        let waveformWidth: CGFloat
        let waveformHeight: CGFloat
        let iconSize: CGFloat
        let transFontSize: CGFloat
        let modeFontSize: CGFloat
        let cornerRadius: CGFloat
        let barCount: Int
        let barWidth: CGFloat
        let barSpacing: CGFloat
        let minBarHeight: CGFloat
        let maxBarHeight: CGFloat
        let containerWidth: CGFloat
        let overlayWidth: CGFloat
        let overlayHeight: CGFloat
        let previewBoxHeight: CGFloat
        let usesFixedCanvas: Bool
        let showsTopControls: Bool
        let showsPreview: Bool
        let showsModeLabel: Bool

        static func get(for size: SettingsStore.OverlaySize) -> LayoutConstants {
            switch size {
            case .pill:
                return LayoutConstants(
                    hPadding: 12,
                    vPadding: 8,
                    waveformWidth: 46,
                    waveformHeight: 30,
                    iconSize: 18,
                    transFontSize: 10,
                    modeFontSize: 9,
                    cornerRadius: 23,
                    barCount: 8,
                    barWidth: 3.0,
                    barSpacing: 2.5,
                    minBarHeight: 4,
                    maxBarHeight: 28,
                    containerWidth: 100,
                    overlayWidth: 100,
                    overlayHeight: 46,
                    previewBoxHeight: 0,
                    usesFixedCanvas: false,
                    showsTopControls: false,
                    showsPreview: false,
                    showsModeLabel: false
                )
            case .small:
                return LayoutConstants(
                    hPadding: 10,
                    vPadding: 6,
                    waveformWidth: 90,
                    waveformHeight: 20,
                    iconSize: 16,
                    transFontSize: 11,
                    modeFontSize: 10,
                    cornerRadius: 14,
                    barCount: 7,
                    barWidth: 3.0,
                    barSpacing: 3.5,
                    minBarHeight: 5,
                    maxBarHeight: 16,
                    containerWidth: 200,
                    overlayWidth: 300,
                    overlayHeight: 124,
                    previewBoxHeight: 0,
                    usesFixedCanvas: false,
                    showsTopControls: false,
                    showsPreview: true,
                    showsModeLabel: true
                )
            case .medium:
                return LayoutConstants(
                    hPadding: 18,
                    vPadding: 12,
                    waveformWidth: 130,
                    waveformHeight: 32,
                    iconSize: 20,
                    transFontSize: 13,
                    modeFontSize: 12,
                    cornerRadius: 18,
                    barCount: 8,
                    barWidth: 3.5,
                    barSpacing: 4.5,
                    minBarHeight: 6,
                    maxBarHeight: 28,
                    containerWidth: 340,
                    overlayWidth: 380,
                    overlayHeight: 156,
                    previewBoxHeight: 0,
                    usesFixedCanvas: false,
                    showsTopControls: true,
                    showsPreview: true,
                    showsModeLabel: true
                )
            case .large:
                return LayoutConstants(
                    hPadding: 18,
                    vPadding: 12,
                    waveformWidth: 180,
                    waveformHeight: 48,
                    iconSize: 26,
                    transFontSize: 15,
                    modeFontSize: 14,
                    cornerRadius: 24,
                    barCount: 11,
                    barWidth: 5.0,
                    barSpacing: 6.0,
                    minBarHeight: 8,
                    maxBarHeight: 44,
                    containerWidth: 600,
                    overlayWidth: 600,
                    overlayHeight: 288,
                    previewBoxHeight: 92,
                    usesFixedCanvas: true,
                    showsTopControls: true,
                    showsPreview: true,
                    showsModeLabel: true
                )
            }
        }
    }

    private var layout: LayoutConstants {
        LayoutConstants.get(for: self.settings.overlaySize)
    }

    private var isCompactControls: Bool {
        self.settings.overlaySize == .medium
    }

    private var waveformHorizontalOffset: CGFloat {
        self.settings.overlaySize == .medium ? -28 : 0
    }

    private var isPillSize: Bool {
        self.settings.overlaySize == .pill
    }

    private var modeColor: Color {
        self.contentState.mode.notchColor
    }

    private var modeLabel: String {
        switch self.contentState.mode {
        case .dictation: return "Dictate"
        case .edit, .rewrite, .write: return "Edit"
        case .command: return "Command"
        }
    }

    private var displayedAppIcon: NSImage? {
        self.contentState.targetAppIcon ?? self.activeAppMonitor.activeAppIcon ?? self.lastResolvedAppIcon
    }

    private var processingLabel: String {
        switch self.contentState.mode {
        case .dictation: return "Refining..."
        case .edit, .rewrite, .write: return "Thinking..."
        case .command: return "Working..."
        }
    }

    private var showsSpokenSendIndicator: Bool {
        self.contentState.mode == .dictation &&
            self.settings.spokenSendEnabled &&
            self.contentState.spokenSendIndicatorState.isVisible
    }

    private var spokenSendIndicatorSize: CGFloat {
        max(self.layout.modeFontSize + 3, 13)
    }

    private static let transientOverlayStatusTexts: Set<String> = [
        "Transcribing",
        "Refining",
        "Thinking",
        "Working",
        "Transcribing...",
        "Refining...",
        "Thinking...",
        "Working...",
    ]

    /// ContentView writes transient status strings into transcriptionText while processing
    /// (e.g. "Transcribing...", "Refining..."). Prefer that when present.
    private var processingStatusText: String {
        let t = self.contentState.transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.transientOverlayStatusTexts.contains(t) else { return self.processingLabel }
        return t
    }

    private var hasTranscription: Bool {
        !self.transcriptionPreviewText.isEmpty
    }

    private var normalizedOverlayMode: OverlayMode {
        switch self.contentState.mode {
        case .dictation:
            return .dictation
        case .edit, .write, .rewrite:
            return .edit
        case .command:
            return .command
        }
    }

    private var activePromptMode: SettingsStore.PromptMode? {
        switch self.normalizedOverlayMode {
        case .dictation:
            return .dictate
        case .edit:
            return .edit
        case .command, .write, .rewrite:
            return nil
        }
    }

    private var isPromptSelectableMode: Bool {
        self.activePromptMode != nil
    }

    private var promptResolutionBundleID: String? {
        self.activeAppMonitor.activeAppBundleID
    }

    private var activeDictationShortcutSlot: SettingsStore.DictationShortcutSlot {
        self.contentState.activeDictationShortcutSlot ?? .primary
    }

    private var isAppPromptOverrideActive: Bool {
        guard let activePromptMode else { return false }
        if activePromptMode.normalized == .dictate {
            return self.settings.isAppDictationPromptBindingActive(
                for: self.activeDictationShortcutSlot,
                appBundleID: self.promptResolutionBundleID
            )
        }
        return self.settings.hasAppPromptBinding(
            for: activePromptMode,
            appBundleID: self.promptResolutionBundleID
        )
    }

    private var selectedPromptLabel: String {
        guard let activePromptMode else { return "N/A" }
        if activePromptMode.normalized == .dictate {
            return self.settings.dictationPromptDisplayName(
                for: self.activeDictationShortcutSlot,
                appBundleID: self.promptResolutionBundleID
            )
        }
        if let profile = self.settings.resolvedPromptProfile(
            for: activePromptMode,
            appBundleID: self.promptResolutionBundleID
        ) {
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Untitled" : name
        }
        return "Default"
    }

    private var promptSelectorBuiltInLabel: String? {
        guard let activePromptMode else { return nil }
        if activePromptMode.normalized == .dictate {
            switch self.settings.dictationPromptSelection(for: self.activeDictationShortcutSlot) {
            case .off:
                return "Fast"
            case .privateAI:
                return "Cleanup"
            case .default:
                let hasAppOverride = self.settings.resolvedDictationPromptProfile(
                    for: self.activeDictationShortcutSlot,
                    appBundleID: self.promptResolutionBundleID
                ) != nil
                return hasAppOverride ? nil : "Cleanup"
            case .profile:
                return nil
            }
        }

        return self.settings.resolvedPromptProfile(
            for: activePromptMode,
            appBundleID: self.promptResolutionBundleID
        ) == nil ? "Cleanup" : nil
    }

    private var promptSelectorDisplayLabel: String {
        let selectedLabel = self.selectedPromptLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = self.promptSelectorBuiltInLabel ?? selectedLabel
        guard !label.isEmpty else { return "Default" }

        let maxLength: Int
        if self.promptSelectorBuiltInLabel == nil {
            maxLength = 11
        } else if self.isCompactControls {
            maxLength = self.isAppPromptOverrideActive ? 8 : 14
        } else {
            maxLength = self.isAppPromptOverrideActive ? 11 : 16
        }

        guard label.count > maxLength else { return label }
        let prefixLength = max(maxLength - 3, 1)
        return "\(label.prefix(prefixLength))..."
    }

    private var promptSelectorIconName: String? {
        switch self.promptSelectorBuiltInLabel {
        case "Fast"?:
            return "bolt.fill"
        case "Cleanup"?:
            return "sparkles"
        default:
            return nil
        }
    }

    private var promptSelectorFontSize: CGFloat {
        if self.isCompactControls { return 10 }
        return max(self.layout.modeFontSize - 1, 9)
    }

    private var promptSelectorLabelFontSize: CGFloat {
        max(self.promptSelectorFontSize - 1, 8)
    }

    private var promptSelectorVerticalPadding: CGFloat {
        4
    }

    private var promptMenuGap: CGFloat {
        max(0, self.layout.vPadding * 0.05)
    }

    private var promptSelectorCornerRadius: CGFloat {
        max(self.layout.cornerRadius * 0.42, 8)
    }

    private var promptSelectorMaxWidth: CGFloat {
        self.layout.waveformWidth * 1.75
    }

    private var previewMaxHeight: CGFloat {
        self.layout.usesFixedCanvas ? self.layout.previewBoxHeight : self.layout.transFontSize * 4.2
    }

    private var shouldReservePreviewArea: Bool {
        self.layout.showsPreview &&
            (self.settings.enableStreamingPreview || self.contentState.isAIProcessingFailureVisible)
    }

    private var overlayFrameHeight: CGFloat? {
        guard self.layout.usesFixedCanvas else { return nil }
        return self.shouldReservePreviewArea ? self.layout.overlayHeight : nil
    }

    private var previewMaxWidth: CGFloat {
        if self.layout.usesFixedCanvas {
            return self.layout.waveformWidth * 2.2
        }

        return max(self.layout.waveformWidth * 2.2, self.layout.containerWidth - self.layout.hPadding * 2)
    }

    private var dynamicPreviewBaseMinHeight: CGFloat {
        guard self.shouldReservePreviewArea else { return 0 }
        let verticalPadding = self.settings.overlaySize == .small
            ? max(2, self.transcriptionVerticalPadding - 1)
            : self.transcriptionVerticalPadding
        return self.estimatedPreviewLineHeight + verticalPadding * 2
    }

    private var effectiveDynamicPreviewLockedHeight: CGFloat? {
        guard self.contentState.isBottomOverlayReleaseTransitioning else { return nil }
        guard let frozenDynamicPreviewHeight else { return nil }
        return max(frozenDynamicPreviewHeight, self.dynamicPreviewBaseMinHeight)
    }

    private var effectiveDynamicPreviewMinHeight: CGFloat {
        self.effectiveDynamicPreviewLockedHeight ?? self.dynamicPreviewBaseMinHeight
    }

    private var estimatedPreviewLineHeight: CGFloat {
        max(self.layout.transFontSize * 1.25, self.layout.transFontSize + 2)
    }

    private var currentPreviewSizingText: String {
        guard self.shouldReservePreviewArea else { return "" }
        if self.shouldShowProcessingPreview {
            return self.processingPreviewText
        }
        return self.shouldShowProcessingStatus ? self.processingStatusText : self.transcriptionPreviewText
    }

    private var shouldShowProcessingStatus: Bool {
        self.shouldReservePreviewArea && self.contentState.isProcessing && self.processingStatusVisible
    }

    private var shouldShowAIProcessingFailure: Bool {
        self.shouldReservePreviewArea && self.contentState.isAIProcessingFailureVisible && !self.contentState.isProcessing
    }

    private var shouldSuppressPreviewDuringRelease: Bool {
        if self.shouldShowProcessingPreview {
            return false
        }
        return self.contentState.isBottomOverlayReleaseTransitioning || self.contentState.isBottomOverlayDismissing
    }

    private func previewResizeBucket(for previewText: String) -> Int {
        guard self.shouldReservePreviewArea else { return 0 }
        if self.shouldShowAIProcessingFailure { return 1 }
        let trimmed = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self.shouldShowProcessingStatus ? 1 : 0 }

        if self.settings.overlaySize == .small {
            return 1
        }

        let newlineCount = trimmed.filter { $0 == "\n" }.count
        let estimatedCharacterWidth = max(self.layout.transFontSize * 0.56, 1)
        let characterCapacity = max(Int((self.previewMaxWidth / estimatedCharacterWidth).rounded(.down)), 12)
        let estimatedWrappedLines = max(1, (trimmed.count + characterCapacity - 1) / characterCapacity)
        let maxVisibleLines = max(Int((self.previewMaxHeight / max(self.estimatedPreviewLineHeight, 1)).rounded(.down)), 1)
        return min(max(estimatedWrappedLines + newlineCount, 1), maxVisibleLines)
    }

    private func refreshDynamicPreviewSizeIfNeeded(for previewText: String) {
        guard self.shouldReservePreviewArea else { return }
        guard !self.layout.usesFixedCanvas else { return }
        let nextBucket = self.previewResizeBucket(for: previewText)
        guard nextBucket != self.dynamicPreviewResizeBucket else { return }
        self.dynamicPreviewResizeBucket = nextBucket
        BottomOverlayWindowController.shared.refreshSizeForContent()
    }

    private var transcriptionVerticalPadding: CGFloat {
        max(4, self.layout.vPadding / 2)
    }

    private var transcriptionPreviewText: String {
        let preview = self.contentState.cachedPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !self.contentState.isProcessing else { return self.contentState.cachedPreviewText }
        guard Self.transientOverlayStatusTexts.contains(preview) else { return self.contentState.cachedPreviewText }
        return ""
    }

    private var processingPreviewText: String {
        guard self.contentState.isProcessing else { return "" }
        let preview = self.transcriptionPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.transientOverlayStatusTexts.contains(preview) else { return "" }
        return self.transcriptionPreviewText
    }

    private var shouldShowProcessingPreview: Bool {
        !self.processingPreviewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func richPreviewText(_ previewText: String) -> Text {
        Text(previewText)
            .foregroundColor(.white.opacity(0.9))
    }

    private var overlayBorderLineWidth: CGFloat {
        self.settings.overlaySize == .large ? 0.8 : 1
    }

    private var overlayBorderTopOpacity: Double {
        switch self.settings.overlaySize {
        case .pill: return 0.22 // a touch crisper so the smaller pill reads clearly
        case .large: return 0.10
        default: return 0.15
        }
    }

    private var overlayBorderBottomOpacity: Double {
        switch self.settings.overlaySize {
        case .pill: return 0.10
        case .large: return 0.05
        default: return 0.08
        }
    }

    private var overlayAnimatedOffsetY: CGFloat {
        if self.contentState.isBottomOverlayDismissing {
            return self.contentState.bottomOverlayDismissOffsetY
        }
        return 0
    }

    private var overlayAnimatedScale: CGFloat {
        self.contentState.isBottomOverlayDismissing ? 0.985 : 1.0
    }

    private var overlayAnimatedOpacity: Double {
        1.0
    }

    private func chipBackground(isHovered: Bool, disabled: Bool) -> some View {
        let fillColor: Color
        if disabled {
            fillColor = Color.black.opacity(0.95)
        } else if isHovered {
            fillColor = Color(red: 0.13, green: 0.13, blue: 0.16)
        } else {
            fillColor = Color.black
        }

        let topStrokeOpacity: Double = disabled ? 0.10 : (isHovered ? 0.36 : 0.14)
        let bottomStrokeOpacity: Double = disabled ? 0.06 : (isHovered ? 0.22 : 0.08)
        let hoverShadowColor: Color = (isHovered && !disabled) ? Color.white.opacity(0.16) : .clear

        return RoundedRectangle(cornerRadius: self.promptSelectorCornerRadius)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: self.promptSelectorCornerRadius)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(topStrokeOpacity),
                                Color.white.opacity(bottomStrokeOpacity),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: hoverShadowColor, radius: 6, x: 0, y: 1)
    }

    private func closePromptMenu() {
        BottomOverlayPromptMenuController.shared.hide()
    }

    private func rememberAppIcon(_ icon: NSImage?) {
        guard let icon else { return }
        self.lastResolvedAppIcon = icon
    }

    private func handlePromptSelectorHover(_ hovering: Bool) {
        // Hover-open disabled by design.
    }

    private func handlePromptSelectorFrameChange(_ frameInScreen: CGRect, window: NSWindow?) {
        self.promptSelectorFrameInScreen = frameInScreen
        self.promptSelectorWindow = window
        guard self.layout.showsTopControls, self.isPromptSelectableMode, !self.contentState.isProcessing else {
            BottomOverlayPromptMenuController.shared.hide()
            return
        }

        BottomOverlayPromptMenuController.shared.updateAnchor(
            selectorFrameInScreen: frameInScreen,
            parentWindow: window,
            maxWidth: self.promptSelectorMaxWidth,
            menuGap: self.promptMenuGap
        )
    }

    private func requestModeSwitch(_ mode: OverlayMode) {
        guard !self.contentState.isProcessing else { return }
        self.contentState.onOverlayModeSwitchRequested?(mode)
        BottomOverlayModeMenuController.shared.hide()
    }

    private func closeModeMenu() {
        BottomOverlayModeMenuController.shared.hide()
    }

    private func closeActionsMenu() {
        BottomOverlayActionsMenuController.shared.hide()
    }

    private func handleModeSelectorHover(_ hovering: Bool) {
        guard !self.contentState.isProcessing else {
            self.closeModeMenu()
            return
        }
        BottomOverlayModeMenuController.shared.selectorHoverChanged(hovering)
    }

    private func handleModeSelectorFrameChange(_ frameInScreen: CGRect, window: NSWindow?) {
        self.modeSelectorFrameInScreen = frameInScreen
        self.modeSelectorWindow = window
        guard self.layout.showsTopControls, !self.contentState.isProcessing else {
            BottomOverlayModeMenuController.shared.hide()
            return
        }

        BottomOverlayModeMenuController.shared.updateAnchor(
            selectorFrameInScreen: frameInScreen,
            parentWindow: window,
            maxWidth: self.promptSelectorMaxWidth,
            menuGap: self.promptMenuGap
        )
    }

    private func handleActionsSelectorHover(_ hovering: Bool) {
        let actionsDisabled = self.contentState.isProcessing
        guard !actionsDisabled else {
            self.closeActionsMenu()
            return
        }
        BottomOverlayActionsMenuController.shared.selectorHoverChanged(hovering)
    }

    private func handleActionsSelectorFrameChange(_ frameInScreen: CGRect, window: NSWindow?) {
        self.actionsSelectorFrameInScreen = frameInScreen
        self.actionsSelectorWindow = window
        let actionsDisabled = self.contentState.isProcessing
        guard self.layout.showsTopControls, !actionsDisabled else {
            BottomOverlayActionsMenuController.shared.hide()
            return
        }

        BottomOverlayActionsMenuController.shared.updateAnchor(
            selectorFrameInScreen: frameInScreen,
            parentWindow: window,
            maxWidth: self.promptSelectorMaxWidth,
            menuGap: self.promptMenuGap
        )
    }

    private var modeSelectorTrigger: some View {
        HStack(spacing: 5) {
            if !self.isCompactControls {
                Text("Mode:")
                    .font(.system(size: self.promptSelectorFontSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Text(self.modeLabel)
                .font(.system(size: self.promptSelectorFontSize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
            Image(systemName: "chevron.up")
                .font(.system(size: max(self.promptSelectorFontSize - 1, 8), weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 8)
        .padding(.vertical, self.promptSelectorVerticalPadding)
        .background(
            self.chipBackground(isHovered: self.isHoveringModeChip, disabled: self.contentState.isProcessing)
        )
    }

    private var modeSelectorView: some View {
        self.modeSelectorTrigger
            .background(
                PromptSelectorAnchorReader { frameInScreen, window in
                    self.handleModeSelectorFrameChange(frameInScreen, window: window)
                }
                .allowsHitTesting(false)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                self.isHoveringModeChip = hovering && !self.contentState.isProcessing
            }
            .onTapGesture {
                guard self.layout.showsTopControls, !self.contentState.isProcessing else { return }
                self.closePromptMenu()
                self.closeActionsMenu()
                BottomOverlayModeMenuController.shared.updateAnchor(
                    selectorFrameInScreen: self.modeSelectorFrameInScreen,
                    parentWindow: self.modeSelectorWindow,
                    maxWidth: self.promptSelectorMaxWidth,
                    menuGap: self.promptMenuGap
                )
                BottomOverlayModeMenuController.shared.toggleFromTap()
            }
    }

    private var promptSelectorTrigger: some View {
        HStack(spacing: 5) {
            if let promptSelectorIconName = self.promptSelectorIconName {
                Image(systemName: promptSelectorIconName)
                    .font(.system(size: max(self.promptSelectorFontSize - 1, 9), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }
            Text(self.promptSelectorDisplayLabel)
                .font(.system(size: self.promptSelectorFontSize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(
                    maxWidth: self.promptSelectorBuiltInLabel == nil ? 72 : nil,
                    alignment: .leading
                )
            if self.isAppPromptOverrideActive {
                Text("App")
                    .font(.system(size: max(self.promptSelectorFontSize - 2, 8), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.15))
                    )
            }
            Image(systemName: "chevron.down")
                .font(.system(size: max(self.promptSelectorFontSize - 1, 8), weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, self.promptSelectorVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: self.promptSelectorCornerRadius, style: .continuous)
                .fill(
                    self.isHoveringPromptChip && self.isPromptSelectableMode && !self.contentState.isProcessing
                        ? Color.white.opacity(0.10)
                        : Color.clear
                )
        )
        .overlay(alignment: .top) {
            if self.isHoveringPromptChip, self.isPromptSelectableMode, !self.contentState.isProcessing {
                Text("Select cleanup mode")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.94))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
                    .fixedSize()
                    .offset(y: -30)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Select cleanup mode")
    }

    private var promptSelectorView: some View {
        Group {
            if self.isPromptSelectableMode {
                self.promptSelectorTrigger
                    .background(
                        PromptSelectorAnchorReader { frameInScreen, window in
                            self.handlePromptSelectorFrameChange(frameInScreen, window: window)
                        }
                        .allowsHitTesting(false)
                    )
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        self.isHoveringPromptChip = hovering && !self.contentState.isProcessing
                    }
                    .onTapGesture {
                        guard self.layout.showsTopControls, self.isPromptSelectableMode, !self.contentState.isProcessing else { return }
                        self.closeModeMenu()
                        self.closeActionsMenu()
                        BottomOverlayPromptMenuController.shared.updateAnchor(
                            selectorFrameInScreen: self.promptSelectorFrameInScreen,
                            parentWindow: self.promptSelectorWindow,
                            maxWidth: self.promptSelectorMaxWidth,
                            menuGap: self.promptMenuGap
                        )
                        BottomOverlayPromptMenuController.shared.toggleFromTap()
                    }
            } else {
                self.promptSelectorTrigger
                    .opacity(0.6)
                    .onHover { _ in
                        self.isHoveringPromptChip = false
                    }
            }
        }
    }

    private var actionsSelectorTrigger: some View {
        let actionsDisabled = self.contentState.isProcessing
        return HStack(spacing: 0) {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white.opacity(actionsDisabled ? 0.3 : 0.78))
        }
        .frame(width: 32, height: 32)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(self.isHoveringActionsChip && !actionsDisabled ? Color.white.opacity(0.1) : Color.clear)
        )
        .overlay(alignment: .top) {
            if self.isHoveringActionsChip, !actionsDisabled {
                Text("Actions")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.94))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
                    .fixedSize()
                    .offset(y: -30)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Actions")
    }

    private var actionsSelectorView: some View {
        let actionsDisabled = self.contentState.isProcessing
        return self.actionsSelectorTrigger
            .background(
                PromptSelectorAnchorReader { frameInScreen, window in
                    self.handleActionsSelectorFrameChange(frameInScreen, window: window)
                }
                .allowsHitTesting(false)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                self.isHoveringActionsChip = hovering && !actionsDisabled
                self.handleActionsSelectorHover(hovering)
            }
            .onTapGesture {
                guard self.layout.showsTopControls, !actionsDisabled else { return }
                self.isHoveringActionsChip = false
                self.closePromptMenu()
                self.closeModeMenu()
                BottomOverlayActionsMenuController.shared.updateAnchor(
                    selectorFrameInScreen: self.actionsSelectorFrameInScreen,
                    parentWindow: self.actionsSelectorWindow,
                    maxWidth: self.promptSelectorMaxWidth,
                    menuGap: self.promptMenuGap
                )
                BottomOverlayActionsMenuController.shared.toggleFromTap()
            }
    }

    private var settingsChip: some View {
        let disabled = false
        return HStack(spacing: 0) {
            Image(systemName: "gearshape")
                .font(.system(size: max(self.promptSelectorFontSize + 1, 10), weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, self.promptSelectorVerticalPadding)
        .background(
            self.chipBackground(
                isHovered: self.isHoveringSettingsChip,
                disabled: disabled
            )
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            self.isHoveringSettingsChip = hovering
        }
        .onTapGesture {
            self.closePromptMenu()
            self.closeModeMenu()
            self.closeActionsMenu()
            self.contentState.onOpenPreferencesRequested?()
        }
        .help("Open Preferences")
    }

    private func failureIconButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: max(self.layout.transFontSize - 1, 10), weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
                .frame(width: 20, height: 20)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var aiProcessingFailureView: some View {
        HStack(spacing: 8) {
            Text(self.contentState.aiProcessingFailureMessage)
                .font(.system(size: self.layout.transFontSize, weight: .semibold))
                .foregroundStyle(
                    self.contentState.canRetryAIProcessingFailure
                        ? Color.white.opacity(0.9)
                        : Color.orange.opacity(0.9)
                )
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if self.contentState.canRetryAIProcessingFailure {
                self.failureIconButton(systemName: "arrow.clockwise", help: "Try again") {
                    self.contentState.clearAIProcessingFailure()
                    self.contentState.onReprocessLastRequested?()
                }
            }

            self.failureIconButton(systemName: "xmark", help: "Dismiss") {
                self.contentState.clearAIProcessingFailure()
                NotchOverlayManager.shared.hide()
            }
        }
        .frame(maxWidth: self.previewMaxWidth, alignment: .leading)
    }

    private var targetAppIconView: some View {
        let appIcon = self.displayedAppIcon
        let showModelLoading = self.layout.showsModeLabel && !self.appServices.asr.isAsrReady &&
            (self.appServices.asr.isLoadingModel || self.appServices.asr.isDownloadingModel)
        return VStack(spacing: 2) {
            if showModelLoading {
                ProgressView()
                    .controlSize(.mini)
            }
            if let appIcon = appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: self.layout.iconSize, height: self.layout.iconSize)
                    .clipShape(RoundedRectangle(cornerRadius: self.layout.iconSize / 4))
            } else if !self.layout.showsModeLabel {
                Circle()
                    .fill(self.modeColor.opacity(0.9))
                    .frame(width: max(self.layout.iconSize * 0.45, 7), height: max(self.layout.iconSize * 0.45, 7))
            }
        }
        .frame(width: self.layout.iconSize, height: self.layout.iconSize)
        .opacity((appIcon != nil || showModelLoading || !self.layout.showsModeLabel) ? 1 : 0)
    }

    private var leadingAppContextView: some View {
        HStack(spacing: self.isPillSize ? 4 : 8) {
            if self.showsSpokenSendIndicator {
                SpokenSendIndicatorView(
                    state: self.contentState.spokenSendIndicatorState,
                    color: self.modeColor,
                    size: self.isPillSize ? 14 : self.spokenSendIndicatorSize
                )
                .id(self.contentState.spokenSendCountdownID)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }

            self.targetAppIconView
        }
        .animation(
            self.reduceMotion ? nil : .easeOut(duration: 0.14),
            value: self.contentState.spokenSendIndicatorState
        )
    }

    private func scrollablePreviewText(_ previewText: String) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                self.richPreviewText(previewText)
                    .font(.system(size: self.layout.transFontSize, weight: .medium))
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(height: 1).id("bottom")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .onChange(of: previewText) { _, _ in
                DispatchQueue.main.async {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func dynamicPreviewText(_ previewText: String) -> some View {
        if self.settings.overlaySize == .small {
            self.richPreviewText(previewText)
                .font(.system(size: self.layout.transFontSize, weight: .medium))
                .multilineTextAlignment(.leading)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, max(2, self.transcriptionVerticalPadding - 1))
        } else {
            self.richPreviewText(previewText)
                .font(.system(size: self.layout.transFontSize, weight: .medium))
                .multilineTextAlignment(.leading)
                .lineLimit(Int(self.previewMaxHeight / max(self.estimatedPreviewLineHeight, 1)))
                .truncationMode(.head)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: self.previewMaxWidth, alignment: .leading)
                .padding(.vertical, self.transcriptionVerticalPadding)
        }
    }

    var body: some View {
        VStack(spacing: max(4, self.layout.vPadding / 2)) {
            if self.layout.showsTopControls, !self.isCompactControls {
                HStack {
                    Spacer(minLength: 4)
                    self.settingsChip
                }
                .padding(.horizontal, self.layout.hPadding)
            }

            VStack(spacing: self.layout.vPadding / 2) {
                if self.shouldReservePreviewArea {
                    if self.layout.usesFixedCanvas {
                        // Transcription text area (fixed-height in large mode)
                        Group {
                            if self.shouldSuppressPreviewDuringRelease {
                                Color.clear
                            } else if self.shouldShowAIProcessingFailure {
                                self.aiProcessingFailureView
                            } else if self.shouldShowProcessingPreview {
                                self.scrollablePreviewText(self.processingPreviewText)
                            } else if self.shouldShowProcessingStatus {
                                // Temporarily hidden; the waveform sweep carries processing state.
                                // ShimmerText(
                                //     text: self.processingStatusText,
                                //     color: self.modeColor,
                                //     font: .system(size: self.layout.transFontSize, weight: .medium)
                                // )
                                // .id(self.processingStatusCycleID)
                                // .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                Color.clear
                            } else if self.contentState.isProcessing {
                                Color.clear
                            } else if self.hasTranscription {
                                let previewText = self.transcriptionPreviewText
                                if !previewText.isEmpty {
                                    ScrollViewReader { proxy in
                                        ScrollView(.vertical, showsIndicators: false) {
                                            Text(previewText)
                                                .font(.system(size: self.layout.transFontSize, weight: .medium))
                                                .foregroundStyle(.white.opacity(0.9))
                                                .multilineTextAlignment(.leading)
                                                .lineLimit(nil)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Color.clear.frame(height: 1).id("bottom")
                                        }
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                        .clipped()
                                        .onAppear {
                                            DispatchQueue.main.async {
                                                proxy.scrollTo("bottom", anchor: .bottom)
                                            }
                                        }
                                        .onChange(of: previewText) { _, _ in
                                            DispatchQueue.main.async {
                                                proxy.scrollTo("bottom", anchor: .bottom)
                                            }
                                        }
                                    }
                                }
                            } else {
                                Color.clear
                            }
                        }
                        .padding(.vertical, self.transcriptionVerticalPadding)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: self.previewMaxHeight,
                            maxHeight: self.previewMaxHeight,
                            alignment: .topLeading
                        )
                    } else {
                        // Original dynamic preview behavior for small/medium
                        Group {
                            if self.shouldSuppressPreviewDuringRelease {
                                Color.clear
                            } else if self.shouldShowAIProcessingFailure {
                                self.aiProcessingFailureView
                            } else if self.shouldShowProcessingPreview {
                                self.dynamicPreviewText(self.processingPreviewText)
                            } else if self.hasTranscription && !self.contentState.isProcessing {
                                let previewText = self.transcriptionPreviewText
                                if !previewText.isEmpty {
                                    if self.settings.overlaySize == .small {
                                        Text(previewText)
                                            .font(.system(size: self.layout.transFontSize, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.9))
                                            .multilineTextAlignment(.leading)
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.vertical, max(2, self.transcriptionVerticalPadding - 1))
                                    } else {
                                        Text(previewText)
                                            .font(.system(size: self.layout.transFontSize, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.9))
                                            .multilineTextAlignment(.leading)
                                            .lineLimit(Int(self.previewMaxHeight / max(self.estimatedPreviewLineHeight, 1)))
                                            .truncationMode(.head)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(width: self.previewMaxWidth, alignment: .leading)
                                            .padding(.vertical, self.transcriptionVerticalPadding)
                                    }
                                }
                            } else if self.shouldShowProcessingStatus {
                                // Temporarily hidden; the waveform sweep carries processing state.
                                // ShimmerText(
                                //     text: self.processingStatusText,
                                //     color: self.modeColor,
                                //     font: .system(size: self.layout.transFontSize, weight: .medium)
                                // )
                                // .id(self.processingStatusCycleID)
                                Color.clear
                            } else if self.contentState.isProcessing {
                                Color.clear
                            } else {
                                Color.clear
                            }
                        }
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .preference(key: DynamicPreviewHeightPreferenceKey.self, value: proxy.size.height)
                            }
                        )
                        .frame(
                            maxWidth: self.previewMaxWidth,
                            minHeight: self.effectiveDynamicPreviewMinHeight,
                            maxHeight: self.effectiveDynamicPreviewLockedHeight
                        )
                    }
                }

                // Waveform + Mode label row
                HStack(spacing: self.isPillSize ? 4 : self.layout.hPadding / 1.5) {
                    if !self.layout.showsTopControls {
                        self.leadingAppContextView
                    }

                    // Waveform visualization
                    BottomWaveformView(
                        color: self.modeColor,
                        layout: self.layout,
                        visibleBarCount: self.isPillSize && self.showsSpokenSendIndicator ? 6 : nil
                    )
                    .frame(
                        width: self.isPillSize && self.showsSpokenSendIndicator
                            ? 32
                            : self.layout.waveformWidth,
                        height: self.layout.waveformHeight
                    )

                    // Compact overlays still need a visible mode because they have no selector.
                    if self.layout.showsModeLabel, !self.layout.showsTopControls {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(self.modeLabel)
                                .font(.system(size: self.layout.modeFontSize, weight: .semibold))
                                .foregroundStyle(self.modeColor)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)

                            if !self.appServices.asr.isAsrReady &&
                                (self.appServices.asr.isLoadingModel || self.appServices.asr.isDownloadingModel)
                                && self.settings.overlaySize != .small
                            {
                                Text("Loading model…")
                                    .font(.system(size: max(self.layout.modeFontSize - 2, 9), weight: .medium))
                                    .foregroundStyle(.orange.opacity(0.85))
                                    .lineLimit(1)
                            }
                        }
                        .animation(
                            self.reduceMotion ? nil : .easeOut(duration: 0.14),
                            value: self.contentState.spokenSendIndicatorState
                        )
                    }
                }
                .offset(x: self.waveformHorizontalOffset)
                .frame(maxWidth: .infinity, alignment: .center)
                .overlay(alignment: .leading) {
                    if self.layout.showsTopControls {
                        self.leadingAppContextView
                    }
                }
                .overlay(alignment: .trailing) {
                    if self.layout.showsTopControls {
                        HStack(spacing: 8) {
                            self.promptSelectorView
                            self.actionsSelectorView
                        }
                    }
                }
            }
            .padding(.horizontal, self.layout.hPadding)
            .padding(.vertical, self.layout.vPadding)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(
                ZStack {
                    // Solid pitch black background, with a soft drop shadow so the pill lifts
                    // off whatever is behind it (pill size only; outer padding reserves room).
                    RoundedRectangle(cornerRadius: self.layout.cornerRadius)
                        .fill(Color.black)
                        .shadow(
                            color: Color.black.opacity(self.isPillSize ? 0.32 : 0),
                            radius: self.isPillSize ? PillShadowMetrics.radius : 0,
                            x: 0,
                            y: self.isPillSize ? PillShadowMetrics.yOffset : 0
                        )

                    if self.isPillSize {
                        // Glossy border: a bright highlight that slowly rotates around the edge.
                        // Paused under reduce-motion to avoid continuous redraws on low-resource Macs.
                        if self.reduceMotion || !self.contentState.isBottomOverlayPresented {
                            RoundedRectangle(cornerRadius: self.layout.cornerRadius)
                                .strokeBorder(
                                    AngularGradient(
                                        gradient: Gradient(stops: [
                                            .init(color: .white.opacity(0.06), location: 0.00),
                                            .init(color: .white.opacity(0.55), location: 0.13),
                                            .init(color: .white.opacity(0.10), location: 0.30),
                                            .init(color: .white.opacity(0.03), location: 0.55),
                                            .init(color: .white.opacity(0.22), location: 0.80),
                                            .init(color: .white.opacity(0.06), location: 1.00),
                                        ]),
                                        center: .center,
                                        angle: .degrees(0)
                                    ),
                                    lineWidth: 1.2
                                )
                        } else {
                            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                                let seconds = max(
                                    0,
                                    timeline.date.timeIntervalSince(self.borderAnimationStartedAt ?? timeline.date)
                                )
                                let angle = (seconds.truncatingRemainder(dividingBy: 6.0) / 6.0) * 360.0
                                RoundedRectangle(cornerRadius: self.layout.cornerRadius)
                                    .strokeBorder(
                                        AngularGradient(
                                            gradient: Gradient(stops: [
                                                .init(color: .white.opacity(0.06), location: 0.00),
                                                .init(color: .white.opacity(0.55), location: 0.13),
                                                .init(color: .white.opacity(0.10), location: 0.30),
                                                .init(color: .white.opacity(0.03), location: 0.55),
                                                .init(color: .white.opacity(0.22), location: 0.80),
                                                .init(color: .white.opacity(0.06), location: 1.00),
                                            ]),
                                            center: .center,
                                            angle: .degrees(angle)
                                        ),
                                        lineWidth: 1.2
                                    )
                            }
                        }
                    } else {
                        // Inner border
                        RoundedRectangle(cornerRadius: self.layout.cornerRadius)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(self.overlayBorderTopOpacity),
                                        Color.white.opacity(self.overlayBorderBottomOpacity),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: self.overlayBorderLineWidth
                            )
                    }
                }
            )
            .frame(maxWidth: .infinity, alignment: .top)
            .transaction { transaction in
                if self.shouldSuppressPreviewDuringRelease {
                    transaction.animation = nil
                }
            }
        }
        .frame(
            width: self.layout.usesFixedCanvas ? self.layout.overlayWidth : self.layout.containerWidth,
            height: self.overlayFrameHeight,
            alignment: .top
        )
        // Reserve space around the pill so its drop shadow isn't clipped by the (content-sized) window.
        .padding(self.isPillSize ? 26 : 0)
        .frame(maxHeight: .infinity, alignment: .top)
        .scaleEffect(self.overlayAnimatedScale, anchor: .center)
        .offset(y: self.overlayAnimatedOffsetY)
        .opacity(self.overlayAnimatedOpacity)
        .animation(.timingCurve(0.22, 0.0, 0.2, 1.0, duration: 0.02), value: self.contentState.isBottomOverlayDismissing)
        .onChange(of: self.settings.overlaySize) { _, _ in
            self.dynamicPreviewResizeBucket = self.previewResizeBucket(for: self.currentPreviewSizingText)
            self.frozenDynamicPreviewHeight = nil
            BottomOverlayWindowController.shared.refreshSizeForContent()
        }
        .onChange(of: self.contentState.isBottomOverlayPresented) { _, presented in
            self.borderAnimationStartedAt = presented ? Date() : nil
        }
        .onChange(of: self.settings.enableStreamingPreview) { _, _ in
            self.dynamicPreviewResizeBucket = self.previewResizeBucket(for: self.currentPreviewSizingText)
            self.frozenDynamicPreviewHeight = nil
            BottomOverlayWindowController.shared.refreshSizeForContent()
        }
        .onChange(of: self.contentState.cachedPreviewText) { _, _ in
            self.refreshDynamicPreviewSizeIfNeeded(for: self.currentPreviewSizingText)
        }
        .onChange(of: self.contentState.mode) { _, _ in
            if !self.isPromptSelectableMode || self.contentState.isProcessing {
                self.closePromptMenu()
            }
            self.closeModeMenu()
            self.closeActionsMenu()
            self.isHoveringModeChip = false
            self.isHoveringPromptChip = false
            self.isHoveringActionsChip = false
            self.isHoveringSettingsChip = false
            switch self.contentState.mode {
            case .dictation: self.contentState.promptPickerMode = .dictate
            case .edit, .write, .rewrite: self.contentState.promptPickerMode = .edit
            case .command: break
            }
            if !self.layout.usesFixedCanvas {
                self.dynamicPreviewResizeBucket = self.previewResizeBucket(for: self.currentPreviewSizingText)
                BottomOverlayWindowController.shared.refreshSizeForContent()
            }
        }
        .onChange(of: self.contentState.isProcessing) { _, processing in
            self.processingStatusVisible = processing
            if processing {
                self.processingStatusCycleID &+= 1
                self.closePromptMenu()
                self.closeModeMenu()
                self.closeActionsMenu()
            }
            self.isHoveringModeChip = false
            self.isHoveringPromptChip = false
            self.isHoveringActionsChip = false
            self.isHoveringSettingsChip = false
            if !self.layout.usesFixedCanvas {
                self.refreshDynamicPreviewSizeIfNeeded(for: self.currentPreviewSizingText)
            }
        }
        .onChange(of: self.contentState.isAIProcessingFailureVisible) { _, _ in
            guard !self.layout.usesFixedCanvas else { return }
            self.refreshDynamicPreviewSizeIfNeeded(for: self.currentPreviewSizingText)
        }
        .onChange(of: self.processingStatusVisible) { _, _ in
            guard !self.layout.usesFixedCanvas else { return }
            self.refreshDynamicPreviewSizeIfNeeded(for: self.currentPreviewSizingText)
        }
        .onChange(of: self.contentState.isBottomOverlayReleaseTransitioning) { _, transitioning in
            guard self.shouldReservePreviewArea else {
                self.frozenDynamicPreviewHeight = nil
                return
            }
            guard !self.layout.usesFixedCanvas else { return }
            if transitioning {
                let measuredHeight = self.dynamicPreviewMeasuredHeight > 0
                    ? self.dynamicPreviewMeasuredHeight
                    : self.effectiveDynamicPreviewMinHeight
                self.frozenDynamicPreviewHeight = max(measuredHeight, self.dynamicPreviewBaseMinHeight)
            } else {
                self.frozenDynamicPreviewHeight = nil
                BottomOverlayWindowController.shared.refreshSizeForContent()
            }
        }
        .onPreferenceChange(DynamicPreviewHeightPreferenceKey.self) { measuredHeight in
            guard !self.layout.usesFixedCanvas else { return }
            guard measuredHeight > 0 else { return }
            self.dynamicPreviewMeasuredHeight = measuredHeight
        }
        .onAppear {
            self.rememberAppIcon(self.contentState.targetAppIcon ?? self.activeAppMonitor.activeAppIcon)
            self.dynamicPreviewResizeBucket = self.previewResizeBucket(for: self.currentPreviewSizingText)
        }
        .onReceive(self.contentState.$targetAppIcon) { icon in
            self.rememberAppIcon(icon)
        }
        .onDisappear {
            self.closePromptMenu()
            self.closeModeMenu()
            self.closeActionsMenu()
            self.isHoveringModeChip = false
            self.isHoveringPromptChip = false
            self.isHoveringActionsChip = false
            self.isHoveringSettingsChip = false
        }
        // TODO: Add tap-to-expand for command mode history (future enhancement)
        // .contentShape(Rectangle())
        // .onTapGesture {
        //     if contentState.mode == .command && !contentState.commandConversationHistory.isEmpty {
        //         NotchOverlayManager.shared.onNotchClicked?()
        //     }
        // }
    }
}

// MARK: - Bottom Waveform View (reads from NotchContentState)

struct BottomWaveformView: View {
    let color: Color
    let layout: BottomOverlayView.LayoutConstants
    let visibleBarCount: Int?

    @ObservedObject private var contentState = NotchContentState.shared
    // Initialize with max possible bar count (11 for large) to prevent index-out-of-range before onAppear
    @State private var barHeights: [CGFloat] = Array(repeating: 6, count: 11)
    @State private var noiseThreshold: CGFloat = .init(SettingsStore.shared.visualizerNoiseThreshold)

    private var barCount: Int {
        self.visibleBarCount ?? self.layout.barCount
    }

    private var barWidth: CGFloat {
        self.layout.barWidth
    }

    private var barSpacing: CGFloat {
        self.layout.barSpacing
    }

    private var minHeight: CGFloat {
        self.layout.minBarHeight
    }

    private var maxHeight: CGFloat {
        self.layout.maxBarHeight
    }

    private var isPillStyle: Bool {
        !self.layout.showsModeLabel
    }

    private var isProcessingVisualActive: Bool {
        self.contentState.isProcessing || self.isReleaseAnimationActive
    }

    private var currentGlowIntensity: CGFloat {
        if self.isPillStyle {
            return 0.0
        }
        return self.isProcessingVisualActive ? 0.0 : 0.5
    }

    private var currentGlowRadius: CGFloat {
        if self.isPillStyle {
            return 0.0
        }
        return self.isProcessingVisualActive ? 0.0 : 4
    }

    private var barFillColor: Color {
        if self.isPillStyle {
            return Color.white.opacity(self.isProcessingVisualActive ? 0.32 : 0.88)
        }
        return self.color.opacity(self.isProcessingVisualActive ? 0.16 : 1.0)
    }

    private var isReleaseAnimationActive: Bool {
        self.contentState.isBottomOverlayReleaseTransitioning || self.contentState.isBottomOverlayDismissing
    }

    /// Safe accessor for bar heights to prevent index-out-of-range crashes
    private func safeBarHeight(at index: Int) -> CGFloat {
        guard index >= 0 && index < self.barHeights.count else {
            return self.minHeight
        }
        return self.barHeights[index]
    }

    var body: some View {
        ZStack {
            self.barsView
                .foregroundStyle(self.barFillColor)

            if self.isProcessingVisualActive {
                CompositorShimmerSweep(duration: 1.05, peakOpacity: 0.9)
                    .mask {
                        self.barsView
                    }
                    .shadow(color: .white.opacity(0.28), radius: 2.5, x: 0, y: 0)
            }
        }
        .onChange(of: self.contentState.bottomOverlayAudioLevel) { _, level in
            guard !self.isReleaseAnimationActive else { return }
            if !self.contentState.isProcessing {
                self.updateBars(level: level)
            }
        }
        .onChange(of: self.contentState.isProcessing) { _, processing in
            guard !self.isReleaseAnimationActive else { return }
            if processing {
                self.setFlatProcessingBars()
            } else {
                // Resume from silence; next audio tick will animate up.
                self.updateBars(level: 0)
            }
        }
        .onChange(of: self.layout.barCount) { _, newCount in
            self.barHeights = Array(repeating: self.minHeight, count: newCount)
        }
        .onAppear {
            // Ensure bar count matches current layout
            if self.barHeights.count != self.barCount {
                self.barHeights = Array(repeating: self.minHeight, count: self.barCount)
            }
            if self.isReleaseAnimationActive {
                self.barHeights = Array(repeating: self.minHeight, count: self.barCount)
            } else if self.contentState.isProcessing {
                self.setFlatProcessingBars()
            } else {
                self.updateBars(level: 0)
            }
        }
        .onDisappear {
            // No timers to clean up.
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            // Update threshold when user changes sensitivity setting
            let newThreshold = CGFloat(SettingsStore.shared.visualizerNoiseThreshold)
            if newThreshold != self.noiseThreshold {
                self.noiseThreshold = newThreshold
            }
        }
    }

    private var barsView: some View {
        HStack(spacing: self.barSpacing) {
            ForEach(0..<self.barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: self.barWidth / 2)
                    .frame(width: self.barWidth, height: self.displayHeight(at: index))
                    .shadow(
                        color: self.color.opacity(self.isReleaseAnimationActive ? 0 : self.currentGlowIntensity),
                        radius: self.isReleaseAnimationActive ? 0 : self.currentGlowRadius,
                        x: 0,
                        y: 0
                    )
            }
        }
    }

    private func displayHeight(at index: Int) -> CGFloat {
        if self.isReleaseAnimationActive || self.contentState.isProcessing {
            return self.minHeight
        }
        return self.safeBarHeight(at: index)
    }

    private func visualizerPeakHeight(at index: Int) -> CGFloat {
        let centerDistance = abs(CGFloat(index) - CGFloat(self.barCount - 1) / 2)
        let maxDistance = max(CGFloat(self.barCount - 1) / 2, 1)
        let normalizedDistance = min(centerDistance / maxDistance, 1)
        let factor = max(0.18, 0.96 - normalizedDistance * 0.78)
        return self.minHeight + (self.maxHeight - self.minHeight) * factor
    }

    private func setFlatProcessingBars() {
        // Ensure array is properly sized before modifying
        guard self.barHeights.count >= self.barCount else { return }

        // During AI processing we want the visualizer to settle to silence (flat).
        withAnimation(.easeOut(duration: 0.18)) {
            for i in 0..<self.barCount {
                self.barHeights[i] = self.minHeight
            }
        }
    }

    private func updateBars(level: CGFloat) {
        // Ensure array is properly sized before modifying
        guard self.barHeights.count >= self.barCount else { return }

        let normalizedLevel = min(max(level, 0), 1)
        let denominator = max(1.0 - self.noiseThreshold, 0.001)
        let adjustedLevel = max(min((normalizedLevel - self.noiseThreshold) / denominator, 1.0), 0.0)
        // Lower exponent => normal speech pushes the bars higher (taller "waves" while talking).
        let amplifiedLevel = pow(adjustedLevel, 0.55)

        withAnimation(.easeOut(duration: 0.08)) {
            for i in 0..<self.barCount {
                let peakHeight = self.visualizerPeakHeight(at: i)
                let variation = 0.92 + 0.08 * cos(CGFloat(i) * 1.45)
                let nextHeight = self.minHeight + (peakHeight - self.minHeight) * amplifiedLevel * variation
                self.barHeights[i] = min(self.maxHeight, max(self.minHeight, nextHeight))
            }
        }
    }
}
