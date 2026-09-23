import Foundation

/// Edit this definition for each release. The renderer and acknowledgement logic stay unchanged.
struct ReleaseHighlightsContent {
    enum Destination { case meetings, dashboard, aiProviders }
    enum Preview { case meeting, dashboard, models }

    struct Feature: Identifiable {
        let id: String
        let preview: Preview
        let eyebrow: String
        let title: String
        let detail: String
        let action: String
        let destination: Destination
    }

    let release: String
    let title: String
    let subtitle: String
    let features: [Feature]

    static func current(hasPrivateAI: Bool) -> Self {
        Self(
            release: "1.6.10",
            title: "Say hello to what’s new.",
            subtitle: "Three new ways to make FluidVoice yours.",
            features: [
                Feature(
                    id: "fluidmeet",
                    preview: .meeting,
                    eyebrow: "MEETINGS, MEET FLUID",
                    title: "Introducing FluidMeet",
                    detail: "Stay in the conversation. Local recording, live captions, and AI summaries.",
                    action: "Open FluidMeet",
                    destination: .meetings
                ),
                Feature(
                    id: "redesign",
                    preview: .dashboard,
                    eyebrow: "A FRESH PERSPECTIVE",
                    title: "Beautifully redesigned",
                    detail: "Your own dashboard. Search across the app. Everything feels right at home.",
                    action: "See the new look",
                    destination: .dashboard
                ),
                Feature(
                    id: "models",
                    preview: .models,
                    eyebrow: hasPrivateAI ? "ON YOUR MAC. FOR YOU." : "YOUR AI, YOUR WAY",
                    title: hasPrivateAI ? "Meet the Fluid models" : "Find your AI",
                    detail: hasPrivateAI
                        ? "Fast cleanup to thoughtful rewrites. Explore local AI built for your words."
                        : "Choose your AI provider and make every dictation sound more like you.",
                    action: hasPrivateAI ? "Explore the models" : "Explore AI providers",
                    destination: .aiProviders
                ),
            ]
        )
    }
}
