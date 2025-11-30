//
//  SetupComponents.swift
//  fluid
//
//  Helper components for setup and onboarding UI
//

import SwiftUI
import AppKit

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
            if status != .completed && showActionButton {
                action()
            }
        }) {
            HStack(alignment: .center, spacing: 10) {
                // Status indicator
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.12))
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle()
                                .stroke(statusColor.opacity(0.25), lineWidth: 1)
                        )

                    if status == .completed {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(statusColor)
                            .font(.body.weight(.semibold))
                    } else if status == .inProgress {
                        ProgressView()
                            .controlSize(.small)
                            .tint(statusColor)
                    } else {
                        Text("\(step)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(statusColor)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)

                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                // Action button or status badge
                if status == .completed {
                    Label("Done", systemImage: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green, in: Capsule())
                } else if showActionButton {
                    HStack(spacing: 3) {
                        Text(actionButtonTitle)
                            .font(.caption.weight(.medium))
                        Image(systemName: "arrow.right")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(theme.palette.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.palette.accent.opacity(0.12), in: Capsule())
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(status == .completed 
                        ? Color.green.opacity(0.06) 
                        : theme.palette.cardBackground.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(
                                status == .completed 
                                    ? Color.green.opacity(0.25)
                                    : theme.palette.cardBorder.opacity(0.2),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(status == .completed || !showActionButton)
        .opacity(status == .completed ? 0.9 : 1.0)
    }

    private var statusColor: Color {
        switch status {
        case .completed: return .green
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
                    .fill(theme.palette.accent.opacity(0.15))
                    .frame(width: 22, height: 22)

                Text("\(number)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.palette.accent)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.medium))

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

// MARK: - Provider Guide

struct ProviderGuide: View {
    @Environment(\.theme) private var theme
    let name: String
    let url: String
    let description: String?
    let baseURL: String
    let keyPrefix: String
    
    init(name: String, url: String, description: String? = nil, baseURL: String, keyPrefix: String) {
        self.name = name
        self.url = url
        self.description = description
        self.baseURL = baseURL
        self.keyPrefix = keyPrefix
    }

    var body: some View {
        ThemedCard(hoverEffect: false) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(name)
                        .font(.subheadline.weight(.semibold))

                    Spacer()

                    if !url.isEmpty {
                        Button("Get API Key") {
                            if let url = URL(string: url) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if let description = description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Base URL:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(baseURL)
                            .font(.caption.weight(.medium))
                            .textSelection(.enabled)
                    }

                    HStack {
                        Text("Key Format:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(keyPrefix == "not-needed" ? "Not required" : "Starts with: \(keyPrefix)")
                            .font(.caption.weight(.medium))
                    }
                }
            }
            .padding(12)
        }
    }
}





