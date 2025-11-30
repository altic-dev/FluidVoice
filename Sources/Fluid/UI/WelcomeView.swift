//
//  WelcomeView.swift
//  fluid
//
//  Welcome and setup guide view
//

import SwiftUI
import AppKit
import AVFoundation

struct WelcomeView: View {
    @ObservedObject var asr: ASRService
    @ObservedObject private var settings = SettingsStore.shared
    @Binding var selectedSidebarItem: SidebarItem?
    @Binding var playgroundUsed: Bool
    var isTranscriptionFocused: FocusState<Bool>.Binding
    @Environment(\.theme) private var theme
    
    let accessibilityEnabled: Bool
    let providerAPIKeys: [String: String]
    let currentProvider: String
    let openAIBaseURL: String
    let availableModels: [String]
    let selectedModel: String
    
    let stopAndProcessTranscription: () async -> Void
    let startRecording: () -> Void
    let isLocalEndpoint: (String) -> Bool
    let openAccessibilitySettings: () -> Void
    
    private var commandModeShortcutDisplay: String {
        settings.commandModeHotkeyShortcut.displayString
    }
    
    private var writeModeShortcutDisplay: String {
        settings.rewriteModeHotkeyShortcut.displayString
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 10) {
                    Image(systemName: "book.fill")
                        .font(.title2)
                        .foregroundStyle(theme.palette.accent)
                    Text("Welcome to FluidVoice")
                        .font(.title2.weight(.bold))
                }
                .padding(.bottom, 4)

                // Quick Setup Checklist
                ThemedCard(style: .prominent) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Quick Setup", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(theme.palette.accent)

                        VStack(alignment: .leading, spacing: 8) {
                            SetupStepView(
                                step: 1,
                                title: asr.isAsrReady ? "Voice Model Ready" : "Download Voice Model",
                                description: asr.isAsrReady
                                    ? "Speech recognition model is loaded and ready"
                                    : "Download the AI model for offline voice transcription (~500MB)",
                                status: asr.isAsrReady ? .completed : .pending,
                                action: {
                                    selectedSidebarItem = .aiSettings
                                },
                                actionButtonTitle: "Go to AI Settings",
                                showActionButton: !asr.isAsrReady
                            )
                            
                            SetupStepView(
                                step: 2,
                                title: asr.micStatus == .authorized ? "Microphone Permission Granted" : "Grant Microphone Permission",
                                description: asr.micStatus == .authorized 
                                    ? "FluidVoice has access to your microphone" 
                                    : "Allow FluidVoice to access your microphone for voice input",
                                status: asr.micStatus == .authorized ? .completed : .pending,
                                action: {
                                    if asr.micStatus == .notDetermined {
                                        asr.requestMicAccess()
                                    } else if asr.micStatus == .denied {
                                        asr.openSystemSettingsForMic()
                                    }
                                },
                                actionButtonTitle: asr.micStatus == .notDetermined ? "Grant Access" : "Open Settings",
                                showActionButton: asr.micStatus != .authorized
                            )

                            SetupStepView(
                                step: 3,
                                title: accessibilityEnabled ? "Accessibility Enabled" : "Enable Accessibility",
                                description: accessibilityEnabled 
                                    ? "Accessibility permission granted for typing into apps" 
                                    : "Grant accessibility permission to type text into other apps",
                                status: accessibilityEnabled ? .completed : .pending,
                                action: {
                                    openAccessibilitySettings()
                                },
                                actionButtonTitle: "Open Settings",
                                showActionButton: !accessibilityEnabled
                            )

                            SetupStepView(
                                step: 4,
                                title: {
                                    let hasApiKey = providerAPIKeys[currentProvider]?.isEmpty == false
                                    let isLocal = isLocalEndpoint(openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
                                    let hasModel = availableModels.contains(selectedModel)
                                    let isConfigured = (isLocal || hasApiKey) && hasModel
                                    return isConfigured ? "AI Enhancement Configured" : "Set Up AI Enhancement (Optional)"
                                }(),
                                description: {
                                    let hasApiKey = providerAPIKeys[currentProvider]?.isEmpty == false
                                    let isLocal = isLocalEndpoint(openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
                                    let hasModel = availableModels.contains(selectedModel)
                                    let isConfigured = (isLocal || hasApiKey) && hasModel
                                    return isConfigured 
                                        ? "AI-powered text enhancement is ready to use" 
                                        : "Configure API keys for AI-powered text enhancement"
                                }(),
                                status: {
                                    let hasApiKey = providerAPIKeys[currentProvider]?.isEmpty == false
                                    let isLocal = isLocalEndpoint(openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
                                    let hasModel = availableModels.contains(selectedModel)
                                    return ((isLocal || hasApiKey) && hasModel) ? .completed : .pending
                                }(),
                                action: {
                                    selectedSidebarItem = .aiSettings
                                },
                                actionButtonTitle: "Configure AI"
                            )

                            SetupStepView(
                                step: 5,
                                title: playgroundUsed ? "Setup Tested Successfully" : "Test Your Setup",
                                description: playgroundUsed 
                                    ? "You've successfully tested voice transcription" 
                                    : "Try the playground below to test your complete setup",
                                status: playgroundUsed ? .completed : .pending,
                                action: {
                                    // Scroll to playground or focus on it
                                    withAnimation {
                                        isTranscriptionFocused.wrappedValue = true
                                    }
                                },
                                actionButtonTitle: "Go to Playground",
                                showActionButton: !playgroundUsed
                            )
                            .id("playground-step-\(playgroundUsed)")
                        }
                    }
                    .padding(14)
                }

                // How to Use
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("How to Use", systemImage: "play.fill")
                            .font(.headline)
                            .foregroundStyle(.green)

                        VStack(alignment: .leading, spacing: 10) {
                            howToStep(number: 1, title: "Start Recording", description: "Press your hotkey (default: Right Option/Alt) or click the button")
                            howToStep(number: 2, title: "Speak Clearly", description: "Speak naturally - works best in quiet environments")
                            howToStep(number: 3, title: "Auto-Type Result", description: "Transcription is automatically typed into your focused app")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                .frame(maxWidth: .infinity)

                // Command Mode
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Label("Command Mode", systemImage: "terminal.fill")
                                .font(.headline)
                                .foregroundStyle(Color(red: 1.0, green: 0.35, blue: 0.35))
                            
                            featureBadge("New", color: Color(red: 1.0, green: 0.35, blue: 0.35))
                            featureBadge("Alpha", color: Color(red: 1.0, green: 0.35, blue: 0.35).opacity(0.7))
                            
                            Spacer()
                            
                            Button("Open") {
                                selectedSidebarItem = .commandMode
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Text("Control your Mac with voice commands. Execute terminal commands, open apps, and more.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Getting Started")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.orange)
                            
                            HStack(spacing: 4) {
                                Text("Press")
                                keyboardBadge(commandModeShortcutDisplay)
                                Text("to open, speak your command, then press again to send.")
                            }
                            .font(.caption)
                            .foregroundStyle(.primary.opacity(0.8))
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Examples")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.orange)
                            commandModeExample(icon: "folder", text: "\"List files in my Downloads folder\"")
                            commandModeExample(icon: "plus.rectangle.on.folder", text: "\"Create a folder called Projects on Desktop\"")
                            commandModeExample(icon: "network", text: "\"What's my IP address?\"")
                            commandModeExample(icon: "safari", text: "\"Open Safari\"")
                        }

                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            Text("AI can make mistakes. Avoid destructive commands.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                }
                .frame(maxWidth: .infinity)

                // Write Mode
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Label("Write Mode", systemImage: "pencil.and.outline")
                                .font(.headline)
                                .foregroundStyle(.blue)
                            
                            featureBadge("New", color: .blue)
                            
                            Spacer()
                            
                            Button("Open") {
                                selectedSidebarItem = .rewriteMode
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Text("AI-powered writing assistant. Write fresh content or rewrite selected text with voice.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("To Write Fresh")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.blue)
                                
                                HStack(spacing: 4) {
                                    Text("Press")
                                    keyboardBadge(writeModeShortcutDisplay)
                                    Text("and speak what you want to write.")
                                }
                                .font(.caption)
                                .foregroundStyle(.primary.opacity(0.8))
                                
                                writeModeExample(text: "\"Write an email asking for time off\"")
                                writeModeExample(text: "\"Draft a thank you note\"")
                            }
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("To Rewrite/Edit")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.blue)
                                
                                HStack(spacing: 4) {
                                    Text("Select text first, then press")
                                    keyboardBadge(writeModeShortcutDisplay)
                                    Text("and speak your instruction.")
                                }
                                .font(.caption)
                                .foregroundStyle(.primary.opacity(0.8))
                                
                                writeModeExample(text: "\"Make this more formal\"")
                                writeModeExample(text: "\"Fix grammar and spelling\"")
                                writeModeExample(text: "\"Summarize this\"")
                            }
                        }
                    }
                    .padding(16)
                }
                .frame(maxWidth: .infinity)

                // Test Playground
                ThemedCard(hoverEffect: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Test Playground")
                                        .font(.headline)
                                    Text("Click record, speak, and see your transcription")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "text.bubble")
                                    .font(.title3)
                            }

                            Spacer()
                            
                            if asr.isRunning {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(.red)
                                        .frame(width: 6, height: 6)
                                    Text("Recording...")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.red)
                                }
                            } else if !asr.finalText.isEmpty {
                                Text("\(asr.finalText.count) characters")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if !asr.finalText.isEmpty {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(asr.finalText, forType: .string)
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            // Recording Control
                            VStack(spacing: 10) {
                                Button {
                                    if asr.isRunning {
                                        Task {
                                            await stopAndProcessTranscription()
                                        }
                                    } else {
                                        startRecording()
                                        playgroundUsed = true
                                        SettingsStore.shared.playgroundUsed = true
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: asr.isRunning ? "stop.fill" : "mic.fill")
                                        Text(asr.isRunning ? "Stop Recording" : "Start Recording")
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(PremiumButtonStyle(isRecording: asr.isRunning))
                                .buttonHoverEffect()
                                .scaleEffect(asr.isRunning ? 1.02 : 1.0)
                                .animation(.spring(response: 0.3), value: asr.isRunning)
                                .disabled(!asr.isAsrReady && !asr.isRunning)

                                if !asr.isRunning && !asr.finalText.isEmpty {
                                    Button("Clear Results") {
                                        asr.finalText = ""
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }

                            // Text Area
                            VStack(alignment: .leading, spacing: 8) {
                                TextEditor(text: $asr.finalText)
                                    .font(.body)
                                    .focused(isTranscriptionFocused)
                                    .frame(height: 140)
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(
                                                asr.isRunning ? theme.palette.accent.opacity(0.06) : Color(nsColor: NSColor.textBackgroundColor)
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .strokeBorder(
                                                        asr.isRunning ? theme.palette.accent.opacity(0.4) : Color(nsColor: NSColor.separatorColor),
                                                        lineWidth: asr.isRunning ? 2 : 1
                                                    )
                                            )
                                    )
                                    .scrollContentBackground(.hidden)
                                    .overlay(
                                        VStack(spacing: 8) {
                                            if asr.isRunning {
                                                Image(systemName: "waveform")
                                                    .font(.title2)
                                                    .foregroundStyle(theme.palette.accent)
                                                Text("Listening... Speak now!")
                                                    .font(.subheadline.weight(.medium))
                                                    .foregroundStyle(theme.palette.accent)
                                                Text("Transcription will appear when you stop recording")
                                                    .font(.caption)
                                                    .foregroundStyle(theme.palette.accent.opacity(0.7))
                                            } else if asr.finalText.isEmpty {
                                                Image(systemName: "text.bubble")
                                                    .font(.title2)
                                                    .foregroundStyle(.secondary.opacity(0.5))
                                                Text("Ready to test!")
                                                    .font(.subheadline.weight(.medium))
                                                Text("Click 'Start Recording' or press your hotkey")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .allowsHitTesting(false)
                                    )

                                if !asr.finalText.isEmpty {
                                    HStack(spacing: 8) {
                                        Button {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(asr.finalText, forType: .string)
                                        } label: {
                                            Label("Copy Text", systemImage: "doc.on.doc")
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(theme.palette.accent)
                                        .controlSize(.small)

                                        Button("Clear & Test Again") {
                                            asr.finalText = ""
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)

                                        Spacer()
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }

            }
            .padding(16)
        }
    }
    
    // MARK: - Helper Views
    
    private func howToStep(number: Int, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(theme.palette.accent.opacity(0.15))
                    .frame(width: 28, height: 28)
                Text("\(number)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.palette.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
    
    private func featureBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
    
    private func keyboardBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
    
    private func commandModeExample(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.orange.opacity(0.8))
                .frame(width: 14)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.8))
        }
    }
    
    private func writeModeExample(text: String) -> some View {
        HStack(spacing: 6) {
            Text("•")
                .foregroundStyle(.blue.opacity(0.6))
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.8))
        }
    }
}

