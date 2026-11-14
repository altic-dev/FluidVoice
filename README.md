# FluidVoice

<p align="center">
  <a href="https://github.com/altic-dev/FluidVoice/stargazers"><img src="https://img.shields.io/github/stars/altic-dev/FluidVoice?style=social" alt="GitHub stars"/></a>
  <a href="https://github.com/sponsors/altic-dev"><img src="https://img.shields.io/badge/Sponsor-GitHub%20Sponsors-ea4aaa?logo=githubsponsors&logoColor=white" alt="Sponsor FluidVoice"/></a>
  <a href="https://x.com/fluidvoiceapp"><img src="https://img.shields.io/badge/X-%40fluidvoiceapp-black?logo=x&logoColor=white" alt="X @fluidvoiceapp"/></a>
  <br />
  <a href="#supported-models"><img src="https://img.shields.io/badge/Speech-Fluid%20Speech%20Pro%20%7C%20Mini%20%7C%20Pico-blue" alt="Fluid Speech Pro, Mini and Pico"/></a>
  <a href="#fluid-intelligence"><img src="https://img.shields.io/badge/Cleanup-Fluid%201.1%20Ripple%20%7C%20Splash-blue" alt="Fluid 1.1 Ripple and Splash"/></a>
  <br /><br />
  <a href="https://trendshift.io/repositories/16601?utm_source=repository-badge&utm_medium=badge&utm_campaign=badge-repository-16601" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/repositories/16601" alt="altic-dev%2FFluidVoice | Trendshift" width="250" height="55"/></a>
</p>

**Free, private dictation that runs on your device.** Speak into the apps you already use, clean up your words locally, and keep a searchable record of your meetings.

This repository is the **macOS app**, open source under GPLv3. FluidVoice is also available on other devices through the betas below.

[Website](https://fluidvoice.com) · [Speech models](https://huggingface.co/FluidVoice-Labs) · [What’s new](https://github.com/altic-dev/FluidVoice/releases/tag/v1.6.13) · [iPhone beta](https://fluidvoice.com/fluid/ios)

**Install with Homebrew:** `brew install --cask fluidvoice`

**Manual download:** [latest release](https://github.com/altic-dev/FluidVoice/releases/latest)

> [!WARNING]
> **fluidvoice.org is not affiliated with, operated by, or endorsed by FluidVoice or Altic.** Its claims to be our official website are unauthorized.
>
> Our official website is [fluidvoice.com](https://fluidvoice.com). Our official domains also include **altic.dev** and **fluidvoice.app**.
>
> For official downloads, use this repository's [GitHub Releases](https://github.com/altic-dev/FluidVoice/releases).
>
> If **fluidvoice.org** appears in your search results claiming to be our official website, please report the misleading result to the search provider.

## Get FluidVoice

| Platform | Status | Download or join |
| --- | --- | --- |
| macOS | Available · macOS 15+ | [Latest release](https://github.com/altic-dev/FluidVoice/releases/latest) · `brew install --cask fluidvoice` |
| iOS | TestFlight beta | [Join the iPhone beta](https://fluidvoice.com/fluid/ios) |
| Windows | Beta | [Get the Windows beta](https://fluidvoice.com/fluid/download/windows) |
| Linux | Early beta | [Get the Linux beta](https://fluidvoice.com/fluid/download/linux) |
| Android | In progress | [Join the waitlist](https://fluidvoice.com/fluid/waitlist) |

Features and available models vary by platform. The features below describe the Mac app.

> [!IMPORTANT]
> This project is free and open source under GPLv3. If FluidVoice is useful to you, please star the repository — it helps visibility and keeps development going.

---

## Support FluidVoice

If FluidVoice helps you, you can support continued development, model training, and work across platforms on [GitHub Sponsors](https://github.com/sponsors/altic-dev).

---

## What's New in 1.6.13

- **Fluid Speech Pro** — our most accurate local dictation model for Apple Silicon. Pro, Mini, and Pico now support 25 languages.
- **Fluid 1.1 Ripple and Splash** — updated on-device text cleanup, with Ripple offering a smaller, faster option for lighter Macs. Both are research previews.
- **Edit Mode (Beta)** — a dedicated local Edit 1.1 model, with its own settings and support for your own AI providers.
- **Qwen3 ASR 1.7B** — another local speech option on Apple Silicon, with automatic detection of 30 languages.
- **Better FluidMeet** — improved call detection, app and microphone selection, Pro-powered transcripts, and the option to redo a saved meeting in another supported language.
- **Everyday improvements** — model recommendations on Dashboard, more reliable text delivery and downloads, improved spoken number formatting, custom accent colors, and shortcuts that distinguish left and right modifier keys.

[Read the full 1.6.13 release notes](https://github.com/altic-dev/FluidVoice/releases/tag/v1.6.13).

## Speech recognition and text cleanup

Two separate steps, both available locally:

1. **Fluid Speech** turns your audio into text. Choose Pro for accuracy, Mini for a smaller download, or Pico for the smallest footprint.
2. **Fluid Intelligence** optionally cleans up that text: remove fillers and false starts, format lists, and apply the writing style you choose for each app.

You can use dictation without cleanup, pair a speech model with local cleanup, or bring your own cloud AI provider.

## Fluid Intelligence

**Fluid 1.1** powers on-device dictation cleanup through Fluid Intelligence. No cloud account or API key is needed for local cleanup.

| Model | Best for | Approximate download |
| --- | --- | --- |
| **Fluid 1.1 Ripple** | Smaller, faster cleanup for lighter Macs | ~600 MB |
| **Fluid 1.1 Splash** | More accurate cleanup, including harder corrections | ~750 MB |

Ripple is almost twice as fast as Splash, with slightly lower accuracy. It can miss harder corrections that Splash catches.

On a smaller Apple Silicon Mac, **Fluid Speech Mini + Fluid 1.1 Ripple** is a good starting point. Choose speech and cleanup models separately in the app; Dashboard also recommends models for your Mac. Ripple and Splash are research previews, so review their changes before sending. Optional screen context is off by default.

The macOS app is open source under GPLv3. **Fluid Intelligence is a separate, privately maintained local AI runtime** included in official downloads; it is not part of this repository's source build. The app also works with supported speech models and optional cloud AI providers without Fluid Intelligence.

We're keeping Fluid Intelligence private for now so we can sustainably offer the core dictation experience for free. This may change in the future.

---

## FluidMeet

Record online or in-person meetings, with audio and transcription kept on your Mac.

- **Live captions and speaker labels** — follow the conversation and see who said what.
- **Local playback and editing** — replay individual segments, correct text, rename speakers, and merge speaker labels.
- **Summaries** — generate a summary on your Mac or with an AI provider you choose, then revisit it after restarting the app.
- **Meeting detection** — choose the meeting app and microphone, with start/end prompts and a cancellable stop countdown.
- **Redo and export** — transcribe saved audio again in another supported language, or export Markdown, text, and JSON with timestamps and speaker names.
- **Assistant integrations** — let Claude Code, Codex, and other local tools read meeting transcripts through FluidMeet's integration settings and local API.

[More about FluidMeet](https://fluidvoice.com/fluid/blog/fluidmeet).

## Fluid Intelligence demos

<table>
  <tr>
    <td width="50%" align="center"><b>Email Template</b></td>
    <td width="50%" align="center"><b>Flowers</b></td>
  </tr>
  <tr>
    <td width="50%"><video src="https://github.com/user-attachments/assets/36747e9d-1ea3-4d27-8d38-eaacb6d57285" width="100%"></video></td>
    <td width="50%"><video src="https://github.com/user-attachments/assets/5f6063ab-0506-4687-b825-c7bf4ab66ed6" width="100%"></video></td>
  </tr>
  <tr>
    <td width="50%" align="center"><b>Change Time & Name</b></td>
    <td width="50%" align="center"><b>Emoji</b></td>
  </tr>
  <tr>
    <td width="50%"><video src="https://github.com/user-attachments/assets/6c7a7c4c-17a8-453d-8eff-1aa1fa9f6077" width="100%"></video></td>
    <td width="50%"><video src="https://github.com/user-attachments/assets/04e00f3d-a602-448d-9bde-50b5e8f61ac6" width="100%"></video></td>
  </tr>
  <tr>
    <td width="50%" align="center"><b>Hyphens & Numbers</b></td>
    <td width="50%"></td>
  </tr>
  <tr>
    <td width="50%"><video src="https://github.com/user-attachments/assets/47175f2b-9f06-452e-b892-42488e4ba536" width="100%"></video></td>
    <td width="50%"></td>
  </tr>
</table>

## Demo

### Command Mode — Take any action on your Mac using FluidVoice

https://github.com/user-attachments/assets/ffb47afd-1621-432a-bdca-baa4b8526301

### Edit Mode — Write or rewrite text in any text box in any app

https://github.com/user-attachments/assets/c57ef6d5-f0a1-4a3f-a121-637533442c24

---

## Features

- **Fluid Intelligence** — on-device AI enhancement for smart formatting, context-aware capitalization, and post-processing, all running locally on your Mac with zero data leaving your machine
- **Command Mode** — control your Mac by voice: launch apps, run shortcuts, trigger system actions, and automate workflows without touching the keyboard
- **Edit Mode (Beta)** — write or rewrite text in place, using the local Edit 1.1 model on Apple Silicon or your own AI provider
- **Live Preview** — real-time transcription overlay with notch support, so you see words appear as you speak
- **Multiple Speech Models** — Fluid Speech Pro, Mini, and Pico; Nemotron Speech 3.5; Parakeet; Qwen3 ASR; Cohere Transcribe; Apple Speech; and Whisper. Pick the model that fits your language and Mac
- **AI Enhancement** — optional post-processing via OpenAI, Groq, custom providers, or local Fluid Intelligence for cleaner, more accurate transcripts
- **Audio History** — optional local recording history with budget controls and ZIP export, so you can review past dictations without cloud storage
- **Today-Usage Stats** — daily usage tracking at a glance with a stats header card and toolbar pill
- **Adaptive Theming** — light/dark theme that follows your system, with a compact toolbar switcher
- **Global Hotkey** — instant voice capture from anywhere, no app switching needed
- **Hold Space to Mute** — optional temporary mute within a dictation: hold Space while thinking, then release to continue the same recording; quick taps still type spaces
- **Smart Typing** — direct insertion into any app via accessibility APIs for reliable, app-independent text entry
- **Menu Bar Integration** — quick access, status, and settings from the menu bar
- **Auto-Updates** — seamless updates with an optional beta channel for early previews
- **Per-App Configuration** — assign different prompt sets to different apps, so your dictation adapts to whatever you're working in. Fully optional
- **Notch-Aware Overlay** — transcription overlay that fits cleanly around the MacBook notch, or use a standard overlay if your Mac doesn't have one
- **Local-First** — your voice and text never leave your machine unless you opt in to a cloud AI provider
- **Custom Dictionary** — save names, jargon, and instant replacements, with experimental pronunciation training for supported speech models
- **Global Search** — find dictations, meeting transcripts, dictionary entries, cleanup styles, and settings from one place
- **File Transcription** — turn saved audio files and voice notes into text locally
- **Configurable Overlay** — choose from pill-shaped to large overlay sizes to show live preview, or keep it minimal. Everything is optional
- **Everything is Optional** — AI enhancement, Fluid Intelligence, audio history, detailed analytics, and beta builds are optional. The core dictation experience works out of the box with zero configuration beyond permissions and a hotkey

---

## Supported Models

These are **speech-to-text models**, separate from the cleanup models above. Downloads below reflect the Mac app's model catalog; sizes can change with model updates.

| Model | Best for | Language support | Approximate download | Hardware |
| --- | --- | --- | --- | --- |
| [Fluid Speech Pro](https://fluidvoice.com/fluid/blog/fluidspeech-pro) | Our most accurate dictation model | [25 languages](#fluid-speech-and-parakeet-tdt-v3-languages) | 622 MiB | Apple Silicon |
| [Fluid Speech Mini](https://fluidvoice.com/labs/fluid-speech-mini) | Small download, clear dictation in noisy places | [25 languages](#fluid-speech-and-parakeet-tdt-v3-languages) | 242 MiB | Apple Silicon |
| Fluid Speech Pico | Smallest Fluid Speech model | [25 languages](#fluid-speech-and-parakeet-tdt-v3-languages) | 154 MiB | Apple Silicon |
| Nemotron Speech 3.5 — Ultra Fast Low Latency | Streaming-capable multilingual dictation | ~40 languages | 668 MiB | Apple Silicon |
| Nemotron 3.5 Multilingual | Multilingual dictation | ~40 languages | 531 MiB | Apple Silicon |
| [Parakeet Flash (Beta)](https://huggingface.co/nvidia/parakeet_realtime_eou_120m-v1) | Live English dictation | English | 428 MiB | Apple Silicon |
| Parakeet TDT v3 | Fast multilingual dictation | [25 languages](#fluid-speech-and-parakeet-tdt-v3-languages) | 461 MiB | Apple Silicon |
| Parakeet TDT v2 | Fast English dictation | English | 443 MiB | Apple Silicon |
| Qwen3 ASR 1.7B | Multilingual dictation with automatic language detection | 30 languages | 2.03 GiB | Apple Silicon |
| Cohere Transcribe | Multilingual dictation | [14 languages](#cohere-transcribe-languages) | 1.54 GiB | Apple Silicon |
| Apple Speech | Native macOS speech recognition | [System-dependent](#apple-speech-languages) | Built-in; system language assets may be needed | Apple Silicon + Intel |
| Whisper Tiny / Base / Small / Medium / Large Turbo / Large | Broad language coverage and Intel support | [Up to 99 languages](#whisper-language-support) | 44 MiB–1.55 GiB | Apple Silicon + Intel |

**About the models:** Fluid Speech Pro is a 0.63B-parameter model with open weights under CC BY 4.0. At its November 2026 launch, it ranked first among open models under 1B parameters on the Open ASR Leaderboard. See the [Pro model card and benchmarks](https://huggingface.co/FluidVoice-Labs/fluid-speech-pro) and [Mini's measurements and limitations](https://fluidvoice.com/labs/fluid-speech-mini). The Mini article describes the earlier English release; the Mac app's 1.6.13 Mini and Pico models support the 25 languages below.

### Fluid Speech and Parakeet TDT v3 Languages

Bulgarian, Croatian, Czech, Danish, Dutch, English, Estonian, Finnish, French, German, Greek, Hungarian, Italian, Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian, Russian, Slovak, Slovenian, Spanish, Swedish, and Ukrainian.

### Parakeet TDT v2 Languages

English.

### Cohere Transcribe Languages

English, French, German, Italian, Spanish, Portuguese, Greek, Dutch, Polish, Mandarin, Japanese, Korean, Vietnamese, and Arabic.

### Apple Speech Languages

System language support depends on the macOS speech recognition languages available on your machine.

### Whisper Language Support

Whisper supports up to 99 languages, depending on the model size you choose.

---

## Quick Start

1. **Install** with Homebrew:
   ```bash
   brew install --cask fluidvoice
   ```
   Or download the [latest release](https://github.com/altic-dev/FluidVoice/releases/latest).

2. **Grant permissions** — FluidVoice will ask for microphone and accessibility access. Both are required for dictation and typing into other apps.

3. **Set your hotkey** — pick a global hotkey in settings that triggers voice capture from anywhere.

4. **Go through onboarding** — choose your voice model based on your language and latency needs. Start with Fluid Speech Pro for accuracy, Mini or Pico for a smaller download, or Whisper on Intel. Other models cover additional languages.

5. **(Optional) Enable Fluid Intelligence** — choose Ripple or Splash for on-device text cleanup. No cloud account or API key is needed.

6. **(Optional) Bring your own AI provider** — add an OpenAI, Groq, or custom provider API key for cloud-based enhancement. Keys are stored securely in macOS Keychain. Select "Always allow" for key access.

7. **(Optional) Opt in to beta builds** — `Settings → Automatic Updates → Beta Releases` for early access to new features.

To pause listening without ending a hands-free dictation, enable **Settings → Dictation → Hold Space to Mute**. Start dictation with your usual shortcut, hold Space to mute, and release it to resume. The overlay shows a muted microphone. A quick tap (up to 250 ms) types one space on release; a longer hold types nothing. Muting starts immediately in both cases. Your normal shortcut still finishes the recording. Muted audio is excluded from live transcription, the final transcript, and saved audio history. Space works normally outside dictation; modifier-plus-Space and configured Space shortcuts keep their existing behavior. The option is off by default and applies to Dictation mode.

---

## Requirements

- macOS 15.0 (Sequoia) or later
- Apple Silicon for Fluid Speech, Parakeet, Nemotron, Qwen3 ASR, Cohere, and the local Edit 1.1 model
- Intel Macs supported via Whisper; Apple Speech availability depends on macOS and language
- Disk space for your chosen speech model: approximately 44 MiB to 2.03 GiB; allow extra space for installation
- Optional local cleanup: about 600 MB for Ripple or 750 MB for Splash; available models depend on your Mac
- Microphone access
- Accessibility permissions for typing

---

## Building from Source

```bash
git clone https://github.com/altic-dev/FluidVoice.git
cd FluidVoice
open Fluid.xcodeproj
```

Build and run in Xcode. All dependencies are managed via Swift Package Manager.

Run a signed Debug build using the script:

```bash
./build.sh
```

The signed build is written to `DerivedData/Build/Products/Debug/FluidVoice Debug.app`.
Keep launching that product after each rebuild so macOS can preserve its Accessibility
authorization.

For CI or contributors who do not have a signing identity, use the explicit unsigned
fallback:

```bash
./build.sh unsigned
```

Unsigned builds are tied to a specific executable version and may require Accessibility,
Screen Recording, and microphone permissions to be removed and granted again after rebuilding.

---

## Contributing

Contributions are welcome! Read the [contribution guidelines](CONTRIBUTING.md) before starting work.

- **Every PR needs a linked issue**, including bug fixes and small changes.
- **Major features and UI or UX changes need maintainer or moderator approval before implementation.** Open an issue and wait for explicit agreement on the scope.
- **Major feature requests start in [Discussions](https://github.com/altic-dev/FluidVoice/discussions/new?category=ideas).** After approval, create or link a tracking issue and reference both in the PR.
- **Keep PRs focused and verifiable.** Include a screenshot, image, or video, clear reproduction or verification steps, and testing results. Show before and after for UI or UX changes.

### Development Setup

1. Clone and open in Xcode as above.
2. **Signing:** `FluidVoice → Signing & Capabilities → Automatically manage signing → pick your Team` (Personal Team is fine). If you have certificates for multiple teams, select one without changing the project by running `FLUIDVOICE_DEVELOPMENT_TEAM=YOUR_TEAM_ID ./build.sh`.
3. Build and run — SPM handles dependencies.
4. **(Optional) Pre-commit hook** to prevent accidental team ID commits:
   ```bash
   cp scripts/check-team-id.sh .git/hooks/pre-commit
   chmod +x .git/hooks/pre-commit
   ```

### Pull Request Guidelines

- **One feature or fix per PR** — keep changes focused and atomic
- **Link a tracking issue** — a Discussion alone does not replace it
- **Get approval before implementing major features or UI or UX changes**
- **Follow the PR template**, including reproduction steps and screenshot, image, or video evidence
- **Report testing results** and any checks you could not run
- **AI-assisted coding is welcome; human review is required.** A human must create or vet the final PR, understand the full diff, and verify the behavior. Briefly explain AI use and your own checks; keep descriptions, code comments, and review replies focused. See [AI-assisted contribution guidelines](CONTRIBUTING.md#ai-assisted-contributions).
- **Never commit personal team IDs or API keys**
- **Check `git diff`** before committing

**These requirements are mandatory. PRs that do not follow the [contribution guidelines](CONTRIBUTING.md) will not be reviewed or merged until they comply, and may be closed.**

---

## Run Integration Tests

```bash
xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS'
```

CI uses unsigned builds:

```bash
xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

---

## Privacy & Analytics

FluidVoice is **local-first**. Your voice, audio, and transcribed text never leave your machine unless you explicitly opt in to a cloud AI provider.

### What's Collected

FluidVoice records one anonymous activity signal per local day and uploads the week's buffered signals together after the week ends. Detailed anonymous analytics are enabled by default and can be disabled at any time from `Settings → Share Detailed Anonymous Analytics`; when disabled, only the weekly activity batch is sent.

**Daily activity:**

- A random installation ID, activity date, app version, and macOS platform label

**With detailed analytics enabled:**

- Daily feature and model usage totals
- Onboarding progress
- Model download starts and high-level outcomes

**Not Collected:**

- Voice, raw audio, or transcribed text
- Selected text, prompts, or AI responses
- Terminal commands, window titles, file paths, clipboard, or typed content
- Any personal or private information

---

## Community

Join our Discord: https://discord.gg/VUPHaKSvYV

Follow development on X: [@fluidvoiceapp](https://x.com/fluidvoiceapp)

---

## License

From 2026-02-23 onward, this project is licensed under the [GNU General Public License, Version 3.0 (GPLv3)](LICENSE).

Versions published before this date were licensed under Apache License 2.0.
