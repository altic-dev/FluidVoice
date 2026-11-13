import SwiftUI

/// Static product illustrations: no live user data, model loading, or recording work.
struct ReleaseFeaturePreview: View {
    let kind: ReleaseHighlightsContent.Preview
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            switch self.kind {
            case .meeting: self.meeting
            case .dashboard: self.dashboard
            case .ripple: self.cleanupModel("Fluid 1.1 Ripple", detail: "Fast & capable", symbol: "bolt")
            case .splash: self.cleanupModel("Fluid 1.1 Splash", detail: "Higher quality", symbol: "sparkles")
            case .speech: self.speech
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(self.theme.palette.elevatedCardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(self.theme.palette.cardBorder, lineWidth: 1)
        }
        .foregroundStyle(self.theme.palette.primaryText)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var meeting: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "waveform").foregroundStyle(FluidBrandColors.blue)
                Text("Product catch-up").font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                Text("12:48").font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(FluidBrandColors.blue.opacity(0.18))
                    .frame(width: 19, height: 19)
                    .overlay(Text("A").font(.system(size: 9, weight: .medium)).foregroundStyle(FluidBrandColors.blue))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Let’s get the next release ready.")
                        .font(.system(size: 10))
                    Text("We’ll start with the new features.")
                        .font(.system(size: 9)).foregroundStyle(self.theme.palette.secondaryText)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Label("Summary", systemImage: "sparkles")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(FluidBrandColors.blue)
                Text("Review features. Prepare the release.")
                    .font(.system(size: 9)).foregroundStyle(self.theme.palette.secondaryText)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Good morning.").font(.system(size: 16, weight: .semibold))
            HStack(spacing: 8) {
                self.stat("1,240", label: "WORDS DICTATED", symbol: "waveform")
                self.stat("24 min", label: "TIME SAVED", symbol: "clock")
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                Text("Search across FluidVoice")
                Spacer(minLength: 0)
            }
            .font(.system(size: 9))
            .foregroundStyle(self.theme.palette.secondaryText)
            .padding(8)
            .background(self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private func stat(_ value: String, label: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(FluidBrandColors.blue)
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded))
            Text(label).font(.system(size: 6, weight: .medium)).foregroundStyle(self.theme.palette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cleanupModel(_ name: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Fluid Intelligence", systemImage: "sparkles")
                .font(.system(size: 11, weight: .semibold))
            self.model(name, detail: detail, symbol: symbol)
            self.model("On-device", detail: "Private", symbol: "lock")
            self.model("Research preview", detail: "Review text", symbol: "text.magnifyingglass")
        }
    }

    private var speech: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Voice Engine", systemImage: "waveform")
                .font(.system(size: 11, weight: .semibold))
            self.model("Fluid Speech Pro", detail: "Most accurate", symbol: "star")
            self.model("Fluid Speech Mini", detail: "Half the size", symbol: "waveform")
            self.model("Fluid Speech Pico", detail: "Smallest", symbol: "bolt")
        }
    }

    private func model(_ name: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11)).foregroundStyle(FluidBrandColors.blue)
                .frame(width: 23, height: 23)
                .background(FluidBrandColors.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            Text(name).font(.system(size: 10, weight: .medium))
            Spacer(minLength: 0)
            Text(detail).font(.system(size: 8)).foregroundStyle(self.theme.palette.secondaryText)
        }
    }
}
