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
            HStack(alignment: .top, spacing: 12) {
                // Status indicator
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.15))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Circle()
                                .stroke(statusColor.opacity(0.3), lineWidth: 1.5)
                        )

                    if status == .completed {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(statusColor)
                            .font(.system(size: 20, weight: .semibold))
                    } else if status == .inProgress {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(statusColor)
                    } else {
                        Text("\(step)")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(statusColor)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)

                            Text(description)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        // Action button or status badge
                        if status == .completed {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                Text("Done")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.green)
                            )
                        } else if showActionButton {
                            HStack(spacing: 4) {
                                Text(actionButtonTitle)
                                    .font(.system(size: 11, weight: .semibold))
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .foregroundStyle(theme.palette.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(theme.palette.accent.opacity(0.15))
                            )
                        }
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(status == .completed 
                        ? Color.green.opacity(0.08) 
                        : theme.palette.cardBackground.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(
                                status == .completed 
                                    ? Color.green.opacity(0.3)
                                    : theme.palette.cardBorder.opacity(0.3),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(status == .completed || !showActionButton)
        .opacity(status == .completed ? 0.85 : 1.0)
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
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(theme.palette.accent.opacity(0.2))
                    .frame(width: 24, height: 24)

                Text("\(number)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.palette.accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))

                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Provider Guide

struct ProviderGuide: View {
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
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))

                    Spacer()

                    if !url.isEmpty {
                        Button("Get API Key") {
                            if let url = URL(string: url) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }

                if let description = description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Base URL:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(baseURL)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }

                    HStack {
                        Text("Key Format:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(keyPrefix == "not-needed" ? "Not required" : "Starts with: \(keyPrefix)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                }
                .padding(.top, 3)
            }
            .padding(10)
        }
    }
}





