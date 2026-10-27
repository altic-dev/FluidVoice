/// Onboarding previews only own recordings aimed at FluidVoice, never other apps.
enum OnboardingDictationOutputPolicy {
    static func usesSandbox(
        onboardingPracticeActive: Bool,
        isDictation: Bool,
        targetProcessID: Int32?,
        fluidVoiceProcessID: Int32
    ) -> Bool {
        guard onboardingPracticeActive, isDictation else { return false }
        // An unknown target stays in the preview instead of writing to an arbitrary app.
        guard let targetProcessID else { return true }
        return targetProcessID == fluidVoiceProcessID
    }
}
