//
//  RecordingView.swift
//  fluid
//
//  Recording controls and configuration view
//

import SwiftUI
import AVFoundation

struct RecordingView: View {
    @EnvironmentObject var appServices: AppServices
    private var asr: ASRService { appServices.asr }
    @Environment(\.theme) private var theme
    @Binding var appear: Bool
    
    let stopAndProcessTranscription: () async -> Void
    let startRecording: () -> Void
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                // Hero Header Card
                ThemedCard(style: .standard) {
                    VStack(spacing: 12) {
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
                        VStack(spacing: 10) {
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
                    .padding(14)
                }
                .modifier(CardAppearAnimation(delay: 0.1, appear: $appear))
            }
            .padding(14)
        }
    }
}

