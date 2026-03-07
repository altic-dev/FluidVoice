import SwiftUI

struct VoiceEngineSettingsView: View {
    @ObservedObject var viewModel: VoiceEngineSettingsViewModel
    @ObservedObject var settings: SettingsStore
    let theme: AppTheme

    var body: some View {
        self.speechRecognitionCard
            .onAppear { self.viewModel.onAppear() }
            .onChange(of: self.settings.selectedSpeechModel) { newValue in
                self.viewModel.handleSelectedSpeechModelChange(newValue)
            }
    }
}
