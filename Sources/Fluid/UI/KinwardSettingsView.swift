import AVFoundation
import SwiftUI

/// Standalone settings window for Kinward Mode, deliberately independent of the existing
/// SettingsView (2000+ lines, ~40 threaded @Binding properties from ContentView) to avoid
/// surgery on that view blind. Opened via Cmd+Shift+K or the "Kinward Settings..." app menu
/// item (see fluidApp.swift).
struct KinwardSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    @State private var tokenInput: String = ""
    @State private var tokenStored: Bool = KeychainService.shared.containsKey(for: KinwardClient.keychainProviderID)
    @State private var accessKeyInput: String = ""
    @State private var accessKeyStored: Bool = false
    @State private var availableVoices: [AVSpeechSynthesisVoice] = []
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section("Kinward Backend") {
                TextField("Base URL (e.g. https://kinward.yourhousehold.internal)", text: self.$settings.kinwardBaseURL)
                    .textFieldStyle(.roundedBorder)

                TextField("Household user id (ha_user_id)", text: self.$settings.kinwardHAUserID)
                    .textFieldStyle(.roundedBorder)
                Text("The same identity string your PersonRecord is already mapped to in Kinward - not a live Home Assistant login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Assistant id (optional - defaults to your primary assistant)", text: self.$settings.kinwardAssistantID)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    SecureField("Integration token", text: self.$tokenInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        try? KeychainService.shared.storeKey(self.tokenInput, for: KinwardClient.keychainProviderID)
                        self.tokenInput = ""
                        self.tokenStored = KeychainService.shared.containsKey(for: KinwardClient.keychainProviderID)
                        self.statusMessage = "Token saved to Keychain."
                    }
                    .disabled(self.tokenInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text(self.tokenStored ? "A token is stored in the Keychain." : "No token stored yet.")
                    .font(.caption)
                    .foregroundStyle(self.tokenStored ? .secondary : .orange)
                Text("Mint one on the Kinward backend with: python -m kinward.cli create-integration-token --name marc-macos-voice")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let issue = self.settings.kinwardModeReadinessIssue {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Label("Kinward Mode is configured.", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Section("Conversation") {
                Text(self.settings.kinwardConversationID.isEmpty
                    ? "No active topic - the next turn starts a new one."
                    : "Continuing topic \(self.settings.kinwardConversationID.prefix(8))...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Start New Conversation") {
                    KinwardClient.shared.startNewConversation()
                }
            }

            Section("Spoken Replies") {
                Picker("Voice", selection: self.$settings.kinwardTTSVoiceIdentifier) {
                    Text("System Default").tag("")
                    ForEach(self.availableVoices, id: \.identifier) { voice in
                        Text("\(voice.name) (\(voice.language))").tag(voice.identifier)
                    }
                }
                Button("Test Voice") {
                    let utterance = AVSpeechUtterance(string: "Hi, I'm your Kinward assistant.")
                    if !self.settings.kinwardTTSVoiceIdentifier.isEmpty {
                        utterance.voice = AVSpeechSynthesisVoice(identifier: self.settings.kinwardTTSVoiceIdentifier)
                    }
                    AVSpeechSynthesizer().speak(utterance)
                }
            }

            Section("Hotkey") {
                Toggle("Enable Option+Command+K push-to-talk", isOn: self.$settings.kinwardHotkeyEnabled)
                    .onChange(of: self.settings.kinwardHotkeyEnabled) { _, _ in
                        KinwardHotkeyMonitor.shared.restart()
                    }
                Text("Press once to start listening, press again to send. Fixed combo for now - not yet customizable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Wake Word") {
                Toggle("Enable always-on wake word", isOn: self.$settings.kinwardWakeWordEnabled)
                    .onChange(of: self.settings.kinwardWakeWordEnabled) { _, enabled in
                        if enabled {
                            KinwardWakeWordService.shared.start()
                        } else {
                            KinwardWakeWordService.shared.stop()
                        }
                    }

                HStack {
                    SecureField("Picovoice AccessKey", text: self.$accessKeyInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        self.settings.kinwardWakeWordAccessKey = self.accessKeyInput
                        self.accessKeyInput = ""
                        self.accessKeyStored = true
                        self.statusMessage = "Picovoice AccessKey saved to Keychain."
                    }
                    .disabled(self.accessKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text(self.accessKeyStored ? "An AccessKey is stored in the Keychain." : "No AccessKey stored yet - get one free at console.picovoice.ai.")
                    .font(.caption)
                    .foregroundStyle(self.accessKeyStored ? .secondary : .orange)

                HStack {
                    TextField("Keyword file (.ppn) path", text: self.$settings.kinwardWakeWordKeywordPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose...") {
                        self.chooseKeywordFile()
                    }
                }
                Text("Train a custom \"Hey Kinward\" keyword at console.picovoice.ai (choose macOS platform), or point this at one of Porcupine's bundled mac keyword files as a placeholder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading) {
                    Text("Sensitivity: \(String(format: "%.2f", self.settings.kinwardWakeWordSensitivity))")
                        .font(.caption)
                    Slider(value: self.$settings.kinwardWakeWordSensitivity, in: 0...1)
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 640)
        .onAppear {
            self.availableVoices = AVSpeechSynthesisVoice.speechVoices()
                .filter { $0.language.hasPrefix("en") }
                .sorted { $0.name < $1.name }
            self.accessKeyStored = !self.settings.kinwardWakeWordAccessKey.isEmpty
        }
    }

    private func chooseKeywordFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Porcupine .ppn keyword file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        self.settings.kinwardWakeWordKeywordPath = url.path
    }
}
