import SwiftUI

/// A model's maker mark on a small rounded tile. Voice Engine, the model pop-ups and any other
/// model list use it, so a model looks the same everywhere. Proportions follow `size`; at 28
/// points it matches the original Voice Engine badge.
struct FluidModelLogo: View {
    enum Mark: Equatable {
        case speech(SettingsStore.SpeechModel)
        /// Fluid Intelligence cleanup models.
        case cleanup
    }

    @Environment(\.theme) private var theme
    let mark: Mark
    var size: CGFloat = 28

    private var scale: CGFloat {
        self.size / 28
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7 * self.scale, style: .continuous)
        ZStack {
            shape.fill(self.background)
            self.symbol
        }
        .frame(width: self.size, height: self.size)
        .clipShape(shape)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var symbol: some View {
        switch self.mark {
        case .cleanup:
            Image("Provider_Fluid1")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: self.size * 0.9, height: self.size * 0.9)
        case let .speech(model):
            if model.brandName == "FluidVoice" {
                FluidVoiceBrandIcon(size: self.size)
            } else if model.usesAppleLogo {
                Image(systemName: "apple.logo")
                    .font(.fluidSystem(size: 14 * self.scale, weight: .medium))
                    .foregroundStyle(.primary)
            } else if let imageName = Self.imageName(for: model) {
                let isNvidia = model.brandName.lowercased().contains("nvidia")
                Image(imageName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    // The NVIDIA mark is drawn larger so it fills about as much of the tile as the others.
                    .frame(width: (isNvidia ? 24 : 18) * self.scale, height: (isNvidia ? 24 : 18) * self.scale)
            } else {
                Text(String(model.brandName.prefix(2)).uppercased())
                    .font(.fluidSystem(size: 10 * self.scale, weight: .bold, design: .rounded))
                    .foregroundStyle(self.theme.palette.primaryText)
            }
        }
    }

    private var background: Color {
        switch self.mark {
        case .cleanup:
            return Color(red: 0.1, green: 0.1, blue: 0.12)
        case let .speech(model):
            let brand = model.brandName.lowercased()
            // Keep these provider marks on a light background in both appearances.
            if brand.contains("nvidia") || brand.contains("openai") || brand.contains("whisper") || brand.contains("qwen") {
                return Color(red: 0.97, green: 0.97, blue: 0.97)
            }
            if brand.contains("apple") || model.usesAppleLogo {
                return self.theme.palette.cardBackground.opacity(0.9)
            }
            // A neutral tile: the maker's own mark is the only color.
            return self.theme.look.quietFill
        }
    }

    private static func imageName(for model: SettingsStore.SpeechModel) -> String? {
        let brand = model.brandName.lowercased()
        if brand.contains("nvidia") { return "Provider_NVIDIA" }
        if brand.contains("cohere") { return "Provider_Cohere" }
        // Official organization mark from https://github.com/QwenLM.
        if brand.contains("qwen") { return "Provider_Qwen" }
        if brand.contains("openai") || brand.contains("whisper") { return "Provider_OpenAI" }
        return nil
    }
}
