import SwiftUI

/// One page for the speech model and the cleanup model. Both pop-ups drive the same view models
/// as Voice Engine and AI Settings, so every page stays in step.
struct ModelsScreen: View {
    /// The open pop-up carries its own data, so a sheet can never open before its content exists.
    private enum Picker: Identifiable {
        case speech
        case cleanup(CleanupModelPickerContent)

        var id: String {
            switch self {
            case .speech: "speech"
            case .cleanup: "cleanup"
            }
        }
    }

    @Environment(\.theme) private var theme
    let openFeedback: (FeedbackDraft) -> Void

    @StateObject private var speech: VoiceEngineSettingsViewModel
    @StateObject private var enhancement: AIEnhancementSettingsViewModel
    @StateObject private var cleanup: PrivateAISettingsController
    @ObservedObject private var settings = SettingsStore.shared

    @State private var openPicker: Picker?
    @State private var memoryBytes: UInt64?
    @State private var recommendedCleanupModelID: String?
    @State private var selectedCleanupFiles: PrivateAIModelFiles?

    init(appServices: AppServices, menuBarManager: MenuBarManager, openFeedback: @escaping (FeedbackDraft) -> Void) {
        self.openFeedback = openFeedback
        _speech = StateObject(wrappedValue: VoiceEngineSettingsViewModel(settings: SettingsStore.shared, appServices: appServices))
        let enhancement = AIEnhancementSettingsViewModel(
            settings: SettingsStore.shared,
            menuBarManager: menuBarManager,
            promptTest: DictationPromptTestCoordinator.shared
        )
        _enhancement = StateObject(wrappedValue: enhancement)
        _cleanup = StateObject(wrappedValue: PrivateAISettingsController(viewModel: enhancement))
    }

    private var isCleanupAvailable: Bool { PrivateAIProviderFeature.shared.isAvailable }

    var body: some View {
        ScrollView(.vertical) {
            // No headline: each card already says what its model does.
            ViewThatFits(in: .horizontal) {
                // Side by side, both cards take the taller one's height.
                HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) { self.cards }
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) { self.cards }
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Same width rule as Voice Engine and AI Settings: fill the page with even margins.
            .fluidPageContent(width: .expanding)
        }
        .fluidCanvas()
        .onAppear {
            self.speech.onAppear()
            self.enhancement.onAppear()
            self.cleanup.synchronizeSelection()
            self.cleanup.refreshPrivateAILoadState()
        }
        .task {
            let hardware = await PrivateAIMacHardware.current()
            let recommendation = await PrivateAIHardwareRecommendation.current()
            guard !Task.isCancelled else { return }
            self.memoryBytes = hardware.memoryBytes
            self.recommendedCleanupModelID = recommendation.model.rawValue
        }
        .task(id: "\(self.cleanup.privateAISelectedModelID)|\(self.cleanup.isBusy)") {
            guard !self.cleanup.isBusy else { return }
            let selected = self.cleanup.selectedPrivateAIModel
            let files = await PrivateAISettingsController.readModelFiles([selected])
            guard !Task.isCancelled else { return }
            self.selectedCleanupFiles = files[selected.id]
        }
        .fluidPopup(item: self.$openPicker) { picker in
            switch picker {
            case .speech:
                SpeechModelPicker(viewModel: self.speech, settings: self.settings, memoryBytes: self.memoryBytes) {
                    self.openPicker = nil
                }
            case let .cleanup(content):
                CleanupModelPicker(
                    controller: self.cleanup,
                    content: content,
                    memoryBytes: self.memoryBytes,
                    close: { self.openPicker = nil },
                    sendFeedback: { model in self.sendCleanupFeedback(model, content: content) }
                )
            }
        }
    }

    @ViewBuilder
    private var cards: some View {
        ModelsCard(
            icon: "waveform",
            label: "Turns your voice into text",
            name: self.settings.selectedSpeechModel.humanReadableName,
            status: self.speechStatus,
            canChange: true
        ) {
            self.openPicker = .speech
        }
        if self.isCleanupAvailable {
            ModelsCard(
                icon: "wand.and.stars",
                label: "Tidies up your words",
                name: self.cleanup.selectedPrivateAIModel.displayName,
                status: self.cleanupStatus,
                canChange: true,
                change: self.openCleanupPicker
            )
        } else {
            ModelsCard(
                icon: "wand.and.stars",
                label: "Tidies up your words",
                name: "Not in this build",
                status: "Fluid Intelligence isn’t included here.",
                canChange: false
            ) {}
        }
    }

    /// Only states that differ from "working normally"; the card itself already says this model is in use.
    private var speechStatus: String? {
        if let model = self.speech.downloadingModel {
            return "Downloading \(model.humanReadableName) · \(Int((self.speech.downloadProgress * 100).rounded()))%"
        }
        return self.speech.isPreparingSelectedModel ? "Preparing…" : nil
    }

    private var isCleanupActive: Bool {
        self.cleanup.isActive(self.cleanup.selectedPrivateAIModel, installed: self.selectedCleanupFiles?.installed == true)
    }

    /// Only states that differ from "working normally".
    private var cleanupStatus: String? {
        let model = self.cleanup.selectedPrivateAIModel
        let state = self.cleanup.privateAILoadState
        if state.isDownloading(model.id) { return PrivateAIModelDownloadProgressText.detailText(for: state.downloadProgress(for: model.id)) }
        if state.isLoading(model.id) { return "Preparing…" }
        if self.isCleanupActive { return nil }
        return self.cleanup.routesDictationThroughPrivateAI ? "Not set up yet" : "Off for dictation"
    }

    private func openCleanupPicker() {
        let languageID = VoiceEngineLanguageCatalog.preferredLanguageID(settings: self.settings)
        let content = CleanupModelPickerContent(
            languageID: languageID,
            languageName: VoiceEngineLanguageCatalog.displayName(forLanguageID: languageID),
            models: PrivateAIModelRegistry.modelIDs().compactMap { PrivateAIModelRegistry.model(id: $0) },
            recommendedModelID: self.recommendedCleanupModelID
        )
        self.openPicker = .cleanup(content)
    }

    private func sendCleanupFeedback(_ model: PrivateAIRegisteredModel, content: CleanupModelPickerContent) {
        let draft = FeedbackDraft(
            category: .issue,
            message: """
            I’d like better cleanup for \(content.languageName).
            Cleanup model: \(model.displayName)
            Speech model: \(self.settings.selectedSpeechModel.humanReadableName)
            """,
            includeDetails: true
        )
        self.openPicker = nil
        self.openFeedback(draft)
    }
}

private struct ModelsCard: View {
    @Environment(\.theme) private var theme
    let icon: String
    let label: String
    let name: String
    /// Shown only when the model is not simply working.
    let status: String?
    let canChange: Bool
    let change: () -> Void

    var body: some View {
        let padding = self.theme.metrics.spacing.xl
        Group {
            if self.canChange {
                // The whole card opens the picker; "Change" names the action.
                Button(action: self.change) { self.content }
                    .fluidCardButton(padding: padding)
                    .accessibilityLabel(self.label)
                    .accessibilityValue([self.name, self.status].compactMap(\.self).joined(separator: ", "))
                    .accessibilityHint("Change")
            } else {
                FluidSurfaceCard(padding: padding) { self.content }
            }
        }
        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A tile: the symbol and "Change" on top, what the card is and the model's name at the bottom.
    /// Fills the height the row gives it, so side-by-side cards stay level.
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
                FluidGlyphTile(systemImage: self.icon, size: 44)
                Spacer(minLength: 0)
                if self.canChange {
                    FluidActionLabel(title: "Change")
                }
            }
            Spacer(minLength: self.theme.metrics.spacing.xxl)
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                Text(self.label)
                    .fluidText(.body)
                    .foregroundStyle(self.theme.look.tertiaryText)
                Text(self.name)
                    .fluidText(.itemTitle)
                    .foregroundStyle(self.theme.look.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let status = self.status {
                    Text(status)
                        .fluidText(.body)
                        .foregroundStyle(self.theme.look.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
