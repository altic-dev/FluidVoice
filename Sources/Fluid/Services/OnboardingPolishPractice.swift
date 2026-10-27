import Foundation

enum FluidIntelligenceInvitation {
    static let dismissedKey = "FluidIntelligenceInvitationDismissed"
    static let usedKey = "HasUsedFluidIntelligence"

    static func shouldShow(available: Bool, dismissed: Bool, hasUsed: Bool) -> Bool {
        available && !dismissed && !hasUsed
    }

    static func recordSuccess(output: String, defaults: UserDefaults) {
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        defaults.set(true, forKey: self.usedKey)
    }
}

/// Local practice progress; never writes dictation, provider, or persisted settings.
struct OnboardingPolishPractice {
    struct Example {
        let spoken: String
        let expected: String
    }

    static let examples = [
        Example(
            spoken: "I'm free at 7:30 tomorrow morning. Would you be available for a quick call? Sorry, I meant 9:30 am.",
            expected: "I'm free at 9:30 am tomorrow morning. Would you be available for a quick call?"
        ),
        Example(
            spoken: "Grocery list. First one is apples, second one is milk, third one is egg.",
            expected: "Grocery list\n\n1. Apples\n2. Milk\n3. Egg"
        ),
        Example(
            spoken: "I think I'm gonna meet you tomorrow at 3 p.m. Let me know if the time works. If not, we can figure out some other time. Also, I think you need to fix the bug. Please let me know if you need some help there.",
            expected: "I think I'm gonna meet you tomorrow at 3 p.m. Let me know if the time works. If not, we can figure out some other time.\n\nAlso, I think you need to fix the bug. Please let me know if you need some help there."
        ),
    ]

    private(set) var index = 0
    private(set) var results: [Int: String] = [:]
    private var awaitingOutput = false
    var example: Example { Self.examples[self.index] }
    var result: String? { self.results[self.index] }
    var isLast: Bool { self.index == Self.examples.count - 1 }

    mutating func beginAttempt() {
        self.awaitingOutput = true
        self.results[self.index] = nil
    }

    mutating func receive(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self.awaitingOutput, !text.isEmpty else { return }
        self.results[self.index] = text
        self.awaitingOutput = false
    }

    @discardableResult
    mutating func advance(isBusy: Bool) -> Bool {
        guard !isBusy, self.result != nil, !self.isLast else { return false }
        self.index += 1
        self.awaitingOutput = false
        return true
    }
}
