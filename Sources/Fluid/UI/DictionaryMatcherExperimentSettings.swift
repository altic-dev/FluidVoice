import SwiftUI

struct DictionaryMatcherExperimentSettings: View {
    @Environment(\.theme) private var theme
    @AppStorage("DictionarySharedFeatureMatcherEnabled") private var enabled = DictionaryMatcherExperiment.defaultEnabled

    var body: some View {
        HStack {
            Text("Learn from your pronunciation")
                .font(self.theme.typography.bodyStrong)
            Spacer()
            Toggle("Learn from your pronunciation", isOn: Binding(
                get: { self.enabled },
                set: { DictionaryMatcherExperiment.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .tint(self.theme.palette.accent)
            .labelsHidden()
            .accessibilityLabel("Learn from your pronunciation")
        }
    }
}
