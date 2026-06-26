import AppKit
import Combine
import SwiftUI

@MainActor
final class VoiceEngineSettingsViewModel: ObservableObject {
    let settings: SettingsStore
    private let appServices: AppServices

    var asr: ASRService { self.appServices.asr }

    @Published var modelSortOption: ModelSortOption = .provider
    @Published var providerFilter: SpeechProviderFilter = .all
    @Published var englishOnlyFilter: Bool = false
    @Published var installedOnlyFilter: Bool = false
    @Published var showSpeechFilters: Bool = false

    @Published var selectedSpeechProvider: SettingsStore.SpeechModel.Provider
    @Published var previewSpeechModel: SettingsStore.SpeechModel
    @Published var showAdvancedSpeechInfo: Bool = false
    @Published var suppressSpeechProviderSync: Bool = false
    @Published var skipNextSpeechModelSync: Bool = false

    /// The model currently being downloaded (nil if no download in progress)
    @Published var downloadingModel: SettingsStore.SpeechModel?
    /// Download progress for the current model (0.0 to 1.0)
    @Published var downloadProgress: Double = 0.0

    @Published var removeFillerWordsEnabled: Bool

    init(settings: SettingsStore, appServices: AppServices) {
        self.settings = settings
        self.appServices = appServices
        self.previewSpeechModel = settings.selectedSpeechModel
        self.selectedSpeechProvider = settings.selectedSpeechModel.provider
        self.removeFillerWordsEnabled = settings.removeFillerWordsEnabled
    }

    func onAppear() {
        self.previewSpeechModel = self.settings.selectedSpeechModel
        self.selectedSpeechProvider = self.settings.selectedSpeechModel.provider
        self.removeFillerWordsEnabled = self.settings.removeFillerWordsEnabled

        Task {
            await self.asr.checkIfModelsExistAsync()
        }
    }

    func handleSelectedSpeechModelChange(_ newValue: SettingsStore.SpeechModel) {
        if self.skipNextSpeechModelSync {
            self.skipNextSpeechModelSync = false
            return
        }
        guard !self.suppressSpeechProviderSync else { return }
        self.previewSpeechModel = newValue
        self.setSelectedSpeechProvider(newValue.provider)
    }

    var filteredSpeechModels: [SettingsStore.SpeechModel] {
        var models = SettingsStore.SpeechModel.availableModels

        switch self.providerFilter {
        case .all:
            break
        case .nvidia:
            models = models.filter { $0.provider == .nvidia }
        case .apple:
            models = models.filter { $0.provider == .apple }
        case .cohere:
            models = models.filter { $0.provider == .cohere }
        case .openai:
            models = models.filter { $0.provider == .openai }
        }

        if self.englishOnlyFilter {
            models = models.filter { model in
                let label = model.languageSupport.lowercased()
                let title = model.humanReadableName.lowercased()
                return label.contains("english only") || title.contains("english")
            }
        }

        if self.installedOnlyFilter {
            models = models.filter { $0.isInstalled }
        }

        switch self.modelSortOption {
        case .provider:
            models.sort { $0.brandName.localizedCaseInsensitiveCompare($1.brandName) == .orderedAscending }
        case .accuracy:
            models.sort { $0.accuracyPercent > $1.accuracyPercent }
        case .speed:
            models.sort { $0.speedPercent > $1.speedPercent }
        }

        return models
    }

    func activateSpeechModel(_ model: SettingsStore.SpeechModel) {
        guard !self.asr.isRunning else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            self.settings.selectedSpeechModel = model
            self.previewSpeechModel = model
            self.setSelectedSpeechProvider(model.provider)
        }
        self.asr.resetTranscriptionProvider()
        Task {
            do {
                try await self.asr.ensureAsrReady()
            } catch {
                DebugLogger.shared.error("Failed to prepare model after activation: \(error)", source: "AISettingsView")
                self.asr.errorTitle = "Model Activation Failed"
                self.asr.errorMessage = error.localizedDescription
                self.asr.showError = true
            }
        }
    }

    func downloadSpeechModel(_ model: SettingsStore.SpeechModel) {
        guard !self.asr.isRunning else { return }
        guard self.downloadingModel == nil else { return } // Prevent concurrent downloads
        self.downloadingModel = model
        self.downloadProgress = 0.0

        Task {
            // Mark this model as downloading
            self.downloadingModel = model
            self.downloadProgress = 0.0

            do {
                // Download the model WITHOUT changing the active selection
                // Capture the model ID to guard against stale progress callbacks
                let downloadingModelId = model.id
                try await self.asr.downloadModel(model, progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        // Only update progress if we're still downloading this specific model
                        guard let self, self.downloadingModel?.id == downloadingModelId else { return }
                        self.downloadProgress = max(self.downloadProgress, progress)
                    }
                })

                DebugLogger.shared.info("Model download completed: \(model.displayName)", source: "VoiceEngineVM")
            } catch {
                DebugLogger.shared.error("Failed to download model \(model.displayName): \(error)", source: "VoiceEngineVM")
                await MainActor.run {
                    self.asr.errorTitle = "Model Download Failed"
                    self.asr.errorMessage = error.localizedDescription
                    self.asr.showError = true
                }
            }

            // Clear downloading state
            self.downloadingModel = nil
            self.downloadProgress = 0.0
        }
    }

    func deleteSpeechModel(_ model: SettingsStore.SpeechModel) {
        guard !self.asr.isRunning else { return }
        let previousActive = self.settings.selectedSpeechModel

        Task {
            let shouldRestore = previousActive != model
            await MainActor.run {
                if shouldRestore {
                    self.suppressSpeechProviderSync = true
                }
                self.settings.selectedSpeechModel = model
                self.asr.resetTranscriptionProvider()
            }

            defer {
                Task { @MainActor in
                    guard shouldRestore else { return }
                    self.skipNextSpeechModelSync = true
                    self.settings.selectedSpeechModel = previousActive
                    self.asr.resetTranscriptionProvider()
                    if self.previewSpeechModel == model {
                        self.previewSpeechModel = model
                    }
                    self.suppressSpeechProviderSync = false
                }
            }

            await self.deleteModels()
        }
    }

    func isActiveSpeechModel(_ model: SettingsStore.SpeechModel) -> Bool {
        self.settings.selectedSpeechModel == model
    }

    var modelDescriptionText: String {
        let model = self.settings.selectedSpeechModel
        switch model {
        case .appleSpeech:
            return "Apple Speech (Legacy) uses built-in macOS speech recognition. No model download required, works on Intel and Apple Silicon."
        case .appleSpeechAnalyzer:
            return "Apple Speech uses advanced on-device recognition with fast, accurate transcription. Requires macOS 26+."
        case .parakeetTDT:
            return "Parakeet TDT v3 uses CoreML and Neural Engine for fastest transcription (25 languages) on Apple Silicon."
        case .parakeetTDTv2:
            return "Parakeet TDT v2 is an English-only model optimized for accuracy and consistency on Apple Silicon."
        case .parakeetRealtime:
            return "Parakeet Flash uses FluidAudio's true streaming EOU pipeline for low-latency English dictation. Best when you want words to appear live as you speak."
        case .qwen3Asr:
            return "Qwen3 ASR is a multilingual FluidAudio model with strong quality, but higher memory usage. Requires macOS 15+."
        case .cohereTranscribeSixBit:
            return "Cohere Transcribe downloads a CoreML pipeline from Hugging Face and caches it locally. Select the language manually before dictation. Best on Apple Silicon with 8GB+ RAM."
        case .nemotronOffline:
            return "Nemotron 3.5 Multilingual is slower but more accurate. Supports around 40 languages with auto or manual language selection. Best on Apple Silicon with 8GB+ RAM."
        case .nemotronStreaming, .nemotronStreaming320:
            return "Nemotron Speech 3.5 Streaming Capable uses NVIDIA's streaming CoreML pipeline. Supports around 40 languages with auto or manual language selection."
        default:
            return "Whisper models support 99 languages and work on any Mac."
        }
    }

    func downloadModels() async {
        do {
            try await self.asr.ensureAsrReady()
        } catch {
            DebugLogger.shared.error("Failed to download models: \(error)", source: "AISettingsView")
            self.asr.errorTitle = "Model Download Failed"
            self.asr.errorMessage = error.localizedDescription
            self.asr.showError = true
        }
    }

    func deleteModels() async {
        do {
            try await self.asr.clearModelCache()
            let model = self.settings.selectedSpeechModel
            if model.requiresExternalArtifacts {
                self.settings.setExternalCoreMLArtifactsDirectory(nil, for: model)
                self.asr.resetTranscriptionProvider()
            }
        } catch {
            DebugLogger.shared.error("Failed to delete models: \(error)", source: "AISettingsView")
        }
    }

    func setSelectedSpeechProvider(_ provider: SettingsStore.SpeechModel.Provider) {
        self.selectedSpeechProvider = provider
    }

    func openExternalModelSource(for model: SettingsStore.SpeechModel) {
        guard let url = model.externalCoreMLSpec?.sourceURL else { return }
        NSWorkspace.shared.open(url)
    }
}
