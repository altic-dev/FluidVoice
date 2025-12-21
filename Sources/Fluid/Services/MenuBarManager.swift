import AppKit
import Combine
import PromiseKit
import SwiftUI

enum MenuBarNavigationDestination: String {
    case preferences
}

@MainActor
final class MenuBarManager: ObservableObject {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var isSetup: Bool = false
    private var hostedWindow: NSWindow?

    // Cached menu items to avoid rebuilding entire menu
    private var statusMenuItem: NSMenuItem?
    private var aiMenuItem: NSMenuItem?

    // References to app state
    private weak var asrService: ASRService?
    private var cancellables = Set<AnyCancellable>()

    // Overlay management (persistent, independent of window lifecycle)
    private var overlayVisible: Bool = false

    @Published var isRecording: Bool = false
    @Published var aiProcessingEnabled: Bool = false

    /// One-shot navigation requests from the menu bar into the main window UI.
    /// `ContentView` consumes this and clears it.
    @Published var requestedNavigationDestination: MenuBarNavigationDestination? = nil

    // Track current overlay mode for notch
    private var currentOverlayMode: OverlayMode = .dictation

    // Track pending overlay operations to prevent spam
    private var pendingShowOperation: DispatchWorkItem?
    private var pendingHideOperation: DispatchWorkItem?

    // Subscription for forwarding audio levels to expanded command notch
    private var expandedModeAudioSubscription: AnyCancellable?

    init() {
        // Don't setup menu bar immediately - defer until app is ready
        // Initialize from persisted setting
        self.aiProcessingEnabled = SettingsStore.shared.enableAIProcessing
        // Reflect changes to menu when toggled from elsewhere (e.g., General tab)
        self.$aiProcessingEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenu()
            }
            .store(in: &self.cancellables)
    }

    func initializeMenuBar() {
        guard !self.isSetup else { return }

        // Ensure we're on main thread and app is active
        DispatchQueue.main.async { [weak self] in
            self?.setupMenuBarSafely()
        }
    }

    deinit {
        statusItem = nil
    }

    func configure(asrService: ASRService) {
        self.asrService = asrService

        // Subscribe to recording state changes
        asrService.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRunning in
                self?.isRecording = isRunning
                self?.updateMenuBarIcon()
                self?.updateMenu()

                // Handle overlay lifecycle (independent of window state)
                self?.handleOverlayState(isRunning: isRunning, asrService: asrService)
            }
            .store(in: &self.cancellables)

        // Subscribe to partial transcription updates for streaming preview
        asrService.$partialTranscription
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newText in
                guard self != nil else { return }
                // CRITICAL FIX: Check if streaming preview is enabled before updating notch
                // The "Show Live Preview" toggle in Preferences should control this behavior
                if SettingsStore.shared.enableStreamingPreview {
                    NotchOverlayManager.shared.updateTranscriptionText(newText)
                }
            }
            .store(in: &self.cancellables)

        // Subscribe to AI processing state
        self.aiProcessingEnabled = SettingsStore.shared.enableAIProcessing
    }

    private func handleOverlayState(isRunning: Bool, asrService: ASRService) {
        // Prevent rapid state changes that could cause cycles
        guard self.overlayVisible != isRunning else { return }

        let delay: DispatchTimeInterval = .milliseconds(150)
        if isRunning {
            // Cancel any pending hide operation
            self.pendingHideOperation?.cancel()
            self.pendingHideOperation = nil

            self.overlayVisible = true

            // If expanded command output is showing, check if we should keep it or close it
            if NotchOverlayManager.shared.isCommandOutputExpanded {
                // Only keep expanded notch if this is a command mode recording (follow-up)
                // For other modes (dictation, rewrite), close it and show regular notch
                if self.currentOverlayMode == .command {
                    // Enable recording visualization in the expanded notch
                    NotchContentState.shared.setRecordingInExpandedMode(true)

                    // Subscribe to audio levels and forward to expanded notch
                    self.expandedModeAudioSubscription = asrService.audioLevelPublisher
                        .receive(on: DispatchQueue.main)
                        .sink { level in
                            NotchContentState.shared.updateExpandedModeAudioLevel(level)
                        }

                    self.pendingShowOperation = nil
                    return
                } else {
                    // Close expanded command notch to transition to regular notch
                    NotchOverlayManager.shared.hideExpandedCommandOutput()
                }
            }

            let showItem = DispatchWorkItem { [weak self] in
                guard let self = self, self.overlayVisible else { return }

                // Double-check expanded notch isn't showing (could have changed during delay)
                // But only block if we're in command mode
                if NotchOverlayManager.shared.isCommandOutputExpanded && self.currentOverlayMode == .command {
                    self.pendingShowOperation = nil
                    return
                }

                // Show notch overlay
                NotchOverlayManager.shared.show(
                    audioLevelPublisher: asrService.audioLevelPublisher,
                    mode: self.currentOverlayMode
                )

                self.pendingShowOperation = nil
            }
            self.pendingShowOperation = showItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: showItem)
        } else {
            // Cancel any pending show operation
            self.pendingShowOperation?.cancel()
            self.pendingShowOperation = nil

            self.overlayVisible = false

            // If expanded command output is showing, don't hide it - let it stay visible
            if NotchOverlayManager.shared.isCommandOutputExpanded {
                // Stop recording visualization in expanded notch
                NotchContentState.shared.setRecordingInExpandedMode(false)
                self.expandedModeAudioSubscription?.cancel()
                self.expandedModeAudioSubscription = nil

                self.pendingHideOperation = nil
                return
            }

            let hideItem = DispatchWorkItem { [weak self] in
                guard let self = self, !self.overlayVisible else { return }

                // Don't hide if expanded command output is now showing
                if NotchOverlayManager.shared.isCommandOutputExpanded {
                    self.pendingHideOperation = nil
                    return
                }

                // Hide notch overlay
                NotchOverlayManager.shared.hide()

                self.pendingHideOperation = nil
            }
            self.pendingHideOperation = hideItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: hideItem)
        }
    }

    // MARK: - Public API for overlay management

    func updateOverlayTranscription(_ text: String) {
        NotchOverlayManager.shared.updateTranscriptionText(text)
    }

    func setOverlayMode(_ mode: OverlayMode) {
        self.currentOverlayMode = mode
        NotchOverlayManager.shared.setMode(mode)
    }

    func setProcessing(_ processing: Bool) {
        if processing {
            // Cancel any pending hide - we want to keep the overlay visible for AI processing
            self.pendingHideOperation?.cancel()
            self.pendingHideOperation = nil
            self.overlayVisible = true
        } else {
            // When processing ends, schedule the hide (unless expanded output is showing)
            self.overlayVisible = false

            // If expanded command output is showing, don't hide it
            if NotchOverlayManager.shared.isCommandOutputExpanded {
                self.pendingHideOperation = nil
                NotchOverlayManager.shared.setProcessing(processing)
                return
            }

            let hideItem = DispatchWorkItem { [weak self] in
                guard let self = self, !self.overlayVisible else { return }

                // Don't hide if expanded command output is now showing
                if NotchOverlayManager.shared.isCommandOutputExpanded {
                    self.pendingHideOperation = nil
                    return
                }

                NotchOverlayManager.shared.hide()
                self.pendingHideOperation = nil
            }
            self.pendingHideOperation = hideItem
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: hideItem)
        }
        NotchOverlayManager.shared.setProcessing(processing)
    }

    private func setupMenuBarSafely() {
        // Check if window server connection is available
        guard NSApp.isActive || NSApp.isRunning else {
            // Retry after a short delay if app isn't ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.setupMenuBarSafely()
            }
            return
        }

        do {
            try self.setupMenuBar()
            self.isSetup = true
        } catch {
            // If setup fails, retry after delay
            DebugLogger.shared.error("MenuBar setup failed, retrying: \(error)", source: "MenuBarManager")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.setupMenuBarSafely()
            }
        }
    }

    private func setupMenuBar() throws {
        // Ensure we're not already set up
        guard !self.isSetup else { return }

        // Create status item with error handling
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let statusItem = statusItem else {
            throw NSError(domain: "MenuBarManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create status item"])
        }

        // Set initial icon
        self.updateMenuBarIcon()

        // Create menu
        self.menu = NSMenu()
        statusItem.menu = self.menu

        self.updateMenu()
    }

    private func updateMenuBarIcon() {
        guard let statusItem = statusItem else { return }

        // Use MenuBarIcon asset - vectorized from logo
        if let image = NSImage(named: "MenuBarIcon") {
            image.isTemplate = true // Adapts to light/dark mode and tints red when recording
            statusItem.button?.image = image
        }
    }

    private func buildMenuStructure() {
        guard let menu = menu else { return }

        menu.removeAllItems()

        // Status indicator with hotkey info
        self.statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        self.statusMenuItem?.isEnabled = false
        if let statusItem = statusMenuItem {
            menu.addItem(statusItem)
        }

        menu.addItem(.separator())

        // AI Processing Toggle
        self.aiMenuItem = NSMenuItem(title: "", action: #selector(self.toggleAIProcessing), keyEquivalent: "")
        self.aiMenuItem?.target = self
        if let aiItem = aiMenuItem {
            menu.addItem(aiItem)
        }

        menu.addItem(.separator())

        // Open Main Window
        let openItem = NSMenuItem(title: "Open Fluid Voice", action: #selector(openMainWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        // Preferences
        let preferencesItem = NSMenuItem(title: "Preferences", action: #selector(openPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        preferencesItem.keyEquivalentModifierMask = [.command]
        menu.addItem(preferencesItem)

        // Check for Updates
        let updateItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit Fluid Voice",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        menu.addItem(quitItem)

        // Now update the text content
        self.updateMenuItemsText()
    }

    private func updateMenu() {
        // If menu structure hasn't been built yet, build it
        if self.statusMenuItem == nil {
            self.buildMenuStructure()
        } else {
            // Just update the text of existing items
            self.updateMenuItemsText()
        }
    }

    private func updateMenuItemsText() {
        // Update status text with hotkey info
        let hotkeyShortcut = SettingsStore.shared.hotkeyShortcut
        let hotkeyInfo = hotkeyShortcut.displayString.isEmpty ? "" : " (\(hotkeyShortcut.displayString))"
        let statusTitle = self.isRecording ? "Recording...\(hotkeyInfo)" : "Ready to Record\(hotkeyInfo)"
        self.statusMenuItem?.title = statusTitle

        // Update AI toggle text
        let aiTitle = self.aiProcessingEnabled ? "Disable AI Processing" : "Enable AI Processing"
        self.aiMenuItem?.title = aiTitle
    }

    @objc private func toggleAIProcessing() {
        self.aiProcessingEnabled.toggle()
        // Persist and broadcast change
        SettingsStore.shared.enableAIProcessing = self.aiProcessingEnabled
        // If a ContentView has bound to MenuBarManager, its onChange sync will mirror this
        self.updateMenu()
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        DebugLogger.shared.info("🔎 Menu action: Check for Updates…", source: "MenuBarManager")

        // Call the AppDelegate's manual update check method if available
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.checkForUpdatesManually()
            return
        }

        // Fallback: perform direct, tolerant check so the menu item always does something
        Task { @MainActor in
            do {
                try await SimpleUpdater.shared.checkAndUpdate(owner: "altic-dev", repo: "Fluid-oss")
                let ok = NSAlert()
                ok.messageText = "Update Found!"
                ok.informativeText = "A new version is available and will be installed now."
                ok.alertStyle = .informational
                ok.addButton(withTitle: "OK")
                ok.runModal()
            } catch {
                let msg = NSAlert()
                if let pmkError = error as? PMKError, pmkError.isCancelled {
                    msg.messageText = "You’re Up To Date"
                    msg.informativeText = "You're already running the latest version of FluidVoice."
                } else {
                    msg.messageText = "Update Check Failed"
                    msg.informativeText = "Unable to check for updates. Please try again later.\n\nError: \(error.localizedDescription)"
                }
                msg.alertStyle = .informational
                msg.runModal()
            }
        }
    }

    @objc private func openMainWindow() {
        // First, unhide the app if it's hidden
        if NSApp.isHidden {
            NSApp.unhide(nil)
        }

        // Activate the app and bring it to the front
        NSApp.activate(ignoringOtherApps: true)

        // Find an existing *non-minimized* primary window.
        // Important: avoid programmatic deminiaturize() — it creates internal window transform animations
        // (NSWindowTransformAnimation) that have been unstable on macOS 26.x for this app.
        if let window = hostedWindow, window.isReleasedWhenClosed == false {
            self.ensureUsableMainWindow(window)
            window.animationBehavior = .none
            window.makeKeyAndOrderFront(nil)
        } else if let window = NSApp.windows.first(where: { win in
            // Only normal app windows (exclude overlays/panels/menus)
            guard win.level == .normal else { return false }
            guard win.styleMask.contains(.titled) else { return false }
            guard win.canBecomeKey else { return false }
            guard win.isMiniaturized == false else { return false }

            // Prefer our main window title when present (both SwiftUI and our fallback window use this)
            return win.title == "FluidVoice" || win.title.contains("FluidVoice")
        }) {
            self.ensureUsableMainWindow(window)
            window.animationBehavior = .none
            window.makeKeyAndOrderFront(nil)
            self.hostedWindow = window
        } else {
            // If there is no suitable window (or it's minimized), create a fresh one.
            self.createAndShowMainWindow()
        }

        // Final attempt: ensure app is active and visible
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openPreferences() {
        // Ensure a fresh one-shot request every time the menu item is clicked.
        self.requestedNavigationDestination = nil
        self.requestedNavigationDestination = .preferences

        self.openMainWindow()

        // Nudge again after the window is front-most, so an already-open ContentView
        // will still switch tabs even if it consumed a previous preference request.
        DispatchQueue.main.async { [weak self] in
            self?.requestedNavigationDestination = nil
            self?.requestedNavigationDestination = .preferences
        }
    }

    /// Create and present a fresh main window hosting `ContentView`
    private func createAndShowMainWindow() {
        // Build the SwiftUI root view with required environment
        let rootView = ContentView()
            .environmentObject(self)
            .environmentObject(AppServices.shared)
            .appTheme(.dark)
            .preferredColorScheme(.dark)

        // Host inside an AppKit window
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FluidVoice"
        window.animationBehavior = .none
        window.minSize = NSSize(width: 800, height: 500)
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.setFrame(self.defaultWindowFrame(), display: false)
        window.makeKeyAndOrderFront(nil)
        self.hostedWindow = window

        // Bring app to front in case we're running as an accessory app (no Dock)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func ensureUsableMainWindow(_ window: NSWindow) {
        // If the window is too small (e.g., height collapsed), reset to the default frame.
        let minSize = NSSize(width: 800, height: 500)
        window.minSize = minSize

        let frame = window.frame
        if frame.height < minSize.height || frame.width < minSize.width {
            window.setFrame(self.defaultWindowFrame(), display: false)
        }
    }

    private func defaultWindowFrame() -> NSRect {
        // Center a sensible default frame on the main screen.
        let size = NSSize(width: 1000, height: 700)
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2
        )
        return NSRect(origin: origin, size: size)
    }
}
