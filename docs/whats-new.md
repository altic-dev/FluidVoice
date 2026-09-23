# What’s New release maintenance

`Sources/Fluid/UI/ReleaseHighlightsContent.swift` is the release definition. Keep the shared presenter, layout, and controls unchanged when updating copy.

For each release:

1. Set `release` to the stable version family (for example `1.6.11`). Its beta versions use the same content.
2. Replace the title, subtitle, and one to three feature entries. Each entry has a stable ID, preview, short copy, action label, and typed destination. Keep private-only features conditional.
3. Reuse a preview kind or add a small static product illustration in `ReleaseFeaturePreview.swift`. Do not load models, user documents, hardware state, or network data for a preview.
4. Run `sh Tests/run_release_highlights_tests.sh` with a full Xcode selected. CI runs this too and rejects content that does not match `Info.plist`.
5. Check the installed popup in both appearances, its X/Escape close actions, and each destination. Keep the separate release notes updated.

## Presentation contract

- Automatically appears in the active main window when onboarding and blocking work have finished. It waits for other sheets to close.
- A main-thread coordinator grants one presentation at a time across windows. Session tokens reject stale dismissal callbacks.
- Acknowledge the full marketing version only after dismissal, including beta suffixes. Beta 7, beta 8, and stable are separate updates; rebuilding the same version does not repeat the popup.
- Store the last 32 acknowledged versions in the local `FluidVoiceSeenReleaseHighlightVersions` preference. No telemetry is sent. Recent downgrades do not repeat acknowledged highlights.
- If recording/processing starts, close without acknowledging or navigating. Retry when eligible. Closing the host window also releases ownership without acknowledging.
- Feature buttons dismiss first, then navigate only if the app is still eligible. Double clicks cannot queue multiple destinations. Closing with X/Escape never navigates.
- Help → What’s new reopens the current release manually, even after acknowledgement.
- Copy edits within an already-acknowledged app version do not reopen the popup. Bump the app version when shipping a new update. Unknown version families never display stale highlights.
