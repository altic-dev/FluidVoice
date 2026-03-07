//
//  SetupComponents.swift
//  fluid
//
//  Helper components for setup and onboarding UI
//

import AppKit
import SwiftUI

// MARK: - Setup Step View

struct SetupStepView: View {
    @Environment(\.theme) private var theme
    let step: Int
    let title: String
    let description: String
    let status: SetupStatus
    let action: () -> Void
    var actionButtonTitle: String = "Configure"
    var showActionButton: Bool = true

    enum SetupStatus {
        case pending, completed, inProgress
    }

    var body: some View {
        Button(action: {
            if self.status != .completed, self.showActionButton {
                self.action()
            }
        }) {
            HStack(alignment: .center, spacing: 10) {
                // Status indicator
                ZStack {
                    Circle()
                        .fill(self.statusColor.opacity(0.12))
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle()
                                .stroke(self.statusColor.opacity(0.25), lineWidth: 1)
                        )

                    if self.status == .completed {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(self.statusColor)
                            .font(.body.weight(.semibold))
                    } else if self.status == .inProgress {
                        ProgressView()
                            
                            .accentColor(self.statusColor)
                    } else {
                        Text("\(self.step)")
                            .font(.caption.weight(.bold))
                            .foregroundColor(self.statusColor)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(self.title)
                        .font(.body.weight(.medium))
                        .foregroundColor(.primary)

                    Text(self.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                // Action button or status badge
                if self.status == .completed {
                    Label("Done", systemImage: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.fluidGreen))
                } else if self.showActionButton {
                    HStack(spacing: 3) {
                        Text(self.actionButtonTitle)
                            .font(.caption.weight(.medium))
                        Image(systemName: "arrow.right")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundColor(self.theme.palette.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(self.theme.palette.accent.opacity(0.12)))
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(self.status == .completed
                        ? Color.fluidGreen.opacity(0.06)
                        : self.theme.palette.cardBackground.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(
                                self.status == .completed
                                    ? Color.fluidGreen.opacity(0.25)
                                    : self.theme.palette.cardBorder.opacity(0.2),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(self.status == .completed || !self.showActionButton)
        .opacity(self.status == .completed ? 0.9 : 1.0)
    }

    private var statusColor: Color {
        switch self.status {
        case .completed: return Color.fluidGreen
        case .inProgress: return .blue
        case .pending: return .secondary
        }
    }
}

// MARK: - Instruction Step

struct InstructionStep: View {
    @Environment(\.theme) private var theme
    let number: Int
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                Circle()
                    .fill(self.theme.palette.accent.opacity(0.15))
                    .frame(width: 22, height: 22)

                Text("\(self.number)")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(self.theme.palette.accent)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(self.title)
                    .font(.subheadline.weight(.medium))

                Text(self.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
    }
}
