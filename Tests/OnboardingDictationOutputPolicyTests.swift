@main
struct OnboardingDictationOutputPolicyTests {
    static func main() {
        var cases = 0
        for active in [false, true] {
            for dictation in [false, true] {
                for target: Int32? in [nil, 100, 200] {
                    let actual = OnboardingDictationOutputPolicy.usesSandbox(
                        onboardingPracticeActive: active,
                        isDictation: dictation,
                        targetProcessID: target,
                        fluidVoiceProcessID: 100
                    )
                    precondition(actual == (active && dictation && target != 200))
                    cases += 1
                }
            }
        }
        print("Passed \(cases) onboarding output routing cases")
    }
}
