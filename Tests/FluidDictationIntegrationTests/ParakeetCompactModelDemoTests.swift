import AppKit
import AVFoundation
@testable import FluidVoice_Debug
import Foundation
import SwiftUI
import XCTest

@MainActor
final class ParakeetCompactModelDemoTests: XCTestCase {
    func testOptInNativeOnboardingAndSettingsReview() async throws {
        guard ProcessInfo.processInfo.environment["FLUIDVOICE_COMPACT_MODEL_DEMO"] == "1",
              let audioPath = ProcessInfo.processInfo.environment["FLUIDVOICE_COMPACT_MODEL_AUDIO"]
        else { throw XCTSkip("Explicitly enable the native model review with a real recorded English WAV") }
        let settings = SettingsStore.shared
        settings.onboardingSelectedLanguageID = "en"
        let finished = expectation(description: "Native review closed")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Mini and Pico — Model Review"
        let viewModel = VoiceEngineSettingsViewModel(settings: settings, appServices: .shared)
        viewModel.providerFilter = .nvidia
        viewModel.englishOnlyFilter = true
        let view = CompactModelReviewView(viewModel: viewModel, audioPath: audioPath) {
            window.orderOut(nil)
            finished.fulfill()
        }
        window.contentView = NSHostingView(rootView: view.appTheme(.dark))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        print("COMPACT_MODEL_DEMO_READY window=\(window.windowNumber)")
        await fulfillment(of: [finished], timeout: 600)
        window.contentView = nil
        window.close()
        await AppServices.shared.asr.finishAudioRouteRecoveryTest()
    }
}

@MainActor
private struct CompactModelReviewView: View {
    @ObservedObject var viewModel: VoiceEngineSettingsViewModel
    let audioPath: String
    let onClose: () -> Void
    @State private var page = 0
    @State private var onboardingStep = 2
    @State private var shortcutTarget: ShortcutRecordingTarget?
    @State private var shortcutMessage: String?
    @State private var transcript = "Choose a downloaded model to transcribe the real recording."
    @State private var isTranscribing = false
    private let menuBarManager = MenuBarManager()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Review", selection: self.$page) {
                    Text("Voice Engine").tag(0)
                    Text("Onboarding").tag(1)
                    Text("Real transcription").tag(2)
                }
                .pickerStyle(.segmented)
                .frame(width: 450)
                Spacer()
                Button("Close review", action: self.onClose)
                    .disabled(self.isTranscribing || self.viewModel.areSpeechModelActionsBlocked)
            }
            .padding(16)
            Divider()
            switch self.page {
            case 1:
                OnboardingFlowView(
                    currentStep: self.$onboardingStep,
                    accessibilityEnabled: true,
                    accessibilitySetupInProgress: false,
                    markAISkipped: {},
                    finishOnboarding: {},
                    finishOnboardingAtGettingStarted: {},
                    openAccessibilitySettings: {},
                    restartApp: {},
                    menuBarManager: self.menuBarManager,
                    activeShortcutRecordingTarget: self.$shortcutTarget,
                    shortcutRecordingMessage: self.$shortcutMessage,
                    theme: .dark
                )
                .environmentObject(AppServices.shared)
            case 2:
                VStack(alignment: .leading, spacing: 20) {
                    Text("Real recorded audio · English · Microphone stays off")
                    HStack {
                        Button("Test Mini") { self.transcribe(.fluidParakeetMini) }
                        Button("Test Pico") { self.transcribe(.fluidParakeetPico) }
                    }
                    .disabled(self.isTranscribing)
                    if self.isTranscribing { ProgressView("Loading and transcribing…") }
                    Text(self.transcript).textSelection(.enabled)
                    Spacer()
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            default:
                ScrollView {
                    VoiceEngineSettingsView(viewModel: self.viewModel, settings: .shared, theme: .dark)
                        .padding(20)
                }
            }
        }
        .preferredColorScheme(.dark)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func transcribe(_ model: SettingsStore.SpeechModel) {
        self.isTranscribing = true
        self.transcript = ""
        Task { @MainActor in
            defer { self.isTranscribing = false }
            do {
                let samples = try await Self.readAudio(self.audioPath)
                let provider = FluidAudioProvider(
                    modelOverride: model,
                    configureWordBoosting: false,
                    enhancementOptions: .init(experimentalUnifiedFinalEnabled: false, pronunciationMatchingEnabled: false, customDictionaryEntries: [])
                )
                try await provider.prepare()
                let result = try await provider.transcribe(samples)
                self.transcript = "\(model.humanReadableName): \(result.text)"
            } catch {
                self.transcript = error.localizedDescription
            }
        }
    }

    @concurrent private static func readAudio(_ path: String) async throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw CocoaError(.fileReadCorruptFile) }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
