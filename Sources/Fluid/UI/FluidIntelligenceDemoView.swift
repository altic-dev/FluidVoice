import AVFoundation
import SwiftUI

/// Reuses the prompt-test sandbox: no provider selection, history, clipboard, or external typing writes.
struct FluidIntelligenceDemoView: View {
    @ObservedObject var asr: ASRService
    let onStart: () -> Void
    let onStop: () async -> Void
    let onCancel: () -> Void
    let onSetup: () -> Void
    let runExample: (String, String) async throws -> String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @ObservedObject private var sandbox = DictationPromptTestCoordinator.shared
    @ObservedObject private var overlay = NotchContentState.shared
    @State private var selected = 0
    @State private var modelID: String?
    @State private var checking = true
    @State private var sessionID: UUID?
    @State private var sampleTask: Task<Void, Never>?
    @State private var runningSample = false
    @State private var stoppingVoice = false
    @State private var result = ""
    @State private var error = ""

    private struct Example {
        let title: String
        let spoken: String
        let expected: String
    }

    private static let examples: [Example] = {
        let practice = OnboardingPolishPractice.examples
        return [
            Example(title: "Corrections", spoken: practice[0].spoken, expected: practice[0].expected),
            Example(title: "Lists", spoken: practice[1].spoken, expected: practice[1].expected),
            Example(title: "Paragraphs", spoken: practice[2].spoken, expected: practice[2].expected),
            Example(
                title: "Emails",
                spoken: "Hi Maya, thanks for the update. Could you send the revised plan by Friday? Thanks, Alex.",
                expected: "Hi Maya,\n\nThanks for the update. Could you send the revised plan by Friday?\n\nThanks,\nAlex"
            ),
            Example(
                title: "Repetitions",
                spoken: "I think we should, we should review the plan tomorrow, um, before the meeting.",
                expected: "I think we should review the plan tomorrow before the meeting."
            ),
        ]
    }()

    private var busy: Bool { self.asr.isRunningOrStarting || self.overlay.isProcessing || self.sandbox.isProcessing || self.runningSample || self.stoppingVoice }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Fluid Intelligence", systemImage: "sparkles").font(self.theme.typography.captionStrong).foregroundStyle(self.theme.palette.accent)
                    Text("Your words, ready to use.").font(.fluidSystem(size: 30, weight: .regular, design: .serif))
                }
                Spacer()
                Button { self.dismiss() } label: {
                    Image(systemName: "xmark").frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(self.busy).accessibilityLabel("Close demo")
            }
            Picker("Example", selection: self.$selected) {
                ForEach(Self.examples.indices, id: \.self) { index in Text(Self.examples[index].title).tag(index) }
            }
            .pickerStyle(.segmented).disabled(self.busy)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    self.textPanel("You say", text: Self.examples[self.selected].spoken, accented: false)
                    self.textPanel(self.result.isEmpty ? "Example result" : "Your result", text: self.result.isEmpty ? Self.examples[self.selected].expected : self.result, accented: true)
                    Text("Illustrative examples. Run one to see your model’s actual output.")
                        .font(self.theme.typography.caption).foregroundStyle(.secondary)
                    if !self.error.isEmpty { Text(self.error).font(self.theme.typography.bodySmall).foregroundStyle(.red) }
                }
                .id(self.selected)
            }
            if self.busy {
                Label(self.asr.isRunning ? "Listening — stop when you’re finished" : "Preparing your result…", systemImage: self.asr.isRunning ? "waveform" : "sparkles")
                    .font(self.theme.typography.bodySmall)
            }
            FluidGlassControlGroup {
                HStack(spacing: 12) {
                    Button("Not now") { self.dismiss() }.fluidGlassAction().disabled(self.busy).keyboardShortcut(.cancelAction)
                    Spacer()
                    if self.checking {
                        ProgressView("Checking model…").controlSize(.small)
                    } else if let modelID {
                        Button("Try example") { self.tryExample(modelID: modelID) }.fluidGlassAction().disabled(self.busy)
                        Button(self.asr.isRunning ? "Stop and polish" : "Try with your voice", systemImage: self.asr.isRunning ? "stop.fill" : "mic") {
                            if self.asr.isRunning {
                                self.stoppingVoice = true
                                Task {
                                    await self.onStop()
                                    self.stoppingVoice = false
                                }
                            } else {
                                self.activateSandbox(modelID: modelID)
                                self.onStart()
                            }
                        }
                        .fluidGlassAction(prominent: true)
                        .disabled(self.runningSample || self.stoppingVoice || self.overlay.isProcessing || self.sandbox.isProcessing || self.asr.isStarting || !self.asr.isAsrReady || self.asr
                            .micStatus != .authorized)
                    } else {
                        Button("Set up Fluid Intelligence", action: self.onSetup).fluidGlassAction(prominent: true)
                    }
                }
            }
            Text(self.modelID == nil ? "A local Fluid Intelligence model is needed to try these examples." : "Practice stays here. Nothing is typed into another app or saved to history.")
                .font(self.theme.typography.caption).foregroundStyle(.secondary)
            if self.modelID != nil, !self.asr.isAsrReady || self.asr.micStatus != .authorized {
                Text("Voice practice needs a ready Voice Engine model and microphone access. You can still try the written examples.")
                    .font(self.theme.typography.caption).foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(width: 740, height: 620)
        .background(self.theme.palette.contentBackground)
        .interactiveDismissDisabled(self.busy)
        .task {
            let model = PrivateAIIntegrationService.selectedModel
            let installed = await Task.detached(priority: .utility) { PrivateAIIntegrationService.isModelInstalled(model) }.value
            guard !Task.isCancelled else { return }
            self.modelID = installed ? PrivateAIProviderPromptFormat.verifiedModelID(for: model.id) : nil
            self.checking = false
        }
        .onChange(of: self.selected) { _, _ in self.result = ""; self.error = "" }
        .onChange(of: self.sandbox.lastOutputText) { _, text in
            guard self.sessionID == self.sandbox.sessionID else { return }
            self.result = text
        }
        .onChange(of: self.sandbox.lastError) { _, text in
            guard self.sessionID == self.sandbox.sessionID else { return }
            self.error = text
        }
        .onDisappear {
            self.sampleTask?.cancel()
            if self.sessionID == self.sandbox.sessionID {
                if self.asr.isRunningOrStarting { self.onCancel() }
                self.sandbox.deactivate()
            }
        }
    }

    private func textPanel(_ title: String, text: String, accented: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(self.theme.typography.captionStrong).foregroundStyle(accented ? self.theme.palette.accent : self.theme.palette.secondaryText)
            Text(text).font(self.theme.typography.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(accented ? self.theme.palette.accent.opacity(0.07) : self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    private func activateSandbox(modelID: String) {
        guard !self.sandbox.isActive || self.sessionID == self.sandbox.sessionID else { return }
        self.sandbox.activate(draftPromptText: "", providerID: PrivateAIProviderFeature.shared.providerID, model: modelID, usesBuiltInPrompt: true)
        self.sessionID = self.sandbox.sessionID
        self.result = ""
        self.error = ""
    }

    private func tryExample(modelID: String) {
        self.activateSandbox(modelID: modelID)
        guard self.sessionID == self.sandbox.sessionID else { return }
        self.runningSample = true
        self.sandbox.isProcessing = true
        let input = Self.examples[self.selected].spoken
        self.sampleTask = Task { @MainActor in
            defer {
                self.runningSample = false
                if self.sessionID == self.sandbox.sessionID { self.sandbox.isProcessing = false }
            }
            do {
                let output = try await self.runExample(input, modelID)
                try Task.checkCancellation()
                guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.error = "No text was returned. Try again."
                    return
                }
                self.result = output
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
