import SwiftUI

/// Reserved space prevents the neighbouring menu moving during the hover transition.
struct FluidModelUpdateButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            ZStack {
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(self.hovered ? 0 : 1)
                Text("Update").font(.system(size: 12, weight: .semibold))
                    .opacity(self.hovered ? 1 : 0)
            }
            .foregroundStyle(.black)
            .frame(width: self.hovered ? 76 : 34, height: 34)
            .background(Color(red: 0.84, green: 0.50, blue: 0.24), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { self.hovered = $0 }
        .animation(self.reduceMotion ? nil : .timingCurve(0.77, 0, 0.175, 1, duration: 0.16), value: self.hovered)
        .frame(width: 76, alignment: .trailing)
        .accessibilityLabel("Update model")
    }
}
