//
//  BottomOverlayView.swift
//  Fluid
//
//  Bottom overlay for transcription (alternative to notch overlay)
//

import AppKit
import Combine
import SwiftUI

private enum OverlayShortcutResolver {
    static func shortcutDisplay(for mode: OverlayMode, settings: SettingsStore = .shared) -> String {
        switch mode {
        case .dictation:
            return settings.hotkeyShortcut.displayString
        case .edit, .write, .rewrite:
            return settings.rewriteModeHotkeyShortcut.displayString
        case .command:
            return settings.commandModeHotkeyShortcut.displayString
        }
    }
}

// MARK: - Bottom Overlay Window Controller

@MainActor
final class BottomOverlayWindowController {
    static let shared = BottomOverlayWindowController()

    private var window: NSPanel?
    private var audioSubscription: AnyCancellable?
    private var pendingResizeWorkItem: DispatchWorkItem?
    private var localMouseDownMonitor: Any?
    private var globalMouseDownMonitor: Any?

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
    }

    func show(audioPublisher: AnyPublisher<CGFloat, Never>, mode: OverlayMode) {
        self.pendingResizeWorkItem?.cancel()
        self.pendingResizeWorkItem = nil
        BottomOverlayPromptMenuController.shared.hide()
        BottomOverlayModeMenuController.shared.hide()
        BottomOverlayActionsMenuController.shared.hide()
        self.ensureMouseDownMonitors()

        // Update mode in content state
        NotchContentState.shared.mode = mode
        switch mode {
        case .dictation: NotchContentState.shared.promptPickerMode = .dictate
        case .edit, .write, .rewrite: NotchContentState.shared.promptPickerMode = .edit
        case .command: break
        }
        NotchContentState.shared.updateTranscription("")
        NotchContentState.shared.bottomOverlayAudioLevel = 0

        // Subscribe to audio levels and route through NotchContentState
        self.audioSubscription?.cancel()
        self.audioSubscription = audioPublisher
            .receive(on: DispatchQueue.main)
            .sink { level in
                NotchContentState.shared.bottomOverlayAudioLevel = level
            }

        // Create window if needed
        if self.window == nil {
            self.createWindow()
        }

        // Position at bottom center of main screen
        self.positionWindow()

        // Show with animation
        self.window?.alphaValue = 0
        self.window?.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.window?.animator().alphaValue = 1
        }
    }

    func hide() {
        // Cancel audio subscription
        self.audioSubscription?.cancel()
        self.audioSubscription = nil
        self.pendingResizeWorkItem?.cancel()
        self.pendingResizeWorkItem = nil
        self.removeMouseDownMonitors()
        BottomOverlayPromptMenuController.shared.hide()
        BottomOverlayModeMenuController.shared.hide()
        BottomOverlayActionsMenuController.shared.hide()

        // Reset state
        NotchContentState.shared.setProcessing(false)
        NotchContentState.shared.bottomOverlayAudioLevel = 0
        NotchContentState.shared.targetAppIcon = nil

        guard let window = window else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: {
            window.orderOut(nil)
        }
    }

    func setProcessing(_ processing: Bool) {
        NotchContentState.shared.setProcessing(processing)
    }

    func refreshSizeForContent() {
        self.scheduleSizeAndPositionUpdate()
    }

    private func scheduleSizeAndPositionUpdate(after delay: TimeInterval = 0.03) {
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
        panel.hasShadow = false // SwiftUI handles shadow
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false

        let contentView = BottomOverlayView()
        let hostingView = NSHostingView(rootView: contentView)

        // Let SwiftUI determine the size
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)

        // Make hosting view fully transparent
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        panel.setContentSize(fittingSize)
        panel.contentView = hostingView

        self.window = panel
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

        // Use the screen that contains the window, or fallback to the main screen
        let screen = window.screen ?? NSScreen.main
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
                        .foregroundColor(.white.opacity(0.7))
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
        .onHover { hovering in
            self.onHoverChanged(hovering)
        }
    }
}

private struct BottomOverlayPromptMenuView: View {
    @ObservedObject private var settings = SettingsStore.shared

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

    @ViewBuilder
    private func defaultRow(selectedID: String?) -> some View {
        let isSelected = selectedID == nil
        Button(action: {
            self.settings.setSelectedPromptID(nil, for: self.promptMode)
            self.restoreTypingTargetApp()
            self.onDismissRequested()
        }) {
            HStack {
                Text("Default")
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
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
    private func profileRow(_ profile: SettingsStore.DictationPromptProfile, selectedID: String?) -> some View {
        let isSelected = selectedID == profile.id
        Button(action: {
            self.settings.setSelectedPromptID(profile.id, for: self.promptMode)
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
            self.defaultRow(selectedID: selectedID)

            if !profiles.isEmpty {
                Divider()
                    .padding(.vertical, 4)

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
        .frame(maxWidth: self.maxWidth)
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

    let maxWidth: CGFloat
    let onHoverChanged: (Bool) -> Void
    let onDismissRequested: () -> Void

    @State private var hoveredRowID: String?

    private var canReprocessLast: Bool {
        !self.historyStore.entries.isEmpty && !self.contentState.isProcessing
    }

    private var latestEntry: TranscriptionHistoryEntry? {
        self.historyStore.entries.first
    }

    private var canCopyLast: Bool {
        guard !self.contentState.isProcessing else { return false }
        guard let latest = self.latestEntry else { return false }
        let processed = latest.processedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = latest.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !(processed.isEmpty && raw.isEmpty)
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

    @ViewBuilder
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.actionRow(
                title: "Reprocess Last Dictation",
                icon: "arrow.clockwise",
                rowID: "reprocess_last",
                enabled: self.canReprocessLast
            ) {
                self.contentState.onReprocessLastRequested?()
            }

            self.actionRow(
                title: "Copy Last Transcription",
                icon: "doc.on.doc",
                rowID: "copy_last",
                enabled: self.canCopyLast
            ) {
                self.contentState.onCopyLastRequested?()
            }

            Divider()
                .padding(.vertical, 4)

            self.actionRow(
                title: "Undo AI on Last",
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

// MARK: - Bottom Overlay SwiftUI View

struct BottomOverlayView: View {
    @ObservedObject private var contentState = NotchContentState.shared
    @ObservedObject private var appServices = AppServices.shared
    @ObservedObject private var activeAppMonitor = ActiveAppMonitor.shared
    @ObservedObject private var historyStore = TranscriptionHistoryStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme
    @State private var isHoveringModeChip = false
    @State private var isHoveringPromptChip = false
    @State private var isHoveringAIToggleChip = false
    @State private var isHoveringActionsChip = false
    @State private var isHoveringSettingsChip = false
    @State private var modeSelectorFrameInScreen: CGRect = .zero
    @State private var modeSelectorWindow: NSWindow?
    @State private var promptSelectorFrameInScreen: CGRect = .zero
    @State private var promptSelectorWindow: NSWindow?
    @State private var actionsSelectorFrameInScreen: CGRect = .zero
    @State private var actionsSelectorWindow: NSWindow?

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

        static func get(for size: SettingsStore.OverlaySize) -> LayoutConstants {
            switch size {
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
                    showsPreview: true
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
                    barCount: 9,
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
                    showsPreview: true
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
                    showsPreview: true
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

    private var processingLabel: String {
        switch self.contentState.mode {
        case .dictation: return "Refining..."
        case .edit, .rewrite, .write: return "Thinking..."
        case .command: return "Working..."
        }
    }

    private static let transientOverlayStatusTexts: Set<String> = [
        "Transcribing...",
        "Refining...",
        "Thinking...",
        "Working...",
    ]

    // ContentView writes transient status strings into transcriptionText while processing
    // (e.g. "Transcribing...", "Refining..."). Prefer that when present.
    private var processingStatusText: String {
        let t = self.contentState.transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? self.processingLabel : t
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

    private var selectedPromptLabel: String {
        guard let activePromptMode else { return "N/A" }
        if let profile = self.settings.selectedPromptProfile(for: activePromptMode) {
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Untitled" : name
        }
        return "Default"
    }

    private var promptSelectorFontSize: CGFloat {
        max(self.layout.modeFontSize - 1, 9)
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

    private var previewMaxWidth: CGFloat {
        self.layout.waveformWidth * 2.2
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

    private var overlayBorderLineWidth: CGFloat {
        self.settings.overlaySize == .large ? 0.8 : 1
    }

    private var overlayBorderTopOpacity: Double {
        self.settings.overlaySize == .large ? 0.10 : 0.15
    }

    private var overlayBorderBottomOpacity: Double {
        self.settings.overlaySize == .large ? 0.05 : 0.08
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
        let actionsDisabled = self.historyStore.entries.isEmpty || self.contentState.isProcessing
        guard !actionsDisabled else {
            self.closeActionsMenu()
            return
        }
        BottomOverlayActionsMenuController.shared.selectorHoverChanged(hovering)
    }

    private func handleActionsSelectorFrameChange(_ frameInScreen: CGRect, window: NSWindow?) {
        self.actionsSelectorFrameInScreen = frameInScreen
        self.actionsSelectorWindow = window
        let actionsDisabled = self.historyStore.entries.isEmpty || self.contentState.isProcessing
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
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Text(self.modeLabel)
                .font(.system(size: self.promptSelectorFontSize, weight: .semibold))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(1)
            Image(systemName: "chevron.up")
                .font(.system(size: max(self.promptSelectorFontSize - 1, 8), weight: .semibold))
                .foregroundColor(.white.opacity(0.45))
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
            if !self.isCompactControls {
                Text("Prompt:")
                    .font(.system(size: self.promptSelectorFontSize, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Text(self.selectedPromptLabel)
                .font(.system(size: self.promptSelectorFontSize, weight: .semibold))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(1)
            Image(systemName: "chevron.up")
                .font(.system(size: max(self.promptSelectorFontSize - 1, 8), weight: .semibold))
                .foregroundColor(.white.opacity(0.45))
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 8)
        .padding(.vertical, self.promptSelectorVerticalPadding)
        .background(
            self.chipBackground(
                isHovered: self.isHoveringPromptChip,
                disabled: !self.isPromptSelectableMode || self.contentState.isProcessing
            )
        )
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
        let actionsDisabled = self.historyStore.entries.isEmpty || self.contentState.isProcessing
        return HStack(spacing: 5) {
            Text("Actions")
                .font(.system(size: self.promptSelectorFontSize, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(1)
            Image(systemName: "chevron.up")
                .font(.system(size: max(self.promptSelectorFontSize - 1, 8), weight: .semibold))
                .foregroundColor(.white.opacity(0.45))
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 8)
        .padding(.vertical, self.promptSelectorVerticalPadding)
        .background(
            self.chipBackground(
                isHovered: self.isHoveringActionsChip,
                disabled: actionsDisabled
            )
        )
    }

    private var aiToggleChip: some View {
        let disabled = self.contentState.isProcessing
        let isEnabled = self.settings.enableAIProcessing
        return HStack(spacing: self.isCompactControls ? 0 : 5) {
            if self.isCompactControls {
                Text(isEnabled ? "AI On" : "AI Off")
                    .font(.system(size: self.promptSelectorFontSize, weight: .semibold))
                    .foregroundColor(isEnabled ? .white.opacity(0.82) : .white.opacity(0.7))
                    .lineLimit(1)
            } else {
                Text("AI:")
                    .font(.system(size: self.promptSelectorFontSize, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                Text(isEnabled ? "On" : "Off")
                    .font(.system(size: self.promptSelectorFontSize, weight: .semibold))
                    .foregroundColor(isEnabled ? .white.opacity(0.82) : .white.opacity(0.7))
                    .lineLimit(1)
                Image(systemName: isEnabled ? "brain.fill" : "brain")
                    .font(.system(size: max(self.promptSelectorFontSize - 1, 8), weight: .semibold))
                    .foregroundColor(isEnabled ? .white.opacity(0.65) : .white.opacity(0.45))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 8)
        .padding(.vertical, self.promptSelectorVerticalPadding)
        .background(
            self.chipBackground(
                isHovered: self.isHoveringAIToggleChip,
                disabled: disabled
            )
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            self.isHoveringAIToggleChip = hovering && !disabled
        }
        .onTapGesture {
            guard !disabled else { return }
            self.closePromptMenu()
            self.closeModeMenu()
            self.closeActionsMenu()
            self.contentState.onToggleAIProcessingRequested?()
        }
        .help("Toggle AI enhancement for dictation")
        .opacity(disabled ? 0.65 : 1)
    }

    private var actionsSelectorView: some View {
        let actionsDisabled = self.historyStore.entries.isEmpty || self.contentState.isProcessing
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
            .help(
                self.historyStore.entries.isEmpty
                    ? "No saved dictation history available"
                    : "Reprocess the latest dictation using current AI settings"
            )
    }

    private var settingsChip: some View {
        let disabled = false
        return HStack(spacing: 0) {
            Image(systemName: "gearshape")
                .font(.system(size: max(self.promptSelectorFontSize + 1, 10), weight: .semibold))
                .foregroundColor(.white.opacity(0.72))
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

    var body: some View {
        VStack(spacing: max(4, self.layout.vPadding / 2)) {
            if self.layout.showsTopControls {
                HStack(spacing: self.isCompactControls ? 6 : 8) {
                    self.modeSelectorView
                    self.promptSelectorView
                    Spacer(minLength: 4)
                    self.aiToggleChip
                    self.actionsSelectorView
                    if !self.isCompactControls {
                        self.settingsChip
                    }
                }
                .frame(maxWidth: .infinity, alignment: self.isCompactControls ? .center : .leading)
                .padding(.horizontal, self.layout.hPadding)
            }

            VStack(spacing: self.layout.vPadding / 2) {
                if self.layout.showsPreview {
                    if self.layout.usesFixedCanvas {
                        // Transcription text area (fixed-height in large mode)
                        Group {
                            if self.contentState.isProcessing {
                                ShimmerText(
                                    text: self.processingStatusText,
                                    color: self.modeColor,
                                    font: .system(size: self.layout.transFontSize, weight: .medium)
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            } else if self.hasTranscription {
                                let previewText = self.transcriptionPreviewText
                                if !previewText.isEmpty {
                                    ScrollViewReader { proxy in
                                        ScrollView(.vertical, showsIndicators: false) {
                                            Text(previewText)
                                                .font(.system(size: self.layout.transFontSize, weight: .medium))
                                                .foregroundColor(.white.opacity(0.9))
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
                                        .onChange(of: previewText) { _ in
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
                            if self.hasTranscription && !self.contentState.isProcessing {
                                let previewText = self.transcriptionPreviewText
                                if !previewText.isEmpty {
                                    if self.settings.overlaySize == .small {
                                        Text(previewText)
                                            .font(.system(size: self.layout.transFontSize, weight: .medium))
                                            .foregroundColor(.white.opacity(0.9))
                                            .multilineTextAlignment(.leading)
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.vertical, max(2, self.transcriptionVerticalPadding - 1))
                                    } else {
                                        ScrollViewReader { proxy in
                                            ScrollView(.vertical, showsIndicators: false) {
                                                Text(previewText)
                                                    .font(.system(size: self.layout.transFontSize, weight: .medium))
                                                    .foregroundColor(.white.opacity(0.9))
                                                    .multilineTextAlignment(.leading)
                                                    .lineLimit(nil)
                                                    .fixedSize(horizontal: false, vertical: true)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                Color.clear.frame(height: 1).id("bottom")
                                            }
                                            .frame(width: self.previewMaxWidth)
                                            .frame(maxHeight: self.previewMaxHeight)
                                            .clipped()
                                            .onAppear {
                                                DispatchQueue.main.async {
                                                    proxy.scrollTo("bottom", anchor: .bottom)
                                                }
                                            }
                                            .onChange(of: previewText) { _ in
                                                DispatchQueue.main.async {
                                                    proxy.scrollTo("bottom", anchor: .bottom)
                                                }
                                            }
                                        }
                                        .padding(.vertical, self.transcriptionVerticalPadding)
                                    }
                                }
                            } else if self.contentState.isProcessing {
                                ShimmerText(
                                    text: self.processingStatusText,
                                    color: self.modeColor,
                                    font: .system(size: self.layout.transFontSize, weight: .medium)
                                )
                            }
                        }
                        .frame(
                            maxWidth: self.previewMaxWidth,
                            minHeight: self.hasTranscription || self.contentState.isProcessing ? self.layout.transFontSize * 1.5 : 0
                        )
                    }
                }

                // Waveform + Mode label row
                HStack(spacing: self.layout.hPadding / 1.5) {
                    // Target app icon (the app where text will be typed)
                    let appIcon = self.contentState.targetAppIcon ?? self.activeAppMonitor.activeAppIcon
                    if appIcon != nil || !self.appServices.asr.isAsrReady &&
                        (self.appServices.asr.isLoadingModel || self.appServices.asr.isDownloadingModel)
                    {
                        let showModelLoading = !self.appServices.asr.isAsrReady &&
                            (self.appServices.asr.isLoadingModel || self.appServices.asr.isDownloadingModel)
                        VStack(spacing: 2) {
                            if showModelLoading {
                                ProgressView()
                                    
                            }
                            if let appIcon = appIcon {
                                Image(nsImage: appIcon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: self.layout.iconSize, height: self.layout.iconSize)
                                    .clipShape(RoundedRectangle(cornerRadius: self.layout.iconSize / 4))
                            }
                        }
                        .frame(width: self.layout.iconSize, height: self.layout.iconSize)
                        .opacity((appIcon != nil || self.appServices.asr.isLoadingModel || self.appServices.asr.isDownloadingModel) ? 1 : 0)
                    }

                    // Waveform visualization
                    BottomWaveformView(color: self.modeColor, layout: self.layout)
                        .frame(width: self.layout.waveformWidth, height: self.layout.waveformHeight)

                    // Mode label + model load hint
                    VStack(alignment: .leading, spacing: 2) {
                        Text(self.modeLabel)
                            .font(.system(size: self.layout.modeFontSize, weight: .semibold))
                            .foregroundColor(self.modeColor)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        if !self.appServices.asr.isAsrReady &&
                            (self.appServices.asr.isLoadingModel || self.appServices.asr.isDownloadingModel)
                            && self.settings.overlaySize != .small
                        {
                            Text("Loading model…")
                                .font(.system(size: max(self.layout.modeFontSize - 2, 9), weight: .medium))
                                .foregroundColor(.orange.opacity(0.85))
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, self.layout.hPadding)
            .padding(.vertical, self.layout.vPadding)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(
                ZStack {
                    // Solid pitch black background
                    RoundedRectangle(cornerRadius: self.layout.cornerRadius)
                        .fill(Color.black)

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
            )
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(
            width: self.layout.usesFixedCanvas ? self.layout.overlayWidth : self.layout.containerWidth,
            height: self.layout.usesFixedCanvas ? self.layout.overlayHeight : nil,
            alignment: .top
        )
        .onChange(of: self.settings.overlaySize) { _ in
            BottomOverlayWindowController.shared.refreshSizeForContent()
        }
        .onChange(of: self.contentState.cachedPreviewText) { _ in
            if !self.layout.usesFixedCanvas {
                BottomOverlayWindowController.shared.refreshSizeForContent()
            }
        }
        .onChange(of: self.contentState.mode) { _ in
            if !self.isPromptSelectableMode || self.contentState.isProcessing {
                self.closePromptMenu()
            }
            self.closeModeMenu()
            self.closeActionsMenu()
            self.isHoveringModeChip = false
            self.isHoveringPromptChip = false
            self.isHoveringAIToggleChip = false
            self.isHoveringActionsChip = false
            self.isHoveringSettingsChip = false
            switch self.contentState.mode {
            case .dictation: self.contentState.promptPickerMode = .dictate
            case .edit, .write, .rewrite: self.contentState.promptPickerMode = .edit
            case .command: break
            }
            if !self.layout.usesFixedCanvas {
                BottomOverlayWindowController.shared.refreshSizeForContent()
            }
        }
        .onChange(of: self.contentState.isProcessing) { processing in
            if processing {
                self.closePromptMenu()
                self.closeModeMenu()
                self.closeActionsMenu()
            }
            self.isHoveringModeChip = false
            self.isHoveringPromptChip = false
            self.isHoveringAIToggleChip = false
            self.isHoveringActionsChip = false
            self.isHoveringSettingsChip = false
            if !self.layout.usesFixedCanvas {
                BottomOverlayWindowController.shared.refreshSizeForContent()
            }
        }
        .onDisappear {
            self.closePromptMenu()
            self.closeModeMenu()
            self.closeActionsMenu()
            self.isHoveringModeChip = false
            self.isHoveringPromptChip = false
            self.isHoveringAIToggleChip = false
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
        .animation(.easeInOut(duration: 0.15), value: self.hasTranscription)
        .animation(.easeInOut(duration: 0.2), value: self.contentState.mode)
        .animation(.easeInOut(duration: 0.2), value: self.contentState.isProcessing)
    }
}

// MARK: - Bottom Waveform View (reads from NotchContentState)

struct BottomWaveformView: View {
    let color: Color
    let layout: BottomOverlayView.LayoutConstants

    @ObservedObject private var contentState = NotchContentState.shared
    // Initialize with max possible bar count (11 for large) to prevent index-out-of-range before onAppear
    @State private var barHeights: [CGFloat] = Array(repeating: 6, count: 11)
    @State private var noiseThreshold: CGFloat = .init(SettingsStore.shared.visualizerNoiseThreshold)

    private var barCount: Int { self.layout.barCount }
    private var barWidth: CGFloat { self.layout.barWidth }
    private var barSpacing: CGFloat { self.layout.barSpacing }
    private var minHeight: CGFloat { self.layout.minBarHeight }
    private var maxHeight: CGFloat { self.layout.maxBarHeight }

    private var currentGlowIntensity: CGFloat {
        self.contentState.isProcessing ? 0.0 : 0.5
    }

    private var currentGlowRadius: CGFloat {
        self.contentState.isProcessing ? 0.0 : 4
    }

    /// Safe accessor for bar heights to prevent index-out-of-range crashes
    private func safeBarHeight(at index: Int) -> CGFloat {
        guard index >= 0 && index < self.barHeights.count else {
            return self.minHeight
        }
        return self.barHeights[index]
    }

    var body: some View {
        HStack(spacing: self.barSpacing) {
            ForEach(0..<self.barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: self.barWidth / 2)
                    .fill(self.color)
                    .frame(width: self.barWidth, height: self.safeBarHeight(at: index))
                    .shadow(color: self.color.opacity(self.currentGlowIntensity), radius: self.currentGlowRadius, x: 0, y: 0)
            }
        }
        .onChange(of: self.contentState.bottomOverlayAudioLevel) { level in
            if !self.contentState.isProcessing {
                self.updateBars(level: level)
            }
        }
        .onChange(of: self.contentState.isProcessing) { processing in
            if processing {
                self.setFlatProcessingBars()
            } else {
                // Resume from silence; next audio tick will animate up.
                self.updateBars(level: 0)
            }
        }
        .onChange(of: self.layout.barCount) { newCount in
            self.barHeights = Array(repeating: self.minHeight, count: newCount)
        }
        .onAppear {
            // Ensure bar count matches current layout
            if self.barHeights.count != self.barCount {
                self.barHeights = Array(repeating: self.minHeight, count: self.barCount)
            }
            if self.contentState.isProcessing {
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
        let isActive = normalizedLevel > self.noiseThreshold // Use user's sensitivity setting

        withAnimation(.spring(response: 0.08, dampingFraction: 0.55)) {
            for i in 0..<self.barCount {
                let centerDistance = abs(CGFloat(i) - CGFloat(self.barCount - 1) / 2)
                let centerFactor = 1.0 - (centerDistance / CGFloat(self.barCount / 2)) * 0.3

                if isActive, self.noiseThreshold < 1.0 {
                    // Amplify the level for more dramatic response
                    // Safety check: ensure denominator is never zero
                    let denominator = max(1.0 - self.noiseThreshold, 0.001)
                    let adjustedLevel = max(min((normalizedLevel - self.noiseThreshold) / denominator, 1.0), 0.0)

                    let amplifiedLevel = pow(adjustedLevel, 0.6) // More responsive to quieter sounds
                    let randomVariation = CGFloat.random(in: 0.8...1.0)
                    self.barHeights[i] = self.minHeight + (self.maxHeight - self.minHeight) * amplifiedLevel * centerFactor * randomVariation
                } else {
                    self.barHeights[i] = self.minHeight
                }
            }
        }
    }
}
