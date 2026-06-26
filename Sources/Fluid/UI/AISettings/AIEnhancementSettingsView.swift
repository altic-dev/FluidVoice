import SwiftUI

enum AIEnhancementConfigurationSection: String, CaseIterable, Identifiable {
    case providers
    case advancedPrompts

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .providers:
            return "AI Providers"
        case .advancedPrompts:
            return "Advanced Prompts"
        }
    }

    var systemImage: String {
        switch self {
        case .providers:
            return "cpu"
        case .advancedPrompts:
            return "slider.horizontal.3"
        }
    }
}

enum PrivateAIModelLoadState: Equatable {
    case idle
    case downloading(modelID: String, progress: PrivateAIModelDownloadProgress?)
    case loading(modelID: String)
    case loaded(modelID: String, latencyMilliseconds: Int?)
    case failed(modelID: String, message: String)

    func isLoading(_ modelID: String) -> Bool {
        if case .loading(modelID) = self { return true }
        return false
    }

    func isDownloading(_ modelID: String) -> Bool {
        if case .downloading(modelID, _) = self { return true }
        return false
    }

    func isLoaded(_ modelID: String) -> Bool {
        if case .loaded(modelID, _) = self { return true }
        return false
    }

    func latencyMilliseconds(for modelID: String) -> Int? {
        if case let .loaded(loadedModelID, latencyMilliseconds) = self, loadedModelID == modelID {
            return latencyMilliseconds
        }
        return nil
    }

    func failureMessage(for modelID: String) -> String? {
        if case let .failed(failedModelID, message) = self, failedModelID == modelID {
            return message
        }
        return nil
    }

    func downloadProgress(for modelID: String) -> PrivateAIModelDownloadProgress? {
        if case let .downloading(downloadingModelID, progress) = self, downloadingModelID == modelID {
            return progress
        }
        return nil
    }
}

struct AIEnhancementSettingsView: View {
    @ObservedObject var viewModel: AIEnhancementSettingsViewModel
    @ObservedObject var settings: SettingsStore
    @ObservedObject var promptTest: DictationPromptTestCoordinator
    let theme: AppTheme
    @Binding var activeShortcutRecordingTarget: ShortcutRecordingTarget?
    @Binding var shortcutRecordingMessage: String?
    @State var expandedProviderID: String? = nil
    @State var providerSearchText: String = ""
    @State var privateAISelectedModelID: String = PrivateAIIntegrationService.configuredModelID
    @State var privateAILoadState: PrivateAIModelLoadState = .idle
    @State var selectedConfigurationSection: AIEnhancementConfigurationSection = .providers
    @State var hoveredConfigurationSection: AIEnhancementConfigurationSection?
    @State var hoveredPromptCardKey: String? = nil
    @State var selectedPromptMode: SettingsStore.PromptMode = .dictate
    @State var hoveredPromptModeKey: String? = nil
    @State var hoveredPromptScopeKey: String? = nil
    @State var isPromptProfilesHelpPresented: Bool = false
    @State var promptEditorPrimarySelectionDraft: SettingsStore.DictationPromptSelection? = nil
    @State var promptEditorShortcutDraft: HotkeyShortcut? = nil
    @State var promptEditorProviderIDDraft: String = ""
    @State var promptEditorModelDraft: String = ""
    @State var promptEditorOriginalConfiguration: SettingsStore.DictationPromptConfiguration? = nil

    var body: some View {
        self.aiConfigurationCard
            .onAppear {
                self.viewModel.onAppear()
                self.privateAISelectedModelID = PrivateAIIntegrationService.configuredModelID
                self.refreshPrivateAILoadState()
            }
            .onChange(of: self.viewModel.connectionStatus) { oldValue, newValue in
                if oldValue == .success && newValue != .success {
                    self.expandedProviderID = self.viewModel.selectedProviderID
                }
            }
            .onChange(of: self.viewModel.showKeychainPermissionAlert) { _, isPresented in
                guard isPresented else { return }
                self.viewModel.presentKeychainAccessAlert(message: self.viewModel.keychainPermissionMessage)
                self.viewModel.showKeychainPermissionAlert = false
            }
            .alert("Delete Prompt?", isPresented: self.$viewModel.showingDeletePromptConfirm) {
                Button("Delete", role: .destructive) {
                    self.viewModel.deletePendingPrompt()
                }
                Button("Cancel", role: .cancel) {
                    self.viewModel.clearPendingDeletePrompt()
                }
            } message: {
                if self.viewModel.pendingDeletePromptName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("This cannot be undone.")
                } else {
                    Text("Delete “\(self.viewModel.pendingDeletePromptName)”? This cannot be undone.")
                }
            }
            .alert(
                "Couldn't Add App Override",
                isPresented: Binding(
                    get: { !self.viewModel.appPromptBindingErrorMessage.isEmpty },
                    set: { isPresented in
                        if !isPresented {
                            self.viewModel.appPromptBindingErrorMessage = ""
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {
                    self.viewModel.appPromptBindingErrorMessage = ""
                }
            } message: {
                Text(self.viewModel.appPromptBindingErrorMessage)
            }
    }
}
