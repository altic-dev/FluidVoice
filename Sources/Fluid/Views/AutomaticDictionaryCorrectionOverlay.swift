import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class DictionaryCorrectionOverlayController {
    static let shared = DictionaryCorrectionOverlayController()

    private static let displayDurationNanoseconds: UInt64 = 10_000_000_000
    private static let successDurationNanoseconds: UInt64 = 1_400_000_000
    private static let presentationDuration: TimeInterval = 0.05
    private static let dismissalDuration: TimeInterval = 0.05

    private var panel: NSPanel?
    private var hostingView: NSHostingView<AutomaticDictionaryCorrectionOverlayView>?
    private var session: AutomaticDictionaryTrainingSession?
    private var sessionCancellable: AnyCancellable?
    private var dismissTask: Task<Void, Never>?
    private var outcomeHandler: ((AutomaticDictionarySuggestionOutcome) -> Void)?
    private var generation: UInt64 = 0

    private init() {}

    var isPresented: Bool {
        self.panel?.isVisible == true
    }

    func transientOverlayLayoutDidChange() {
        guard self.isPresented else { return }
        self.resizeAndPositionPanel(animated: true)
    }

    func show(
        candidate: AutomaticDictionaryCorrectionCandidate,
        onOutcome: @escaping (AutomaticDictionarySuggestionOutcome) -> Void
    ) {
        self.generation &+= 1
        self.dismissTask?.cancel()
        self.session?.cancel()
        self.outcomeHandler = onOutcome

        let session = AutomaticDictionaryTrainingSession(
            candidate: candidate,
            asr: AppServices.shared.asr
        )
        session.onInteraction = { [weak self] in
            self?.keepVisible()
        }
        session.onSuccess = { [weak self] in
            self?.reportOutcome(.accepted)
            self?.scheduleSuccessDismissal()
        }
        self.session = session

        let rootView = AutomaticDictionaryCorrectionOverlayView(
            session: session,
            displayDuration: Double(Self.displayDurationNanoseconds) / 1_000_000_000,
            onDismiss: { [weak self] in
                self?.dismiss()
            },
            onIgnore: { [weak self] in
                self?.reportOutcome(.ignored)
                self?.hide()
            },
            onFrequencyChange: { [weak self] frequency in
                SettingsStore.shared.automaticDictionarySuggestionFrequency = frequency
                self?.scheduleChoiceDismissal()
            },
            onDisableSuggestions: { [weak self] in
                SettingsStore.shared.automaticDictionaryLearningEnabled = false
                self?.hide()
            }
        )

        if let hostingView = self.hostingView {
            hostingView.rootView = rootView
        } else {
            self.createPanel(rootView: rootView)
        }

        self.sessionCancellable = session.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.resizeAndPositionPanel(animated: true)
                }
            }

        guard let panel = self.panel else { return }
        self.resizeAndPositionPanel(animated: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.presentationDuration
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1
        }

        self.scheduleChoiceDismissal()
    }

    private func scheduleChoiceDismissal() {
        self.keepVisible()
        let currentGeneration = self.generation
        self.dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.displayDurationNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  self.generation == currentGeneration,
                  self.session?.screen == .choice
            else {
                return
            }
            self.reportOutcome(.timedOut)
            self.hide()
        }
    }

    func hide() {
        self.generation &+= 1
        let hideGeneration = self.generation
        self.dismissTask?.cancel()
        self.dismissTask = nil
        self.session?.cancel()
        guard let panel, panel.isVisible else {
            self.clearSession()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.dismissalDuration
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == hideGeneration else { return }
                self.panel?.orderOut(nil)
                self.panel?.alphaValue = 1
                self.clearSession()
            }
        }
    }

    func dismiss() {
        self.reportOutcome(.dismissed)
        self.hide()
    }

    private func keepVisible() {
        self.dismissTask?.cancel()
        self.dismissTask = nil
    }

    private func scheduleSuccessDismissal() {
        self.keepVisible()
        let successGeneration = self.generation
        self.dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.successDurationNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  self.generation == successGeneration
            else {
                return
            }
            self.hide()
        }
    }

    private func clearSession() {
        self.sessionCancellable?.cancel()
        self.sessionCancellable = nil
        self.session = nil
        self.outcomeHandler = nil
    }

    private func reportOutcome(_ outcome: AutomaticDictionarySuggestionOutcome) {
        guard let outcomeHandler = self.outcomeHandler else { return }
        self.outcomeHandler = nil
        outcomeHandler(outcome)
    }

    private func createPanel(rootView: AutomaticDictionaryCorrectionOverlayView) {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        panel.contentView = hostingView

        self.panel = panel
        self.hostingView = hostingView
    }

    private func resizeAndPositionPanel(animated: Bool) {
        guard let panel, let hostingView,
              let screen = OverlayScreenResolver.screenForCurrentPointer() ?? NSScreen.main
        else {
            return
        }

        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let size = NSSize(width: ceil(fittingSize.width), height: ceil(fittingSize.height))
        guard size.width > 0, size.height > 0 else { return }
        hostingView.frame = NSRect(origin: .zero, size: size)

        let visibleFrame = screen.visibleFrame
        let requestedY = visibleFrame.minY + CGFloat(SettingsStore.shared.overlayBottomOffset)
        let microphoneToastY = MicrophoneChangeOverlayController.shared.topEdge(on: screen).map { $0 + 10 }
        let stackedY = max(requestedY, microphoneToastY ?? requestedY)
        let y = max(visibleFrame.minY + 10, min(stackedY, visibleFrame.maxY - size.height - 40))
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: y,
            width: size.width,
            height: size.height
        )

        guard animated, panel.isVisible else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }
}

enum MicrophoneChangePresentation: Hashable {
    case startupSelection
    case selectionChange
    case activeChange
}

struct MicrophoneChangeNotice: Hashable {
    let previousName: String?
    let currentName: String?
    let presentation: MicrophoneChangePresentation
}

@MainActor
final class MicrophoneChangeOverlayController {
    static let shared = MicrophoneChangeOverlayController()

    private static let displayDurationNanoseconds: UInt64 = 5_000_000_000
    private static let supportedBundleIdentifiers = [
        "com.FluidApp.app",
        "com.FluidApp.app.debug",
    ]
    private var panel: NSPanel?
    private var hostingView: NSHostingView<MicrophoneChangeOverlayView>?
    private var dismissTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    private init() {}

    func show(_ notice: MicrophoneChangeNotice) {
        guard Self.supportsAlerts(bundleIdentifier: Bundle.main.bundleIdentifier),
              SettingsStore.shared.showMicrophoneChangeAlerts
        else { return }
        self.generation &+= 1
        let currentGeneration = self.generation
        self.dismissTask?.cancel()

        let rootView = MicrophoneChangeOverlayView(
            notice: notice,
            displayDuration: Double(Self.displayDurationNanoseconds) / 1_000_000_000,
            startedAt: Date(),
            onSettings: { [weak self] in
                self?.hide()
                NotificationCenter.default.post(name: .openMicrophoneSettingsRequested, object: nil)
            },
            onDisable: { [weak self] in
                self?.disableFutureAlerts()
            },
            onDismiss: { [weak self] in self?.hide() }
        )
        if let hostingView = self.hostingView {
            hostingView.rootView = rootView
        } else {
            self.createPanel(rootView: rootView)
        }

        guard let panel = self.panel else { return }
        self.resizeAndPositionPanel()
        DebugLogger.shared.debug(
            "Showing microphone change overlay frame=\(NSStringFromRect(panel.frame))",
            source: "MicrophoneChangeOverlay"
        )
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        self.animate(duration: 0.12) {
            panel.animator().alphaValue = 1
        }
        DictionaryCorrectionOverlayController.shared.transientOverlayLayoutDidChange()

        self.dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.displayDurationNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  self.generation == currentGeneration
            else { return }
            self.hide()
        }
    }

    nonisolated static func supportsAlerts(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return self.supportedBundleIdentifiers.contains(bundleIdentifier)
    }

    func disableFutureAlerts() {
        SettingsStore.shared.showMicrophoneChangeAlerts = false
        self.hide()
    }

    func hide() {
        self.generation &+= 1
        let hideGeneration = self.generation
        self.dismissTask?.cancel()
        self.dismissTask = nil
        guard let panel, panel.isVisible else { return }
        self.animate(duration: 0.1) {
            panel.animator().alphaValue = 0
        } completion: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == hideGeneration else { return }
                self.panel?.orderOut(nil)
                self.panel?.alphaValue = 1
                DictionaryCorrectionOverlayController.shared.transientOverlayLayoutDidChange()
            }
        }
    }

    func topEdge(on screen: NSScreen) -> CGFloat? {
        guard let panel, panel.isVisible, panel.frame.intersects(screen.frame) else { return nil }
        return panel.frame.maxY
    }

    private func createPanel(rootView: MicrophoneChangeOverlayView) {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        panel.contentView = hostingView
        self.panel = panel
        self.hostingView = hostingView
    }

    private func resizeAndPositionPanel() {
        guard let panel, let hostingView,
              let screen = OverlayScreenResolver.screenForCurrentPointer() ?? NSScreen.main
        else { return }
        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let size = NSSize(width: ceil(fittingSize.width), height: ceil(fittingSize.height))
        guard size.width > 0, size.height > 0 else { return }
        hostingView.frame = NSRect(origin: .zero, size: size)
        let visibleFrame = screen.visibleFrame
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: visibleFrame.minY + 10,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
    }

    private func animate(
        duration: TimeInterval,
        changes: () -> Void,
        completion: (() -> Void)? = nil
    ) {
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false else {
            changes()
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            changes()
        } completionHandler: {
            completion?()
        }
    }
}

private struct MicrophoneChangeOverlayView: View {
    let notice: MicrophoneChangeNotice
    let displayDuration: TimeInterval
    let startedAt: Date
    let onSettings: () -> Void
    let onDisable: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isCloseHovered = false
    @State private var isDisableHovered = false
    @State private var isSettingsHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: self.notice.currentName == nil ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 24, height: 24)

                Text(self.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))

                Spacer(minLength: 8)

                Button(action: self.onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(self.isCloseHovered ? 0.95 : 0.68))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(self.isCloseHovered ? 0.13 : 0.06)))
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .onHover { self.isCloseHovered = $0 }
                .help("Dismiss")
                .accessibilityLabel("Dismiss microphone change")
            }

            Text(self.detailText)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Text(self.explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Button("Do not show again", action: self.onDisable)
                    .buttonStyle(TransientOverlaySettingsButtonStyle(isHovered: self.isDisableHovered))
                    .onHover { self.isDisableHovered = $0 }
                    .help("Turn off microphone change alerts")

                Button("Settings", action: self.onSettings)
                    .buttonStyle(TransientOverlaySettingsButtonStyle(isHovered: self.isSettingsHovered))
                    .onHover { self.isSettingsHovered = $0 }
                    .help("Open microphone settings")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 540)
        .background(TransientOverlayBackground())
        .overlay(alignment: .bottomLeading) {
            TransientOverlayCountdownBar(
                startedAt: self.startedAt,
                duration: self.displayDuration,
                reduceMotion: self.reduceMotion
            )
        }
        .preferredColorScheme(.dark)
        .id(self.notice)
    }

    private var detailText: String {
        if self.notice.presentation == .startupSelection,
           let currentName = self.notice.currentName
        {
            return currentName
        }
        switch (self.notice.previousName, self.notice.currentName) {
        case let (previous?, current?):
            return "\(previous)  →  \(current)"
        case let (previous?, nil):
            return "\(previous) is no longer available"
        case let (nil, current?):
            return "Now using \(current)"
        case (nil, nil):
            return "Connect or restore a microphone in Settings"
        }
    }

    private var title: String {
        if self.notice.presentation == .startupSelection {
            return "Microphone selected"
        }
        return self.notice.currentName == nil ? "Microphone unavailable" : "Microphone changed"
    }

    private var explanation: String {
        if self.notice.currentName == nil {
            return "Choose an available microphone in Settings."
        }
        if self.notice.presentation == .startupSelection {
            return "FluidVoice will try this microphone first when you dictate."
        }
        if self.notice.presentation == .selectionChange {
            return "FluidVoice selected this microphone for capture."
        }
        return "FluidVoice confirmed this microphone is capturing audio."
    }
}

private struct TransientOverlaySettingsButtonStyle: ButtonStyle {
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 1 : 0.9))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.20 : self.isHovered ? 0.14 : 0.09))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(
                                Color.white.opacity(configuration.isPressed ? 0.28 : 0.12),
                                lineWidth: 1
                            )
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct TransientOverlayCountdownBar: View {
    let startedAt: Date
    let duration: TimeInterval
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: self.reduceMotion ? 1 : 1 / 30)) { context in
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(Color.white.opacity(0.82))
                        .frame(width: proxy.size.width * self.remainingProgress(at: context.date))
                }
            }
        }
        .frame(height: 3)
        .padding(.horizontal, 14)
        .padding(.bottom, 3)
        .allowsHitTesting(false)
    }

    private func remainingProgress(at date: Date) -> CGFloat {
        guard self.duration > 0 else { return 0 }
        return CGFloat(max(0, min(1, 1 - date.timeIntervalSince(self.startedAt) / self.duration)))
    }
}

private struct TransientOverlayBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.black)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.15), .white.opacity(0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
    }
}

extension Notification.Name {
    static let openMicrophoneSettingsRequested = Notification.Name("OpenMicrophoneSettingsRequested")
}

private struct AutomaticDictionaryCorrectionOverlayView: View {
    @ObservedObject var session: AutomaticDictionaryTrainingSession
    @ObservedObject private var settings = SettingsStore.shared

    let displayDuration: TimeInterval
    let onDismiss: () -> Void
    let onIgnore: () -> Void
    let onFrequencyChange: (SettingsStore.AutomaticDictionarySuggestionFrequency) -> Void
    let onDisableSuggestions: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDismissHovered = false
    @State private var progress: CGFloat = 1

    private var accent: Color { self.settings.accentColor }

    var body: some View {
        Group {
            switch self.session.screen {
            case .choice:
                self.choiceContent
            case .training:
                self.trainingContent
            case .success:
                self.successContent
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 460)
        .background(TransientOverlayBackground())
        .overlay(alignment: .bottomLeading) {
            if self.session.screen == .choice {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.white.opacity(0.72))
                        .frame(width: proxy.size.width * self.progress, height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 3)
                .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.16), value: self.session.screen)
        .onAppear {
            self.startProgressAnimation()
        }
    }

    private var choiceContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            self.header(title: "Correction noticed", allowsBack: false)

            self.correctionPair

            Text("Save only this correction, or teach FluidVoice other pronunciations.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)

            HStack(spacing: 8) {
                CorrectionOverlayActionButton(
                    title: "Train by Voice",
                    systemImage: "mic.fill",
                    style: .secondary,
                    accent: self.accent,
                    action: self.session.beginTraining
                )

                CorrectionOverlayActionButton(
                    title: "Add This Correction",
                    systemImage: "plus",
                    style: .accent,
                    accent: self.accent,
                    action: self.session.addOnlyCorrection
                )

                self.moreOptionsMenu
            }
        }
        .transition(.opacity)
    }

    private var moreOptionsMenu: some View {
        Menu {
            Button("Ignore This Correction", systemImage: "eye.slash", action: self.onIgnore)

            Menu("Suggest After") {
                ForEach(SettingsStore.AutomaticDictionarySuggestionFrequency.allCases) { frequency in
                    Button {
                        self.onFrequencyChange(frequency)
                        self.startProgressAnimation()
                    } label: {
                        if self.settings.automaticDictionarySuggestionFrequency == frequency {
                            Label(frequency.displayName, systemImage: "checkmark")
                        } else {
                            Text(frequency.displayName)
                        }
                    }
                }
            }

            Divider()

            Button("Turn Off Auto-Learn", role: .destructive, action: self.onDisableSuggestions)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 36, height: 36)
                .background(self.panelSurface)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More correction options")
    }

    private var trainingContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            self.header(title: "Train by Voice", allowsBack: true)

            self.correctionPair

            VStack(alignment: .leading, spacing: 9) {
                Text("Teach FluidVoice your pronunciation")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))

                if self.session.isReady {
                    Label("FluidVoice got it right 3 times in a row.", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(self.accent)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        self.trainingInstruction(number: 1, text: "Press Start once.")
                        self.trainingInstruction(
                            number: 2,
                            text: "Say the word, then pause. FluidVoice captures it and listens again."
                        )
                        self.trainingInstruction(number: 3, text: "Repeat naturally until the circle reaches 3/3.")
                    }
                }

                HStack(spacing: 12) {
                    CorrectionOverlayReadinessRing(
                        progress: self.session.readinessProgress,
                        total: CustomDictionaryTrainingMerge.readyCoveredCount,
                        isReady: self.session.isReady,
                        accent: self.accent
                    )

                    Text(self.overlayReadinessCaption)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(self.session.isReady ? self.accent : .white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    CorrectionOverlayRecordButton(
                        title: self.session.recordButtonTitle,
                        isStop: self.session.recordButtonIsStop,
                        isEnabled: self.session.canUseRecordButton,
                        accent: self.accent,
                        action: self.session.toggleCapture
                    )
                }
            }
            .padding(10)
            .background(self.panelSurface)

            self.finalOutputRow

            if !self.session.variants.isEmpty {
                self.capturedVariantsRow
            }

            if self.session.capturePhase == .idle, self.session.hasError, !self.session.statusMessage.isEmpty {
                Label(
                    self.session.statusMessage,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.red.opacity(0.9))
                .lineLimit(1)
            }

            CorrectionOverlayActionButton(
                title: "Add Replacement",
                systemImage: self.session.isReady ? "sparkles" : "plus",
                style: .accent,
                accent: self.accent,
                isEnabled: self.session.canSave,
                isReady: self.session.isReady,
                action: self.session.addTrainedReplacement
            )
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var overlayReadinessCaption: String {
        if self.session.isReady {
            return "Ready. Add Replacement is unlocked."
        }
        let remaining = max(
            0,
            CustomDictionaryTrainingMerge.readyCoveredCount - self.session.readinessProgress
        )
        return "\(remaining) correct \(remaining == 1 ? "try" : "tries") to unlock Add Replacement."
    }

    private func trainingInstruction(number: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("\(number)")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(self.accent)
                .frame(width: 14)

            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var successContent: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(self.accent.opacity(0.18))
                    .frame(width: 38, height: 38)
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(self.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(self.session.successTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("“\(self.session.candidate.heardText)” will become “\(self.session.candidate.correctedText)”.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    private func header(title: String, allowsBack: Bool) -> some View {
        HStack(spacing: 7) {
            if allowsBack {
                Button(action: self.session.returnToChoice) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .disabled(self.session.capturePhase != .idle)
                .opacity(self.session.capturePhase == .idle ? 1 : 0.35)
                .help("Back")
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 24, height: 24)
            }

            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))

            Spacer(minLength: 8)

            Button(action: self.onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(self.isDismissHovered ? 0.95 : 0.68))
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(self.isDismissHovered ? 0.13 : 0.06))
                    )
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .onHover { self.isDismissHovered = $0 }
            .help("Dismiss")
        }
    }

    private var correctionPair: some View {
        HStack(spacing: 8) {
            Text(self.session.candidate.heardText)
                .foregroundStyle(.white.opacity(0.78))

            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.42))

            Text(self.session.candidate.correctedText)
                .foregroundStyle(.white)
        }
        .font(.system(size: 16, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var finalOutputRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Final output")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.46))
                Text(self.session.finalOutputText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(self.session.lastOutput.isEmpty ? 0.48 : 0.9))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if self.session.isReady {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(self.accent)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(self.panelSurface)
    }

    private var capturedVariantsRow: some View {
        HStack(spacing: 6) {
            Text("Captured")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.46))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(self.session.variants, id: \.self) { variant in
                        CorrectionOverlayVariantChip(variant: variant) {
                            self.session.removeVariant(variant)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 24)
    }

    private func startProgressAnimation() {
        self.progress = 1
        guard !self.reduceMotion else { return }
        DispatchQueue.main.async {
            withAnimation(.linear(duration: self.displayDuration)) {
                self.progress = 0
            }
        }
    }

    private var panelSurface: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
            )
    }
}

private struct CorrectionOverlayReadinessRing: View {
    let progress: Int
    let total: Int
    let isReady: Bool
    let accent: Color

    private var fraction: Double {
        guard self.total > 0 else { return 0 }
        return min(max(Double(self.progress) / Double(self.total), 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: 7)

            Circle()
                .trim(from: 0, to: self.fraction)
                .stroke(
                    self.accent,
                    style: StrokeStyle(lineWidth: 7, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: 0) {
                Text("\(self.progress)/\(self.total)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(self.isReady ? self.accent : .white.opacity(0.92))
                    .monospacedDigit()

                Text(self.isReady ? "Ready" : "correct")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.46))
            }
        }
        .frame(width: 76, height: 76)
        .shadow(color: self.isReady ? self.accent.opacity(0.22) : .clear, radius: 9)
        .animation(.easeOut(duration: 0.24), value: self.progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Training progress")
        .accessibilityValue("\(self.progress) of \(self.total) correct")
    }
}

private struct CorrectionOverlayActionButton: View {
    enum Style {
        case accent
        case secondary
    }

    let title: String
    let systemImage: String
    let style: Style
    let accent: Color
    var isEnabled = true
    var isReady = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var isGlowExpanded = false

    private var shouldPulse: Bool {
        self.isReady && self.isEnabled && !self.isHovered && !self.reduceMotion
    }

    var body: some View {
        Button(action: self.action) {
            Label(self.title, systemImage: self.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(self.isEnabled ? 0.94 : 0.42))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(self.background)
        }
        .buttonStyle(.plain)
        .disabled(!self.isEnabled)
        .onHover { self.isHovered = $0 }
        .onAppear { self.updateGlow() }
        .onChange(of: self.shouldPulse) { _, _ in
            self.updateGlow()
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(self.fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(self.borderColor, lineWidth: self.isReady ? 1.5 : 1)
            )
            .shadow(
                color: self.isReady ? self.accent.opacity(self.isGlowExpanded ? 0.34 : 0.14) : .clear,
                radius: self.isReady ? (self.isGlowExpanded ? 16 : 7) : 0,
                y: 3
            )
    }

    private var fillColor: Color {
        guard self.isEnabled else {
            return Color.white.opacity(0.045)
        }
        switch self.style {
        case .accent:
            return self.accent.opacity(self.isHovered ? 1 : 0.9)
        case .secondary:
            return Color.white.opacity(self.isHovered ? 0.1 : 0.045)
        }
    }

    private var borderColor: Color {
        guard self.isEnabled else {
            return Color.white.opacity(0.1)
        }
        if self.isReady {
            return self.accent.opacity(0.78)
        }
        switch self.style {
        case .accent:
            return Color.white.opacity(self.isEnabled ? 0.18 : 0.06)
        case .secondary:
            return Color.white.opacity(self.isHovered ? 0.28 : 0.16)
        }
    }

    private func updateGlow() {
        guard self.shouldPulse else {
            withAnimation(.easeOut(duration: 0.16)) {
                self.isGlowExpanded = false
            }
            return
        }

        self.isGlowExpanded = false
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            self.isGlowExpanded = true
        }
    }
}

private struct CorrectionOverlayRecordButton: View {
    let title: String
    let isStop: Bool
    let isEnabled: Bool
    let accent: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: self.action) {
            Label(self.title, systemImage: self.isStop ? "stop.fill" : "mic.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(self.isEnabled ? 0.95 : 0.4))
                .padding(.horizontal, 13)
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(self.buttonColor.opacity(self.isEnabled ? (self.isHovered ? 1 : 0.9) : 0.25))
                )
        }
        .buttonStyle(.plain)
        .disabled(!self.isEnabled)
        .onHover { self.isHovered = $0 }
    }

    private var buttonColor: Color {
        self.isStop ? Color(red: 0.82, green: 0.18, blue: 0.2) : self.accent
    }
}

private struct CorrectionOverlayVariantChip: View {
    let variant: String
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: self.onRemove) {
            HStack(spacing: 4) {
                Text(self.variant)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(self.isHovered ? 0.72 : 0.42))
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 7)
            .frame(height: 23)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(self.isHovered ? 0.1 : 0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 112)
        .onHover { self.isHovered = $0 }
        .help("Remove \(self.variant)")
    }
}
