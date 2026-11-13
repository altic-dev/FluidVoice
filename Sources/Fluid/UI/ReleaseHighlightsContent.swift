import Foundation

/// Edit this definition for each release. The renderer and acknowledgement logic stay unchanged.
struct ReleaseHighlightsContent {
    enum Destination { case meetings, dashboard, aiProviders, voiceEngine }
    enum Preview { case meeting, dashboard, ripple, splash, speech }

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
    let officialSiteNotice: String
    let features: [Feature]

    static func current(hasPrivateAI: Bool) -> Self {
        let ripple = Feature(
            id: "ripple",
            preview: .ripple,
            eyebrow: "FASTER CLEANUP",
            title: "Fluid 1.1 Ripple",
            detail: "Fast, multilingual cleanup on your Mac. Research preview: review your text before sending.",
            action: "Explore Ripple",
            destination: .aiProviders
        )
        let splash = Feature(
            id: "splash",
            preview: .splash,
            eyebrow: "HIGHER-QUALITY CLEANUP",
            title: "Fluid 1.1 Splash",
            detail: "Our most capable multilingual cleanup model. Research preview: review your text before sending.",
            action: "Explore Splash",
            destination: .aiProviders
        )
        let speechPro = Feature(
            id: "speech-pro",
            preview: .speech,
            eyebrow: "NEW SPEECH MODEL",
            title: "Fluid Speech Pro",
            detail: "Our most accurate dictation model. Runs on Apple Silicon, with support for 25 languages.",
            action: "Explore Speech Pro",
            destination: .voiceEngine
        )
        return Self(
            release: "1.6.13",
            title: hasPrivateAI ? "Better dictation. Smarter cleanup." : "Meet Fluid Speech Pro",
            subtitle: hasPrivateAI
                ? "Explore our latest on-device models for dictation and cleanup."
                : "On-device dictation in 25 languages, built for Apple Silicon.",
            officialSiteNotice: "**Help people find the real FluidVoice.** A site impersonating FluidVoice is appearing above us in search results, making it harder for people to find us. "
                + "Our official websites are [fluidvoice.com](https://fluidvoice.com) and [altic.dev/fluid](https://altic.dev/fluid). "
                + "If FluidVoice has helped you, please visit [fluidvoice.com](https://fluidvoice.com) and explore. Bookmark and share it to help others find the real app. Thank you for supporting us.",
            features: hasPrivateAI ? [speechPro, ripple, splash] : [speechPro]
        )
    }
}
