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
    let step: Int
    let title: String
    let description: String
    let status: SetupStatus
    let action: () -> Void
    var showConfigureButton: Bool = true

    enum SetupStatus {
        case pending, completed, inProgress
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.2))
                    .frame(width: 32, height: 32)

                if status == .completed {
                    Image(systemName: "checkmark")
                        .foregroundStyle(statusColor)
                        .font(.system(size: 14, weight: .bold))
                } else {
                    Text("\(step)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))

                    Spacer()

                    if status != .completed && showConfigureButton {
                        Button("Configure") {
                            action()
                        }
                        .font(.system(size: 12))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
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
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(theme.palette.accent.opacity(0.2))
                    .frame(width: 28, height: 28)

                Text("\(number)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.palette.accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))

                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

// MARK: - Provider Guide

struct ProviderGuide: View {
    let name: String
    let url: String
    let description: String
    let baseURL: String
    let keyPrefix: String

    var body: some View {
        ThemedCard(hoverEffect: false) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(name)
                        .font(.system(size: 14, weight: .semibold))

                    Spacer()

                    if !url.isEmpty {
                        Button("Get API Key") {
                            if let url = URL(string: url) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .font(.system(size: 12))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Base URL:")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(baseURL)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }

                    HStack {
                        Text("Key Format:")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(keyPrefix == "not-needed" ? "Not required" : "Starts with: \(keyPrefix)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                }
                .padding(.top, 4)
            }
            .padding(12)
        }
    }
}




