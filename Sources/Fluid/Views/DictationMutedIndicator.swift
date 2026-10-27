import SwiftUI

struct DictationMutedIndicator: View {
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "mic.slash.fill")
            if !self.compact {
                Text("Muted")
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.orange)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dictation muted. Release Space to resume.")
        .help("Release Space to resume dictation")
    }
}
