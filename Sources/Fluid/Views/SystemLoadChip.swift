//
//  SystemLoadChip.swift
//  Fluid
//
//  Capsule shown above the live-transcription area while the Mac is low on memory.
//

import SwiftUI

struct SystemLoadChip: View {
    let fontSize: CGFloat

    static func height(for fontSize: CGFloat) -> CGFloat {
        fontSize + 10
    }

    var body: some View {
        Label("Mac is low on memory · cleanup may be slower", systemImage: "memorychip")
            .font(.system(size: self.fontSize - 1, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(Color.orange.opacity(0.95))
            .padding(.horizontal, 8)
            .frame(height: Self.height(for: self.fontSize))
            .background(Capsule().fill(Color.orange.opacity(0.14)))
    }
}
