import SwiftUI

/// The current FluidVoice icon (Edge Shine) for in-app badges. The app icon
/// AppKit hands back can be the older artwork the icon set keeps for earlier
/// macOS, so badges use their own copy of the new one.
struct FluidVoiceBrandIcon: View {
    let size: CGFloat

    var body: some View {
        Image("BrandIcon")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: self.size, height: self.size)
            .accessibilityHidden(true)
    }
}
