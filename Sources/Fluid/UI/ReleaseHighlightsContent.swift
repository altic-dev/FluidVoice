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
    let officialSiteNotice: String
    let features: [Feature]

    static func current(hasPrivateAI: Bool) -> Self {
        Self(
            release: "1.6.12",
            title: "Meeting summaries and agent integrations",
            subtitle: "Summarize meetings on your Mac or with your AI provider. Connect your coding agents from FluidMeet settings.",
            officialSiteNotice: "**Help people find the real FluidVoice.** A site impersonating FluidVoice is appearing above us in search results, making it harder for people to find us. "
                + "Our official websites are [fluidvoice.com](https://fluidvoice.com) and [altic.dev/fluid](https://altic.dev/fluid). "
                + "If FluidVoice has helped you, please visit [fluidvoice.com](https://fluidvoice.com) and explore. Bookmark and share it to help others find the real app. Thank you for supporting us.",
            features: [
                Feature(
                    id: "summaries",
                    preview: .meeting,
                    eyebrow: "YOUR MEETINGS, SUMMARIZED",
                    title: "Meeting summaries are back",
                    detail: "Summarize on your Mac or with your own AI provider. Add a custom prompt and keep your summaries after restarting.",
                    action: "Open FluidMeet",
                    destination: .meetings
                ),
                Feature(
                    id: "integrations",
                    preview: .meeting,
                    eyebrow: "MEET YOUR CODING AGENTS",
                    title: "Connect your coding agents",
                    detail: "Let Claude Code, Codex and other coding agents read your meetings. Set them up in FluidMeet settings → Integrations.",
                    action: "Open FluidMeet",
                    destination: .meetings
                ),
            ]
        )
    }
}
