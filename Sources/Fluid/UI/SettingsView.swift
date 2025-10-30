//
//  SettingsView.swift
//  fluid
//
//  App preferences and audio device settings
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var asr: ASRService
    @Environment(\.theme) private var theme
    @Binding var appear: Bool
    @Binding var showWhatsNewSheet: Bool
    @Binding var visualizerNoiseThreshold: Double
    @Binding var selectedInputUID: String
    @Binding var selectedOutputUID: String
    @Binding var inputDevices: [AudioDevice.Device]
    @Binding var outputDevices: [AudioDevice.Device]
    
    let startRecording: () -> Void
    let refreshDevices: () -> Void
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 24) {
                // Header
                ThemedCard(style: .standard) {
                    VStack(spacing: 16) {
                        HStack {
                            Image(systemName: "gear")
                                .font(.system(size: 32))
                                .foregroundStyle(.white)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Settings")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                Text("App behavior and preferences")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }
                    }
                    .padding(24)
                }

                // App Settings Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "power")
                                .font(.title2)
                                .foregroundStyle(.white)
                            Text("App Settings")
                                .font(.title3)
                                .fontWeight(.semibold)
                        }

                        VStack(spacing: 16) {
                            Toggle(isOn: Binding(
                                get: { SettingsStore.shared.launchAtStartup },
                                set: { SettingsStore.shared.launchAtStartup = $0 }
                            )) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Launch at startup")
                                        .font(.headline)
                                    Text("Automatically start FluidVoice when you log in")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.switch)

                            Text("Note: Requires app to be signed for this to work.")
                                .font(.caption2)
                                .foregroundStyle(.secondary.opacity(0.7))

                            Divider()

                            Toggle(isOn: Binding(
                                get: { SettingsStore.shared.showInDock },
                                set: { SettingsStore.shared.showInDock = $0 }
                            )) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Show in Dock")
                                        .font(.headline)
                                    Text("Display FluidVoice icon in the Dock")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.switch)

                            Text("Note: May require app restart to take effect.")
                                .font(.caption2)
                                .foregroundStyle(.secondary.opacity(0.7))

                            Divider()

                            Toggle(isOn: Binding(
                                get: { SettingsStore.shared.autoUpdateCheckEnabled },
                                set: { SettingsStore.shared.autoUpdateCheckEnabled = $0 }
                            )) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Automatic Updates")
                                        .font(.headline)
                                    Text("Check for updates automatically once per day")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.switch)

                            if let lastCheck = SettingsStore.shared.lastUpdateCheckDate {
                                Text("Last checked: \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary.opacity(0.7))
                            }
                            
                            // What's New Button
                            Button("What's New") {
                                DispatchQueue.main.async {
                                    showWhatsNewSheet = true
                                }
                            }
                            .buttonStyle(PremiumButtonStyle(height: 40))
                            .buttonHoverEffect()
                            .padding(.top, 8)
                        }
                    }
                    .padding(24)
                }
                
                // Audio Devices Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                            Text("Audio Devices")
                                .font(.title3)
                                .fontWeight(.semibold)
                        }
                        
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Text("Input Device")
                                    .fontWeight(.medium)
                                Spacer()
                                Picker("Input Device", selection: $selectedInputUID) {
                                    ForEach(inputDevices, id: \.uid) { dev in
                                        Text(dev.name).tag(dev.uid)
                                    }
                                }
                                .frame(width: 280)
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
                                    .fontWeight(.medium)
                                Spacer()
                                Picker("Output Device", selection: $selectedOutputUID) {
                                    ForEach(outputDevices, id: \.uid) { dev in
                                        Text(dev.name).tag(dev.uid)
                                    }
                                }
                                .frame(width: 280)
                                .onChange(of: selectedOutputUID) { newUID in
                                    SettingsStore.shared.preferredOutputDeviceUID = newUID
                                    _ = AudioDevice.setDefaultOutputDevice(uid: newUID)
                                }
                            }

                            HStack(spacing: 12) {
                                Button {
                                    refreshDevices()
                                } label: {
                                    Label("Refresh", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(GlassButtonStyle())
                                .buttonHoverEffect()

                                Spacer()
                                
                                if let defIn = AudioDevice.getDefaultInputDevice()?.name, 
                                   let defOut = AudioDevice.getDefaultOutputDevice()?.name {
                                    Text("Default In: \(defIn) · Default Out: \(defOut)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .padding(24)
                }
                
                // Visualization Sensitivity Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "waveform")
                                .font(.title2)
                                .foregroundStyle(.white)
                            Text("Visualization")
                                .font(.title3)
                                .fontWeight(.semibold)
                        }
                        
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Visualization Sensitivity")
                                        .font(.system(size: 16, weight: .semibold))
                                    Text("Control how sensitive the audio visualizer is to sound input")
                                        .font(.system(size: 13))
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                Button("Reset") {
                                    visualizerNoiseThreshold = 0.4
                                    SettingsStore.shared.visualizerNoiseThreshold = visualizerNoiseThreshold
                                }
                                .font(.system(size: 12))
                                .buttonStyle(GlassButtonStyle())
                                .buttonHoverEffect()
                            }
                            
                            HStack(spacing: 12) {
                                Text("More Sensitive")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .frame(width: 90)
                                
                                Slider(value: $visualizerNoiseThreshold, in: 0.01...0.8, step: 0.01)
                                    .controlSize(.regular)
                                
                                Text("Less Sensitive")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .frame(width: 90)
                                
                                Text(String(format: "%.2f", visualizerNoiseThreshold))
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .frame(width: 40)
                            }
                        }
                    }
                    .padding(24)
                }
            }
            .padding(24)
        }
        .onAppear {
            refreshDevices()
        }
        .onChange(of: visualizerNoiseThreshold) { newValue in
            SettingsStore.shared.visualizerNoiseThreshold = newValue
        }
    }
}




