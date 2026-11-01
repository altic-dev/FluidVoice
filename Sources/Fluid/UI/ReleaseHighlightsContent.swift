import Foundation

/// Edit this definition for each release. The renderer and acknowledgement logic stay unchanged.
struct ReleaseHighlightsContent {
    enum Destination { case meetings, dashboard, aiProviders, voiceEngine }
    enum Preview { case meeting, dashboard, models, speech }

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
        let splash = Feature(
            id: "splash",
            preview: .models,
            eyebrow: "RESEARCH PREVIEW",
            title: "Meet Fluid 1.1 Splash",
            detail: "Our best cleanup model yet. Multilingual, and it reads what's on screen so names and terms come out right.",
            action: "Try Splash",
            destination: .aiProviders
        )
        let speechPro = Feature(
            id: "speech-pro",
            preview: .speech,
            eyebrow: "NEW SPEECH MODEL",
            title: "Fluid Speech Pro",
            detail: "Our most accurate speech model, built for clear dictation in noisy places. Runs on your Mac.",
            action: "Open Voice Engine",
            destination: .voiceEngine
        )
        return Self(
            release: "1.6.13-beta.2",
            title: hasPrivateAI ? "Smarter cleanup, sharper speech" : "Sharper speech",
            subtitle: hasPrivateAI
                ? "Meet Fluid 1.1 Splash and Fluid Speech Pro. Plus Qwen dictation, smoother live captions and faster cleanup on M5 Macs."
                : "Meet Fluid Speech Pro. Plus Qwen dictation and smoother live captions.",
            officialSiteNotice: "**Help people find the real FluidVoice.** A site impersonating FluidVoice is appearing above us in search results, making it harder for people to find us. "
                + "Our official websites are [fluidvoice.com](https://fluidvoice.com) and [altic.dev/fluid](https://altic.dev/fluid). "
                + "If FluidVoice has helped you, please visit [fluidvoice.com](https://fluidvoice.com) and explore. Bookmark and share it to help others find the real app. Thank you for supporting us.",
            features: hasPrivateAI ? [splash, speechPro] : [speechPro]
        )
    }
}
