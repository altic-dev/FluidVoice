//
//  WelcomeView.swift
//  fluid
//
//  Welcome and setup guide view
//

import AppKit
import AVFoundation
import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var appServices: AppServices
    private var asr: ASRService {
        self.appServices.asr
    }

    @ObservedObject private var settings = SettingsStore.shared
    @Binding var selectedSidebarItem: SidebarItem?
    @Binding var playgroundUsed: Bool
    var isTranscriptionFocused: FocusState<Bool>.Binding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme

    let accessibilityEnabled: Bool
    let stopAndProcessTranscription: () async -> Void
    let startRecording: () -> Void
    let openAccessibilitySettings: () -> Void
    let restartApp: () -> Void

    private var commandModeShortcutDisplay: String {
        self.settings.commandModeHotkeyShortcut.displayString
    }

    private var writeModeShortcutDisplay: String {
        self.settings.rewriteModeHotkeyShortcut.displayString
    }

    private let playgroundSectionID = "welcome-playground-section"

    private var commandModeColor: Color {
        self.theme.palette.warning
    }

    private var editModeColor: Color {
        self.theme.palette.accent
    }

    private var isAIEnhancementReady: Bool {
        DictationAIPostProcessingGate.isProviderConfigured()
    }

    private var appDisplayName: String {
        Bundle.main.fluidAppDisplayName
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Image(systemName: "book.fill")
                            .font(self.theme.typography.titleIcon)
                            .foregroundStyle(self.theme.palette.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text((self.asr.isAsrReady || self.asr.modelsExistOnDisk) ? "Getting Started" : "Welcome to FluidVoice")
                                .font(self.theme.typography.title)
                            Text("Talk anywhere. FluidVoice types for you.")
                                .font(self.theme.typography.bodySmall)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 4)

                    // Quick Setup Checklist
                    ThemedCard(style: .prominent) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                Label("Quick Setup", systemImage: "checkmark.circle.fill")
                                    .font(self.theme.typography.sectionTitle)
                                    .foregroundStyle(self.theme.palette.accent)

                                Spacer()

                                Button {
                                    self.settings.resetOnboardingProgress()
                                    self.playgroundUsed = false
                                } label: {
                                    Label("Run Onboarding Again", systemImage: "arrow.counterclockwise")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                SetupStepView(
                                    step: 1,
                                    // Consider model step complete if ready OR downloaded (even if not loaded)
                                    title: (self.asr.isAsrReady || self.asr.modelsExistOnDisk) ? "Voice Model Ready" : "Download Voice Model",
                                    description: self.asr.isAsrReady
                                        ? "Speech recognition model is loaded and ready"
                                        : (
                                            self.asr.modelsExistOnDisk
                                                ? "Model downloaded, will load when needed"
                                                : "Download the AI model for offline voice transcription (~500MB)"
                                        ),
                                    status: (self.asr.isAsrReady || self.asr.modelsExistOnDisk) ? .completed : .pending,
                                    action: {
                                        self.selectedSidebarItem = .voiceEngine
                                    },
                                    actionButtonTitle: "Go to Voice Engine",
                                    showActionButton: !(self.asr.isAsrReady || self.asr.modelsExistOnDisk)
                                )

                                SetupStepView(
                                    step: 2,
                                    title: self.asr.micStatus == .authorized ? "Microphone Permission Granted" : "Grant Microphone Permission",
                                    description: self.asr.micStatus == .authorized
                                        ? "FluidVoice has access to your microphone"
                                        : "Allow FluidVoice to access your microphone for voice input",
                                    status: self.asr.micStatus == .authorized ? .completed : .pending,
                                    action: {
                                        if self.asr.micStatus == .notDetermined {
                                            self.asr.requestMicAccess()
                                        } else if self.asr.micStatus == .denied {
                                            self.asr.openSystemSettingsForMic()
                                        }
                                    },
                                    actionButtonTitle: self.asr.micStatus == .notDetermined ? "Grant Access" : "Open Settings",
                                    showActionButton: self.asr.micStatus != .authorized
                                )

                                SetupStepView(
                                    step: 3,
                                    title: self.accessibilityEnabled ? "Accessibility Access Enabled" : "Enable Accessibility Access",
                                    description: self.accessibilityEnabled
                                        ? "Accessibility permission granted for typing into apps"
                                        : "Drag \(self.appDisplayName) into the Accessibility apps list as shown",
                                    status: self.accessibilityEnabled ? .completed : .pending,
                                    action: {
                                        self.openAccessibilitySettings()
                                    },
                                    actionButtonTitle: "Open Settings",
                                    showActionButton: !self.accessibilityEnabled
                                )

                                SetupStepView(
                                    step: 4,
                                    title: self.isAIEnhancementReady ? "AI Enhancement Configured" : "Set Up AI Enhancement (Optional)",
                                    description: self.isAIEnhancementReady
                                        ? "AI-powered text enhancement is ready to use"
                                        : "Configure API keys for AI-powered text enhancement",
                                    status: self.isAIEnhancementReady ? .completed : .pending,
                                    action: {
                                        self.selectedSidebarItem = .aiEnhancements
                                    },
                                    actionButtonTitle: "Configure AI"
                                )

                                SetupStepView(
                                    step: 5,
                                    title: self.playgroundUsed ? "Setup Tested Successfully" : "Test Your Setup",
                                    description: self.playgroundUsed
                                        ? "You've successfully tested voice transcription"
                                        : "Try the playground below to test your complete setup",
                                    status: self.playgroundUsed ? .completed : .pending,
                                    action: {
                                        withAnimation(.easeInOut(duration: 0.25)) {
                                            proxy.scrollTo(self.playgroundSectionID, anchor: .top)
                                        }
                                        self.isTranscriptionFocused.wrappedValue = true
                                    },
                                    actionButtonTitle: "Go to Playground",
                                    showActionButton: !self.playgroundUsed
                                )
                                .id("playground-step-\(self.playgroundUsed)")
                            }
                        }
                        .padding(14)
                    }

                    // Test Playground
                    ThemedCard(hoverEffect: false) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Test Playground")
                                            .font(self.theme.typography.sectionTitle)
                                        Text("Click record, speak, and see your transcription")
                                            .font(self.theme.typography.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "text.bubble")
                                        .font(self.theme.typography.titleIcon)
                                }

                                Spacer()

                                if self.asr.isRunning {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(.red)
                                            .frame(width: 6, height: 6)
                                        Text("Recording...")
                                            .font(self.theme.typography.captionStrong)
                                            .foregroundStyle(.red)
                                    }
                                } else if !self.asr.finalText.isEmpty {
                                    Text("\(self.asr.finalText.count) characters")
                                        .font(self.theme.typography.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if self.settings.selectedSpeechModel == .parakeetTDT || self.settings.selectedSpeechModel == .parakeetTDTv2 {
                                HStack(spacing: 6) {
                                    Image(systemName: "text.magnifyingglass")
                                        .font(self.theme.typography.caption)
                                        .foregroundStyle(self.theme.palette.accent)
                                    Text(self.asr.wordBoostStatusText)
                                        .font(self.theme.typography.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(self.theme.palette.contentBackground.opacity(0.6))
                                )
                            }

                            VStack(alignment: .leading, spacing: 14) {
                                // Recording Control — centered button
                                HStack {
                                    Spacer()
                                    Button {
                                        if self.asr.isRunning {
                                            Task {
                                                await self.stopAndProcessTranscription()
                                            }
                                        } else {
                                            self.startRecording()
                                            self.playgroundUsed = true
                                            SettingsStore.shared.playgroundUsed = true
                                        }
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: self.asr.isRunning ? "stop.fill" : "mic.fill")
                                            Text(self.asr.isRunning ? "Stop Recording" : "Start Recording")
                                        }
                                        .frame(maxWidth: 220)
                                    }
                                    .fluidButton(.primary, size: .large, isRecording: self.asr.isRunning)
                                    .buttonHoverEffect()
                                    .scaleEffect(!self.reduceMotion && self.asr.isRunning ? 1.02 : 1.0)
                                    .animation(self.reduceMotion ? nil : .spring(response: 0.3), value: self.asr.isRunning)
                                    .disabled(!self.asr.isAsrReady && !self.asr.isRunning)
                                    Spacer()
                                }

                                // Text Area
                                VStack(alignment: .leading, spacing: 8) {
                                    TextEditor(text: Binding(
                                        get: { self.asr.finalText },
                                        set: { self.asr.finalText = $0 }
                                    ))
                                    .font(self.theme.typography.body)
                                    .focused(self.isTranscriptionFocused)
                                    .frame(height: 120)
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(
                                                self.asr.isRunning ? self.theme.palette.accent.opacity(0.06) : self.theme.palette.cardBackground
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .strokeBorder(
                                                        self.asr.isRunning ? self.theme.palette.accent.opacity(0.4) : self.theme.palette.cardBorder.opacity(0.6),
                                                        lineWidth: self.asr.isRunning ? 2 : 1
                                                    )
                                            )
                                    )
                                    .scrollContentBackground(.hidden)
                                    .overlay(
                                        VStack(spacing: 8) {
                                            if self.asr.isRunning {
                                                Image(systemName: "waveform")
                                                    .font(self.theme.typography.titleIcon)
                                                    .foregroundStyle(self.theme.palette.accent)
                                                Text("Listening... Speak now!")
                                                    .font(self.theme.typography.bodySmallStrong)
                                                    .foregroundStyle(self.theme.palette.accent)
                                                Text("Transcription will appear when you stop recording")
                                                    .font(self.theme.typography.caption)
                                                    .foregroundStyle(self.theme.palette.accent.opacity(0.7))
                                            } else if self.asr.finalText.isEmpty {
                                                Image(systemName: "text.bubble")
                                                    .font(self.theme.typography.titleIcon)
                                                    .foregroundStyle(.secondary.opacity(0.5))
                                                Text("Press record or your hotkey to begin")
                                                    .font(self.theme.typography.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .allowsHitTesting(false)
                                    )

                                    if !self.asr.finalText.isEmpty {
                                        HStack(spacing: 8) {
                                            Button {
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(self.asr.finalText, forType: .string)
                                            } label: {
                                                Label("Copy Text", systemImage: "doc.on.doc")
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(self.theme.palette.accent)
                                            .controlSize(.small)

                                            Button("Clear & Test Again") {
                                                self.asr.finalText = ""
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
                    .id(self.playgroundSectionID)

                    // Secondary guidance
                    ThemedCard(style: .subtle) {
                        VStack(alignment: .leading, spacing: 12) {
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 10) {
                                    self.howToStep(number: 1, title: "Start Recording", description: "Press your hotkey (default: Right Option/Alt) or click the button")
                                    self.howToStep(number: 2, title: "Speak Clearly", description: "Speak naturally - works best in quiet environments")
                                    self.howToStep(number: 3, title: "Auto-Type Result", description: "Transcription is automatically typed into your focused app")
                                }
                                .padding(.top, 8)
                            } label: {
                                Label("How to Use", systemImage: "play.fill")
                                    .font(self.theme.typography.sectionTitle)
                                    .foregroundStyle(self.theme.palette.accent)
                            }

                            Divider().opacity(0.2)

                            DisclosureGroup {
                                self.commandModeGuide
                                    .padding(.top, 8)
                            } label: {
                                HStack(spacing: 8) {
                                    Label("Command Mode", systemImage: "terminal.fill")
                                        .font(self.theme.typography.sectionTitle)
                                        .foregroundStyle(self.commandModeColor)
                                    self.featureBadge("New", color: self.commandModeColor)
                                    self.featureBadge("Alpha", color: self.commandModeColor.opacity(0.75))
                                }
                            }

                            Divider().opacity(0.2)

                            DisclosureGroup {
                                self.editModeGuide
                                    .padding(.top, 8)
                            } label: {
                                HStack(spacing: 8) {
                                    Label("Edit Mode", systemImage: "pencil.and.outline")
                                        .font(self.theme.typography.sectionTitle)
                                        .foregroundStyle(self.editModeColor)
                                    self.featureBadge("New", color: self.editModeColor)
                                }
                            }
                        }
                        .padding(12)
                    }
                }
                .padding(16)
            }
        }
        .onAppear {
            // CRITICAL FIX: Refresh microphone and model status immediately on appear
            // This prevents the Quick Setup from showing stale status before ASRService.initialize() runs
            Task { @MainActor in
                // Check microphone status without triggering the full initialize() delay
                self.asr.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

                // Check if models exist on disk (async for accurate detection with AppleSpeechAnalyzerProvider)
                await self.asr.checkIfModelsExistAsync()
            }
        }
    }

    // MARK: - Helper Views

    private var commandModeGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Control your Mac with voice commands. Execute terminal commands, open apps, and more.")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Open") {
                    self.selectedSidebarItem = .commandMode
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Getting Started")
                    .font(self.theme.typography.bodySmallStrong)
                    .foregroundStyle(self.commandModeColor)

                HStack(spacing: 4) {
                    Text("Press")
                    self.keyboardBadge(self.commandModeShortcutDisplay)
                    Text("to open, speak your command, then press again to send.")
                }
                .font(self.theme.typography.caption)
                .foregroundStyle(.primary.opacity(0.8))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Examples")
                    .font(self.theme.typography.bodySmallStrong)
                    .foregroundStyle(self.commandModeColor)
                self.commandModeExample(icon: "folder", text: "\"List files in my Downloads folder\"")
                self.commandModeExample(icon: "plus.rectangle.on.folder", text: "\"Create a folder called Projects on Desktop\"")
                self.commandModeExample(icon: "network", text: "\"What's my IP address?\"")
                self.commandModeExample(icon: "safari", text: "\"Open Safari\"")
            }

            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(self.theme.typography.captionSmall)
                    .foregroundStyle(self.commandModeColor)
                Text("AI can make mistakes. Avoid destructive commands.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var editModeGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI-powered editing assistant. Write fresh content or edit selected text with voice.")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Open AI Settings") {
                    self.selectedSidebarItem = .aiEnhancements
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Create New Text")
                        .font(self.theme.typography.bodySmallStrong)
                        .foregroundStyle(self.editModeColor)

                    HStack(spacing: 4) {
                        Text("Press")
                        self.keyboardBadge(self.writeModeShortcutDisplay)
                        Text("and speak what you want to write.")
                    }
                    .font(self.theme.typography.caption)
                    .foregroundStyle(.primary.opacity(0.8))

                    self.writeModeExample(text: "\"Write an email asking for time off\"")
                    self.writeModeExample(text: "\"Draft a thank you note\"")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Edit Selected Text")
                        .font(self.theme.typography.bodySmallStrong)
                        .foregroundStyle(self.editModeColor)

                    HStack(spacing: 4) {
                        Text("Select text first, then press")
                        self.keyboardBadge(self.writeModeShortcutDisplay)
                        Text("and speak your instruction.")
                    }
                    .font(self.theme.typography.caption)
                    .foregroundStyle(.primary.opacity(0.8))

                    self.writeModeExample(text: "\"Make this more formal\"")
                    self.writeModeExample(text: "\"Fix grammar and spelling\"")
                    self.writeModeExample(text: "\"Summarize this\"")
                }
            }
        }
    }

    private func howToStep(number: Int, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(self.theme.palette.accent.opacity(0.15))
                    .frame(width: 28, height: 28)
                Text("\(number)")
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.theme.palette.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(self.theme.typography.bodyStrong)
                Text(description)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func featureBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(self.theme.typography.badge)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func keyboardBadge(_ text: String) -> some View {
        Text(text)
            .font(self.theme.typography.captionStrong)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(self.theme.palette.cardBackground.opacity(0.7), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func commandModeExample(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(self.theme.typography.captionSmall)
                .foregroundStyle(self.commandModeColor.opacity(0.8))
                .frame(width: 14)
            Text(text)
                .font(self.theme.typography.caption)
                .foregroundStyle(.primary.opacity(0.8))
        }
    }

    private func writeModeExample(text: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(self.editModeColor.opacity(0.6))
                .frame(width: 4, height: 4)
            Text(text)
                .font(self.theme.typography.caption)
                .foregroundStyle(.primary.opacity(0.8))
        }
    }
}

struct OnboardingFlowView: View {
    @EnvironmentObject var appServices: AppServices
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var asr: ASRService {
        self.appServices.asr
    }

    @ObservedObject private var settings = SettingsStore.shared

    @Binding var currentStep: Int
    let accessibilityEnabled: Bool
    let accessibilitySetupInProgress: Bool
    let markAISkipped: () -> Void
    let finishOnboarding: () -> Void
    let finishOnboardingAtGettingStarted: () -> Void
    let openAIEnhancementSettingsFromOnboarding: () -> Void
    let openAccessibilitySettings: () -> Void
    let restartApp: () -> Void
    let menuBarManager: MenuBarManager
    @Binding var activeShortcutRecordingTarget: ShortcutRecordingTarget?
    @Binding var shortcutRecordingMessage: String?
    let theme: AppTheme

    @State private var selectedLanguageID = SettingsStore.shared.onboardingSelectedLanguageID
    @State private var selectedModelRouteID: String?
    @State private var hoveredLanguageID: String?
    @State private var hoveredModelRouteID: String?
    @State private var hoveredModelActionButtonID: String?
    @State private var hoveredPermissionButtonID: String?
    @State private var hoveredFooterButton: OnboardingFooterButton?
    @State private var isShowingAllLanguages = false
    @State private var isShowingOtherModelRoutes = false
    @State private var preparingModelRouteID: String?
    @State private var uninstallingModelRouteID: String?
    @State private var languageSearchText = ""
    @FocusState private var isLanguageSearchFocused: Bool
    @State private var hasPlayedLandingWelcomeSound = false
    @State private var landingGlowCenter = UnitPoint(x: 0.5, y: 0.18)
    @State private var lastLandingGlowLocation = CGPoint(x: -1000, y: -1000)
    private let landingGlowMovementThreshold: CGFloat = 24

    private enum OnboardingFooterButton {
        case back
        case skip
        case next
    }

    private enum OnboardingPillButtonTone {
        case primary
        case secondary
        case destructive
    }

    private struct OnboardingPillButtonConfiguration {
        let title: String
        let systemImage: String?
        let tone: OnboardingPillButtonTone
        let width: CGFloat?
        let height: CGFloat
        let fontSize: CGFloat
        let iconSize: CGFloat
        let isHovered: Bool
        let isEnabled: Bool
    }

    private enum Step: Int, CaseIterable {
        case landing = 0
        case language = 1
        case voiceModel = 2
        case permissions = 3
        case playground = 4
        case aiEnhancement = 5

        var title: String {
            switch self {
            case .landing:
                return "Welcome"
            case .language:
                return "Choose Language"
            case .voiceModel:
                return "Choose Voice Engine"
            case .permissions:
                return "Enable Access"
            case .aiEnhancement:
                return "Set Up AI Enhancement"
            case .playground:
                return "Try FluidVoice"
            }
        }

        var subtitle: String {
            switch self {
            case .landing:
                return "Talk anywhere. FluidVoice types for you."
            case .language:
                return "Pick the language you speak most."
            case .voiceModel:
                return "Choose the best local engine for your language."
            case .permissions:
                return "Allow FluidVoice to listen and type into other apps."
            case .aiEnhancement:
                return "Optional: Configure AI post-processing or skip this step."
            case .playground:
                return "Use your dictation shortcut once before finishing setup."
            }
        }
    }

    private var step: Step {
        Step(rawValue: self.currentStep) ?? .voiceModel
    }

    private var progressValue: Double {
        Double(self.step.rawValue) / Double(Step.allCases.count - 1)
    }

    private var compactProgressValue: Double {
        Double(self.step.rawValue + 1) / Double(Step.allCases.count)
    }

    private var popularOnboardingLanguages: [VoiceEngineLanguage] {
        VoiceEngineLanguageCatalog.popularLanguages()
    }

    private var selectedOnboardingLanguage: VoiceEngineLanguage {
        VoiceEngineLanguageCatalog.language(id: self.selectedLanguageID)
            ?? VoiceEngineLanguageCatalog.language(id: "en")
            ?? VoiceEngineLanguage(id: "en", displayName: "English", aliases: [], isPopular: true)
    }

    private var searchedOnboardingLanguages: [VoiceEngineLanguage] {
        VoiceEngineLanguageCatalog.searchableLanguages(query: self.languageSearchText)
    }

    private var selectedLanguageRoutes: [VoiceEngineLanguageRoute] {
        VoiceEngineLanguageCatalog.routes(for: self.selectedOnboardingLanguage)
    }

    private var selectedOnboardingRoute: VoiceEngineLanguageRoute? {
        if let selectedModelRouteID,
           let selectedRoute = self.selectedLanguageRoutes.first(where: { $0.id == selectedModelRouteID })
        {
            return selectedRoute
        }

        if let selectedRoute = self.selectedLanguageRoutes.first(where: { self.isRouteSelectedInSettings($0) }) {
            return selectedRoute
        }

        return self.selectedLanguageRoutes.first
    }

    private var primaryDisplayedModelRoute: VoiceEngineLanguageRoute? {
        self.selectedLanguageRoutes.first
    }

    private var defaultDisplayedModelRoutes: [VoiceEngineLanguageRoute] {
        var routes: [VoiceEngineLanguageRoute] = []
        if let primaryDisplayedModelRoute {
            routes.append(primaryDisplayedModelRoute)
        }
        if let builtInRoute = self.defaultBuiltInModelRoute,
           !routes.contains(where: { $0.id == builtInRoute.id })
        {
            routes.append(builtInRoute)
        }
        return routes
    }

    private var defaultBuiltInModelRoute: VoiceEngineLanguageRoute? {
        guard self.selectedOnboardingLanguage.id == "en" else {
            return nil
        }

        return self.selectedLanguageRoutes.first { route in
            switch route.model {
            case .appleSpeech, .appleSpeechAnalyzer:
                return true
            default:
                return false
            }
        }
    }

    private var otherModelRoutes: [VoiceEngineLanguageRoute] {
        let defaultRouteIDs = Set(self.defaultDisplayedModelRoutes.map(\.id))
        return self.selectedLanguageRoutes.filter { !defaultRouteIDs.contains($0.id) }
    }

    private var recommendedOnboardingModel: SettingsStore.SpeechModel {
        self.selectedOnboardingRoute?.model ?? SettingsStore.SpeechModel.defaultModel
    }

    private var recommendedModelReasonText: String {
        "Recommended for \(self.selectedOnboardingLanguage.displayName). You can see more options if needed."
    }

    private var isRecommendedModelDownloaded: Bool {
        self.isOnboardingModelDownloaded(self.recommendedOnboardingModel)
    }

    private var isPreparingRecommendedModel: Bool {
        self.isPreparingOnboardingModel(self.recommendedOnboardingModel)
    }

    private var isRecommendedModelReady: Bool {
        self.isOnboardingModelReady(self.recommendedOnboardingModel)
    }

    private var isVoiceModelReady: Bool {
        guard let route = self.selectedOnboardingRoute else {
            return false
        }
        return self.isOnboardingRouteReady(route)
    }

    private var isModelPreparationInProgress: Bool {
        guard self.step == .voiceModel else {
            return false
        }
        return self.preparingModelRouteID != nil || self.asr.isDownloadingModel || (self.asr.isLoadingModel && !self.asr.isAsrReady)
    }

    private var isMicrophoneReady: Bool {
        self.asr.micStatus == .authorized
    }

    private var isAccessibilityReady: Bool {
        self.accessibilityEnabled
    }

    private var isPermissionsReady: Bool {
        self.isMicrophoneReady && self.isAccessibilityReady
    }

    private var isAIReady: Bool {
        self.settings.onboardingAISkipped || DictationAIPostProcessingGate.isProviderConfigured()
    }

    private var isPlaygroundReady: Bool {
        self.settings.onboardingPlaygroundValidated || self.settings.onboardingPlaygroundSkipped
    }

    private var onboardingShortcutDisplay: String {
        let display = self.settings.primaryDictationShortcutDisplayString.trimmingCharacters(in: .whitespacesAndNewlines)
        return display.isEmpty ? "your shortcut" : display
    }

    private var isRecordingAnyShortcut: Bool {
        self.activeShortcutRecordingTarget != nil
    }

    private var isRecordingPrimaryShortcut: Bool {
        self.activeShortcutRecordingTarget?.isPrimaryDictation == true
    }

    private var canContinue: Bool {
        guard !self.isModelPreparationInProgress else {
            return false
        }

        switch self.step {
        case .landing:
            return true
        case .language:
            return !self.selectedLanguageRoutes.isEmpty
        case .voiceModel:
            return self.isVoiceModelReady
        case .permissions:
            return self.isPermissionsReady
        case .aiEnhancement:
            return self.isAIReady
        case .playground:
            return self.isPlaygroundReady && !self.asr.isRunning && !self.isRecordingAnyShortcut
        }
    }

    private var primaryButtonTitle: String {
        switch self.step {
        case .landing:
            return "Next"
        case .language:
            return "Continue"
        case .aiEnhancement:
            return "Finish Setup"
        default:
            return "Continue"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            self.stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .background {
            ZStack {
                self.theme.palette.windowBackground
                    .opacity(0.98)
                    .ignoresSafeArea()

                Rectangle()
                    .fill(self.theme.materials.window)
                    .opacity(0.75)
                    .ignoresSafeArea()
            }
        }
        .onAppear {
            self.syncOnboardingSelectionFromSettings()
            self.playLandingWelcomeSoundIfNeeded()
            Task { @MainActor in
                self.asr.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                await self.asr.checkIfModelsExistAsync()
            }
        }
        .onChange(of: self.currentStep) { _, _ in
            self.playLandingWelcomeSoundIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            self.syncOnboardingSelectionFromSettings()
            self.asr.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Welcome to FluidVoice")
                .font(self.theme.typography.title)
                .foregroundStyle(self.theme.palette.primaryText)

            Text(self.step.subtitle)
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.theme.palette.secondaryText)

            HStack {
                Text("Step \(self.step.rawValue + 1) of \(Step.allCases.count)")
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(self.step.title)
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.theme.palette.accent)
            }

            ProgressView(value: self.progressValue)
                .tint(self.theme.palette.accent)
        }
        .padding(24)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch self.step {
        case .landing:
            self.landingStep
        case .language:
            self.languageStep
        case .voiceModel:
            self.voiceModelStep
        case .permissions:
            self.permissionsStep
        case .aiEnhancement:
            self.aiEnhancementStep
        case .playground:
            self.playgroundStep
        }
    }

    private var landingStep: some View {
        GeometryReader { proxy in
            let landing = self.theme.metrics.onboardingSurface.landing

            ZStack {
                VStack(alignment: .center, spacing: self.theme.metrics.onboardingSurface.landing.sectionSpacing) {
                    FluidOnboardingLandingHero(
                        eyebrow: "",
                        title: "Just speak.",
                        accentTitle: "We'll handle the rest.",
                        firstDetail: "Accurate. Fast. Private. Free.",
                        secondDetail: "Built for creators, thinkers, and builders."
                    ) {
                        FluidOnboardingLandingPrimaryButton(title: "Next") {
                            self.goNext()
                        }
                        .frame(
                            width: FluidOnboardingLandingPrimaryButton.size.width,
                            height: FluidOnboardingLandingPrimaryButton.size.height
                        )
                    }
                }
                .frame(width: landing.contentWidth, alignment: .center)
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height, alignment: .center)
                .offset(y: -78)
                .padding(.horizontal, 24)
                .padding(.vertical, 24)

                FluidOnboardingLandingHoverTracker(
                    onMove: { location, size in
                        self.updateLandingGlow(location: location, in: size)
                    },
                    onExit: {
                        self.resetLandingGlow()
                    }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .accessibilityHidden(true)
                .zIndex(-1)
            }
            .background {
                FluidOnboardingLandingBackdrop(glowCenter: self.landingGlowCenter)
            }
        }
    }

    private func updateLandingGlow(location: CGPoint, in size: CGSize) {
        guard !self.reduceMotion else { return }
        guard location.x.isFinite, location.y.isFinite, size.width > 0, size.height > 0 else { return }

        let dx = location.x - self.lastLandingGlowLocation.x
        let dy = location.y - self.lastLandingGlowLocation.y
        guard (dx * dx) + (dy * dy) > (self.landingGlowMovementThreshold * self.landingGlowMovementThreshold) else { return }

        self.lastLandingGlowLocation = location
        let normalizedX = min(max(location.x / size.width, 0), 1)
        let normalizedY = min(max(location.y / size.height, 0), 1)

        withAnimation(.easeOut(duration: 0.22)) {
            self.landingGlowCenter = UnitPoint(x: normalizedX, y: normalizedY)
        }
    }

    private func resetLandingGlow() {
        guard !self.reduceMotion else { return }
        self.lastLandingGlowLocation = CGPoint(x: -1000, y: -1000)

        withAnimation(.easeOut(duration: 0.35)) {
            self.landingGlowCenter = UnitPoint(x: 0.5, y: 0.18)
        }
    }

    private func playLandingWelcomeSoundIfNeeded() {
        guard self.step == .landing, !self.hasPlayedLandingWelcomeSound else { return }
        self.hasPlayedLandingWelcomeSound = true
        OnboardingSoundPlayer.shared.playWelcomeSound()
    }

    private var languageStep: some View {
        GeometryReader { proxy in
            ZStack {
                FluidOnboardingLandingBackdrop(glowCenter: self.landingGlowCenter)

                VStack(spacing: 0) {
                    FluidOnboardingCompactProgress(value: self.compactProgressValue)
                        .padding(.top, 28)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            FluidOnboardingCompactAppIconMark(size: 66)
                                .padding(.bottom, 22)

                            Text("What language will\nyou speak most?")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineSpacing(4)
                                .padding(.bottom, 18)

                            Text("We'll show the best voice engines for it.")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.62))
                                .padding(.bottom, 26)

                            LazyVGrid(
                                columns: [
                                    GridItem(.fixed(166), spacing: 16),
                                    GridItem(.fixed(166), spacing: 16),
                                    GridItem(.fixed(166), spacing: 16),
                                ],
                                spacing: 16
                            ) {
                                ForEach(self.popularOnboardingLanguages) { language in
                                    self.languageChoiceCard(for: language)
                                }

                                self.otherLanguageCard
                            }
                            .frame(width: 530)

                            if self.isShowingAllLanguages {
                                self.allLanguagesPicker
                                    .padding(.top, 18)
                            }

                            Text("You can change this later in Voice Engine settings.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.44))
                                .padding(.top, 18)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                        .padding(.bottom, 12)
                    }

                    self.cinematicFooter(
                        continueTitle: "Continue",
                        canContinue: self.canContinue
                    ) {
                        self.handlePrimaryAction()
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)

                FluidOnboardingLandingHoverTracker(
                    onMove: { location, size in
                        self.updateLandingGlow(location: location, in: size)
                    },
                    onExit: {
                        self.resetLandingGlow()
                    }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .accessibilityHidden(true)
            }
        }
    }

    private func languageChoiceCard(for language: VoiceEngineLanguage) -> some View {
        let isSelected = self.selectedLanguageID == language.id
        let isHovered = self.hoveredLanguageID == language.id
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        let cardFillOpacity = isSelected
            ? (isHovered ? 0.15 : 0.075)
            : (isHovered ? 0.10 : 0.04)
        let borderColor = isSelected
            ? FluidOnboardingLandingColors.blue.opacity(isHovered ? 1 : 0.92)
            : (isHovered ? FluidOnboardingLandingColors.blue.opacity(0.58) : Color.white.opacity(0.10))
        let borderWidth: CGFloat = isSelected
            ? (isHovered ? 1.8 : 1.4)
            : (isHovered ? 1.2 : 1)
        let shadowColor = isSelected
            ? FluidOnboardingLandingColors.blue.opacity(isHovered ? 0.36 : 0.18)
            : FluidOnboardingLandingColors.blue.opacity(isHovered ? 0.18 : 0)
        let shadowRadius: CGFloat = isSelected
            ? (isHovered ? 24 : 18)
            : (isHovered ? 20 : 14)

        return Button {
            self.selectOnboardingLanguage(language)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isSelected ? FluidOnboardingLandingColors.blue : Color.white.opacity(0.72))
                    .frame(width: 22)

                Text(language.popularDisplayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(FluidOnboardingLandingColors.blue)
                }
            }
            .padding(.horizontal, 15)
            .frame(width: 166, height: 58)
            .background(
                shape
                    .fill(Color.white.opacity(cardFillOpacity))
                    .overlay(
                        shape.stroke(
                            borderColor,
                            lineWidth: borderWidth
                        )
                    )
            )
            .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: 0)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered in
            if isHovered {
                self.setHoveredLanguage(language.id)
            } else if self.hoveredLanguageID == language.id {
                self.setHoveredLanguage(nil)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    self.selectOnboardingLanguage(language)
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(language.displayName)
        .accessibilityValue(isSelected ? "Selected" : "")
    }

    private var otherLanguageCard: some View {
        let isSelected = !self.selectedOnboardingLanguage.isPopular
        let isHovered = self.hoveredLanguageID == "other"
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        let fillOpacity = isSelected
            ? (isHovered ? 0.15 : 0.075)
            : (isHovered ? 0.10 : 0.04)
        let borderColor = isSelected
            ? FluidOnboardingLandingColors.blue.opacity(isHovered ? 1 : 0.92)
            : (isHovered ? FluidOnboardingLandingColors.blue.opacity(0.58) : Color.white.opacity(self.isShowingAllLanguages ? 0.16 : 0.10))
        let shadowColor = isSelected
            ? FluidOnboardingLandingColors.blue.opacity(isHovered ? 0.36 : 0.18)
            : FluidOnboardingLandingColors.blue.opacity(isHovered ? 0.18 : 0)

        return Button {
            self.toggleAllLanguagesPicker()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(isSelected ? FluidOnboardingLandingColors.blue : Color.white.opacity(self.isShowingAllLanguages ? 0.78 : 0.72))
                    .frame(width: 22)

                Text(isSelected ? self.selectedOnboardingLanguage.displayName : "Other")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)

                Spacer(minLength: 0)

                Image(systemName: self.isShowingAllLanguages ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.46))
            }
            .padding(.horizontal, 15)
            .frame(width: 166, height: 58)
            .background(
                shape
                    .fill(Color.white.opacity(fillOpacity))
                    .overlay(
                        shape.stroke(
                            borderColor,
                            lineWidth: isSelected ? 1.4 : 1
                        )
                    )
            )
            .shadow(color: shadowColor, radius: isSelected ? (isHovered ? 24 : 18) : 20, x: 0, y: 0)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered in
            self.setHoveredLanguage(isHovered ? "other" : nil)
        }
        .accessibilityLabel("Other languages")
        .accessibilityValue(self.isShowingAllLanguages ? "Expanded" : "Collapsed")
    }

    private var allLanguagesPicker: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.48))

                TextField(
                    "",
                    text: self.$languageSearchText,
                    prompt: Text("Search supported languages")
                        .foregroundStyle(Color.white.opacity(0.42))
                )
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .focused(self.$isLanguageSearchFocused)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .frame(width: 530, height: 38)
            .contentShape(Rectangle())
            .onTapGesture {
                self.isLanguageSearchFocused = true
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )
            )

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 6) {
                    ForEach(self.searchedOnboardingLanguages) { language in
                        self.languageSearchRow(for: language)
                    }
                }
                .padding(8)
            }
            .frame(width: 530, height: 156)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
        }
    }

    private func languageSearchRow(for language: VoiceEngineLanguage) -> some View {
        let isSelected = self.selectedLanguageID == language.id

        return Button {
            self.selectOnboardingLanguage(language)
        } label: {
            HStack(spacing: 10) {
                Text(language.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(FluidOnboardingLandingColors.blue)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? FluidOnboardingLandingColors.blue.opacity(0.14) : Color.white.opacity(0.045))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private func cinematicFooter(
        continueTitle: String,
        canContinue: Bool,
        continueAction: @escaping () -> Void,
        skipTitle: String? = nil,
        canSkip: Bool = false,
        skipAction: (() -> Void)? = nil
    ) -> some View {
        let canNavigateBack = !self.isModelPreparationInProgress && !self.asr.isRunning && !self.isRecordingAnyShortcut

        return HStack {
            self.cinematicFooterButton(
                title: "Back",
                kind: .back,
                isEnabled: canNavigateBack
            ) {
                self.goBack()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if let skipTitle, let skipAction {
                self.cinematicFooterButton(
                    title: skipTitle,
                    kind: .skip,
                    isEnabled: canSkip
                ) {
                    skipAction()
                }
            }

            self.cinematicFooterButton(
                title: continueTitle,
                kind: .next,
                isEnabled: canContinue
            ) {
                continueAction()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 24)
    }

    private func cinematicFooterButton(
        title: String,
        kind: OnboardingFooterButton,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isPrimary = kind == .next
        let isHovered = self.hoveredFooterButton == kind && isEnabled

        return self.onboardingPillButton(
            configuration: OnboardingPillButtonConfiguration(
                title: title,
                systemImage: nil,
                tone: isPrimary ? .primary : .secondary,
                width: 132,
                height: 48,
                fontSize: 16,
                iconSize: 14,
                isHovered: isHovered,
                isEnabled: isEnabled
            ),
            action: action
        ) { isHovered in
            self.setHoveredFooterButton(isHovered ? kind : nil)
        }
        .accessibilityLabel(title)
    }

    private func setHoveredFooterButton(_ button: OnboardingFooterButton?) {
        guard self.hoveredFooterButton != button else { return }
        if self.reduceMotion {
            self.hoveredFooterButton = button
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                self.hoveredFooterButton = button
            }
        }
    }

    private func setHoveredLanguage(_ languageID: String?) {
        guard self.hoveredLanguageID != languageID else { return }
        if self.reduceMotion {
            self.hoveredLanguageID = languageID
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                self.hoveredLanguageID = languageID
            }
        }
    }

    private func toggleAllLanguagesPicker() {
        if self.isShowingAllLanguages {
            self.isShowingAllLanguages = false
            self.isLanguageSearchFocused = false
            self.languageSearchText = ""
        } else {
            self.isShowingAllLanguages = true
            self.isLanguageSearchFocused = true
        }
    }

    private func selectOnboardingLanguage(_ language: VoiceEngineLanguage) {
        guard self.selectedLanguageID != language.id else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            self.selectedLanguageID = language.id
            self.settings.onboardingSelectedLanguageID = language.id
            self.selectedModelRouteID = VoiceEngineLanguageCatalog.routes(for: language).first?.id
            self.isShowingOtherModelRoutes = false
            self.isLanguageSearchFocused = false
            if language.isPopular {
                self.isShowingAllLanguages = false
                self.languageSearchText = ""
            }
            self.resetTryoutValidationForSetupChange()
        }
    }

    private func syncOnboardingSelectionFromSettings() {
        let allRoutes = VoiceEngineLanguageCatalog.allLanguages()
            .flatMap { VoiceEngineLanguageCatalog.routes(for: $0) }

        let storedLanguageID = self.settings.onboardingSelectedLanguageID
        let storedLanguageRoutes = VoiceEngineLanguageCatalog.routes(forLanguageID: storedLanguageID)
        let route = storedLanguageRoutes.first { route in
            self.isRouteModelAndLanguageSettingsSelected(route)
        } ?? storedLanguageRoutes.first ?? allRoutes.first { route in
            self.isRouteModelAndLanguageSettingsSelected(route)
        }

        guard let route else {
            if self.selectedModelRouteID == nil {
                self.selectedModelRouteID = self.selectedLanguageRoutes.first?.id
            }
            return
        }

        guard self.selectedLanguageID != route.language.id || self.selectedModelRouteID != route.id else {
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            self.selectedLanguageID = route.language.id
            self.selectedModelRouteID = route.id
            self.isShowingOtherModelRoutes = false
            self.languageSearchText = ""
            self.isLanguageSearchFocused = false
        }
    }

    private var voiceModelStep: some View {
        GeometryReader { proxy in
            ZStack {
                FluidOnboardingLandingBackdrop(glowCenter: self.landingGlowCenter)

                VStack(spacing: 0) {
                    FluidOnboardingCompactProgress(value: self.compactProgressValue)
                        .padding(.top, 28)

                    ScrollView(.vertical, showsIndicators: self.isShowingOtherModelRoutes) {
                        VStack(spacing: 0) {
                            FluidOnboardingCompactAppIconMark(size: 66)
                                .padding(.bottom, 22)

                            Text("Choose your\nvoice engine")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 16)

                            Text(self.recommendedModelReasonText)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.62))
                                .multilineTextAlignment(.center)
                                .padding(.bottom, 14)

                            Text(self.selectedOnboardingLanguage.displayName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(FluidOnboardingLandingColors.blue)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(FluidOnboardingLandingColors.blue.opacity(0.12))
                                        .overlay(Capsule().stroke(FluidOnboardingLandingColors.blue.opacity(0.24), lineWidth: 1))
                                )
                                .padding(.bottom, 18)

                            VStack(spacing: 10) {
                                let defaultRoutes = self.defaultDisplayedModelRoutes
                                if defaultRoutes.count == 1, let route = defaultRoutes.first {
                                    self.onboardingRouteCard(for: route)
                                } else if !defaultRoutes.isEmpty {
                                    HStack(spacing: 16) {
                                        ForEach(defaultRoutes) { route in
                                            self.onboardingRouteCard(for: route)
                                        }
                                    }
                                }

                                if !self.otherModelRoutes.isEmpty {
                                    self.otherModelRoutesToggleButton
                                }

                                if self.isShowingOtherModelRoutes {
                                    LazyVGrid(
                                        columns: [
                                            GridItem(.fixed(292), spacing: 16, alignment: .top),
                                            GridItem(.fixed(292), spacing: 16, alignment: .top),
                                        ],
                                        spacing: 16
                                    ) {
                                        ForEach(self.otherModelRoutes) { route in
                                            self.onboardingRouteCard(for: route, enablesHover: false)
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                            .transaction { transaction in
                                transaction.animation = nil
                            }
                            .frame(width: 608)

                            Text("You can switch models later in Voice Engine settings.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.44))
                                .padding(.top, 18)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                        .padding(.bottom, 12)
                    }

                    self.cinematicFooter(
                        continueTitle: "Continue",
                        canContinue: self.canContinue
                    ) {
                        self.handlePrimaryAction()
                    }
                }

                FluidOnboardingLandingHoverTracker(
                    onMove: { location, size in
                        self.updateLandingGlow(location: location, in: size)
                    },
                    onExit: {
                        self.resetLandingGlow()
                    }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .accessibilityHidden(true)
            }
        }
    }

    private var permissionsStep: some View {
        GeometryReader { proxy in
            ZStack {
                FluidOnboardingLandingBackdrop(glowCenter: self.landingGlowCenter)

                VStack(spacing: 0) {
                    FluidOnboardingCompactProgress(value: self.compactProgressValue)
                        .padding(.top, 28)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            FluidOnboardingCompactAppIconMark(size: 66)
                                .padding(.bottom, 22)

                            Text("Let FluidVoice\nlisten and type")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineSpacing(4)
                                .padding(.bottom, 16)

                            Text("Two quick permissions make dictation work anywhere.")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.62))
                                .padding(.bottom, 28)

                            VStack(spacing: 14) {
                                self.permissionRow(
                                    stepNumber: 1,
                                    title: self.isMicrophoneReady ? "Microphone is ready" : "Allow microphone",
                                    subtitle: self.isMicrophoneReady
                                        ? "FluidVoice can hear your dictation."
                                        : "macOS will ask once. Click Allow to start dictating.",
                                    systemImage: "mic.fill",
                                    isReady: self.isMicrophoneReady,
                                    actionTitle: self.microphoneActionButtonTitle
                                ) {
                                    self.handleMicrophoneAction()
                                }

                                self.permissionRow(
                                    stepNumber: 2,
                                    title: self.accessibilityPermissionTitle,
                                    subtitle: self.accessibilityPermissionSubtitle,
                                    systemImage: "keyboard.fill",
                                    isReady: self.isAccessibilityReady,
                                    statusTitle: self.accessibilityPermissionStatusTitle,
                                    actionTitle: self.accessibilityPermissionActionTitle
                                ) {
                                    self.openAccessibilitySettings()
                                }

                                if !self.isAccessibilityReady {
                                    Text("Already enabled it? FluidVoice will update when macOS confirms access.")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.white.opacity(0.42))
                                        .padding(.top, 2)
                                }
                            }
                            .frame(width: 560)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 34)
                        .padding(.bottom, 12)
                    }

                    self.cinematicFooter(
                        continueTitle: "Continue",
                        canContinue: self.canContinue
                    ) {
                        self.handlePrimaryAction()
                    }
                }

                FluidOnboardingLandingHoverTracker(
                    onMove: { location, size in
                        self.updateLandingGlow(location: location, in: size)
                    },
                    onExit: {
                        self.resetLandingGlow()
                    }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .accessibilityHidden(true)
            }
        }
    }

    private var aiEnhancementStep: some View {
        OnboardingAIEnhancementStepView(
            finalText: Binding(
                get: { self.asr.finalText },
                set: { self.asr.finalText = $0 }
            ),
            progressValue: self.compactProgressValue,
            glowCenter: self.landingGlowCenter,
            language: self.selectedOnboardingLanguage,
            shortcutDisplay: self.onboardingShortcutDisplay,
            isTestReady: self.isPlaygroundReady,
            isRunning: self.asr.isRunning,
            isRecordingShortcut: self.isRecordingPrimaryShortcut,
            shortcutRecordingMessage: self.isRecordingPrimaryShortcut ? self.shortcutRecordingMessage : nil,
            onGlowMove: self.updateLandingGlow(location:in:),
            onGlowExit: self.resetLandingGlow,
            onBack: self.goBack,
            onSkip: {
                self.markAISkipped()
                self.finishOnboardingAtGettingStarted()
            },
            onUseAIProvider: self.openAIEnhancementSettingsFromOnboarding,
            onFinishSetup: self.finishOnboardingAtGettingStarted
        )
    }

    private var playgroundStep: some View {
        GeometryReader { proxy in
            ZStack {
                FluidOnboardingLandingBackdrop(glowCenter: self.landingGlowCenter)

                VStack(spacing: 0) {
                    FluidOnboardingCompactProgress(value: self.compactProgressValue)
                        .padding(.top, 28)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            FluidOnboardingCompactAppIconMark(size: 66)
                                .padding(.bottom, 22)

                            Text("FluidVoice is ready.")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.74)
                                .padding(.horizontal, 32)
                                .padding(.bottom, 14)

                            Text("Now let's try it out.")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.62))
                                .padding(.bottom, 28)

                            OnboardingTryoutStepView(
                                finalText: Binding(
                                    get: { self.asr.finalText },
                                    set: { self.asr.finalText = $0 }
                                ),
                                language: self.selectedOnboardingLanguage,
                                shortcutDisplay: self.onboardingShortcutDisplay,
                                isReady: self.isPlaygroundReady,
                                isRunning: self.asr.isRunning,
                                isRecordingShortcut: self.isRecordingPrimaryShortcut,
                                shortcutRecordingMessage: self.isRecordingPrimaryShortcut ? self.shortcutRecordingMessage : nil,
                                onToggleShortcut: self.togglePrimaryShortcutRecording
                            )
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 34)
                        .padding(.bottom, 12)
                    }

                    self.cinematicFooter(
                        continueTitle: "Continue",
                        canContinue: self.canContinue,
                        continueAction: {
                            self.handlePrimaryAction()
                        },
                        skipTitle: "Skip",
                        canSkip: !self.asr.isRunning && !self.isRecordingAnyShortcut,
                        skipAction: {
                            self.settings.onboardingPlaygroundSkipped = true
                            self.goNext()
                        }
                    )
                }
                .frame(width: proxy.size.width, height: proxy.size.height)

                FluidOnboardingLandingHoverTracker(
                    onMove: { location, size in
                        self.updateLandingGlow(location: location, in: size)
                    },
                    onExit: {
                        self.resetLandingGlow()
                    }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .accessibilityHidden(true)
            }
        }
    }

    private var microphoneActionButtonTitle: String {
        switch self.asr.micStatus {
        case .notDetermined:
            return "Allow"
        case .denied, .restricted:
            return "Open Settings"
        default:
            return "Allow"
        }
    }

    private var accessibilityPermissionTitle: String {
        if self.isAccessibilityReady {
            return "Typing access is ready"
        }
        return self.accessibilitySetupInProgress ? "Finish Accessibility Access" : "Enable Accessibility Access"
    }

    private var accessibilityPermissionSubtitle: String {
        if self.isAccessibilityReady {
            return "\(self.appDisplayName) can place text into the app you're using."
        }
        if self.accessibilitySetupInProgress {
            return "Use the floating guide to drag \(self.appDisplayName) into the Accessibility apps list."
        }
        return "Open Settings, then use the floating guide to add \(self.appDisplayName)."
    }

    private var appDisplayName: String {
        Bundle.main.fluidAppDisplayName
    }

    private var accessibilityPermissionStatusTitle: String {
        if self.isAccessibilityReady {
            return "Ready"
        }
        return self.accessibilitySetupInProgress ? "In Settings" : "Needed"
    }

    private var accessibilityPermissionActionTitle: String {
        self.accessibilitySetupInProgress ? "Show Guide" : "Open Settings"
    }

    private var otherModelRoutesToggleButton: some View {
        Button {
            self.toggleOtherModelRoutes()
        } label: {
            HStack(spacing: 6) {
                Text(self.isShowingOtherModelRoutes ? "Hide other models" : "Show other models")

                Image(systemName: self.isShowingOtherModelRoutes ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.62))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.025))
                    .overlay(Capsule().stroke(Color.white.opacity(0.07), lineWidth: 1))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(self.isShowingOtherModelRoutes ? "Hide other models" : "Show other models")
    }

    private func toggleOtherModelRoutes() {
        self.isShowingOtherModelRoutes.toggle()
    }

    private func isOnboardingModelSelected(_ model: SettingsStore.SpeechModel) -> Bool {
        self.settings.selectedSpeechModel == model
    }

    private func isOnboardingModelReady(_ model: SettingsStore.SpeechModel) -> Bool {
        self.isOnboardingModelSelected(model) && self.asr.isAsrReady
    }

    private func isOnboardingRouteReady(_ route: VoiceEngineLanguageRoute) -> Bool {
        self.isRouteSelectedInSettings(route) && self.asr.isAsrReady
    }

    private func isOnboardingModelDownloaded(_ model: SettingsStore.SpeechModel) -> Bool {
        self.isOnboardingModelBundledOrInstalled(model) || (self.isOnboardingModelSelected(model) && (self.asr.isAsrReady || self.asr.modelsExistOnDisk))
    }

    private func isOnboardingModelBundledOrInstalled(_ model: SettingsStore.SpeechModel) -> Bool {
        model.isInstalled
    }

    private func isPreparingOnboardingModel(_ model: SettingsStore.SpeechModel) -> Bool {
        self.isOnboardingModelSelected(model) && (self.asr.isDownloadingModel || (self.asr.isLoadingModel && !self.asr.isAsrReady))
    }

    private func onboardingModelActionButtonTitle(isPreparing: Bool, isDownloaded: Bool, isReady: Bool) -> String {
        if isPreparing {
            return self.asr.isLoadingModel ? "Loading..." : "Downloading..."
        }
        if isReady {
            return "Active now"
        }
        if isDownloaded {
            return "Activate"
        }
        return "Download & Activate"
    }

    private func prepareOnboardingRoute(_ route: VoiceEngineLanguageRoute) {
        guard !self.asr.isRunning, !self.isModelPreparationInProgress, self.uninstallingModelRouteID == nil else { return }

        self.preparingModelRouteID = route.id
        self.selectOnboardingRoute(route)

        Task { @MainActor in
            defer {
                self.preparingModelRouteID = nil
            }

            do {
                try await self.asr.ensureAsrReady()
            } catch {
                DebugLogger.shared.error("Failed to prepare onboarding voice model \(route.model.displayName): \(error)", source: "OnboardingFlowView")
                // Surface the failure in the UI instead of only logging it, so the user
                // isn't stuck at a disabled button. The shared ContentView alert (bound to
                // asr.showError) presents this during onboarding. See #355.
                self.asr.errorTitle = "Voice Model Setup Failed"
                self.asr.errorMessage = error.localizedDescription
                self.asr.showError = true
            }
            await self.asr.checkIfModelsExistAsync()
        }
    }

    private func uninstallOnboardingRoute(_ route: VoiceEngineLanguageRoute) {
        guard !self.asr.isRunning, !self.isModelPreparationInProgress, self.uninstallingModelRouteID == nil else { return }

        self.uninstallingModelRouteID = route.id

        Task { @MainActor in
            defer {
                self.uninstallingModelRouteID = nil
            }

            do {
                try await self.asr.clearModelCache(for: route.model)
                await self.asr.checkIfModelsExistAsync()
            } catch {
                DebugLogger.shared.error("Failed to delete onboarding voice model \(route.model.displayName): \(error)", source: "OnboardingFlowView")
                self.asr.errorTitle = "Model Delete Failed"
                self.asr.errorMessage = error.localizedDescription
                self.asr.showError = true
            }
        }
    }

    private func onboardingRouteCard(
        for route: VoiceEngineLanguageRoute,
        enablesHover: Bool = true
    ) -> some View {
        let model = route.model
        let isSelected = self.isOnboardingRouteSelected(route)
        let isHovered = enablesHover && self.hoveredModelRouteID == route.id
        let isRouteActiveInSettings = self.isRouteSelectedInSettings(route)
        let isDownloaded = self.isOnboardingModelBundledOrInstalled(model) || (isRouteActiveInSettings && (self.asr.isAsrReady || self.asr.modelsExistOnDisk))
        let isPreparing = self.preparingModelRouteID == route.id || (isRouteActiveInSettings && (self.asr.isDownloadingModel || (self.asr.isLoadingModel && !self.asr.isAsrReady)))
        let isReady = self.isOnboardingRouteReady(route)
        let isUninstalling = self.uninstallingModelRouteID == route.id
        let areModelActionsBlocked = self.asr.isRunning || self.uninstallingModelRouteID != nil || self.preparingModelRouteID != nil || isPreparing || self.isModelPreparationInProgress
        let isBuiltInAppleModel = model == .appleSpeech || model == .appleSpeechAnalyzer
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let cardFill = isHovered
            ? Color(red: 0.042, green: 0.052, blue: 0.074)
            : Color(red: 0.030, green: 0.038, blue: 0.056)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text(self.onboardingModelTitle(for: model))
                    .font(self.theme.typography.sectionTitle)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Image(systemName: "info.circle")
                    .font(self.theme.typography.sectionTitle)
                    .foregroundStyle(Color.white.opacity(0.58))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
                    .help(self.onboardingModelTooltip(for: route))
                    .accessibilityLabel(self.onboardingModelTooltip(for: route))
            }
            .frame(height: 38, alignment: .top)

            self.onboardingModelMetadataRow(badgeText: route.badgeText)

            self.onboardingModelFeaturePanel(for: model)

            Spacer(minLength: 0)

            Divider()
                .overlay(Color.white.opacity(0.10))

            HStack(spacing: 10) {
                Image(systemName: "internaldrive")
                    .font(self.theme.typography.sectionTitle)
                    .foregroundStyle(Color.white.opacity(0.62))
                    .frame(width: 22)

                Text("Download size")
                    .font(self.theme.typography.bodySmallStrong)
                    .foregroundStyle(Color.white.opacity(0.62))

                Spacer()

                Text(model.downloadSize)
                    .font(self.theme.typography.bodySmallStrong)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.80)
            }

            if isPreparing || isUninstalling {
                VStack(alignment: .leading, spacing: 7) {
                    if self.asr.isDownloadingModel, let progress = self.asr.downloadProgress {
                        ProgressView(value: progress)
                            .tint(FluidOnboardingLandingColors.blue)

                        HStack(spacing: 6) {
                            ZStack {
                                if progress >= 0.82 {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .fixedSize()
                                }
                            }
                            .frame(width: 14, height: 14)
                            .opacity(progress >= 0.82 ? 1 : 0)

                            Text("Downloading \(Int(progress * 100))%")
                                .font(self.theme.typography.captionStrong)
                                .foregroundStyle(Color.white.opacity(0.56))
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                                .fixedSize()

                            Text(isUninstalling ? "Deleting..." : "Loading model...")
                                .font(self.theme.typography.captionStrong)
                                .foregroundStyle(Color.white.opacity(0.62))
                        }
                    }
                }
                .frame(height: 42, alignment: .center)
            } else if isDownloaded, isBuiltInAppleModel {
                self.onboardingModelActionButton(
                    id: "\(route.id)-activate",
                    title: self.onboardingModelActionButtonTitle(isPreparing: false, isDownloaded: true, isReady: isReady),
                    systemImage: isReady ? "checkmark" : "bolt.fill",
                    tone: .primary,
                    width: nil,
                    isDisabled: areModelActionsBlocked || isReady
                ) {
                    self.prepareOnboardingRoute(route)
                }
            } else if isDownloaded {
                HStack(spacing: 8) {
                    self.onboardingModelActionButton(
                        id: "\(route.id)-activate",
                        title: self.onboardingModelActionButtonTitle(isPreparing: false, isDownloaded: true, isReady: isReady),
                        systemImage: isReady ? "checkmark" : "bolt.fill",
                        tone: .primary,
                        width: 124,
                        isDisabled: areModelActionsBlocked || isReady
                    ) {
                        self.prepareOnboardingRoute(route)
                    }

                    self.onboardingModelActionButton(
                        id: "\(route.id)-uninstall",
                        title: "Delete",
                        systemImage: "trash",
                        tone: .destructive,
                        width: 124,
                        isDisabled: areModelActionsBlocked
                    ) {
                        self.uninstallOnboardingRoute(route)
                    }
                }
            } else {
                self.onboardingModelActionButton(
                    id: "\(route.id)-download-activate",
                    title: self.onboardingModelActionButtonTitle(isPreparing: false, isDownloaded: false, isReady: false),
                    systemImage: "arrow.down.circle.fill",
                    tone: .primary,
                    width: nil,
                    isDisabled: areModelActionsBlocked
                ) {
                    self.prepareOnboardingRoute(route)
                }
            }
        }
        .padding(16)
        .frame(width: 292, height: 292, alignment: .topLeading)
        .background(
            shape
                .fill(cardFill)
                .overlay(
                    shape.stroke(
                        isSelected
                            ? FluidOnboardingLandingColors.blue.opacity(isHovered ? 0.92 : 0.78)
                            : (isHovered ? Color.white.opacity(0.20) : Color.white.opacity(0.10)),
                        lineWidth: isSelected ? 1.4 : 1
                    )
                )
        )
        .shadow(color: Color.black.opacity(0.34), radius: isHovered ? 20 : 14, x: 0, y: isHovered ? 12 : 8)
        .contentShape(shape)
        .onTapGesture {
            guard !areModelActionsBlocked else { return }
            self.selectOnboardingRoute(route)
        }
        .onHover { isHovered in
            guard enablesHover else { return }
            self.setHoveredModelRoute(isHovered ? route.id : nil)
        }
    }

    private func onboardingModelFeaturePanel(for model: SettingsStore.SpeechModel) -> some View {
        VStack(spacing: 10) {
            self.onboardingModelMetricRow(
                fillPercent: model.speedPercent,
                color: .yellow,
                secondaryColor: .orange,
                icon: "bolt.fill",
                label: "Speed"
            )

            self.onboardingModelMetricRow(
                fillPercent: model.accuracyPercent,
                color: Color.fluidGreen,
                secondaryColor: .cyan,
                icon: "target",
                label: "Accuracy"
            )
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Speed \(Int(model.speedPercent * 100)) percent. Accuracy \(Int(model.accuracyPercent * 100)) percent.")
    }

    private func onboardingModelMetadataRow(badgeText: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let badgeText {
                Label(badgeText, systemImage: "checkmark.seal.fill")
                    .font(self.theme.typography.badge)
                    .foregroundStyle(Color.green.opacity(0.92))
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
        .frame(height: badgeText == nil ? 0 : 18, alignment: .leading)
    }

    private func onboardingModelMetricRow(
        fillPercent: Double,
        color: Color,
        secondaryColor: Color,
        icon: String,
        label: String
    ) -> some View {
        let clampedFill = min(max(fillPercent, 0), 1)

        return HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(color)

                Text(label)
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(Color.white.opacity(0.66))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(width: 86, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.075))

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [color, secondaryColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, proxy.size.width * CGFloat(clampedFill)))
                        .overlay(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.24),
                                            Color.clear,
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        )
                }
            }
            .frame(height: 9)

            Text("\(Int(fillPercent * 100))%")
                .font(self.theme.typography.bodySmallStrong)
                .foregroundStyle(fillPercent > 0 ? color : Color.white.opacity(0.48))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .contentTransition(.numericText())
                .frame(width: 46, alignment: .trailing)
        }
        .frame(height: 18)
    }

    private func onboardingModelActionButton(
        id: String,
        title: String,
        systemImage: String,
        tone: OnboardingPillButtonTone = .primary,
        width: CGFloat?,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = self.hoveredModelActionButtonID == id && !isDisabled

        return self.onboardingPillButton(
            configuration: OnboardingPillButtonConfiguration(
                title: title,
                systemImage: systemImage,
                tone: tone,
                width: width,
                height: 36,
                fontSize: 12,
                iconSize: 14,
                isHovered: isHovered,
                isEnabled: !isDisabled
            ),
            action: action
        ) { isHovered in
            self.setHoveredModelActionButton(isHovered ? id : nil)
        }
    }

    private func onboardingPillButton(
        configuration: OnboardingPillButtonConfiguration,
        action: @escaping () -> Void,
        onHover: @escaping (Bool) -> Void
    ) -> some View {
        let shape = Capsule()
        let accentColor: Color = configuration.tone == .destructive ? .red : FluidOnboardingLandingColors.blue
        let isFilledTone = configuration.tone == .primary || configuration.tone == .destructive
        let fillColor: Color = {
            switch configuration.tone {
            case .primary, .destructive:
                return accentColor.opacity(configuration.isEnabled ? 1 : 0.34)
            case .secondary:
                return Color.white.opacity(configuration.isEnabled ? (configuration.isHovered ? 0.11 : 0.07) : 0.045)
            }
        }()
        let borderColor: Color = {
            switch configuration.tone {
            case .primary, .destructive:
                return Color.white.opacity(configuration.isHovered && configuration.isEnabled ? 0.30 : 0)
            case .secondary:
                return configuration.isHovered && configuration.isEnabled ? FluidOnboardingLandingColors.blue.opacity(0.30) : Color.white.opacity(0.07)
            }
        }()
        let foregroundOpacity: Double = configuration.isEnabled ? (isFilledTone ? 1.0 : (configuration.isHovered ? 0.94 : 0.78)) : 0.42
        let shadowOpacity: Double = {
            guard configuration.isEnabled else { return 0 }
            switch configuration.tone {
            case .primary, .destructive:
                return configuration.isHovered ? 0.56 : 0.26
            case .secondary:
                return configuration.isHovered ? 0.08 : 0
            }
        }()
        let ringOpacity: Double = configuration.isHovered && configuration.isEnabled ? 0.50 : 0

        return Button {
            action()
        } label: {
            HStack(spacing: configuration.systemImage == nil ? 0 : 8) {
                if let systemImage = configuration.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: configuration.iconSize, weight: .bold))
                }

                Text(configuration.title)
                    .font(.system(size: configuration.fontSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(.white.opacity(foregroundOpacity))
            .frame(width: configuration.width, height: configuration.height)
            .frame(maxWidth: configuration.width == nil ? .infinity : nil)
            .background(
                shape
                    .fill(fillColor)
                    .overlay(shape.fill(Color.white.opacity(isFilledTone && configuration.isHovered && configuration.isEnabled ? 0.10 : 0)))
                    .overlay(shape.stroke(borderColor, lineWidth: configuration.isHovered && configuration.isEnabled ? 1.2 : 1))
                    .overlay(
                        shape
                            .stroke(accentColor.opacity(ringOpacity), lineWidth: configuration.isHovered && configuration.isEnabled ? 1.4 : 1)
                            .padding(-2)
                    )
                    .shadow(color: accentColor.opacity(shadowOpacity), radius: configuration.isHovered && configuration.isEnabled ? 16 : 9, x: 0, y: configuration.isHovered && configuration.isEnabled ? 6 : 3)
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .contentShape(shape)
        .disabled(!configuration.isEnabled)
        .onHover { isHovered in
            onHover(isHovered && configuration.isEnabled)
        }
    }

    private func onboardingModelTooltip(for route: VoiceEngineLanguageRoute) -> String {
        let model = route.model
        return "\(self.onboardingModelSubtitle(for: model)) - \(model.downloadSize)\n\(model.cardDescription)"
    }

    private func onboardingModelTitle(for model: SettingsStore.SpeechModel) -> String {
        model.humanReadableName
    }

    private func onboardingModelSubtitle(for model: SettingsStore.SpeechModel) -> String {
        switch model {
        case .parakeetTDT:
            return "Parakeet v3"
        case .parakeetTDTv2:
            return "Parakeet v2"
        case .parakeetRealtime:
            return "Parakeet Flash"
        case .cohereTranscribeSixBit:
            return "Cohere"
        case .nemotronStreaming:
            return "Nemotron Streaming"
        case .nemotronOffline:
            return "Nemotron Offline"
        case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLarge:
            return "Whisper"
        default:
            return model.displayName
        }
    }

    private func permissionRow(
        stepNumber: Int,
        title: String,
        subtitle: String,
        systemImage: String,
        isReady: Bool,
        statusTitle: String? = nil,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let resolvedStatusTitle = statusTitle ?? (isReady ? "Ready" : "Needed")

        return HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(isReady ? Color.green.opacity(0.16) : FluidOnboardingLandingColors.blue.opacity(0.12))
                    .frame(width: 46, height: 46)

                if isReady {
                    Image(systemName: "checkmark")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.green.opacity(0.92))
                } else {
                    VStack(spacing: 1) {
                        Image(systemName: systemImage)
                            .font(.system(size: 14, weight: .bold))

                        Text("\(stepNumber)")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(FluidOnboardingLandingColors.blue)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(resolvedStatusTitle)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isReady ? Color.green.opacity(0.92) : FluidOnboardingLandingColors.blue)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill((isReady ? Color.green : FluidOnboardingLandingColors.blue).opacity(0.12))
                        )
                }

                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(2)
            }

            Spacer()

            if !isReady {
                let actionIcon = ["Open Settings", "Show Guide"].contains(actionTitle) ? "arrow.up.right" : "hand.tap.fill"
                let buttonID = "permission-\(stepNumber)"

                self.onboardingPillButton(
                    configuration: OnboardingPillButtonConfiguration(
                        title: actionTitle,
                        systemImage: actionIcon,
                        tone: .primary,
                        width: 132,
                        height: 36,
                        fontSize: 12,
                        iconSize: 10,
                        isHovered: self.hoveredPermissionButtonID == buttonID,
                        isEnabled: true
                    ),
                    action: action
                ) { isHovered in
                    self.setHoveredPermissionButton(isHovered ? buttonID : nil)
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 88)
        .background(
            shape
                .fill(Color.white.opacity(isReady ? 0.045 : 0.070))
                .overlay(
                    shape.stroke(
                        isReady ? Color.green.opacity(0.18) : FluidOnboardingLandingColors.blue.opacity(0.26),
                        lineWidth: 1
                    )
                )
        )
    }

    private func isOnboardingRouteSelected(_ route: VoiceEngineLanguageRoute) -> Bool {
        self.selectedOnboardingRoute?.id == route.id || self.isRouteSelectedInSettings(route)
    }

    private func isRouteSelectedInSettings(_ route: VoiceEngineLanguageRoute) -> Bool {
        guard route.model == self.settings.selectedSpeechModel else {
            return false
        }

        switch route.binding {
        case .automatic, .whisper:
            return self.settings.onboardingSelectedLanguageID == route.language.id
        case let .appleSpeech(localeIdentifier):
            return self.settings.selectedAppleSpeechLocaleIdentifier == localeIdentifier
        case let .cohere(language):
            return self.settings.selectedCohereLanguage == language
        case let .nemotron(language):
            return self.settings.selectedNemotronLanguage == language
        }
    }

    private func isRouteModelAndLanguageSettingsSelected(_ route: VoiceEngineLanguageRoute) -> Bool {
        guard route.model == self.settings.selectedSpeechModel else {
            return false
        }

        switch route.binding {
        case .automatic, .whisper:
            return true
        case let .appleSpeech(localeIdentifier):
            return self.settings.selectedAppleSpeechLocaleIdentifier == localeIdentifier
        case let .cohere(language):
            return self.settings.selectedCohereLanguage == language
        case let .nemotron(language):
            return self.settings.selectedNemotronLanguage == language
        }
    }

    private func selectOnboardingRoute(_ route: VoiceEngineLanguageRoute) {
        let oldModel = self.settings.selectedSpeechModel
        let oldAppleSpeechLocaleIdentifier = self.settings.selectedAppleSpeechLocaleIdentifier
        let oldCohereLanguage = self.settings.selectedCohereLanguage
        let oldNemotronLanguage = self.settings.selectedNemotronLanguage

        self.selectedModelRouteID = route.id
        VoiceEngineLanguageCatalog.apply(route, to: self.settings)

        let languageChanged: Bool
        switch route.binding {
        case .automatic, .whisper:
            languageChanged = false
        case .appleSpeech:
            languageChanged = oldAppleSpeechLocaleIdentifier != self.settings.selectedAppleSpeechLocaleIdentifier
        case .cohere:
            languageChanged = oldCohereLanguage != self.settings.selectedCohereLanguage
        case .nemotron:
            languageChanged = oldNemotronLanguage != self.settings.selectedNemotronLanguage
        }

        if oldModel != self.settings.selectedSpeechModel || languageChanged {
            self.resetTryoutValidationForSetupChange()
            self.asr.resetTranscriptionProvider()
        }
    }

    private func setHoveredModelRoute(_ routeID: String?) {
        guard self.hoveredModelRouteID != routeID else { return }
        if self.reduceMotion {
            self.hoveredModelRouteID = routeID
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                self.hoveredModelRouteID = routeID
            }
        }
    }

    private func setHoveredModelActionButton(_ buttonID: String?) {
        guard self.hoveredModelActionButtonID != buttonID else { return }
        if self.reduceMotion {
            self.hoveredModelActionButtonID = buttonID
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                self.hoveredModelActionButtonID = buttonID
            }
        }
    }

    private func setHoveredPermissionButton(_ buttonID: String?) {
        guard self.hoveredPermissionButtonID != buttonID else { return }
        if self.reduceMotion {
            self.hoveredPermissionButtonID = buttonID
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                self.hoveredPermissionButtonID = buttonID
            }
        }
    }

    private func togglePrimaryShortcutRecording() {
        guard !self.asr.isRunning else { return }
        if self.isRecordingPrimaryShortcut {
            self.activeShortcutRecordingTarget = nil
            self.shortcutRecordingMessage = nil
        } else {
            self.shortcutRecordingMessage = nil
            self.activeShortcutRecordingTarget = .primaryDictation(.replace(0))
        }
    }

    private func resetTryoutValidationForSetupChange() {
        self.settings.onboardingPlaygroundValidated = false
        self.settings.onboardingPlaygroundSkipped = false
        self.settings.playgroundUsed = false
        self.asr.finalText = ""
    }

    private func handleMicrophoneAction() {
        if self.asr.micStatus == .notDetermined {
            self.asr.requestMicAccess()
        } else {
            self.asr.openSystemSettingsForMic()
        }
    }

    private func goBack() {
        self.activeShortcutRecordingTarget = nil
        self.shortcutRecordingMessage = nil
        self.currentStep = max(0, self.currentStep - 1)
    }

    private func goNext() {
        self.activeShortcutRecordingTarget = nil
        self.shortcutRecordingMessage = nil
        self.currentStep = min(Step.allCases.count - 1, self.currentStep + 1)
    }

    private func handlePrimaryAction() {
        guard !self.isModelPreparationInProgress else {
            return
        }

        if self.step == .language, let route = self.selectedOnboardingRoute {
            self.selectOnboardingRoute(route)
        }

        if self.step == .aiEnhancement {
            guard self.isAIReady else { return }
            self.finishOnboarding()
            return
        }
        self.goNext()
    }
}
