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
    @Binding var activeShortcutRecordingTarget: ShortcutRecordingTarget?
    @Binding var shortcutRecordingMessage: String?

    @StateObject private var viewModel: AIEnhancementSettingsViewModel

    init(
        menuBarManager: MenuBarManager,
        theme: AppTheme,
        activeShortcutRecordingTarget: Binding<ShortcutRecordingTarget?> = .constant(nil),
        shortcutRecordingMessage: Binding<String?> = .constant(nil)
    ) {
        self.menuBarManager = menuBarManager
        self.theme = theme
        _activeShortcutRecordingTarget = activeShortcutRecordingTarget
        _shortcutRecordingMessage = shortcutRecordingMessage
        _viewModel = StateObject(wrappedValue: AIEnhancementSettingsViewModel(
            settings: SettingsStore.shared,
            menuBarManager: menuBarManager,
            promptTest: DictationPromptTestCoordinator.shared
        ))
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                AIEnhancementSettingsView(
                    viewModel: self.viewModel,
                    settings: self.viewModel.settings,
                    promptTest: self.viewModel.promptTest,
                    theme: self.theme,
                    activeShortcutRecordingTarget: self.$activeShortcutRecordingTarget,
                    shortcutRecordingMessage: self.$shortcutRecordingMessage
                )
            }
            .padding(14)
        }
    }
}
