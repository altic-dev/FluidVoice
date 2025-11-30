//
//  SettingsView.swift
//  fluid
//
//  App preferences and audio device settings
//

import SwiftUI
import AVFoundation
import PromiseKit

struct SettingsView: View {
    @ObservedObject var asr: ASRService
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
    @Binding var hotkeyManagerInitialized: Bool
    @Binding var pressAndHoldModeEnabled: Bool
    @Binding var enableStreamingPreview: Bool
    @Binding var copyToClipboard: Bool
    
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
                            settingsToggleRow(
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
                            settingsToggleRow(
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
                                    .tint(theme.palette.accent)
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
                                .tint(theme.palette.accent)
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
                                    .fill(asr.micStatus == .authorized ? theme.palette.success : theme.palette.warning)
                                    .frame(width: 8, height: 8)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(asr.micStatus == .authorized ? "Microphone access granted" : 
                                         asr.micStatus == .denied ? "Microphone access denied" :
                                         "Microphone access not determined")
                                        .font(.body)
                                        .foregroundStyle(asr.micStatus == .authorized ? .primary : theme.palette.warning)
                                    
                                    if asr.micStatus != .authorized {
                                        Text("Microphone access is required for voice recording")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                
                                if asr.micStatus == .notDetermined {
                                    Button {
                                        asr.requestMicAccess()
                                    } label: {
                                        Label("Grant Access", systemImage: "mic.fill")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(theme.palette.accent)
                                    .controlSize(.regular)
                                } else if asr.micStatus == .denied {
                                    Button {
                                        asr.openSystemSettingsForMic()
                                    } label: {
                                        Label("Open Settings", systemImage: "gear")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.regular)
                                }
                            }
                            
                            if asr.micStatus != .authorized {
                                instructionsBox(
                                    title: "How to enable microphone access:",
                                    steps: asr.micStatus == .notDetermined 
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
                        
                        if accessibilityEnabled {
                            VStack(alignment: .leading, spacing: 12) {
                                // Status indicator
                                HStack(spacing: 8) {
                                    if isRecordingShortcut || isRecordingCommandModeShortcut || isRecordingRewriteShortcut {
                                        Image(systemName: "hand.point.up.left.fill")
                                            .foregroundStyle(.orange)
                                        Text("Press your new hotkey combination now...")
                                            .font(.subheadline)
                                            .foregroundStyle(.orange)
                                    } else if hotkeyManagerInitialized {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                        Text("Global Shortcuts Active")
                                            .font(.subheadline.weight(.medium))
                                        
                                        Spacer()
                                        
                                        if !hotkeyManagerInitialized && accessibilityEnabled {
                                            Button {
                                                DebugLogger.shared.debug("User requested app restart for accessibility changes", source: "SettingsView")
                                                restartApp()
                                            } label: {
                                                Label("Restart", systemImage: "arrow.clockwise.circle")
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        }
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
                                    
                                    shortcutRow(
                                        icon: "mic.fill",
                                        iconColor: .secondary,
                                        title: "Transcribe Mode",
                                        description: "Dictate text anywhere",
                                        shortcut: hotkeyShortcut,
                                        isRecording: isRecordingShortcut,
                                        onChangePressed: {
                                            DebugLogger.shared.debug("Starting to record new transcribe shortcut", source: "SettingsView")
                                            isRecordingShortcut = true
                                        }
                                    )
                                    
                                    Divider()
                                    
                                    shortcutRow(
                                        icon: "terminal.fill",
                                        iconColor: .secondary,
                                        title: "Command Mode",
                                        description: "Execute voice commands",
                                        shortcut: commandModeShortcut,
                                        isRecording: isRecordingCommandModeShortcut,
                                        onChangePressed: {
                                            DebugLogger.shared.debug("Starting to record new command mode shortcut", source: "SettingsView")
                                            isRecordingCommandModeShortcut = true
                                        }
                                    )
                                    
                                    Divider()
                                    
                                    shortcutRow(
                                        icon: "pencil.and.outline",
                                        iconColor: .secondary,
                                        title: "Write Mode",
                                        description: "Select text and speak how to rewrite, or write new content",
                                        shortcut: rewriteShortcut,
                                        isRecording: isRecordingRewriteShortcut,
                                        onChangePressed: {
                                            DebugLogger.shared.debug("Starting to record new write mode shortcut", source: "SettingsView")
                                            isRecordingRewriteShortcut = true
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
                                    optionToggleRow(
                                        title: "Press and Hold Mode",
                                        description: "The shortcut only records while you hold it down, giving you quick push-to-talk style control.",
                                        isOn: $pressAndHoldModeEnabled
                                    )
                                    .onChange(of: pressAndHoldModeEnabled) { newValue in
                                        SettingsStore.shared.pressAndHoldMode = newValue
                                        hotkeyManager?.enablePressAndHoldMode(newValue)
                                    }
                                    
                                    Divider().padding(.vertical, 8)
                                    
                                    optionToggleRow(
                                        title: "Show Live Preview",
                                        description: "Display transcription text in real-time in the overlay as you speak.",
                                        isOn: $enableStreamingPreview
                                    )
                                    .onChange(of: enableStreamingPreview) { newValue in
                                        SettingsStore.shared.enableStreamingPreview = newValue
                                    }
                                    
                                    Divider().padding(.vertical, 8)
                                    
                                    optionToggleRow(
                                        title: "Copy to Clipboard",
                                        description: "Automatically copy transcribed text to clipboard as a backup.",
                                        isOn: $copyToClipboard
                                    )
                                    .onChange(of: copyToClipboard) { newValue in
                                        SettingsStore.shared.copyTranscriptionToClipboard = newValue
                                    }
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
                            }
                        } else {
                            // Hotkey disabled - accessibility not enabled
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(theme.palette.warning)
                                        .frame(width: 8, height: 8)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .foregroundStyle(theme.palette.warning)
                                            Text("Accessibility permissions required")
                                                .font(.body)
                                                .foregroundStyle(theme.palette.warning)
                                        }
                                        Text("Required for global hotkey functionality")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    
                                    Button("Open Accessibility Settings") {
                                        openAccessibilitySettings()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(theme.palette.accent)
                                    .controlSize(.regular)
                                }
                                
                                instructionsBox(
                                    title: "Follow these steps to enable Accessibility:",
                                    steps: [
                                        "Click **Open Accessibility Settings** above",
                                        "In the Accessibility window, click the **+ button**",
                                        "Navigate to Applications and select **FluidVoice**",
                                        "Click **Open**, then toggle **FluidVoice ON** in the list"
                                    ],
                                    warningStyle: true
                                )
                                
                                HStack(spacing: 10) {
                                    Button("Reveal in Finder") {
                                        revealAppInFinder()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    
                                    Button("Open Applications") {
                                        openApplicationsFolder()
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
                        Label("Audio Devices", systemImage: "speaker.wave.2.fill")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Input Device")
                                    .font(.body)
                                Spacer()
                                Picker("Input Device", selection: $selectedInputUID) {
                                    ForEach(inputDevices, id: \.uid) { dev in
                                        Text(dev.name).tag(dev.uid)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 240)
                                .onChange(of: selectedInputUID) { newUID in
                                    SettingsStore.shared.preferredInputDeviceUID = newUID
                                    _ = AudioDevice.setDefaultInputDevice(uid: newUID)
                                    if asr.isRunning {
                                        asr.stopWithoutTranscription()
                                        startRecording()
                                    }
                                }
                            }

                            HStack {
                                Text("Output Device")
                                    .font(.body)
                                Spacer()
                                Picker("Output Device", selection: $selectedOutputUID) {
                                    ForEach(outputDevices, id: \.uid) { dev in
                                        Text(dev.name).tag(dev.uid)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 240)
                                .onChange(of: selectedOutputUID) { newUID in
                                    SettingsStore.shared.preferredOutputDeviceUID = newUID
                                    _ = AudioDevice.setDefaultOutputDevice(uid: newUID)
                                }
                            }

                            HStack(spacing: 10) {
                                Button {
                                    refreshDevices()
                                } label: {
                                    Label("Refresh", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)

                                Spacer()
                                
                                if let defIn = AudioDevice.getDefaultInputDevice()?.name, 
                                   let defOut = AudioDevice.getDefaultOutputDevice()?.name {
                                    Text("Default: \(defIn) / \(defOut)")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
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
                                    visualizerNoiseThreshold = 0.4
                                    SettingsStore.shared.visualizerNoiseThreshold = visualizerNoiseThreshold
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            
                            HStack(spacing: 10) {
                                Text("More")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, alignment: .trailing)
                                
                                Slider(value: $visualizerNoiseThreshold, in: 0.01...0.8, step: 0.01)
                                    .controlSize(.regular)
                                
                                Text("Less")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, alignment: .leading)
                                
                                Text(String(format: "%.2f", visualizerNoiseThreshold))
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
        .onAppear {
            refreshDevices()
        }
        .onChange(of: visualizerNoiseThreshold) { newValue in
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
                    .tint(theme.palette.accent)
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
                .tint(theme.palette.accent)
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
                    .foregroundStyle(warningStyle ? theme.palette.warning : theme.palette.accent)
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
                            .foregroundStyle(warningStyle ? theme.palette.warning : theme.palette.accent)
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
                .fill((warningStyle ? theme.palette.warning : theme.palette.accent).opacity(0.12))
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
        onChangePressed: @escaping () -> Void
    ) -> some View {
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
            
            if isRecording {
                Text("Press shortcut...")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.orange.opacity(0.2))
                    )
            } else {
                Text(shortcut.displayString)
                    .font(.caption.monospaced().weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.quaternary.opacity(0.5))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(.primary.opacity(0.15), lineWidth: 1)
                            )
                    )
            }
            
            Button("Change") {
                onChangePressed()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isRecording)
        }
    }
}




