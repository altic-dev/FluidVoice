import Foundation

@main
struct OnboardingPolishPracticeTests {
    static func main() {
        var practice = OnboardingPolishPractice()
        practice.receive("Stale result from earlier onboarding")
        precondition(practice.result == nil)
        precondition(!practice.advance(isBusy: false))
        practice.beginAttempt()
        practice.receive(" \n ")
        precondition(practice.result == nil)
        precondition(!practice.advance(isBusy: false))
        practice.receive("Hey John,\nHow are you doing today?")
        precondition(practice.result != nil)
        precondition(!practice.advance(isBusy: true))
        precondition(practice.index == 0)
        precondition(practice.advance(isBusy: false))
        precondition(!practice.advance(isBusy: false))
        practice.receive("Late duplicate")
        precondition(practice.result == nil && practice.results.count == 1)
        practice.beginAttempt()
        practice.receive("Correction result")
        practice.beginAttempt()
        precondition(practice.result == nil && practice.results[0] != nil)
        practice.receive("")
        precondition(!practice.advance(isBusy: false))
        practice.receive("Retried correction")
        precondition(practice.advance(isBusy: false))
        practice.beginAttempt()
        practice.receive("Grocery list:\n- banana\n- apple\n- orange")
        precondition(practice.isLast && practice.results.count == 3)
        precondition(!practice.advance(isBusy: false))
        precondition(practice.index == 2)
        print("Practice progression, empty/failure, retry, busy, stale output, and bounded final-step checks passed")
    }
}
