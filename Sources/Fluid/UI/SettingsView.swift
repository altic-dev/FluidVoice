//
//  SettingsView.swift
//  fluid
//
//  App preferences and audio device settings
//

import AVFoundation
import PromiseKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appServices: AppServices
    private var asr: ASRService { self.appServices.asr }
    @Environment(\.theme) private var theme
    @Binding var appear: Bool
    @Binding var visualizerNoiseThreshold: Double
    @Binding var selectedInputUID: String
    @Binding var selectedOutputUID: String
    @Binding var inputDevices: [AudioDevice.Device]
    @Binding var outputDevices: [AudioDevice.Device]
    @Binding var accessibilityEnabled: Bool
    @Binding var hotkeyShortcut: HotkeyShortcut
    @Binding var isRecordingShortcut: Bool
    @Binding var commandModeShortcut: HotkeyShortcut
    @Binding var isRecordingCommandModeShortcut: Bool
    @Binding var rewriteShortcut: HotkeyShortcut
    @Binding var isRecordingRewriteShortcut: Bool
    @Binding var commandModeShortcutEnabled: Bool
    @Binding var rewriteShortcutEnabled: Bool
    @Binding var hotkeyManagerInitialized: Bool
    @Binding var pressAndHoldModeEnabled: Bool
    @Binding var enableStreamingPreview: Bool
    @Binding var copyToClipboard: Bool

    // CRITICAL FIX: Cache default device names to avoid CoreAudio calls during view body evaluation.
    // Querying AudioDevice.getDefaultInputDevice() in the view body triggers HALSystem::InitializeShell()
    // which races with SwiftUI's AttributeGraph metadata processing and causes EXC_BAD_ACCESS crashes.
    @State private var cachedDefaultInputName: String = ""
    @State private var cachedDefaultOutputName: String = ""

    // Analytics consent UI state (default ON; user can opt-out)
    @State private var shareAnonymousAnalytics: Bool = SettingsStore.shared.shareAnonymousAnalytics
    @State private var showAnalyticsPrivacy: Bool = false

    let hotkeyManager: GlobalHotkeyManager?
    let menuBarManager: MenuBarManager
    let startRecording: () -> Void
    let refreshDevices: () -> Void
    let openAccessibilitySettings: () -> Void
    let restartApp: () -> Void
    let revealAppInFinder: () -> Void
    let openApplicationsFolder: () -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                // App Settings Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        // Section header
                        Label("App Settings", systemImage: "power")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        VStack(spacing: 0) {
                            // Launch at startup
                            self.settingsToggleRow(
                                title: "Launch at startup",
                                description: "Automatically start FluidVoice when you log in",
                                footnote: "Note: Requires app to be signed for this to work.",
                                isOn: Binding(
                                    get: { SettingsStore.shared.launchAtStartup },
                                    set: { SettingsStore.shared.launchAtStartup = $0 }
                                )
                            )

                            Divider().padding(.vertical, 10)

                            // Show in Dock
                            self.settingsToggleRow(
                                title: "Show in Dock",
                                description: "Display FluidVoice icon in the Dock",
                                footnote: "Note: May require app restart to take effect.",
                                isOn: Binding(
                                    get: { SettingsStore.shared.showInDock },
                                    set: { SettingsStore.shared.showInDock = $0 }
                                )
                            )

                            Divider().padding(.vertical, 10)

                            // Automatic Updates
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .center) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Automatic Updates")
                                            .font(.body)
                                        Text("Check for updates automatically once per day")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Toggle("", isOn: Binding(
                                        get: { SettingsStore.shared.autoUpdateCheckEnabled },
                                        set: { SettingsStore.shared.autoUpdateCheckEnabled = $0 }
                                    ))
                                    .toggleStyle(.switch)
                                    .tint(self.theme.palette.accent)
                                    .labelsHidden()
                                }

                                if let lastCheck = SettingsStore.shared.lastUpdateCheckDate {
                                    Text("Last checked: \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            // Update Buttons
                            HStack(spacing: 10) {
                                Button("Check for Updates") {
                                    Task { @MainActor in
                                        do {
                                            try await SimpleUpdater.shared.checkAndUpdate(
                                                owner: "altic-dev",
                                                repo: "Fluid-oss"
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
                                                msg.messageText = "You're Up To Date"
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
                                .buttonStyle(.borderedProminent)
                                .tint(self.theme.palette.accent)
                                .controlSize(.regular)

                                Button("Release Notes") {
                                    if let url = URL(string: "https://github.com/altic-dev/Fluid-oss/releases") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                            }
                            .padding(.top, 12)
                        }
                    }
                    .padding(16)
                }

                // Microphone Permission Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Microphone Permission", systemImage: "mic.fill")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(self.asr.micStatus == .authorized ? self.theme.palette.success : self.theme.palette.warning)
                                    .frame(width: 8, height: 8)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(self.asr.micStatus == .authorized ? "Microphone access granted" :
                                        self.asr.micStatus == .denied ? "Microphone access denied" :
                                        "Microphone access not determined")
                                        .font(.body)
                                        .foregroundStyle(self.asr.micStatus == .authorized ? .primary : self.theme.palette.warning)

                                    if self.asr.micStatus != .authorized {
                                        Text("Microphone access is required for voice recording")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()

                                if self.asr.micStatus == .notDetermined {
                                    Button {
                                        self.asr.requestMicAccess()
                                    } label: {
                                        Label("Grant Access", systemImage: "mic.fill")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(self.theme.palette.accent)
                                    .controlSize(.regular)
                                } else if self.asr.micStatus == .denied {
                                    Button {
                                        self.asr.openSystemSettingsForMic()
                                    } label: {
                                        Label("Open Settings", systemImage: "gear")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.regular)
                                }
                            }

                            if self.asr.micStatus != .authorized {
                                self.instructionsBox(
                                    title: "How to enable microphone access:",
                                    steps: self.asr.micStatus == .notDetermined
                                        ? ["Click **Grant Access** above", "Choose **Allow** in the system dialog"]
                                        : ["Click **Open Settings** above", "Find **FluidVoice** in the microphone list", "Toggle **FluidVoice ON** to allow access"]
                                )
                            }
                        }
                    }
                    .padding(16)
                }

                // Global Hotkey Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Global Hotkey", systemImage: "keyboard")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        if self.accessibilityEnabled {
                            VStack(alignment: .leading, spacing: 12) {
                                // Status indicator
                                HStack(spacing: 8) {
                                    if self.isRecordingShortcut || self.isRecordingCommandModeShortcut || self.isRecordingRewriteShortcut {
                                        Image(systemName: "hand.point.up.left.fill")
                                            .foregroundStyle(.orange)
                                        Text("Press your new hotkey combination now...")
                                            .font(.subheadline)
                                            .foregroundStyle(.orange)
                                    } else if self.hotkeyManagerInitialized {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                        Text("Global Shortcuts Active")
                                            .font(.subheadline.weight(.medium))

                                        Spacer()
                                    } else {
                                        ProgressView()
                                            .controlSize(.small)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Hotkey Initializing...")
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(.orange)
                                            Text("Please wait while the global hotkey system starts up")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(.ultraThinMaterial.opacity(0.5))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .stroke(.white.opacity(0.1), lineWidth: 1)
                                        )
                                )

                                // MARK: - Shortcuts Section

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Keyboard Shortcuts")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.secondary)

                                    self.shortcutRow(
                                        icon: "mic.fill",
                                        iconColor: .secondary,
                                        title: "Transcribe Mode",
                                        description: "Dictate text anywhere",
                                        shortcut: self.hotkeyShortcut,
                                        isRecording: self.isRecordingShortcut,
                                        onChangePressed: {
                                            DebugLogger.shared.debug("Starting to record new transcribe shortcut", source: "SettingsView")
                                            self.isRecordingShortcut = true
                                        }
                                    )

                                    Divider()

                                    self.shortcutRow(
                                        icon: "terminal.fill",
                                        iconColor: .secondary,
                                        title: "Command Mode",
                                        description: "Execute voice commands",
                                        shortcut: self.commandModeShortcut,
                                        isRecording: self.isRecordingCommandModeShortcut,
                                        isEnabled: self.$commandModeShortcutEnabled,
                                        onChangePressed: {
                                            DebugLogger.shared.debug("Starting to record new command mode shortcut", source: "SettingsView")
                                            self.isRecordingCommandModeShortcut = true
                                        }
                                    )

                                    Divider()

                                    self.shortcutRow(
                                        icon: "pencil.and.outline",
                                        iconColor: .secondary,
                                        title: "Write Mode",
                                        description: "Select text and speak how to rewrite, or write new content",
                                        shortcut: self.rewriteShortcut,
                                        isRecording: self.isRecordingRewriteShortcut,
                                        isEnabled: self.$rewriteShortcutEnabled,
                                        onChangePressed: {
                                            DebugLogger.shared.debug("Starting to record new write mode shortcut", source: "SettingsView")
                                            self.isRecordingRewriteShortcut = true
                                        }
                                    )
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(.ultraThinMaterial.opacity(0.5))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .stroke(.white.opacity(0.08), lineWidth: 1)
                                        )
                                )

                                // MARK: - Options Section

                                VStack(spacing: 0) {
                                    self.optionToggleRow(
                                        title: "Press and Hold Mode",
                                        description: "The shortcut only records while you hold it down, giving you quick push-to-talk style control.",
                                        isOn: self.$pressAndHoldModeEnabled
                                    )
                                    .onChange(of: self.pressAndHoldModeEnabled) { _, newValue in
                                        SettingsStore.shared.pressAndHoldMode = newValue
                                        self.hotkeyManager?.enablePressAndHoldMode(newValue)
                                    }

                                    Divider().padding(.vertical, 8)

                                    self.optionToggleRow(
                                        title: "Show Live Preview",
                                        description: "Display transcription text in real-time in the overlay as you speak.",
                                        isOn: self.$enableStreamingPreview
                                    )
                                    .onChange(of: self.enableStreamingPreview) { _, newValue in
                                        SettingsStore.shared.enableStreamingPreview = newValue
                                    }

                                    Divider().padding(.vertical, 8)

                                    self.optionToggleRow(
                                        title: "Copy to Clipboard",
                                        description: "Automatically copy transcribed text to clipboard as a backup.",
                                        isOn: self.$copyToClipboard
                                    )
                                    .onChange(of: self.copyToClipboard) { _, newValue in
                                        SettingsStore.shared.copyTranscriptionToClipboard = newValue
                                    }

                                    Divider().padding(.vertical, 8)

                                    self.optionToggleRow(
                                        title: "Save Transcription History",
                                        description: "Save transcriptions for stats tracking. Disable for privacy.",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.saveTranscriptionHistory },
                                            set: { SettingsStore.shared.saveTranscriptionHistory = $0 }
                                        )
                                    )

                                    Divider().padding(.vertical, 8)

                                    self.optionToggleRow(
                                        title: "Share Anonymous Analytics",
                                        description: "Send anonymous usage and performance metrics to help improve FluidVoice. Never includes transcription text or prompts.",
                                        isOn: self.$shareAnonymousAnalytics
                                    )
                                    .onChange(of: self.shareAnonymousAnalytics) { _, newValue in
                                        SettingsStore.shared.shareAnonymousAnalytics = newValue
                                        AnalyticsService.shared.setEnabled(newValue)
                                        AnalyticsService.shared.capture(.analyticsConsentChanged, properties: ["enabled": newValue])
                                    }

                                    HStack {
                                        Button("What we collect") {
                                            self.showAnalyticsPrivacy = true
                                        }
                                        .buttonStyle(.link)

                                        Spacer()
                                    }
                                    .padding(.top, 6)
                                }
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(.ultraThinMaterial.opacity(0.5))
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(.white.opacity(0.08), lineWidth: 1)))
                            }
                        } else {
                            // Hotkey disabled - accessibility not enabled
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(self.theme.palette.warning)
                                        .frame(width: 8, height: 8)

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .foregroundStyle(self.theme.palette.warning)
                                            Text("Accessibility permissions required")
                                                .font(.body)
                                                .foregroundStyle(self.theme.palette.warning)
                                        }
                                        Text("Required for global hotkey functionality")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()

                                    Button("Open Accessibility Settings") {
                                        self.openAccessibilitySettings()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(self.theme.palette.accent)
                                    .controlSize(.regular)
                                }

                                self.instructionsBox(
                                    title: "Follow these steps to enable Accessibility:",
                                    steps: [
                                        "Click **Open Accessibility Settings** above",
                                        "In the Accessibility window, click the **+ button**",
                                        "Navigate to Applications and select **FluidVoice**",
                                        "Click **Open**, then toggle **FluidVoice ON** in the list",
                                    ],
                                    warningStyle: true
                                )

                                HStack(spacing: 10) {
                                    Button("Reveal in Finder") {
                                        self.revealAppInFinder()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Button("Open Applications") {
                                        self.openApplicationsFolder()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                    .padding(16)
                }

                // Audio Devices Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label("Audio Devices", systemImage: "speaker.wave.2.fill")
                                .font(.headline)
                                .foregroundStyle(.primary)

                            Spacer()

                            Button {
                                self.refreshDevices()
                                // Update cached default device names on refresh
                                self.cachedDefaultInputName = AudioDevice.getDefaultInputDevice()?.name ?? ""
                                self.cachedDefaultOutputName = AudioDevice.getDefaultOutputDevice()?.name ?? ""
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Input Device")
                                    .font(.body)
                                Spacer()
                                Picker("Input Device", selection: self.$selectedInputUID) {
                                    // Handle empty state gracefully
                                    if self.inputDevices.isEmpty {
                                        Text("Loading...").tag("")
                                    } else {
                                        ForEach(self.inputDevices, id: \.uid) { dev in
                                            Text(dev.name).tag(dev.uid)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 240)
                                .onChange(of: self.selectedInputUID) { _, newUID in
                                    guard !newUID.isEmpty else { return }
                                    SettingsStore.shared.preferredInputDeviceUID = newUID
                                    // Only change system default if sync is enabled
                                    if SettingsStore.shared.syncAudioDevicesWithSystem {
                                        _ = AudioDevice.setDefaultInputDevice(uid: newUID)
                                    }
                                    if self.asr.isRunning {
                                        Task {
                                            await self.asr.stopWithoutTranscription()
                                            self.startRecording()
                                        }
                                    }
                                }
                                // Sync selection when devices load or change
                                .onChange(of: self.inputDevices) { _, newDevices in
                                    // If selection is empty or not found in new list, select first available
                                    if !newDevices.isEmpty {
                                        let currentValid = newDevices.contains { $0.uid == self.selectedInputUID }
                                        if !currentValid {
                                            if let prefUID = SettingsStore.shared.preferredInputDeviceUID,
                                               newDevices.contains(where: { $0.uid == prefUID })
                                            {
                                                self.selectedInputUID = prefUID
                                            } else if let defaultUID = AudioDevice.getDefaultInputDevice()?.uid,
                                                      newDevices.contains(where: { $0.uid == defaultUID })
                                            {
                                                self.selectedInputUID = defaultUID
                                            } else {
                                                self.selectedInputUID = newDevices.first?.uid ?? ""
                                            }
                                        }
                                    }
                                }
                            }

                            HStack {
                                Text("Output Device")
                                    .font(.body)
                                Spacer()
                                Picker("Output Device", selection: self.$selectedOutputUID) {
                                    // Handle empty state gracefully
                                    if self.outputDevices.isEmpty {
                                        Text("Loading...").tag("")
                                    } else {
                                        ForEach(self.outputDevices, id: \.uid) { dev in
                                            Text(dev.name).tag(dev.uid)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 240)
                                .onChange(of: self.selectedOutputUID) { _, newUID in
                                    guard !newUID.isEmpty else { return }
                                    SettingsStore.shared.preferredOutputDeviceUID = newUID
                                    // Only change system default if sync is enabled
                                    if SettingsStore.shared.syncAudioDevicesWithSystem {
                                        _ = AudioDevice.setDefaultOutputDevice(uid: newUID)
                                    }
                                }
                                // Sync selection when devices load or change
                                .onChange(of: self.outputDevices) { _, newDevices in
                                    if !newDevices.isEmpty {
                                        let currentValid = newDevices.contains { $0.uid == self.selectedOutputUID }
                                        if !currentValid {
                                            if let prefUID = SettingsStore.shared.preferredOutputDeviceUID,
                                               newDevices.contains(where: { $0.uid == prefUID })
                                            {
                                                self.selectedOutputUID = prefUID
                                            } else if let defaultUID = AudioDevice.getDefaultOutputDevice()?.uid,
                                                      newDevices.contains(where: { $0.uid == defaultUID })
                                            {
                                                self.selectedOutputUID = defaultUID
                                            } else {
                                                self.selectedOutputUID = newDevices.first?.uid ?? ""
                                            }
                                        }
                                    }
                                }
                            }

                            // CRITICAL FIX: Use cached values instead of querying CoreAudio in view body.
                            // Querying AudioDevice here triggers HALSystem::InitializeShell() race condition.
                            if !self.cachedDefaultInputName.isEmpty && !self.cachedDefaultOutputName.isEmpty {
                                HStack {
                                    Spacer()
                                    Text("Default: \(self.cachedDefaultInputName) / \(self.cachedDefaultOutputName)")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }

                            Divider().padding(.vertical, 4)

                            self.optionToggleRow(
                                title: "Sync with System Settings",
                                description: "When enabled, FV and macOS share the same audio devices (bidirectional sync).",
                                isOn: Binding(
                                    get: { SettingsStore.shared.syncAudioDevicesWithSystem },
                                    set: { newValue in
                                        SettingsStore.shared.syncAudioDevicesWithSystem = newValue

                                        // When sync is toggled ON, adopt system's current devices as the source of truth
                                        if newValue {
                                            if let sysInputUID = AudioDevice.getDefaultInputDevice()?.uid {
                                                self.selectedInputUID = sysInputUID
                                                SettingsStore.shared.preferredInputDeviceUID = sysInputUID
                                            }
                                            if let sysOutputUID = AudioDevice.getDefaultOutputDevice()?.uid {
                                                self.selectedOutputUID = sysOutputUID
                                                SettingsStore.shared.preferredOutputDeviceUID = sysOutputUID
                                            }
                                            DebugLogger.shared.info("Sync enabled: adopted system audio devices", source: "SettingsView")
                                        } else {
                                            DebugLogger.shared.info("Sync disabled: FV will use independent audio device selection", source: "SettingsView")
                                        }
                                    }
                                )
                            )
                        }
                    }
                    .padding(16)
                }

                // Visualization Sensitivity Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Visualization", systemImage: "waveform")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Sensitivity")
                                        .font(.body)
                                    Text("Control how sensitive the audio visualizer is to sound input")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button("Reset") {
                                    self.visualizerNoiseThreshold = 0.4
                                    SettingsStore.shared.visualizerNoiseThreshold = self.visualizerNoiseThreshold
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            HStack(spacing: 10) {
                                Text("More")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, alignment: .trailing)

                                Slider(value: self.$visualizerNoiseThreshold, in: 0.01...0.8, step: 0.01)
                                    .controlSize(.regular)

                                Text("Less")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, alignment: .leading)

                                Text(String(format: "%.2f", self.visualizerNoiseThreshold))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 36)
                            }
                        }
                    }
                    .padding(16)
                }

                // Debug Settings Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Debug Settings", systemImage: "ladybug.fill")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        VStack(alignment: .leading, spacing: 8) {
                            self.settingsToggleRow(
                                title: "Enable Debug Logs",
                                description: "Capture and show detailed app activity.",
                                isOn: Binding(
                                    get: { SettingsStore.shared.enableDebugLogs },
                                    set: { SettingsStore.shared.enableDebugLogs = $0 }
                                )
                            )

                            Divider().padding(.vertical, 8)

                            Button {
                                let url = FileLogger.shared.currentLogFileURL()
                                if FileManager.default.fileExists(atPath: url.path) {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                } else {
                                    DebugLogger.shared.info("Log file not found at \(url.path)", source: "SettingsView")
                                }
                            } label: {
                                Label("Reveal Log File", systemImage: "doc.richtext")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)

                            Text("The debug log contains detailed information about app operations and can help with troubleshooting.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                }
            }
            .padding(16)
        }
        .sheet(isPresented: self.$showAnalyticsPrivacy) {
            AnalyticsPrivacyView()
                .frame(minWidth: 520, minHeight: 520)
                .appTheme(self.theme)
                .preferredColorScheme(.dark)
        }
        .onAppear {
            Task { @MainActor in
                // Ensure the shared audio startup gate is scheduled. Safe to call repeatedly.
                await AudioStartupGate.shared.scheduleOpenAfterInitialUISettled()
                await AudioStartupGate.shared.waitUntilOpen()

                self.refreshDevices()

                // Sync input device selection after refresh
                if !self.inputDevices.isEmpty {
                    let inputValid = self.inputDevices.contains { $0.uid == self.selectedInputUID }
                    if !inputValid || self.selectedInputUID.isEmpty {
                        if let prefUID = SettingsStore.shared.preferredInputDeviceUID,
                           self.inputDevices.contains(where: { $0.uid == prefUID })
                        {
                            self.selectedInputUID = prefUID
                        } else if let defaultUID = AudioDevice.getDefaultInputDevice()?.uid,
                                  self.inputDevices.contains(where: { $0.uid == defaultUID })
                        {
                            self.selectedInputUID = defaultUID
                        } else {
                            self.selectedInputUID = self.inputDevices.first?.uid ?? ""
                        }
                    }
                }

                // Sync output device selection after refresh
                if !self.outputDevices.isEmpty {
                    let outputValid = self.outputDevices.contains { $0.uid == self.selectedOutputUID }
                    if !outputValid || self.selectedOutputUID.isEmpty {
                        if let prefUID = SettingsStore.shared.preferredOutputDeviceUID,
                           self.outputDevices.contains(where: { $0.uid == prefUID })
                        {
                            self.selectedOutputUID = prefUID
                        } else if let defaultUID = AudioDevice.getDefaultOutputDevice()?.uid,
                                  self.outputDevices.contains(where: { $0.uid == defaultUID })
                        {
                            self.selectedOutputUID = defaultUID
                        } else {
                            self.selectedOutputUID = self.outputDevices.first?.uid ?? ""
                        }
                    }
                }

                // CRITICAL FIX: Populate cached default device names after onAppear, not during view body evaluation.
                // This avoids the CoreAudio/SwiftUI AttributeGraph race condition that causes EXC_BAD_ACCESS.
                self.cachedDefaultInputName = AudioDevice.getDefaultInputDevice()?.name ?? ""
                self.cachedDefaultOutputName = AudioDevice.getDefaultOutputDevice()?.name ?? ""
            }
        }
        .onChange(of: self.visualizerNoiseThreshold) { _, newValue in
            SettingsStore.shared.visualizerNoiseThreshold = newValue
        }
    }

    // MARK: - Helper Views

    @ViewBuilder
    private func settingsToggleRow(
        title: String,
        description: String,
        footnote: String? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: isOn)
                    .toggleStyle(.switch)
                    .tint(self.theme.palette.accent)
                    .labelsHidden()
            }

            if let footnote = footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func optionToggleRow(
        title: String,
        description: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .tint(self.theme.palette.accent)
                .labelsHidden()
        }
    }

    @ViewBuilder
    private func instructionsBox(
        title: String,
        steps: [String],
        warningStyle: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(warningStyle ? self.theme.palette.warning : self.theme.palette.accent)
                    .font(.caption)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.caption)
                            .foregroundStyle(warningStyle ? self.theme.palette.warning : self.theme.palette.accent)
                            .fontWeight(.semibold)
                            .frame(width: 16, alignment: .trailing)
                        Text(.init(step))
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((warningStyle ? self.theme.palette.warning : self.theme.palette.accent).opacity(0.12))
        )
    }

    @ViewBuilder
    private func shortcutRow(
        icon: String,
        iconColor: Color,
        title: String,
        description: String,
        shortcut: HotkeyShortcut,
        isRecording: Bool,
        isEnabled: Binding<Bool>? = nil,
        onChangePressed: @escaping () -> Void
    ) -> some View {
        let enabledValue = isEnabled?.wrappedValue ?? true

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.body)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if let isEnabled {
                    Toggle("", isOn: isEnabled)
                        .toggleStyle(.switch)
                        .tint(self.theme.palette.accent)
                        .labelsHidden()
                }
            }

            HStack(spacing: 10) {
                Color.clear
                    .frame(width: 20)

                if isRecording && enabledValue {
                    Text("Press shortcut...")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.orange.opacity(0.2)))
                } else {
                    Text(shortcut.displayString)
                        .font(.caption.monospaced().weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.quaternary.opacity(0.5))
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(.primary.opacity(0.15), lineWidth: 1)))
                }

                Button("Change") {
                    onChangePressed()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRecording || !enabledValue)
            }
        }
        .opacity(enabledValue ? 1 : 0.7)
    }
}

// MARK: - Filler Words Editor

struct FillerWordsEditor: View {
    @State private var fillerWords: [String] = SettingsStore.shared.fillerWords
    @State private var newWord: String = ""
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Filler words to remove:")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Word chips
            FlowLayout(spacing: 6) {
                ForEach(self.fillerWords, id: \.self) { word in
                    HStack(spacing: 4) {
                        Text(word)
                            .font(.caption)
                        Button {
                            self.removeWord(word)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary))
                }
            }

            // Add new word
            HStack(spacing: 8) {
                TextField("Add word", text: self.$newWord)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .onSubmit { self.addWord() }

                Button("Add") { self.addWord() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(self.newWord.trimmingCharacters(in: .whitespaces).isEmpty)

                Spacer()

                Button("Reset") {
                    self.fillerWords = SettingsStore.defaultFillerWords
                    SettingsStore.shared.fillerWords = self.fillerWords
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func addWord() {
        let word = self.newWord.trimmingCharacters(in: .whitespaces).lowercased()
        guard !word.isEmpty, !self.fillerWords.contains(word) else { return }
        self.fillerWords.append(word)
        SettingsStore.shared.fillerWords = self.fillerWords
        self.newWord = ""
    }

    private func removeWord(_ word: String) {
        self.fillerWords.removeAll { $0 == word }
        SettingsStore.shared.fillerWords = self.fillerWords
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = self.arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = self.arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrangeSubviews(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + self.spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + self.spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}
