//
//  LiveTypingStatusRow.swift
//  Fluid
//
//  Settings readout for the experimental Live Typing path.
//

import SwiftUI

/// Shows what the last Live Typing session actually did.
///
/// This is how a given application gets certified: dictate once with the option
/// on, then read the level it resolved to here. It is a convenience for a
/// feature that is deliberately not enabled by default.
struct LiveTypingStatusRow: View {
    @ObservedObject private var controller = LiveTypingController.shared

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(self.controller.lastReport)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
