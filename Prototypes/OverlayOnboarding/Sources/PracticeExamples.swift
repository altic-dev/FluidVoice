// Verbatim examples from the earlier onboarding cleanup carousel in the original checkout.
// Source: Sources/Fluid/UI/OnboardingCleanupExampleCarousel.swift, correction and list entries.
enum PracticeExamples {
    struct Item {
        let label: String
        let title: String
        let spoken: String
        let cleaned: String
    }
    static let items = [
        Item(label: "Correction", title: "Understand when you change your mind", spoken: "I'm free at 7:30 tomorrow morning. Would you be available for a quick call? Sorry, I meant 9:30 am.", cleaned: "I'm free at 9:30 am tomorrow morning. Would you be available for a quick call?"),
        Item(label: "List & numbers", title: "Turn your rambling into lists", spoken: "Grocery list. First one is apples, second one is milk, third one is egg.", cleaned: "Grocery list\n\n1. Apples\n2. Milk\n3. Egg")
    ]
}
