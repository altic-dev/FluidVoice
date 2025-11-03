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
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: "book.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(theme.palette.accent)
                    Text("Welcome to FluidVoice")
                        .font(.system(size: 22, weight: .bold))
                }
                .padding(.bottom, 6)

                // Quick Setup Checklist
                ThemedCard(style: .prominent) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(theme.palette.accent)
                            Text("Quick Setup")
                                .font(.system(size: 15, weight: .semibold))
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            SetupStepView(
                                step: 1,
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
                                step: 2,
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
                                step: 3,
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
                                step: 4,
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

                // How to Use - Before playground
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "play.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.green)
                            Text("How to Use")
                                .font(.system(size: 15, weight: .semibold))
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 10) {
                                ZStack {
                                    Circle()
                                        .fill(theme.palette.accent.opacity(0.15))
                                        .frame(width: 28, height: 28)
                                    Text("1")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(theme.palette.accent)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Start Recording")
                                        .font(.system(size: 14, weight: .semibold))
                                    Text("Press your hotkey (default: Right Option/Alt) or click the button")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            HStack(alignment: .top, spacing: 10) {
                                ZStack {
                                    Circle()
                                        .fill(theme.palette.accent.opacity(0.15))
                                        .frame(width: 28, height: 28)
                                    Text("2")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(theme.palette.accent)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Speak Clearly")
                                        .font(.system(size: 14, weight: .semibold))
                                    Text("Speak naturally - works best in quiet environments")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            HStack(alignment: .top, spacing: 10) {
                                ZStack {
                                    Circle()
                                        .fill(theme.palette.accent.opacity(0.15))
                                        .frame(width: 28, height: 28)
                                    Text("3")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(theme.palette.accent)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Auto-Type Result")
                                        .font(.system(size: 14, weight: .semibold))
                                    Text("Transcription is automatically typed into your focused app")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(14)
                }

                // Test Playground - At the end
                ThemedCard(hoverEffect: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 18))
                                .foregroundStyle(.white)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Test Playground")
                                    .font(.system(size: 16, weight: .semibold))
                                Text("Click record, speak, and see your transcription")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                            
                            // Status indicator
                            if asr.isRunning {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(.red)
                                        .frame(width: 8, height: 8)
                                    Text("Recording...")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.red)
                                }
                            } else if !asr.finalText.isEmpty {
                                Text("\(asr.finalText.count) characters")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }

                            if !asr.finalText.isEmpty {
                                Button(action: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(asr.finalText, forType: .string)
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.on.doc")
                                            .font(.system(size: 11))
                                        Text("Copy")
                                            .font(.system(size: 11))
                                    }
                                }
                                .buttonStyle(InlineButtonStyle())
                                .buttonHoverEffect()
                            }
                        }

                        VStack(alignment: .leading, spacing: 10) {

                            // Recording Control - Big Premium Button
                            VStack(spacing: 10) {
                                Button(action: {
                                    if asr.isRunning {
                                        Task {
                                            await stopAndProcessTranscription()
                                            // Mark playground as used when transcription completes successfully
                                            await MainActor.run {
                                                // Only mark as used if we actually got some text
                                                if !asr.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                                    playgroundUsed = true
                                                    SettingsStore.shared.playgroundUsed = true
                                                }
                                            }
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

                                if !asr.isRunning && !asr.finalText.isEmpty {
                                    Button("Clear Results") {
                                        asr.finalText = ""
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }

                            // TRANSCRIPTION TEXT AREA
                            VStack(alignment: .leading, spacing: 8) {
                                // REAL TEXT EDITOR - Can receive focus and display transcription
                                TextEditor(text: $asr.finalText)
                                    .font(.system(size: 13))
                                    .focused(isTranscriptionFocused)
                                    .frame(height: 150)
                                    .padding(12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(
                                                asr.isRunning ? theme.palette.accent.opacity(0.08) : Color(nsColor: NSColor.textBackgroundColor)
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .strokeBorder(
                                                        asr.isRunning ? theme.palette.accent.opacity(0.5) : Color(nsColor: NSColor.separatorColor),
                                                        lineWidth: asr.isRunning ? 2 : 1.5
                                                    )
                                            )
                                    )
                                    .scrollContentBackground(.hidden)
                                    .overlay(
                                        VStack {
                                            if asr.isRunning {
                                                VStack(spacing: 8) {
                                                    // Animated recording indicator overlay
                                                    HStack(spacing: 6) {
                                                        Image(systemName: "waveform")
                                                            .font(.system(size: 18))
                                                            .foregroundStyle(theme.palette.accent)
                                                            .scaleEffect(1.0)
                                                            .animation(.easeInOut(duration: 0.8).repeatForever(), value: asr.isRunning)

                                                        Image(systemName: "waveform")
                                                            .font(.system(size: 16))
                                                            .foregroundStyle(theme.palette.accent.opacity(0.7))
                                                            .scaleEffect(1.0)
                                                            .animation(.easeInOut(duration: 0.6).repeatForever(), value: asr.isRunning)

                                                        Image(systemName: "waveform")
                                                            .font(.system(size: 14))
                                                            .foregroundStyle(theme.palette.accent.opacity(0.5))
                                                            .scaleEffect(1.0)
                                                            .animation(.easeInOut(duration: 0.4).repeatForever(), value: asr.isRunning)
                                                    }

                                                    VStack(spacing: 2) {
                                                        Text("Listening... Speak now!")
                                                            .font(.system(size: 16, weight: .semibold))
                                                            .foregroundStyle(theme.palette.accent)

                                                        Text("Transcription will appear when you stop recording")
                                                            .font(.system(size: 12))
                                                            .foregroundStyle(theme.palette.accent.opacity(0.8))
                                                    }
                                                }
                                            } else if asr.finalText.isEmpty {
                                                VStack(spacing: 8) {
                                                    Image(systemName: "text.bubble")
                                                        .font(.system(size: 24))
                                                        .foregroundStyle(.secondary.opacity(0.6))

                                                    VStack(spacing: 2) {
                                                        Text("Ready to test!")
                                                            .font(.system(size: 16, weight: .semibold))
                                                            .foregroundStyle(.primary)

                                                        Text("Click 'Start Recording' or press your hotkey")
                                                            .font(.system(size: 12))
                                                            .foregroundStyle(.secondary)
                                                    }
                                                }
                                            }
                                        }
                                        .allowsHitTesting(false) // Don't block text editor interaction
                                    )

                                // Quick Action Buttons
                                if !asr.finalText.isEmpty {
                                    HStack(spacing: 8) {
                                        Button(action: {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(asr.finalText, forType: .string)
                                        }) {
                                            HStack(spacing: 4) {
                                                Image(systemName: "doc.on.doc")
                                                    .font(.system(size: 11))
                                                Text("Copy Text")
                                                    .font(.system(size: 12))
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(theme.palette.accent.opacity(0.12))
                                            .foregroundStyle(theme.palette.accent)
                                            .cornerRadius(6)
                                        }

                                        Button("Clear & Test Again") {
                                            asr.finalText = ""
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)

                                        Spacer()
                                    }
                                    .padding(.top, 6)
                                }
                            }
                        }
                    }
                    .padding(14)
                }

            }
            .padding(16)
        }
    }
}

