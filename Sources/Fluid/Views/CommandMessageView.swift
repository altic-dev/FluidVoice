import Foundation
import SwiftUI

/// Conversation rows use the page itself as the assistant surface.
struct CommandMessageView: View {
    let message: CommandModeService.Message
    var onExpand: () -> Void = {}
    @Environment(\.theme) private var theme
    @ObservedObject private var settings = SettingsStore.shared
    @State private var thinkingExpanded = false
    @State private var commandExpanded = false
    @State private var outputExpanded = false
    @State private var toolOutput: CommandToolOutput?

    var body: some View {
        Group {
            if self.message.role == .user {
                self.userMessage
            } else {
                self.assistantMessage
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: self.message.content) {
            guard self.message.role == .tool else { return }
            let content = self.message.content
            let parsed = await Task.detached(priority: .userInitiated) { CommandToolOutput.parse(content) }.value
            guard !Task.isCancelled else { return }
            self.toolOutput = parsed
        }
    }

    private var userMessage: some View {
        HStack(alignment: .top, spacing: 24) {
            Spacer(minLength: 36)
            VStack(alignment: .trailing, spacing: 5) {
                Text(verbatim: self.message.content)
                    .font(self.theme.typography.body)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(self.theme.palette.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                CommandCopyButton(text: self.message.content, label: "Copy message")
            }
            .frame(maxWidth: 620, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: 12) {
            if self.settings.showThinkingTokens, let thinking = self.message.thinking, !thinking.isEmpty {
                self.thinking(thinking)
            }

            if self.message.role == .tool {
                self.toolResult
            } else if let tool = self.message.toolCall {
                self.command(tool)
            } else {
                if !self.message.content.isEmpty {
                    if self.message.stepType == .failure {
                        Label("Couldn’t complete this step", systemImage: "exclamationmark.circle")
                            .font(self.theme.typography.captionStrong)
                            .foregroundStyle(self.theme.palette.warning)
                    }
                    CommandMarkdownContent(text: self.message.content)
                }
                if !self.message.content.isEmpty {
                    HStack(spacing: 8) {
                        CommandCopyButton(text: self.message.content, label: "Copy response")
                        if self.message.stepType == .success {
                            Label("Completed", systemImage: "checkmark.circle")
                                .font(self.theme.typography.captionSmall)
                                .foregroundStyle(self.theme.palette.secondaryText)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func thinking(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            self.disclosure(title: "Reasoning", symbol: "text.bubble", expanded: self.$thinkingExpanded)
            if self.thinkingExpanded {
                ScrollView {
                    Text(verbatim: text)
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 24)
                }
                .frame(maxHeight: 220)
            }
        }
    }

    private func command(_ tool: CommandModeService.Message.ToolCall) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            self.disclosure(
                title: tool.purpose?.isEmpty == false ? tool.purpose ?? "Command" : "Command",
                symbol: "terminal",
                expanded: self.$commandExpanded
            )
            if self.commandExpanded {
                if !self.message.content.isEmpty {
                    CommandMarkdownContent(text: self.message.content)
                }
                CommandCodeBlock(code: tool.command, language: "Shell")
                if let directory = tool.workingDirectory, !directory.isEmpty {
                    Label(directory, systemImage: "folder")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var toolResult: some View {
        let failed = self.toolOutput?.success == false || self.message.stepType == .failure
        let title = self.toolOutput?.title ?? (failed ? "Command failed" : "Command result")
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                self.disclosure(
                    title: title,
                    symbol: failed ? "exclamationmark.circle" : (self.toolOutput?.success == true ? "checkmark.circle" : "text.alignleft"),
                    expanded: self.$outputExpanded,
                    failed: failed
                )
                if let duration = self.toolOutput?.executionTime, duration > 0 {
                    Text(duration < 1000 ? "\(duration) ms" : String(format: "%.1f s", Double(duration) / 1000))
                        .font(self.theme.typography.captionSmall)
                        .foregroundStyle(self.theme.palette.tertiaryText)
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            if failed, !self.outputExpanded, let error = self.toolOutput?.error, !error.isEmpty {
                Text(error)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.warning)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .padding(.leading, 24)
            }
            if self.outputExpanded {
                if let parsed = self.toolOutput {
                    if !parsed.output.isEmpty {
                        CommandCodeBlock(code: parsed.output, language: parsed.language)
                    }
                    if let error = parsed.error, !error.isEmpty {
                        Text(verbatim: error)
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.theme.palette.warning)
                            .textSelection(.enabled)
                    }
                    if parsed.output.isEmpty, parsed.error?.isEmpty != false {
                        Text("No output")
                            .font(self.theme.typography.caption)
                            .foregroundStyle(self.theme.palette.secondaryText)
                    }
                } else {
                    CommandCodeBlock(code: self.message.content, language: "Output")
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func disclosure(title: String, symbol: String, expanded: Binding<Bool>, failed: Bool = false) -> some View {
        Button {
            if !expanded.wrappedValue { self.onExpand() }
            expanded.wrappedValue.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol).frame(width: 16)
                Text(title).lineLimit(2).multilineTextAlignment(.leading)
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.fluidSystem(size: 9, weight: .semibold))
                Spacer(minLength: 0)
            }
            .font(self.theme.typography.bodySmall)
            .foregroundStyle(failed ? self.theme.palette.warning : self.theme.palette.secondaryText)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
        .help(expanded.wrappedValue ? "Hide details" : "Show details")
    }
}

/// Accept both the saved terminal result schema and unfamiliar results without losing their text.
struct CommandToolOutput: Sendable, Equatable {
    let success: Bool?
    let title: String
    let output: String
    let error: String?
    let executionTime: Int
    let language: String

    static func parse(_ text: String) -> CommandToolOutput {
        guard let data = text.data(using: .utf8), let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return CommandToolOutput(success: nil, title: "Command output", output: text, error: nil, executionTime: 0, language: "Output")
        }
        let success = result["success"] as? Bool
        let error = result["error"] as? String
        let purpose = result["purpose"] as? String
        let output = result["output"] as? String
        // Unknown structured formats stay inspectable instead of disappearing as empty output.
        let display = output ?? (result["content"] as? String) ?? text
        return CommandToolOutput(
            success: success,
            title: purpose?.isEmpty == false ? purpose ?? "Command result" : (success == false ? "Command failed" : "Command result"),
            output: display,
            error: error,
            executionTime: result["executionTimeMs"] as? Int ?? 0,
            language: "Output"
        )
    }
}
