import SwiftUI

struct VoiceEngineSettingsScreen: View {
    let appServices: AppServices
    let theme: AppTheme

    @StateObject private var viewModel: VoiceEngineSettingsViewModel

    init(appServices: AppServices, theme: AppTheme) {
        self.appServices = appServices
        self.theme = theme
        _viewModel = StateObject(wrappedValue: VoiceEngineSettingsViewModel(
            settings: SettingsStore.shared,
            appServices: appServices
        ))
    }

    var body: some View {
        VoiceEngineSettingsView(
            viewModel: self.viewModel,
            settings: self.viewModel.settings,
            theme: self.theme
        )
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct AIEnhancementSettingsScreen: View {
    let menuBarManager: MenuBarManager
    let theme: AppTheme
    @Binding var selectedConfigurationSection: AIEnhancementConfigurationSection
    @Binding var activeShortcutRecordingTarget: ShortcutRecordingTarget?
    @Binding var shortcutRecordingMessage: String?

    @StateObject private var viewModel: AIEnhancementSettingsViewModel
    @StateObject private var privateAIController: PrivateAISettingsController

    init(
        menuBarManager: MenuBarManager,
        theme: AppTheme,
        selectedConfigurationSection: Binding<AIEnhancementConfigurationSection> = .constant(.providers),
        activeShortcutRecordingTarget: Binding<ShortcutRecordingTarget?> = .constant(nil),
        shortcutRecordingMessage: Binding<String?> = .constant(nil)
    ) {
        self.menuBarManager = menuBarManager
        self.theme = theme
        _selectedConfigurationSection = selectedConfigurationSection
        _activeShortcutRecordingTarget = activeShortcutRecordingTarget
        _shortcutRecordingMessage = shortcutRecordingMessage
        let enhancementModel = AIEnhancementSettingsViewModel(
            settings: SettingsStore.shared,
            menuBarManager: menuBarManager,
            promptTest: DictationPromptTestCoordinator.shared
        )
        _viewModel = StateObject(wrappedValue: enhancementModel)
        _privateAIController = StateObject(wrappedValue: PrivateAISettingsController(viewModel: enhancementModel))
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                AIEnhancementSettingsView(
                    viewModel: self.viewModel,
                    privateAIController: self.privateAIController,
                    settings: self.viewModel.settings,
                    promptTest: self.viewModel.promptTest,
                    theme: self.theme,
                    selectedConfigurationSection: self.$selectedConfigurationSection,
                    activeShortcutRecordingTarget: self.$activeShortcutRecordingTarget,
                    shortcutRecordingMessage: self.$shortcutRecordingMessage
                )
            }
            .padding(14)
        }
    }
}
