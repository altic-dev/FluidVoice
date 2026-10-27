import Foundation
import SwiftUI

struct OnboardingAIEnhancementStepView: View {
    @ObservedObject var setup: OnboardingAISetupController
    @Binding var finalText: String
    let progressValue: Double
    let glowCenter: UnitPoint
    let shortcutDisplay: String
    let isRunning: Bool
    let isListening: Bool
    let isRecordingShortcut: Bool
    let onGlowMove: (CGPoint, CGSize) -> Void
    let onGlowExit: () -> Void
    let onBack: () -> Void
    let onSkip: () -> Void
    let onFinishSetup: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject private var settings = SettingsStore.shared
    @StateObject private var carouselAutoplay = OnboardingCarouselAutoplay()
    @State private var hoveredButtonID: String?
    @State private var showPractice = false
    @State private var introductionPlaybackID = UUID()
    @State private var practice = OnboardingPolishPractice()
    @ObservedObject private var contentState = NotchContentState.shared

    private static let overlaySceneOffset: CGFloat = 24

    private static let selectedOverlayImage: NSImage = {
        guard let url = Bundle.main.url(forResource: "OnboardingSmartModeSelected", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return NSImage() }
        return image
    }()

    // Hide only the old title area; the menu begins below 36% of the frame.
    private static let heldFrameMask: [Gradient.Stop] = [
        .init(color: .clear, location: 0),
        .init(color: .clear, location: 0.27),
        .init(color: .white, location: 0.35),
        .init(color: .white, location: 0.88),
        .init(color: .clear, location: 1),
    ]
    private static let horizontalFrameMask: [Gradient.Stop] = [
        .init(color: .clear, location: 0),
        .init(color: .white, location: 0.12),
        .init(color: .white, location: 0.88),
        .init(color: .clear, location: 1),
    ]

    private enum ButtonTone { case primary, secondary, destructive }
    private struct PillButtonConfiguration {
        let id: String
        let title: String
        let systemImage: String?
        let tone: ButtonTone
        let width: CGFloat
        let height: CGFloat
        let fontSize: CGFloat
        let isEnabled: Bool
    }

    private var canNavigate: Bool { !self.isRunning && !self.isRecordingShortcut && !self.contentState.isProcessing && !self.isShowingIntroduction }
    private var isShowingIntroduction: Bool { self.isReady && !self.setup.introductionFinished && !self.reduceMotion }
    private var isReady: Bool { self.setup.phase == .ready }
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                FluidOnboardingLandingBackdrop(glowCenter: self.glowCenter)
                VStack(spacing: 0) {
                    FluidOnboardingCompactProgress(value: self.progressValue)
                        .padding(.top, 28)
                    self.mainContent
                    if !self.isReady {
                        self.offerStatus
                            .padding(.horizontal, 30)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .center, spacing: 20) {
                        self.action(id: "back", title: "Back", tone: .secondary, width: 132) {
                            if self.isReady && self.showPractice {
                                self.showPractice = false
                            } else {
                                self.setup.leavePage()
                                self.onBack()
                            }
                        }
                        .keyboardShortcut(.cancelAction)
                        Spacer()
                        if self.isReady && self.showPractice {
                            Button("Skip practice", action: self.onFinishSetup)
                                .buttonStyle(.plain)
                                .foregroundStyle(.white.opacity(0.58))
                                .disabled(!self.canNavigate)
                            self.action(id: "practice-next", title: self.practice.isLast ? "Finish setup" : "Next example", tone: .primary, width: 180) {
                                guard self.canNavigate, self.practice.result != nil else { return }
                                if self.practice.isLast {
                                    self.onFinishSetup()
                                } else {
                                    self.practice.advance(isBusy: !self.canNavigate)
                                }
                            }
                            .disabled(self.practice.result == nil)
                        } else if self.isReady && !self.isShowingIntroduction {
                            if !self.reduceMotion {
                                self.action(id: "intro-replay", title: "Replay", tone: .secondary, width: 132) {
                                    self.setup.introductionFinished = false
                                    self.introductionPlaybackID = UUID()
                                }
                            }
                            self.action(id: "intro-continue", title: "Continue", tone: .primary, width: 160) {
                                self.setup.introductionFinished = true
                                self.showPractice = true
                            }
                        } else if !self.isReady {
                            self.offerNavigation
                        }
                    }
                    .padding(.horizontal, FluidOnboardingLayout.footerHorizontalInset)
                    .padding(.bottom, FluidOnboardingLayout.footerBottomInset)
                    .padding(.top, 12)
                    .fixedSize(horizontal: false, vertical: true)
                }
                FluidOnboardingLandingHoverTracker(onMove: self.onGlowMove, onExit: self.onGlowExit)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            if !self.isReady {
                OnboardingCarouselInteractionTracker(autoplay: self.carouselAutoplay)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .task { self.setup.refresh() }
        .onDisappear {
            self.setup.leavePage()
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if self.isReady {
            OnboardingFittedContent(width: 844, heightAnimation: self.reduceMotion ? nil : .easeInOut(duration: 0.32)) {
                self.introductionScene
                    .frame(maxWidth: 780)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .padding(.top, 36)
                    .padding(.bottom, 24)
            }
        } else {
            // Fit the showcase into the space left above the fixed status and footer.
            OnboardingFittedContent(width: 880) {
                VStack(spacing: 0) {
                    self.hero.padding(.bottom, 16)
                    OnboardingCleanupExampleCarousel(autoplay: self.carouselAutoplay)
                    Text("You can choose a different model or turn off Fluid Intelligence anytime in Settings.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(.white.opacity(0.46))
                        .multilineTextAlignment(.center)
                        .padding(.top, 12)
                }
                .frame(maxWidth: 880)
                .padding(.horizontal, 32)
                .padding(.top, 16)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            FluidOnboardingCompactAppIconMark(size: 40)
                .padding(.bottom, 4)
            Text("Meet Fluid Intelligence")
                .font(.fluidSystem(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text("Exclusive to FluidVoice. Optimized for your Mac. It turns your spoken words into clear, formatted text. Entirely on your device.")
                .font(.fluidSystem(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.64))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 540)
            if !self.isReady {
                Text("Fluid Intelligence can…")
                    .font(.fluidSystem(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.top, 4)
            }
        }
    }

    private var offerStatus: some View {
        VStack(spacing: 8) {
            if self.setup.phase == .checking, !self.setup.canEnable {
                ProgressView("Finding the right model for your Mac…")
                    .controlSize(.small)
            } else if self.setup.showsPreparationProgress || self.setup.phase == .cancelling {
                self.preparationProgress
                    .transition(.opacity)
            }
            if let error = self.setup.errorMessage {
                Text(error)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.warning)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if self.setup.phase == .unavailable {
                Text("Fluid Intelligence isn't available right now. You can finish setup and try again later.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(.white.opacity(0.64))
                    .multilineTextAlignment(.center)
                Button("Try again") { self.setup.refresh() }
                    .buttonStyle(.plain)
                    .foregroundStyle(FluidOnboardingLandingColors.blue)
            }
        }
        .animation(self.reduceMotion ? nil : .easeInOut(duration: 0.32), value: self.setup.isBusy)
    }

    private var offerNavigation: some View {
        HStack(spacing: 20) {
            if !self.setup.showsPreparationProgress {
                Button("I’ll set it up later") {
                    self.setup.setUpLater()
                    self.onSkip()
                }
                .buttonStyle(.plain)
                .font(.fluidSystem(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(self.canNavigate ? 0.86 : 0.4))
                .disabled(!self.canNavigate)
            }

            if self.setup.canEnable {
                self.action(id: "enable", title: "Enable", tone: .primary, width: 210) {
                    self.setup.enable { model in
                        guard self.canNavigate else {
                            throw SetupError(message: "Stop dictation, then enable Smart mode again.")
                        }
                        guard let registered = PrivateAIModelRegistry.model(id: model.id) else {
                            throw PrivateAIUnavailableError()
                        }
                        self.persistPrivateAIVerification(registered)
                        self.finalText = ""
                    }
                }
                .keyboardShortcut(.defaultAction)
                .transition(.opacity)
            } else {
                Color.clear.frame(width: 210, height: 48)
                    .accessibilityHidden(true)
            }
        }
        .animation(self.reduceMotion ? nil : .easeInOut(duration: 0.2), value: self.setup.phase == .offered)
    }

    private var preparationProgress: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                if self.setup.phase == .downloading {
                    HStack(spacing: 12) {
                        if let fraction = self.setup.progress?.fraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        if let bytes = self.setup.progress?.bytes {
                            Text(bytes.replacingOccurrences(of: " downloaded", with: " ready").replacingOccurrences(of: " download", with: ""))
                                .font(self.theme.typography.caption)
                                .foregroundStyle(.white.opacity(0.62))
                                .monospacedDigit()
                                .fixedSize()
                        }
                    }
                    Text(self.downloadProgressTitle)
                        .font(self.theme.typography.caption)
                        .foregroundStyle(.white.opacity(0.58))
                        .monospacedDigit()
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(self.preparationStatus)
                            .font(self.theme.typography.captionStrong)
                            .foregroundStyle(.white.opacity(0.62))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if self.setup.phase != .cancelling {
                Button { self.setup.cancel() } label: {
                    Label("Cancel", systemImage: "xmark")
                        .font(self.theme.typography.bodySmallStrong)
                        .frame(minWidth: 80, minHeight: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(red: 1, green: 0.48, blue: 0.48))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.red.opacity(0.18), lineWidth: 1))
            }
        }
        .tint(FluidOnboardingLandingColors.blue)
        .frame(height: 44)
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.09), lineWidth: 1))
        .frame(maxWidth: 600)
    }

    private var downloadProgressTitle: String {
        guard let fraction = self.setup.progress?.fraction, fraction.isFinite else { return "Preparing…" }
        let percent = min(max(fraction, 0), 1).formatted(.percent.precision(.fractionLength(0)))
        return "Preparing \(percent)"
    }

    private var preparationStatus: String {
        switch self.setup.phase {
        case .loading: "Preparing the model for your Mac. This can take a little while."
        case .cancelling: "Cancelling setup… You can go back or set this up later."
        default: "Preparing Fluid Intelligence…"
        }
    }

    private var introductionScene: some View {
        ZStack(alignment: .top) {
            if self.reduceMotion || self.setup.introductionFinished {
                Color.clear.aspectRatio(1560.0 / 1096.0, contentMode: .fit)
            } else {
                OnboardingOverlayIntroductionView { self.setup.introductionFinished = true }
                    .id(self.introductionPlaybackID)
                    .offset(y: Self.overlaySceneOffset)
                    .allowsHitTesting(false)
            }
            if !self.isShowingIntroduction && !self.showPractice {
                // The still is a 1560 × 1096 video frame. Use exactly the player's
                // aspect-fit canvas and shared offset; never crop or independently size it.
                Image(nsImage: Self.selectedOverlayImage)
                    .resizable()
                    .aspectRatio(1560.0 / 1096.0, contentMode: .fit)
                    .mask {
                        LinearGradient(stops: Self.heldFrameMask, startPoint: .top, endPoint: .bottom)
                            .mask {
                                LinearGradient(stops: Self.horizontalFrameMask, startPoint: .leading, endPoint: .trailing)
                            }
                    }
                    .offset(y: Self.overlaySceneOffset)
                    .accessibilityLabel("The same tilted overlay frame from the video, with Smart selected.")
            }
            Group {
                if self.showPractice {
                    self.tryout
                } else if !self.isShowingIntroduction {
                    self.introductionSummary
                }
            }
            .frame(maxWidth: self.showPractice ? 680 : 600)
            .padding(.top, 28)
        }
        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.45), value: self.setup.introductionFinished)
    }

    private var introductionSummary: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Change modes with one click")
                .font(.fluidSystem(size: 28, weight: .regular, design: .serif))
                .foregroundStyle(.white.opacity(0.94))
            HStack(alignment: .top, spacing: 24) {
                self.modeSummary(
                    name: "Basic",
                    subtitle: "Without Fluid Intelligence",
                    detail: "Keeps your words as spoken, including mistakes.",
                    smart: false
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                self.modeSummary(
                    name: SettingsStore.DictationModeLabels.smart,
                    subtitle: "With Fluid Intelligence",
                    detail: "Removes rambling, fixes mistakes, and formats your text.",
                    smart: true
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(28)
    }

    private func modeSummary(name: String, subtitle: String, detail: String, smart: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(name, systemImage: smart ? "sparkles" : "bolt.fill")
                    .font(.fluidSystem(size: 18, weight: .semibold))
                    .foregroundStyle(smart ? Color(red: 0.48, green: 0.72, blue: 1) : .white)
                Text(subtitle)
                    .font(.fluidSystem(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Text(detail)
                .font(.fluidSystem(size: 15))
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tryout: some View {
        OnboardingPolishPracticeView(
            finalText: self.$finalText,
            practice: self.practice,
            isRunning: self.isListening,
            isProcessing: self.contentState.isProcessing,
            isActive: !self.isShowingIntroduction,
            shortcutDisplay: self.shortcutDisplay
        )
        .onChange(of: self.isRunning) { _, running in
            if running { self.practice.beginAttempt() }
        }
        .onChange(of: self.finalText) { _, text in
            self.practice.receive(text)
        }
    }

    @ViewBuilder
    private func action(id: String, title: String, tone: ButtonTone, width: CGFloat, action: @escaping () -> Void) -> some View {
        if #available(macOS 26, *), !self.reduceTransparency {
            Button(action: action) {
                Text(title)
                    .font(.fluidSystem(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: width - 32, height: 40)
            }
            .fluidGlassAction(prominent: tone == .primary)
            .font(.fluidSystem(size: 17, weight: .semibold))
            .tint(tone == .primary ? Color(red: 0.20, green: 0.43, blue: 0.88) : nil)
            .disabled(!self.canNavigate)
        } else {
            self.pillButton(PillButtonConfiguration(
                id: id,
                title: title,
                systemImage: nil,
                tone: tone,
                width: width,
                height: 48,
                fontSize: 16,
                isEnabled: self.canNavigate
            ), action: action)
        }
    }

    private struct SetupError: LocalizedError {
        let message: String
        var errorDescription: String? { self.message }
    }

    private func pillButton(
        _ configuration: PillButtonConfiguration,
        action: @escaping () -> Void
    ) -> some View {
        let isDisabled = !configuration.isEnabled
        let isHovered = self.hoveredButtonID == configuration.id && !isDisabled
        let shape = Capsule()
        let accentColor = configuration.tone == .destructive ? Color.red : FluidOnboardingLandingColors.blue
        let isPrimary = configuration.tone == .primary
        let isDestructive = configuration.tone == .destructive
        let fillColor: Color = {
            if isPrimary {
                return accentColor.opacity(isDisabled ? 0.34 : 1)
            }
            if isDestructive {
                return Color.red.opacity(isDisabled ? 0.045 : (isHovered ? 0.24 : 0.16))
            }
            return Color.white.opacity(isDisabled ? 0.045 : (isHovered ? 0.11 : 0.07))
        }()
        let borderColor: Color = {
            if isPrimary {
                return Color.white.opacity(isHovered ? 0.30 : 0)
            }
            if isDestructive {
                return Color.red.opacity(isHovered ? 0.48 : 0.24)
            }
            return isHovered ? accentColor.opacity(0.30) : Color.white.opacity(0.07)
        }()
        let foregroundOpacity = isDisabled ? 0.42 : (isPrimary ? 1.0 : (isHovered ? 0.94 : 0.78))
        let shadowOpacity = isDisabled ? 0 : (isPrimary ? (isHovered ? 0.56 : 0.26) : (isHovered ? 0.12 : 0))

        return Button(action: action) {
            HStack(spacing: configuration.systemImage == nil ? 0 : 8) {
                if let systemImage = configuration.systemImage {
                    Image(systemName: systemImage)
                        .font(.fluidSystem(size: 12, weight: .bold))
                }

                Text(configuration.title)
                    .font(.fluidSystem(size: configuration.fontSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(.white.opacity(foregroundOpacity))
            .frame(width: configuration.width, height: configuration.height)
            .background(
                shape
                    .fill(fillColor)
                    .overlay(shape.fill(Color.white.opacity(isPrimary && isHovered ? 0.10 : 0)))
                    .overlay(shape.stroke(borderColor, lineWidth: isHovered ? 1.2 : 1))
                    .overlay(
                        shape
                            .stroke(accentColor.opacity(isHovered ? 0.50 : 0), lineWidth: isHovered ? 1.4 : 1)
                            .padding(-2)
                    )
                    .shadow(color: accentColor.opacity(shadowOpacity), radius: isHovered ? 16 : 9, x: 0, y: isHovered ? 6 : 3)
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .contentShape(shape)
        .disabled(isDisabled)
        .onHover { isHovered in
            self.setHoveredButton(isHovered && !isDisabled ? configuration.id : nil)
        }
    }

    private func setHoveredButton(_ buttonID: String?) {
        guard self.hoveredButtonID != buttonID else { return }
        if self.reduceMotion {
            self.hoveredButtonID = buttonID
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                self.hoveredButtonID = buttonID
            }
        }
    }

    private func persistPrivateAIVerification(_ model: PrivateAIRegisteredModel) {
        let providerID = PrivateAIProviderFeature.shared.providerID
        let providerKey = DictationAIPostProcessingGate.providerKey(for: providerID)
        let modelIDs = PrivateAIModelRegistry.modelIDs()

        var availableModelsByProvider = self.settings.availableModelsByProvider
        availableModelsByProvider[providerKey] = modelIDs
        self.settings.availableModelsByProvider = availableModelsByProvider

        var selectedModelByProvider = self.settings.selectedModelByProvider
        selectedModelByProvider[providerKey] = model.id
        self.settings.selectedModelByProvider = selectedModelByProvider

        var fingerprints = self.settings.verifiedProviderFingerprints
        let fingerprint = PrivateAIProviderFeature.verificationFingerprint(for: model.id)
        fingerprints[providerKey] = fingerprint
        self.settings.verifiedProviderFingerprints = fingerprints
        self.settings.verifiedPrivateAIModelFingerprints[model.id] = fingerprint

        // Smart dictation selects FI independently of the global Edit/Command provider.
        self.settings.setDictationPromptSelection(.privateAI)
        self.settings.onboardingAISkipped = false
        UserDefaults.standard.set(model.id, forKey: PrivateAIIntegrationService.selectedModelDefaultsKey)
    }
}
