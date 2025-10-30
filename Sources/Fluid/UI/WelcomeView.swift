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
    var isTranscriptionFocused: FocusState<Bool>.Binding
    @Environment(\.theme) private var theme
    
    let accessibilityEnabled: Bool
    let providerAPIKeys: [String: String]
    let currentProvider: String
    let openAIBaseURL: String
    let availableModels: [String]
    let selectedModel: String
    let playgroundUsed: Bool
    
    let stopAndProcessTranscription: () async -> Void
    let startRecording: () -> Void
    let isLocalEndpoint: (String) -> Bool
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "book.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(theme.palette.accent)
                        VStack(alignment: .leading) {
                            Text("Welcome to FluidVoice")
                                .font(.system(size: 28, weight: .bold))
                            Text("Your AI-powered voice transcription assistant")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Follow this quick setup to start using FluidVoice.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .padding(.bottom, 8)

                // Quick Setup Checklist
                ThemedCard(style: .prominent) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(theme.palette.accent)
                            Text("Quick Setup")
                                .font(.headline)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            SetupStepView(
                                step: 1,
                                title: "Grant Microphone Permission",
                                description: "Allow FluidVoice to access your microphone for voice input",
                                status: asr.micStatus == .authorized ? .completed : .pending,
                                action: {
                                    selectedSidebarItem = .recording
                                }
                            )

                            SetupStepView(
                                step: 2,
                                title: "Enable Accessibility",
                                description: "Grant accessibility permission to type text into other apps",
                                status: accessibilityEnabled ? .completed : .pending,
                                action: {
                                    selectedSidebarItem = .recording
                                }
                            )

                            SetupStepView(
                                step: 3,
                                title: "Set Up AI Enhancement (Optional)",
                                description: "Configure API keys for AI-powered text enhancement",
                                status: {
                                    let hasApiKey = providerAPIKeys[currentProvider]?.isEmpty == false
                                    let isLocal = isLocalEndpoint(openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
                                    let hasModel = availableModels.contains(selectedModel)
                                    return ((isLocal || hasApiKey) && hasModel) ? .completed : .pending
                                }(),
                                action: {
                                    selectedSidebarItem = .aiProcessing
                                }
                            )

                            SetupStepView(
                                step: 4,
                                title: "Test Your Setup below",
                                description: "Try the playground below to test your complete setup",
                                status: playgroundUsed ? .completed : .pending,
                                action: {
                                    // No action needed - playground is right below
                                },
                                showConfigureButton: false
                            )
                        }
                    }
                    .padding(20)
                }

                // Test Playground - Right after setup checklist
                ThemedCard(hoverEffect: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "text.bubble")
                                .font(.title2)
                                .foregroundStyle(.white)
                            Text("Test Playground")
                                .font(.title3)
                                .fontWeight(.semibold)

                            Spacer()

                            if !asr.finalText.isEmpty {
                                Button(action: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(asr.finalText, forType: .string)
                                }) {
                                    HStack {
                                        Image(systemName: "doc.on.doc")
                                        Text("Copy")
                                    }
                                }
                                .buttonStyle(InlineButtonStyle())
                                .buttonHoverEffect()
                            }
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Test your voice transcription here!")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.secondary)

                                    Text("• Click 'Start Recording' or use hotkey (Right Option/Alt)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Text("• Speak naturally - words appear in real-time")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Text("• Click 'Stop Recording' when finished")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 4) {
                                    if asr.isRunning {
                                        HStack {
                                            Image(systemName: "waveform")
                                                .foregroundStyle(.red)
                                            Text("Recording...")
                                                .font(.caption)
                                                .foregroundStyle(.red)
                                        }
                                    } else if !asr.finalText.isEmpty {
                                        Text("\(asr.finalText.count) characters")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            // Recording Controls
                            HStack(spacing: 16) {
                                if asr.isRunning {
                                    Button(action: {
                                        Task {
                                            await stopAndProcessTranscription()
                                        }
                                    }) {
                                        HStack(spacing: 8) {
                                            Image(systemName: "stop.fill")
                                                .foregroundStyle(.red)
                                            Text("Stop Recording")
                                                .fontWeight(.medium)
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .background(theme.palette.warning.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                } else {
                                    Button(action: {
                                        startRecording()
                                    }) {
                                        HStack(spacing: 8) {
                                            Image(systemName: "mic.fill")
                                                .foregroundStyle(.green)
                                            Text("Start Recording")
                                                .fontWeight(.medium)
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .background(theme.palette.success.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                }

                                if !asr.isRunning && !asr.finalText.isEmpty {
                                    Button("Clear Results") {
                                        asr.finalText = ""
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }

                            // TRANSCRIPTION TEXT AREA - ACTUAL TEXT FIELD
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("Transcription Playground")
                                        .font(.headline)
                                        .fontWeight(.semibold)

                                    Spacer()

                                    if !asr.finalText.isEmpty {
                                        Text("\(asr.finalText.count) characters")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                // REAL TEXT EDITOR - Can receive focus and display transcription
                                TextEditor(text: $asr.finalText)
                                    .font(.system(size: 16))
                                    .focused(isTranscriptionFocused)
                                    .frame(height: 200)
                                    .padding(16)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(
                                                asr.isRunning ? theme.palette.accent.opacity(0.12) : theme.palette.cardBackground.opacity(0.85)
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 12)
                                                    .stroke(
                                                        asr.isRunning ? theme.palette.accent.opacity(0.4) : theme.palette.cardBorder.opacity(0.35),
                                                        lineWidth: asr.isRunning ? 2 : 1
                                                    )
                                            )
                                    )
                                    .overlay(
                                        VStack {
                                            if asr.isRunning {
                                                VStack(spacing: 12) {
                                                    // Animated recording indicator overlay
                                                    HStack(spacing: 8) {
                                                        Image(systemName: "waveform")
                                                            .font(.system(size: 24))
                                                            .foregroundStyle(theme.palette.accent)
                                                            .scaleEffect(1.0)
                                                            .animation(.easeInOut(duration: 0.8).repeatForever(), value: asr.isRunning)

                                                        Image(systemName: "waveform")
                                                            .font(.system(size: 20))
                                                            .foregroundStyle(theme.palette.accent.opacity(0.7))
                                                            .scaleEffect(1.0)
                                                            .animation(.easeInOut(duration: 0.6).repeatForever(), value: asr.isRunning)

                                                        Image(systemName: "waveform")
                                                            .font(.system(size: 16))
                                                            .foregroundStyle(theme.palette.accent.opacity(0.5))
                                                            .scaleEffect(1.0)
                                                            .animation(.easeInOut(duration: 0.4).repeatForever(), value: asr.isRunning)
                                                    }

                                                    VStack(spacing: 4) {
                                                        Text("Listening... Speak now!")
                                                            .font(.title3)
                                                            .fontWeight(.semibold)
                                                            .foregroundStyle(theme.palette.accent)

                                                        Text("Your words will appear here in real-time")
                                                            .font(.subheadline)
                                                            .foregroundStyle(theme.palette.accent.opacity(0.8))
                                                    }
                                                }
                                            } else if asr.finalText.isEmpty {
                                                VStack(spacing: 12) {
                                                    Image(systemName: "text.bubble")
                                                        .font(.system(size: 32))
                                                        .foregroundStyle(.secondary.opacity(0.6))

                                                    VStack(spacing: 4) {
                                                        Text("Ready to test!")
                                                            .font(.title3)
                                                            .fontWeight(.semibold)
                                                            .foregroundStyle(.primary)

                                                        Text("Click 'Start Recording' or press your hotkey")
                                                            .font(.subheadline)
                                                            .foregroundStyle(.secondary)
                                                    }
                                                }
                                            }
                                        }
                                        .allowsHitTesting(false) // Don't block text editor interaction
                                    )

                                // Quick Action Buttons
                                if !asr.finalText.isEmpty {
                                    HStack(spacing: 12) {
                                        Button(action: {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(asr.finalText, forType: .string)
                                        }) {
                                            HStack(spacing: 6) {
                                                Image(systemName: "doc.on.doc")
                                                Text("Copy Text")
                                            }
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .background(theme.palette.accent.opacity(0.12))
                                            .foregroundStyle(theme.palette.accent)
                                            .cornerRadius(8)
                                        }

                                        Button("Clear & Test Again") {
                                            asr.finalText = ""
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.regular)

                                        Spacer()
                                    }
                                    .padding(.top, 8)
                                }
                            }
                        }
                    }
                    .padding(20)
                }

                // How to Use
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "play.fill")
                                .foregroundStyle(.green)
                            Text("How to Use")
                                .font(.headline)
                        }

                        VStack(alignment: .leading, spacing: 16) {
                            InstructionStep(
                                number: 1,
                                title: "Start Recording",
                                description: "Use your hotkey (default: Right Option/Alt) or click the record button in the main window"
                            )

                            InstructionStep(
                                number: 2,
                                title: "Speak Clearly",
                                description: "Speak your text naturally. The app works best in quiet environments"
                            )

                            InstructionStep(
                                number: 3,
                                title: "AI Enhancement",
                                description: "Your speech is transcribed, then enhanced by AI for better grammar and clarity"
                            )

                            InstructionStep(
                                number: 4,
                                title: "Auto-Type Result",
                                description: "The enhanced text is automatically typed into your focused application"
                            )
                        }
                    }
                    .padding(20)
                }

                // API Configuration Guide
                ThemedCard(style: .prominent) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "key.fill")
                                .foregroundStyle(.purple)
                            Text("Get API Keys")
                                .font(.headline)
                        }

                        VStack(alignment: .leading, spacing: 16) {
                            Text("Choose your AI provider:")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            ProviderGuide(
                                name: "OpenAI",
                                url: "https://platform.openai.com/api-keys",
                                description: "Most popular choice with GPT-4.1 models",
                                baseURL: "https://api.openai.com/v1",
                                keyPrefix: "sk-"
                            )

                            ProviderGuide(
                                name: "Groq",
                                url: "https://console.groq.com/keys",
                                description: "Fast inference with Llama and Mixtral models",
                                baseURL: "https://api.groq.com/openai/v1",
                                keyPrefix: "gsk_"
                            )

                            // Local Models Coming Soon
                            ThemedCard(hoverEffect: false) {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("Local Models")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.secondary)

                                        Spacer()

                                        Text("Coming Soon")
                                            .font(.system(size: 12))
                                            .foregroundStyle(theme.palette.warning)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 2)
                                            .background(theme.palette.warning.opacity(0.12))
                                            .cornerRadius(8)
                                    }

                                    Text("Run models locally for privacy and offline use")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(12)
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .padding(20)
        }
    }
}

