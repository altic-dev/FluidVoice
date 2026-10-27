import SwiftUI

/// Shared icon tile extracted from Dashboard, with its original defaults preserved.
struct FluidIconTile: View {
    let icon: String
    let tint: Color
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: self.icon)
            .font(.fluidSystem(size: self.size > 34 ? 20 : 15, weight: .medium))
            .foregroundStyle(self.tint)
            .frame(width: self.size, height: self.size)
            .background(
                LinearGradient(colors: [self.tint.opacity(0.18), self.tint.opacity(0.07)], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(self.tint.opacity(0.16), lineWidth: 1))
            .accessibilityHidden(true)
    }
}
