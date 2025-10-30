//
//  RecordingView.swift
//  fluid
//
//  Recording controls and configuration view
//

import SwiftUI
import AVFoundation

struct RecordingView: View {
    @ObservedObject var asr: ASRService
    @Environment(\.theme) private var theme
    @Binding var appear: Bool
    @Binding var accessibilityEnabled: Bool
    @Binding var hotkeyShortcut: HotkeyShortcut
    @Binding var isRecordingShortcut: Bool
    @Binding var hotkeyManagerInitialized: Bool
    @Binding var pressAndHoldModeEnabled: Bool
    @Binding var enableStreamingPreview: Bool
    @Binding var copyToClipboard: Bool
    
    let hotkeyManager: GlobalHotkeyManager?
    let menuBarManager: MenuBarManager
    let stopAndProcessTranscription: () async -> Void
    let startRecording: () -> Void
    let downloadModels: () async -> Void
    let deleteModels: () async -> Void
    let openAccessibilitySettings: () -> Void
    let restartApp: () -> Void
    let revealAppInFinder: () -> Void
    let openApplicationsFolder: () -> Void
    let getModelStatusText: () -> String
    let labelFor: (AVAuthorizationStatus) -> String
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 24) {
                // Hero Header Card
                ThemedCard(style: .standard) {
                    VStack(spacing: 16) {
                        HStack {
                            Image(systemName: "waveform.circle.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(.white)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Voice Dictation")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                Text("AI-powered speech recognition")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }

                        // Status and Recording Control
                        VStack(spacing: 12) {
                            // Status indicator
                            HStack {
                                Circle()
                                    .fill(asr.isRunning ? .red : asr.isAsrReady ? .green : .secondary)
                                    .frame(width: 8, height: 8)

                                Text(asr.isRunning ? "Recording..." : asr.isAsrReady ? "Ready to record" : "Model not ready")
                                    .font(.subheadline)
                                    .foregroundStyle(asr.isRunning ? .red : asr.isAsrReady ? .green : .secondary)
                            }

                            // Recording Control (Single Toggle Button)
                            Button(action: {
                                if asr.isRunning {
                                    Task {
                                        await stopAndProcessTranscription()
                                    }
                                } else {
                                    startRecording()
                                }
                            }) {
                                HStack {
                                    Image(systemName: asr.isRunning ? "stop.fill" : "mic.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                    Text(asr.isRunning ? "Stop Recording" : "Start Recording")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PremiumButtonStyle(isRecording: asr.isRunning))
                            .buttonHoverEffect()
                            .scaleEffect(asr.isRunning ? 1.05 : 1.0)
                            .animation(.spring(response: 0.3), value: asr.isRunning)
                            .disabled(!asr.isAsrReady && !asr.isRunning)
                        }
                    }
                    .padding(24)
                }
                .modifier(CardAppearAnimation(delay: 0.1, appear: $appear))

                // Permissions Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "shield.checkered")
                                .font(.title2)
                                .foregroundStyle(.white)
                            Text("Permissions")
                                .font(.title3)
                                .fontWeight(.semibold)
                        }
                        
                        MicrophonePermissionView(
                            asr: asr,
                            labelFor: labelFor
                        )
                    }
                    .padding(24)
                }
                .modifier(CardAppearAnimation(delay: 0.2, appear: $appear))

                // Model Configuration Card
                ThemedCard(hoverEffect: false) {
                    ModelConfigurationCard(
                        asr: asr,
                        getModelStatusText: getModelStatusText,
                        deleteModels: deleteModels,
                        downloadModels: downloadModels
                    )
                }
                .modifier(CardAppearAnimation(delay: 0.3, appear: $appear))

                // Global Hotkey Card
                ThemedCard(style: .standard) {
                    GlobalHotkeyCard(
                        accessibilityEnabled: accessibilityEnabled,
                        hotkeyShortcut: $hotkeyShortcut,
                        isRecordingShortcut: $isRecordingShortcut,
                        hotkeyManagerInitialized: hotkeyManagerInitialized,
                        pressAndHoldModeEnabled: $pressAndHoldModeEnabled,
                        enableStreamingPreview: $enableStreamingPreview,
                        copyToClipboard: $copyToClipboard,
                        hotkeyManager: hotkeyManager,
                        menuBarManager: menuBarManager,
                        openAccessibilitySettings: openAccessibilitySettings,
                        restartApp: restartApp,
                        revealAppInFinder: revealAppInFinder,
                        openApplicationsFolder: openApplicationsFolder
                    )
                }
                .modifier(CardAppearAnimation(delay: 0.5, appear: $appear))

                // Debug Settings Card
                ThemedCard(style: .prominent) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "ladybug.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                            Text("Debug Settings")
                                .font(.title3)
                                .fontWeight(.semibold)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            Button {
                                let url = FileLogger.shared.currentLogFileURL()
                                if FileManager.default.fileExists(atPath: url.path) {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                } else {
                                    DebugLogger.shared.info("Log file not found at \(url.path)", source: "RecordingView")
                                }
                            } label: {
                                Label("Reveal Log File", systemImage: "doc.richtext")
                                    .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(GlassButtonStyle())
                            .buttonHoverEffect()

                            Text("Click to reveal the debug log file. This file contains detailed information about app operations and can help with troubleshooting issues.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 4)
                        }
                    }
                }
                .padding(24)
                .modifier(CardAppearAnimation(delay: 0.6, appear: $appear))
            }
            .padding(24)
        }
    }
}

// MARK: - Microphone Permission View

private struct MicrophonePermissionView: View {
    @ObservedObject var asr: ASRService
    @Environment(\.theme) private var theme
    let labelFor: (AVAuthorizationStatus) -> String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                // Status indicator
                Circle()
                    .fill(asr.micStatus == .authorized ? theme.palette.success : theme.palette.warning)
                    .frame(width: 10, height: 10)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(labelFor(asr.micStatus))
                        .fontWeight(.medium)
                        .foregroundStyle(asr.micStatus == .authorized ? theme.palette.primaryText : theme.palette.warning)
                    
                    if asr.micStatus != .authorized {
                        Text("Microphone access is required for voice recording")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                
                microphoneActionButton
            }
            
            // Step-by-step instructions when microphone is not authorized
            if asr.micStatus != .authorized {
                microphoneInstructionsView
            }
        }
    }
    
    private var microphoneActionButton: some View {
        Group {
            if asr.micStatus == .notDetermined {
                Button {
                    asr.requestMicAccess()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                        Text("Grant Access")
                            .fontWeight(.medium)
                    }
                }
                .buttonStyle(GlassButtonStyle())
                .buttonHoverEffect()
            } else if asr.micStatus == .denied {
                Button {
                    asr.openSystemSettingsForMic()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "gear")
                        Text("Open Settings")
                            .fontWeight(.medium)
                    }
                }
                .buttonStyle(GlassButtonStyle())
                .buttonHoverEffect()
            }
        }
    }
    
    private var microphoneInstructionsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(theme.palette.accent)
                    .font(.caption)
                Text("How to enable microphone access:")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                if asr.micStatus == .notDetermined {
                    instructionStep(number: "1", text: "Click **Grant Access** above")
                    instructionStep(number: "2", text: "Choose **Allow** in the system dialog")
                } else if asr.micStatus == .denied {
                    instructionStep(number: "1", text: "Click **Open Settings** above")
                    instructionStep(number: "2", text: "Find **FluidVoice** in the microphone list")
                    instructionStep(number: "3", text: "Toggle **FluidVoice ON** to allow access")
                }
            }
            .padding(.leading, 4)
        }
        .padding(12)
        .background(theme.palette.accent.opacity(0.12))
        .cornerRadius(8)
    }
    
    private func instructionStep(number: String, text: String) -> some View {
        HStack(spacing: 8) {
            Text(number + ".")
                .font(.caption2)
                .foregroundStyle(theme.palette.accent)
                .fontWeight(.semibold)
                .frame(width: 16)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Model Configuration Card

private struct ModelConfigurationCard: View {
    @ObservedObject var asr: ASRService
    @Environment(\.theme) private var theme
    let getModelStatusText: () -> String
    let deleteModels: () async -> Void
    let downloadModels: () async -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "brain.head.profile")
                    .font(.title2)
                    .foregroundStyle(.white)
                Text("Voice to Text Model")
                    .font(.title3)
                    .fontWeight(.semibold)
            }
            
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("Model")
                        .fontWeight(.medium)
                    Spacer()
                    Menu(asr.selectedModel.displayName) {
                        ForEach(ASRService.ModelOption.allCases) { option in
                            Button(option.displayName) { asr.selectedModel = option }
                        }
                    }
                    .disabled(asr.isRunning)
                }
                
                Text(getModelStatusText())
                    .font(.caption)
                    .foregroundStyle(asr.isAsrReady ? .white : .secondary)
                    .padding(.leading, 4)
                
                Text("Automatically detects and transcribes 25 European languages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)

                // Model status indicator with action buttons
                HStack(spacing: 12) {
                    if asr.isDownloadingModel {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Downloading Model…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if asr.isAsrReady {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Model Ready")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.white)
                        }
                        
                        Button(action: {
                            Task { await deleteModels() }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                Text("Delete")
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Delete downloaded models (~500MB)")
                    } else if asr.modelsExistOnDisk {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.fill")
                                .foregroundStyle(theme.palette.accent)
                            Text("Models on Disk (Not Loaded)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Button(action: {
                            Task { await deleteModels() }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                Text("Delete")
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Delete downloaded models (~500MB)")
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(.orange)
                            Text("Models Not Downloaded")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Button(action: {
                            Task { await downloadModels() }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down.circle.fill")
                                Text("Download")
                            }
                            .font(.caption)
                            .foregroundStyle(theme.palette.accent)
                        }
                        .buttonStyle(.plain)
                        .help("Download ASR models (~500MB)")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.ultraThinMaterial.opacity(0.3))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.white.opacity(0.1), lineWidth: 1)
                        )
                )

                // Helpful link: Supported languages
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                    Link(
                        "Supported languages",
                        destination: URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3")!
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }
}

// MARK: - Global Hotkey Card

private struct GlobalHotkeyCard: View {
    @Environment(\.theme) private var theme
    let accessibilityEnabled: Bool
    @Binding var hotkeyShortcut: HotkeyShortcut
    @Binding var isRecordingShortcut: Bool
    let hotkeyManagerInitialized: Bool
    @Binding var pressAndHoldModeEnabled: Bool
    @Binding var enableStreamingPreview: Bool
    @Binding var copyToClipboard: Bool
    let hotkeyManager: GlobalHotkeyManager?
    let menuBarManager: MenuBarManager
    let openAccessibilitySettings: () -> Void
    let restartApp: () -> Void
    let revealAppInFinder: () -> Void
    let openApplicationsFolder: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "keyboard")
                    .font(.title2)
                    .foregroundStyle(.white)
                Text("Global Hotkey")
                    .font(.title3)
                    .fontWeight(.semibold)
            }
            
            if accessibilityEnabled {
                hotkeyEnabledView
            } else {
                hotkeyDisabledView
            }
        }
        .padding(24)
    }
    
    // Content when accessibility is enabled
    private var hotkeyEnabledView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Current Hotkey Display
            VStack(alignment: .leading, spacing: 8) {
                Text("Current Hotkey")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                
                // Hotkey Display Row
                HStack(spacing: 16) {
                    // Clean Hotkey Display
                    HStack(spacing: 8) {
                        Text(hotkeyShortcut.displayString)
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.quaternary.opacity(0.5))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(.primary.opacity(0.2), lineWidth: 1)
                                    )
                            )
                    }
                    
                    Spacer()
                    
                    // Enhanced Change Button
                    Button {
                        DebugLogger.shared.debug("Starting to record new shortcut", source: "RecordingView")
                        isRecordingShortcut = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "pencil")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Change")
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(GlassButtonStyle())
                    .buttonHoverEffect()
                    
                    // Restart button for accessibility changes
                    if !hotkeyManagerInitialized && accessibilityEnabled {
                        Button {
                            DebugLogger.shared.debug("User requested app restart for accessibility changes", source: "RecordingView")
                            restartApp()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise.circle")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Restart")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .buttonStyle(InlineButtonStyle())
                        .buttonHoverEffect()
                    }
                }
            }
            
            // Enhanced Status/Instruction Text
            HStack(spacing: 10) {
                if isRecordingShortcut {
                    Image(systemName: "hand.point.up.left.fill")
                        .foregroundStyle(.white)
                        .font(.system(size: 16, weight: .medium))
                    Text("Press your new hotkey combination now...")
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(.white)
                } else if hotkeyManagerInitialized {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Global Shortcut Active")
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(pressAndHoldModeEnabled
                             ? "Hold \(hotkeyShortcut.displayString) to record and release to stop"
                             : "Press \(hotkeyShortcut.displayString) anywhere to start/stop recording")
                            .font(.system(.caption))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(width: 16, height: 16)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hotkey Initializing...")
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text("Please wait while the global hotkey system starts up")
                            .font(.system(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.ultraThinMaterial.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.white.opacity(0.1), lineWidth: 1)
                    )
            )
            
            // Press and hold toggle
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Press and Hold Mode", isOn: $pressAndHoldModeEnabled)
                    .toggleStyle(GlassToggleStyle())
                Text("When enabled, the shortcut only records while you hold it down, giving you quick push-to-talk style control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.ultraThinMaterial.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .onChange(of: pressAndHoldModeEnabled) { newValue in
                SettingsStore.shared.pressAndHoldMode = newValue
                hotkeyManager?.enablePressAndHoldMode(newValue)
            }
            
            // Streaming preview toggle
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Show Live Preview", isOn: $enableStreamingPreview)
                    .toggleStyle(GlassToggleStyle())
                Text("Display transcription text in real-time in the overlay as you speak. When disabled, only the animation is shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.ultraThinMaterial.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .onChange(of: enableStreamingPreview) { newValue in
                SettingsStore.shared.enableStreamingPreview = newValue
                menuBarManager.updateOverlayPreviewSetting(newValue)
                if !newValue {
                    menuBarManager.updateOverlayTranscription("")
                }
            }
            
            // Copy to clipboard toggle
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Copy to Clipboard", isOn: $copyToClipboard)
                    .toggleStyle(GlassToggleStyle())
                Text("Automatically copy transcribed text to clipboard as a backup, useful when no text field is selected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.ultraThinMaterial.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .onChange(of: copyToClipboard) { newValue in
                SettingsStore.shared.copyTranscriptionToClipboard = newValue
            }
        }
    }
    
    // Content when accessibility is disabled
    private var hotkeyDisabledView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                // Status indicator
                Circle()
                    .fill(theme.palette.warning)
                    .frame(width: 10, height: 10)
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(theme.palette.warning)
                        Text("Accessibility permissions required")
                            .fontWeight(.medium)
                            .foregroundStyle(theme.palette.warning)
                    }
                    Text("Required for global hotkey functionality")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                
                Button("Open Accessibility Settings") {
                    openAccessibilitySettings()
                }
                .buttonStyle(GlassButtonStyle())
                .buttonHoverEffect()
            }
            
            // Prominent step-by-step instructions
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(theme.palette.accent)
                        .font(.caption)
                    Text("Follow these steps to enable Accessibility:")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("1.")
                            .font(.caption2)
                            .foregroundStyle(theme.palette.accent)
                            .fontWeight(.semibold)
                            .frame(width: 16)
                        Text("Click **Open Accessibility Settings** above")
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                    HStack(spacing: 8) {
                        Text("2.")
                            .font(.caption2)
                            .foregroundStyle(theme.palette.accent)
                            .fontWeight(.semibold)
                            .frame(width: 16)
                        Text("In the Accessibility window, click the **+ button**")
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                    HStack(spacing: 8) {
                        Text("3.")
                            .font(.caption2)
                            .foregroundStyle(theme.palette.accent)
                            .fontWeight(.semibold)
                            .frame(width: 16)
                        Text("Navigate to Applications and select **FluidVoice**")
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                    HStack(spacing: 8) {
                        Text("4.")
                            .font(.caption2)
                            .foregroundStyle(theme.palette.accent)
                            .fontWeight(.semibold)
                            .frame(width: 16)
                        Text("Click **Open**, then toggle **FluidVoice ON** in the list")
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                }
                .padding(.leading, 4)
                
                // Helper buttons
                HStack(spacing: 12) {
                    Button("Reveal FluidVoice in Finder") {
                        revealAppInFinder()
                    }
                    .buttonStyle(InlineButtonStyle())
                    .buttonHoverEffect()
                    
                    Button("Open Applications Folder") {
                        openApplicationsFolder()
                    }
                    .buttonStyle(InlineButtonStyle())
                    .buttonHoverEffect()
                }
            }
            .padding(12)
            .background(theme.palette.warning.opacity(0.12))
            .cornerRadius(8)
        }
    }
}




