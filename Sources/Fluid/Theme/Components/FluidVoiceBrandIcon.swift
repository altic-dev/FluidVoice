import AppKit
import SwiftUI

/// Reuse AppKit's cached app icon; no asset lookup or filesystem query in the view.
struct FluidVoiceBrandIcon: View {
    private static let appIconImage: NSImage = NSApplication.shared.applicationIconImage
        ?? NSImage(size: NSSize(width: 32, height: 32))

    let size: CGFloat

    var body: some View {
        Image(nsImage: Self.appIconImage)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: self.size, height: self.size)
            .accessibilityHidden(true)
    }
}
