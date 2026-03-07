# FluidVoice

[![Supported Models](https://img.shields.io/badge/Models-Parakeet%20v3%20%26%20v2%20%7C%20Apple%20Speech%20%7C%20Whisper-blue)](https://github.com/altic-dev/Fluid-oss)

Fully open source voice-to-text dictation app for macOS with AI enhancement.

**Get the latest release from [here](https://github.com/altic-dev/Fluid-oss/releases/latest)**

> [!IMPORTANT]
> This project is completely free and open source. If you find FluidVoice useful, please star the repository. It helps with visibility and motivates continued development. Your support means a lot.

## Star History

<a href="https://star-history.com/#altic-dev/Fluid-oss&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=altic-dev/Fluid-oss&type=Date&theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=altic-dev/Fluid-oss&type=Date" />
    <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=altic-dev/Fluid-oss&type=Date" />
  </picture>
</a>

## Demo

### Command Mode - Take any action on your mac using FluidVoice  

https://github.com/user-attachments/assets/ffb47afd-1621-432a-bdca-baa4b8526301

### Write Mode - Write/Rewrite text in ANY text box in ANY App on your mac  

https://github.com/user-attachments/assets/c57ef6d5-f0a1-4a3f-a121-637533442c24

## Screenshots

### Command Mode Preview

![Command Mode Preview](assets/cmd_mode_ss.png)

### FluidVoice History

![FluidVoice History](assets/history__ss.png)

## New Features (v1.5)   
- **Overlay with Notch support**
- **Command Mode**  
- **Write Mode**    
- **New History stats**  
- **Stats to monitor usage**  


## Features
- **Live Preview Mode**: Real-time transcription preview in overlay
- **Multiple Speech Models**: Parakeet TDT v3 & v2, Apple Speech, and Whisper
- **Real-time transcription** with extremely low latency
- **AI enhancement** with OpenAI, Groq, and custom providers
- **Global hotkey** for instant voice capture
- **Smart typing** directly into any app
- **Menu bar integration** for quick access
- **Auto-updates** with seamless restart

## Supported Models

### Parakeet TDT v3 (Default)
Optimized for Apple Silicon. Supports 25 languages with auto-detection:
**Bulgarian, Croatian, Czech, Danish, Dutch, English, Estonian, Finnish, French, German, Greek, Hungarian, Italian, Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian, Slovak, Slovenian, Spanish, Swedish, Russian, Ukrainian.**

### Parakeet TDT v2
English-only model optimized for higher accuracy and consistency on Apple Silicon.

### Apple Speech
Uses the native macOS Speech Recognition engine and Speech Analyzer API (macOS 26+).

### Whisper
Universal support (runs on Intel & Apple Silicon). Supports 99 languages.

## Quick Start

1. Download the latest release
2. Move to Applications folder
3. Grant microphone and accessibility permissions when prompted
4. Set your preferred hotkey in settings
5. Optionally add an AI provider API key for enhanced transcription, keys are stored securely in your macOS Keychain. Make sure select "Always allow" for permissions

## Requirements

- macOS 11.0 (Big Sur) or later
- Apple Silicon Mac (M1, M2, M3, M4)
- Intel Macs are supported using Whisper models!
- Microphone access
- Accessibility permissions for typing

> **Note**: This is a community fork targeting macOS Big Sur (11.7.x) compatibility.
> Some features may have reduced visual fidelity on older macOS versions (e.g., no Material blur effects, no notch overlay on pre-notch Macs).
> Streaming SSE responses are buffered on macOS 11 (true streaming requires macOS 12+).


## Join our small community to help us grow and give feedback :) ( Or just hang?!)   

https://discord.gg/VUPHaKSvYV  

## Building from Source

```bash
git clone https://github.com/altic-dev/Fluid-oss.git
cd Fluid-oss
open Fluid.xcodeproj
```

Build and run in Xcode. All dependencies are managed via Swift Package Manager.

## Contributing

Contributions are welcome! Please create an issue first to discuss any major changes or feature requests before submitting a pull request.

### Setting Up Your Development Environment

1. **Clone the repository:**
   ```bash
   git clone https://github.com/altic-dev/Fluid-oss.git
   cd Fluid-oss
   ```

2. **Open in Xcode:**
   ```bash
   open Fluid.xcodeproj
   ```

3. **Run from Xcode (one-time signing setup):**
   - Target: `FluidVoice` → `Signing & Capabilities`
   - Enable `Automatically manage signing`
   - Pick your `Team` (Personal Team is fine)
   - This is stored in `xcuserdata/` (gitignored), so it won’t affect your PR

4. **Build and run** - All dependencies are managed via Swift Package Manager

5. **Build only (no signing):**
   ```bash
   xcodebuild -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
   ```

5. **(Optional) Install pre-commit hook** to prevent accidental team ID commits:
   ```bash
   cp scripts/check-team-id.sh .git/hooks/pre-commit
   chmod +x .git/hooks/pre-commit
   ```

### Pull Request Guidelines

- **Keep changes focused and atomic** - one feature or fix per PR
- **Update documentation** if adding new features
- **Test thoroughly** on your machine before submitting
- **Never commit personal team IDs or API keys** to `project.pbxproj`
- **Check git diff** before committing to ensure no personal settings leaked in

## Connect

Follow development updates on X: [@ALTIC_DEV](https://x.com/ALTIC_DEV)

## Run integration dictation test

```bash
xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS'
```

If you run into a test bundle load error related to code signing/Team ID, run without overriding code signing flags (the command above), or explicitly:

```bash
xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS' CODE_SIGN_STYLE=Automatic
```

CI uses unsigned builds:

```bash
xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

## Privacy & Analytics

FluidVoice is designed to be local-first, but it includes optional anonymous analytics, solely to keep track of FV usage and future feature development.

### What this helps with
- Feature usage patterns (for example dictation, command mode, and write mode)
- Product reliability and performance tuning
- Anonymous release health signals to prioritize fixes and improvements

### What is collected
- App version, build, and macOS version
- Low-cardinality feature/config flags (for example app mode and major settings)
- Approximate usage ranges (not exact values)
- High-level success/error outcomes

### What is not collected
- Your voice, Raw audio or transcribed text
- Selected text, prompts, or AI-generated responses
- Terminal commands or outputs
- Window titles, file names/paths, clipboard content, or typed content
- or ANYTHING personal or private information. 

### How to disable
Analytics are enabled by default. You can disable or re-enable them at any time from:

`Settings → Share Anonymous Analytics`

### Why this exists
Anonymous telemetry helps us understand what breaks, where performance can be improved, and which features matter most without collecting personal content.
This helps us continue building what users want and if we should even continue developing features for you. 

## License History

- Versions before **2026-02-23**: Apache License 2.0
- Versions on and after **2026-02-23**: GNU General Public License v3.0 (GPLv3)

## License

From 2026-02-23 onward, this project is licensed under the [GNU General Public License, Version 3.0 (GPLv3)](LICENSE).

Versions published before this date were licensed under Apache License 2.0.

---
