import SwiftUI

enum AIEnhancementConfigurationSection: String {
    case providers
    case advancedPrompts

    var sidebarItem: SidebarItem {
        switch self {
        case .providers:
            return .aiEnhancements
        case .advancedPrompts:
            return .cleanupStyles
        }
    }
}

extension SidebarItem {
    var aiEnhancementConfigurationSection: AIEnhancementConfigurationSection? {
        switch self {
        case .aiEnhancements:
            return .providers
        case .cleanupStyles:
            return .advancedPrompts
        default:
            return nil
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
    @Binding var selectedConfigurationSection: AIEnhancementConfigurationSection
    @Binding var activeShortcutRecordingTarget: ShortcutRecordingTarget?
    @Binding var shortcutRecordingMessage: String?
    @State var expandedProviderID: String? = nil
    @State var providerSearchText: String = ""
    @State var privateAISelectedModelID: String = PrivateAIIntegrationService.configuredModelID
    @State var privateAILoadState: PrivateAIModelLoadState = .idle
    @State var privateAIModelUpdateStatusByID: [String: PrivateAIModelUpdateStatus] = [:]
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
                self.refreshPrivateAIModelUpdateStatus(self.selectedPrivateAIModel)
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

    var customPromptOnlyToggleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "text.quote")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(self.theme.palette.accent)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text("Send Custom Prompt Only")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(self.theme.palette.primaryText)
                Text("For custom Dictate prompts, send your prompt without prepending the built-in dictation prompt.")
                    .font(.caption2)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: Binding(
                get: { self.viewModel.sendCustomPromptOnly },
                set: { self.viewModel.setSendCustomPromptOnly($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .help("Send custom Dictate prompts without prepending the built-in dictation prompt.")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(self.theme.palette.cardBackground.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.32), lineWidth: 1)
                )
        )
    }
}
