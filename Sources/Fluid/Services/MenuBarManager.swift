import AppKit
import Combine
import PromiseKit
import SwiftUI

enum MenuBarNavigationDestination: String {
    case preferences
}

@MainActor
final class MenuBarManager: NSObject, ObservableObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var isSetup: Bool = false
    private var hostedWindow: NSWindow?

    // Cached menu items to avoid rebuilding entire menu
    private var statusMenuItem: NSMenuItem?
    private var rollbackMenuItem: NSMenuItem?
    private var microphoneMenuItem: NSMenuItem?
    private var microphoneSubmenu: NSMenu?

    // References to app state
    private weak var asrService: ASRService?
    private var cancellables = Set<AnyCancellable>()

    // Overlay management (persistent, independent of window lifecycle)
    private var overlayVisible: Bool = false

    // Track when AI processing is active.
    // When recording stops, ASRService flips `isRunning` to false, which would normally hide the
    // overlay. During post-processing we want the overlay to stay visible until processing ends.
    private var isProcessingActive: Bool = false

    @Published var isRecording: Bool = false

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

    override init() {
        super.init()
        // Don't setup menu bar immediately - defer until app is ready
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
    }

    private func handleOverlayState(isRunning: Bool, asrService: ASRService) {
        // Don't hide the overlay while AI processing is active.
        // Without this, the notch can disappear during the short "Refining..." phase because
        // `isRunning` becomes false before post-processing completes.
        if !isRunning, self.isProcessingActive {
            return
        }

        // Prevent rapid state changes that could cause cycles
        guard self.overlayVisible != isRunning else { return }

        let delay: DispatchTimeInterval = .milliseconds(30)
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
        // Track processing state to prevent hide during AI refinement
        self.isProcessingActive = processing

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
        self.menu?.delegate = self
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

        // Open Main Window
        let openItem = NSMenuItem(title: "Open MedVoice", action: #selector(openMainWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        // Preferences
        let preferencesItem = NSMenuItem(title: "Preferences", action: #selector(openPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        preferencesItem.keyEquivalentModifierMask = [.command]
        menu.addItem(preferencesItem)

        let microphoneSubmenu = NSMenu(title: "Microphone")
        let microphoneMenuItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        microphoneMenuItem.submenu = microphoneSubmenu
        menu.addItem(microphoneMenuItem)
        self.microphoneMenuItem = microphoneMenuItem
        self.microphoneSubmenu = microphoneSubmenu

        // Check for Updates
        let updateItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let rollbackMenuItem = NSMenuItem(
            title: "Rollback to Previous Version...",
            action: #selector(rollbackToPreviousVersion(_:)),
            keyEquivalent: ""
        )
        rollbackMenuItem.target = self
        rollbackMenuItem.isEnabled = SimpleUpdater.shared.hasRollbackBackup()
        menu.addItem(rollbackMenuItem)
        self.rollbackMenuItem = rollbackMenuItem

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit MedVoice",
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
        self.microphoneMenuItem?.isEnabled = true

        // Update rollback availability text
        self.rollbackMenuItem?.isEnabled = SimpleUpdater.shared.hasRollbackBackup()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu {
            self.updateMenuItemsText()
            self.refreshMicrophoneMenu()
        }
    }

    private func refreshMicrophoneMenu() {
        guard let submenu = self.microphoneSubmenu else { return }

        submenu.removeAllItems()
        let loadingItem = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
        loadingItem.isEnabled = false
        submenu.addItem(loadingItem)

        DispatchQueue.global(qos: .userInitiated).async {
            let inputDevices = AudioDevice.listInputDevices()
            let defaultInputUID = AudioDevice.getDefaultInputDevice()?.uid

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.populateMicrophoneMenu(
                    inputDevices: inputDevices,
                    defaultInputUID: defaultInputUID
                )
            }
        }
    }

    private func populateMicrophoneMenu(inputDevices: [AudioDevice.Device], defaultInputUID: String?) {
        guard let submenu = self.microphoneSubmenu else { return }

        submenu.removeAllItems()

        guard !inputDevices.isEmpty else {
            let emptyItem = NSMenuItem(title: "No microphones found", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
            return
        }

        let currentUID = self.currentPreferredInputUID(defaultInputUID: defaultInputUID)

        for device in inputDevices {
            let isSystemDefault = device.uid == defaultInputUID
            let title = isSystemDefault ? "\(device.name) (System Default)" : device.name
            let item = NSMenuItem(title: title, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = device.uid == currentUID ? .on : .off
            item.isEnabled = !self.isRecording
            submenu.addItem(item)
        }

        if self.isRecording {
            submenu.addItem(.separator())
            let recordingItem = NSMenuItem(title: "Unavailable while recording", action: nil, keyEquivalent: "")
            recordingItem.isEnabled = false
            submenu.addItem(recordingItem)
        }
    }

    private func currentPreferredInputUID(defaultInputUID: String?) -> String? {
        return defaultInputUID
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard self.isRecording == false else { return }
        guard let uid = sender.representedObject as? String, !uid.isEmpty else { return }

        SettingsStore.shared.preferredInputDeviceUID = uid

        if SettingsStore.shared.syncAudioDevicesWithSystem {
            _ = AudioDevice.setDefaultInputDevice(uid: uid)
        }

        self.refreshMicrophoneMenu()
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
                try await SimpleUpdater.shared.checkAndUpdate(
                    owner: "altic-dev",
                    repo: "Fluid-oss",
                    includePrerelease: SettingsStore.shared.betaReleasesEnabled
                )
                let ok = NSAlert()
                ok.messageText = "Update Found!"
                ok.informativeText = "A new version is available and will be installed now."
                ok.alertStyle = .informational
                ok.addButton(withTitle: "OK")
                ok.runModal()
            } catch {
                let msg = NSAlert()
                if let pmkError = error as? PMKError, pmkError.isCancelled {
                    let isBeta = SettingsStore.shared.betaReleasesEnabled
                    msg.messageText = isBeta ? "You’re Up To Date (Beta)" : "You’re Up To Date"
                    msg.informativeText = isBeta
                        ? "You're already running the latest build available in the beta channel."
                        : "You're already running the latest version of MedVoice."
                } else {
                    msg.messageText = "Update Check Failed"
                    msg.informativeText = "Unable to check for updates. Please try again later.\n\nError: \(error.localizedDescription)"
                }
                msg.alertStyle = .informational
                msg.runModal()
            }
        }
    }

    @objc private func rollbackToPreviousVersion(_ sender: Any?) {
        let availableVersion = SimpleUpdater.shared.latestRollbackVersion() ?? ""
        guard !availableVersion.isEmpty else {
            let msg = NSAlert()
            msg.messageText = "No rollback backup found"
            msg.informativeText = "No previous version backup is available on this device."
            msg.alertStyle = .informational
            msg.addButton(withTitle: "Get Previous Builds")
            msg.addButton(withTitle: "Cancel")
            if msg.runModal() == .alertFirstButtonReturn {
                self.openPreviousBuildPicker()
            }
            return
        }

        let confirm = NSAlert()
        confirm.messageText = "Rollback to \(availableVersion)?"
        confirm.informativeText = "This will restore the backup and relaunch MedVoice."
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Rollback")
        confirm.addButton(withTitle: "Cancel")

        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        Task { @MainActor in
            do {
                try await SimpleUpdater.shared.rollbackToLatestBackup()
                let success = NSAlert()
                success.messageText = "Rollback Successful"
                success.informativeText = "Rolled back to \(availableVersion). MedVoice will relaunch shortly."
                success.alertStyle = .informational
                success.addButton(withTitle: "Report Bug")
                success.addButton(withTitle: "OK")
                let response = success.runModal()
                if response == .alertFirstButtonReturn {
                    self.openIssueReportingPage()
                }
            } catch {
                let fail = NSAlert()
                fail.messageText = "Rollback Failed"
                fail.informativeText = error.localizedDescription
                fail.alertStyle = .critical
                fail.addButton(withTitle: "OK")
                fail.runModal()
            }
        }
    }

    private func openIssueReportingPage() {
        guard let url = URL(string: "https://github.com/altic-dev/Fluid-oss/issues/new/choose") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openPreviousBuildPicker() {
        Task { @MainActor in
            do {
                let options = try await SimpleUpdater.shared.fetchRecentReleaseBuildOptions(
                    owner: "altic-dev",
                    repo: "Fluid-oss",
                    limit: 3,
                    includePrerelease: SettingsStore.shared.betaReleasesEnabled
                )
                self.presentPreviousBuildPicker(options)
            } catch {
                self.openAllReleasesPage()
            }
        }
    }

    private func presentPreviousBuildPicker(_ options: [SimpleUpdater.ReleaseBuildOption]) {
        guard !options.isEmpty else {
            self.openAllReleasesPage()
            return
        }

        let picker = NSAlert()
        picker.messageText = "Download Previous Build"
        picker.informativeText = "Choose one of the latest release builds to install manually."
        picker.alertStyle = .informational

        for option in options {
            picker.addButton(withTitle: option.version)
        }
        picker.addButton(withTitle: "All Releases")
        picker.addButton(withTitle: "Cancel")

        let response = picker.runModal()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let index = response.rawValue - first

        if index >= 0, index < options.count {
            NSWorkspace.shared.open(options[index].url)
            return
        }
        if index == options.count {
            self.openAllReleasesPage()
        }
    }

    private func openAllReleasesPage() {
        guard let url = URL(string: "https://github.com/altic-dev/Fluid-oss/releases") else { return }
        NSWorkspace.shared.open(url)
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
            self.bringToFront(window)
        } else if let window = NSApp.windows.first(where: { win in
            // Only normal app windows (exclude overlays/panels/menus)
            guard win.level == .normal else { return false }
            guard win.styleMask.contains(.titled) else { return false }
            guard win.canBecomeKey else { return false }
            guard win.isMiniaturized == false else { return false }

            // Prefer our main window title when present (both SwiftUI and our fallback window use this)
            return win.title == "MedVoice" || win.title.contains("MedVoice")
        }) {
            self.ensureUsableMainWindow(window)
            window.animationBehavior = .none
            self.bringToFront(window)
            self.hostedWindow = window
        } else {
            // If there is no suitable window (or it's minimized), create a fresh one.
            self.createAndShowMainWindow()
        }

        // Final attempt: ensure app is active and visible
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            NSApp.activate(ignoringOtherApps: true)
        }
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

    /// Public entry-point for non-menu UI surfaces (e.g. overlay controls) to open Preferences.
    func openPreferencesFromUI() {
        self.openPreferences()
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
        window.title = "MedVoice"
        window.animationBehavior = .none
        window.minSize = NSSize(width: 800, height: 500)
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.setFrame(self.defaultWindowFrame(), display: false)
        self.bringToFront(window)
        self.hostedWindow = window

        // Bring app to front in case we're running as an accessory app (no Dock)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            NSApp.activate(ignoringOtherApps: true)
        }
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

    private func bringToFront(_ window: NSWindow) {
        // Keep ordering explicit to avoid "opened but behind other apps" behavior.
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }
}
