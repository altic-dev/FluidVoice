import SwiftUI

extension Notification.Name {
    /// Opens Settings at Experimental, where the on-screen context switches live.
    static let openScreenContextSettings = Notification.Name("OpenScreenContextSettings")
}

/// Shows on the card of a model trained to read the screen whether on-screen
/// context is on. Clicking it opens the settings that turn it on or off.
struct ScreenContextChip: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var settings: SettingsStore

    private var isOn: Bool { self.settings.dictationScreenContextEnabled }

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .openScreenContextSettings, object: nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: self.isOn ? "checkmark.circle.fill" : "circle")
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(self.isOn ? FluidBrandColors.blue : self.theme.palette.secondaryText)
                Text("On-screen context")
                    .foregroundStyle(self.isOn ? self.theme.palette.primaryText : self.theme.palette.secondaryText)
                Image(systemName: "chevron.right")
                    .font(.fluidSystem(size: 9, weight: .semibold))
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            .font(self.theme.typography.captionStrong)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(self.isOn ? FluidBrandColors.blue.opacity(0.16) : self.theme.palette.secondaryText.opacity(0.08))
            )
            .overlay(
                Capsule().strokeBorder(self.isOn ? FluidBrandColors.blue.opacity(0.45) : self.theme.palette.cardBorder, lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(self.reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: self.isOn)
        .help(self.isOn ? "On. Click to change it in Settings." : "Off. Click to turn it on in Settings.")
        .accessibilityLabel("On-screen context, \(self.isOn ? "on" : "off")")
        .accessibilityHint("Opens the setting in Settings, Experimental.")
    }
}
