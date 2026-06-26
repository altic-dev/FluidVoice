import SwiftUI

struct VoiceEngineSettingsView: View {
    @ObservedObject var viewModel: VoiceEngineSettingsViewModel
    @ObservedObject var settings: SettingsStore
    @Environment(\.colorScheme) var colorScheme
    @State var isShowingNemotronLanguagePicker = false
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

    var body: some View {
        self.speechRecognitionCard
            .onAppear { self.viewModel.onAppear() }
            .onChange(of: self.settings.selectedSpeechModel) { _, newValue in
                self.viewModel.handleSelectedSpeechModelChange(newValue)
            }
    }
}
