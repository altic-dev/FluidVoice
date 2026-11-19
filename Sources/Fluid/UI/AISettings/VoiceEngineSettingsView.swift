import SwiftUI

struct VoiceEngineSettingsView: View {
    @ObservedObject var viewModel: VoiceEngineSettingsViewModel
    @ObservedObject var settings: SettingsStore
    @Environment(\.fluidPagePrewarmState) private var prewarmState
    @Environment(\.colorScheme) var colorScheme
    @State var isShowingNemotronLanguagePicker = false
    @State var isShowingWhisperLanguagePicker = false
    @State var whisperLanguageSearchText = ""
    @State var isShowingAppleSpeechLocalePicker = false
    @State var appleSpeechLocaleSearchText = ""
    @State var appleSpeechLocaleOptions: [AppleSpeechLocaleOption] = []
    let theme: AppTheme

    var voiceEngineTitleText: Color {
        Color(nsColor: .labelColor)
    }

    var voiceEngineSecondaryText: Color {
        self.colorScheme == .light ? Color(nsColor: .labelColor).opacity(0.90) : self.theme.palette.primaryText.opacity(0.82)
    }

    var voiceEngineTertiaryText: Color {
        self.colorScheme == .light ? Color(nsColor: .labelColor).opacity(0.85) : self.theme.palette.secondaryText
    }

    private var isPrewarming: Bool {
        self.prewarmState?.isPrewarming == true
    }

    var body: some View {
        self.speechRecognitionCard
            .onAppear { self.viewModel.onAppear(isPrewarming: self.isPrewarming) }
            .onChange(of: self.settings.selectedSpeechModel) { _, newValue in
                self.viewModel.handleSelectedSpeechModelChange(newValue)
            }
    }
}
