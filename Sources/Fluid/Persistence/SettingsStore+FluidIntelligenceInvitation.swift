import Combine
import Foundation

extension SettingsStore {
    var fluidIntelligenceInvitationDismissed: Bool {
        get { UserDefaults.standard.bool(forKey: FluidIntelligenceInvitation.dismissedKey) }
        set {
            self.objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: FluidIntelligenceInvitation.dismissedKey)
        }
    }

    var hasUsedFluidIntelligence: Bool {
        UserDefaults.standard.bool(forKey: FluidIntelligenceInvitation.usedKey)
    }

    func recordFluidIntelligenceUse(output: String) {
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !self.hasUsedFluidIntelligence else { return }
        self.objectWillChange.send()
        FluidIntelligenceInvitation.recordSuccess(output: output, defaults: .standard)
    }
}
