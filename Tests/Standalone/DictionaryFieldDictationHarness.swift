// Standalone UI regression fixture. Compile alongside DictionaryFieldDictation.swift.
// In First, select "world", then Cmd-1: expect "Hello FluidVoice"; Second stays untouched.
// Cmd-2 simulates training: neither field changes. Cmd-3 moves focus before completion:
// neither field changes. Repeat Cmd-1 in Second to verify repeated identical transcripts.
import AppKit
import Combine
import SwiftUI

final class ASRFixture: ObservableObject {
    @Published var isRunning = false
    @Published var finalText = ""
    @Published var showError = false
    var isDictionaryTrainingCaptureActive = false
}

final class AppServices: ObservableObject { let asr = ASRFixture() }
struct Demo: View {
    @StateObject var services = AppServices()
    @State var first = "Hello world"
    @State var second = "Untouched"
    @FocusState var focus: Int?
    var body: some View {
        VStack {
            TextField("First", text: self.$first).focused(self.$focus, equals: 1).dictionaryDictationInput(focused: self.focus == 1)
            TextField("Second", text: self.$second).focused(self.$focus, equals: 2).dictionaryDictationInput(focused: self.focus == 2)
            Button("Dictate") { self.run(training: false, move: false) }.keyboardShortcut("1")
            Button("Training") { self.run(training: true, move: false) }.keyboardShortcut("2")
            Button("Change focus") { self.run(training: false, move: true) }.keyboardShortcut("3")
            Text(self.first + " | " + self.second)
        }.padding(30).frame(width: 600, height: 220).environmentObject(self.services)
    }

    func run(training: Bool, move: Bool) {
        self.services.asr.isDictionaryTrainingCaptureActive = training
        self.services.asr.isRunning = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            if move { self.focus = 2 }
            self.services.asr.isRunning = false
            try? await Task.sleep(for: .milliseconds(150))
            self.services.asr.finalText = "FluidVoice"
        }
    }
}

@main struct Fixture: App { var body: some Scene { WindowGroup { Demo() }}}
