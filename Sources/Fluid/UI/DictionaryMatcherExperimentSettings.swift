import SwiftUI

struct DictionaryMatcherExperimentSettings: View {
    @AppStorage("DictionarySharedFeatureMatcherEnabled") private var enabled = DictionaryMatcherExperiment.defaultEnabled

    var body: some View {
        FluidSettingsRow(title: "Learn from your pronunciation") {
            Toggle("Learn from your pronunciation", isOn: Binding(
                get: { self.enabled },
                set: { DictionaryMatcherExperiment.setEnabled($0) }
            ))
            .fluidSwitch()
            .accessibilityLabel("Learn from your pronunciation")
        }
    }
}
