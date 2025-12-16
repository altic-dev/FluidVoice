# FluidVoice

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
- **Real-time transcription** using Parakeet TDT v3 model
- **AI enhancement** with OpenAI, Groq, and custom providers
- **25+ languages** with auto-detection
- **Global hotkey** for instant voice capture
- **Smart typing** directly into any app
- **Menu bar integration** for quick access
- **Auto-updates** with seamless restart

## Quick Start

1. Download the latest release
2. Move to Applications folder
3. Grant microphone and accessibility permissions when prompted
4. Set your preferred hotkey in settings
5. Optionally add an AI provider API key for enhanced transcription, keys are stored securely in your macOS Keychain. Make sure select "Always allow" for permissions

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon Mac (M1, M2, M3, M4)
- Intel Macs are supported from 1.5.1 builds using Whisper models!
- Microphone access
- Accessibility permissions for typing


## Join our small community to help us grow and give feedback :) ( Or just hang?!)   

https://discord.gg/VUPHaKSvYV  

## Building from Source

```bash
git clone https://github.com/altic-dev/Fluid-oss.git
cd Fluid-oss
open FluidVoice.xcodeproj
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

3. **Configure your Team ID:**
   - Select the project in Xcode's navigator
   - Go to "Signing & Capabilities" tab
   - Select your Apple Developer Team from the dropdown
   - Xcode will save this locally in `xcuserdata/` (which is gitignored)

4. **Build and run** - All dependencies are managed via Swift Package Manager

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

## License

This project is licensed under the [Apache License 2.0](LICENSE).

---
