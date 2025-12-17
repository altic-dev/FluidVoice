import SwiftUI

struct CommandModeView: View {
    @ObservedObject var service: CommandModeService
    @EnvironmentObject var appServices: AppServices
    private var asr: ASRService { self.appServices.asr }
    @ObservedObject var settings = SettingsStore.shared
    @EnvironmentObject var menuBarManager: MenuBarManager
    var onClose: (() -> Void)?
    @State private var inputText: String = ""

    // Local state for available models (derived from shared AI Settings pool)
    @State private var availableModels: [String] = []

    // UI State
    @State private var showingClearConfirmation = false
    @State private var showHowTo = false
    @State private var isHoveringHowTo = false

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            // Header
            self.headerView

            // How To (collapsible)
            self.howToSection

            Divider()

            // Chat Area
            self.chatArea

            // Pending Command Confirmation (if any)
            if let pending = service.pendingCommand {
                self.pendingCommandView(pending)
            }

            Divider()

            // Input Area
            self.inputArea
        }
        .onAppear {
            self.updateAvailableModels()
            // Disable notch output when using in-app UI (conversation is shared but notch shouldn't show)
            self.service.enableNotchOutput = false
        }
        .onDisappear {
            // Re-enable notch output when leaving in-app UI
            self.service.enableNotchOutput = true
        }
        .onChange(of: self.asr.finalText) { _, newText in
            if !newText.isEmpty {
                self.inputText = newText
            }
        }
        .onChange(of: self.settings.commandModeSelectedProviderID) { _, _ in
            self.updateAvailableModels()
        }
        .onExitCommand {
            self.onClose?()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            HStack(spacing: 8) {
                Text("Command Mode")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Alpha")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(red: 1.0, green: 0.35, blue: 0.35)) // Command mode red
                    .cornerRadius(4)
            }

            Spacer()

            // Chat management buttons
            HStack(spacing: 4) {
                // New Chat Button
                Button(action: { self.service.createNewChat() }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .help("New chat")
                .disabled(self.service.isProcessing)

                // Recent Chats Menu
                Menu {
                    let recentChats = self.service.getRecentChats()
                    if recentChats.isEmpty {
                        Text("No recent chats")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(recentChats) { chat in
                            Button(action: {
                                if chat.id != self.service.currentChatID {
                                    self.service.switchToChat(id: chat.id)
                                }
                            }) {
                                HStack {
                                    if chat.id == self.service.currentChatID {
                                        Image(systemName: "checkmark")
                                            .font(.caption)
                                    }
                                    Text(chat.title)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(chat.relativeTimeString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(self.service.isProcessing)
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 32, height: 24)
                .help("Recent chats")

                // Delete Chat Button - deletes the current chat entirely
                Button(action: { self.showingClearConfirmation = true }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .help("Delete chat")
                .disabled(self.service.isProcessing)
            }

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 8)

            // Confirm Before Execute Toggle
            Toggle(isOn: self.$settings.commandModeConfirmBeforeExecute) {
                Label("Confirm", systemImage: "checkmark.shield")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .help("Ask for confirmation before running commands")
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            "Delete this chat?",
            isPresented: self.$showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                self.service.deleteCurrentChat()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - How To Section

    private var shortcutDisplay: String {
        self.settings.commandModeHotkeyShortcut.displayString
    }

    private var howToSection: some View {
        VStack(spacing: 0) {
            // Toggle button with hover effect
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { self.showHowTo.toggle() } }) {
                HStack {
                    Image(systemName: "questionmark.circle")
                        .font(.caption)
                    Text("How to use")
                        .font(.caption)
                    Spacer()
                    Image(systemName: self.showHowTo ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(self.isHoveringHowTo ? .primary : .secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(self.isHoveringHowTo ? Color.primary.opacity(0.05) : Color.clear)
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) { self.isHoveringHowTo = hovering }
            }

            if self.showHowTo {
                VStack(alignment: .leading, spacing: 12) {
                    // Start section
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Getting Started")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 4) {
                            Text("Press")
                                .font(.caption)
                            Text(self.shortcutDisplay)
                                .font(.caption)
                                .fontWeight(.medium)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.1))
                                .cornerRadius(4)
                            Text("to open Command Mode, speak your command, then press again to send.")
                                .font(.caption)
                        }
                        .foregroundStyle(.primary.opacity(0.8))
                    }

                    // Examples
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Examples")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            self.howToItem("\"List files in my Downloads folder\"")
                            self.howToItem("\"Create a folder called Projects on Desktop\"")
                            self.howToItem("\"What's my IP address?\"")
                            self.howToItem("\"Open Safari\"")
                        }
                    }

                    // Caution note
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Caution")
                                .fontWeight(.semibold)
                        }
                        .font(.caption)

                        Text("AI can make mistakes. Avoid dangerous commands like deleting important files. Destructive actions will ask for confirmation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }

    private func howToItem(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.8))
        }
    }

    // MARK: - Chat Area

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(self.service.conversationHistory) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    if self.service.isProcessing {
                        VStack(alignment: .leading, spacing: 8) {
                            self.processingIndicator

                            // Show streaming text in real-time
                            if !self.service.streamingText.isEmpty {
                                self.streamingTextView
                            }
                        }
                        .id("processing")
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .onChange(of: self.service.conversationHistory.count) { _, _ in
                self.scrollToBottom(proxy)
            }
            .onChange(of: self.service.isProcessing) { _, isProcessing in
                // Scroll when processing starts, not on every streaming update
                if isProcessing {
                    self.scrollToBottom(proxy)
                }
            }
            .onChange(of: self.service.currentStep) { _, _ in
                self.scrollToBottom(proxy)
            }
            // Removed: .onChange(of: service.streamingText) - causes scroll on every token, too expensive
        }
    }

    // MARK: - Processing Indicator (Minimal with Shimmer)

    private var processingIndicator: some View {
        CommandShimmerText(text: self.currentStepLabel)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            .cornerRadius(6)
    }

    // MARK: - Streaming Text View (Real-time AI response)

    private var streamingTextView: some View {
        // Use fixedSize to prevent expensive re-layout on every update
        Text(self.service.streamingText)
            .font(.system(size: 13))
            .foregroundStyle(.primary.opacity(0.9))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: 520, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .cornerRadius(8)
            .drawingGroup() // Flatten to bitmap for faster updates
        // textSelection disabled during streaming - re-enabled in final message
    }

    private var currentStepLabel: String {
        guard let step = service.currentStep else { return "Working..." }
        switch step {
        case .thinking: return "Thinking..."
        case let .checking(cmd): return "Checking \(self.truncateCommand(cmd, to: 30))"
        case let .executing(cmd): return "Running \(self.truncateCommand(cmd, to: 30))"
        case .verifying: return "Verifying..."
        case let .completed(success): return success ? "Done" : "Stopped"
        }
    }

    private func truncateCommand(_ cmd: String, to limit: Int) -> String {
        if cmd.count > limit {
            return String(cmd.prefix(limit - 3)) + "..."
        }
        return cmd
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: - Pending Command

    private func pendingCommandView(_ pending: CommandModeService.PendingCommand) -> some View {
        VStack(spacing: 10) {
            Divider()

            HStack {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Confirm Execution")
                        .fontWeight(.semibold)
                    if let purpose = pending.purpose {
                        Text(purpose)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            // Command preview
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: "terminal.fill")
                        .font(.caption)
                    Text("Command")
                        .font(.caption)
                        .fontWeight(.medium)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .windowBackgroundColor))

                Divider()

                Text(pending.command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.5), lineWidth: 1))

            HStack(spacing: 12) {
                Button(action: { self.service.cancelPendingCommand() }) {
                    Label("Cancel", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape, modifiers: [])

                Button(action: {
                    Task { await self.service.confirmAndExecute() }
                }) {
                    Label("Run Command", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding()
        .background(Color.orange.opacity(0.08))
    }

    // MARK: - Input Area

    private var inputArea: some View {
        HStack(spacing: 8) {
            // Provider Selector (compact)
            Picker("", selection: self.$settings.commandModeSelectedProviderID) {
                Text("OpenAI").tag("openai")
                Text("Groq").tag("groq")

                // Apple Intelligence - disabled for Command Mode (no tool support)
                Text("Apple Intelligence (No tools)")
                    .foregroundColor(.secondary)
                    .tag("apple-intelligence-disabled")

                ForEach(self.settings.savedProviders) { provider in
                    Text(provider.name).tag(provider.id)
                }
            }
            .frame(width: 110)
            .onChange(of: self.settings.commandModeSelectedProviderID) { _, newValue in
                // Prevent selecting disabled Apple Intelligence
                if newValue == "apple-intelligence-disabled" || newValue == "apple-intelligence" {
                    self.settings.commandModeSelectedProviderID = "openai"
                }
            }

            // Model Selector (compact)
            Picker(
                "",
                selection: Binding(
                    get: {
                        self.settings.commandModeSelectedModel ?? self.availableModels.first ?? "gpt-4o"
                    },
                    set: { self.settings.commandModeSelectedModel = $0 }
                )
            ) {
                ForEach(self.availableModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .frame(width: 130)

            // Input field (flexible)
            TextField("Type a command or ask a question...", text: self.$inputText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    self.submitCommand()
                }

            Button(action: self.submitCommand) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(self.inputText.isEmpty || self.service.isProcessing)

            // Voice Input
            Button(action: self.toggleRecording) {
                Image(systemName: self.asr.isRunning ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.title2)
                    .foregroundStyle(self.asr.isRunning ? Color.red : Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Actions

    private func toggleRecording() {
        if self.asr.isRunning {
            Task { await self.asr.stop() }
        } else {
            self.asr.start()
        }
    }

    private func submitCommand() {
        guard !self.inputText.isEmpty else { return }
        let text = self.inputText
        self.inputText = ""
        Task {
            await self.service.processUserCommand(text)
        }
    }

    private func updateAvailableModels() {
        let currentProviderID = self.settings.commandModeSelectedProviderID
        let currentModel = self.settings.commandModeSelectedModel ?? "gpt-4o"

        // Pull models from the shared pool configured in AI Settings
        let possibleKeys = self.providerKeys(for: currentProviderID)
        let storedList = possibleKeys.lazy
            .compactMap { SettingsStore.shared.availableModelsByProvider[$0] }
            .first { !$0.isEmpty }

        if let stored = storedList {
            self.availableModels = stored
        } else {
            self.availableModels = self.defaultModels(for: currentProviderID)
        }

        // If current model not in list, select first available
        if !self.availableModels.contains(currentModel) {
            self.settings.commandModeSelectedModel = self.availableModels.first ?? "gpt-4o"
        }
    }

    /// Returns possible keys used to store models for a provider.
    private func providerKeys(for providerID: String) -> [String] {
        var keys: [String] = []
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return [providerID]
        }

        if trimmed == "openai" || trimmed == "groq" {
            return [trimmed]
        }

        if trimmed.hasPrefix("custom:") {
            keys.append(trimmed)
            keys.append(String(trimmed.dropFirst("custom:".count)))
        } else {
            keys.append("custom:\(trimmed)")
            keys.append(trimmed)
        }

        // Add legacy key used in ContentView before the fix
        keys.append("custom:\\(trimmed)")

        return Array(Set(keys))
    }

    private func defaultModels(for provider: String) -> [String] {
        switch provider {
        case "openai": return ["gpt-4.1"]
        case "groq": return ["llama-3.3-70b-versatile", "llama3-70b-8192", "mixtral-8x7b-32768"]
        default: return ["gpt-4.1"]
        }
    }
}

// MARK: - Shimmer Effect (Cursor-style)

struct CommandShimmerText: View {
    let text: String

    @State private var shimmerPhase: CGFloat = 0

    var body: some View {
        Text(self.text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(LinearGradient(
                colors: [
                    Color.primary.opacity(0.4),
                    Color.primary.opacity(0.4),
                    Color.primary.opacity(0.8),
                    Color.primary.opacity(0.4),
                    Color.primary.opacity(0.4),
                ],
                startPoint: UnitPoint(x: self.shimmerPhase - 0.3, y: 0.5),
                endPoint: UnitPoint(x: self.shimmerPhase + 0.3, y: 0.5)
            ))
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    self.shimmerPhase = 1.3
                }
            }
    }
}

// MARK: - Message Bubble (Minimal Design)

struct MessageBubble: View {
    let message: CommandModeService.Message

    var body: some View {
        HStack(alignment: .top) {
            if self.message.role == .user {
                Spacer()
                self.userMessageView
            } else {
                self.agentMessageView
                Spacer()
            }
        }
    }

    // MARK: - User Message

    private var userMessageView: some View {
        Text(self.message.content)
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.15))
            .cornerRadius(10)
            .frame(maxWidth: 380, alignment: .trailing)
    }

    // MARK: - Agent Message

    private var agentMessageView: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Purpose label (minimal, gray)
            if let tc = message.toolCall, let purpose = tc.purpose {
                Text(purpose)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // Main content
            if self.message.role == .tool {
                self.toolOutputView
            } else if let tc = message.toolCall {
                self.commandCallView(tc)
            } else if !self.message.content.isEmpty {
                self.textContentView
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    // MARK: - Command Call View (Minimal)

    private func commandCallView(_ tc: CommandModeService.Message.ToolCall) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Reasoning text (if meaningful)
            if !self.message.content.isEmpty &&
                !self.message.content.lowercased().starts(with: "checking") &&
                !self.message.content.lowercased().starts(with: "executing") &&
                !self.message.content.lowercased().starts(with: "i'll")
            {
                Text(self.message.content)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            // Command block - clean and simple
            Text(tc.command)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
        }
    }

    // MARK: - Tool Output View (Minimal)

    private var toolOutputView: some View {
        let parsed = self.parseToolOutput(self.message.content)

        return VStack(alignment: .leading, spacing: 0) {
            // Minimal header - just status and time
            HStack(spacing: 6) {
                Text(parsed.success ? "Success" : "Error")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(parsed.success ? .primary : .secondary)

                Spacer()

                if parsed.executionTime > 0 {
                    Text("\(parsed.executionTime)ms")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            // Output content (if any)
            if !parsed.output.isEmpty || parsed.error != nil {
                Divider()
                    .padding(.horizontal, 10)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        if !parsed.output.isEmpty {
                            Text(self.markdownAttributedString(from: parsed.output))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        if let error = parsed.error, !error.isEmpty {
                            Text(error)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }

    // MARK: - Text Content View (Minimal)

    private var textContentView: some View {
        Text(self.markdownAttributedString(from: self.message.content))
            .font(.system(size: 13))
            .textSelection(.enabled)
    }

    // MARK: - Markdown Rendering

    private func markdownAttributedString(from text: String) -> AttributedString {
        do {
            let attributed = try AttributedString(
                markdown: text,
                options: AttributedString
                    .MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
            return attributed
        } catch {
            return AttributedString(text)
        }
    }

    // MARK: - Helpers

    private struct ParsedOutput {
        let success: Bool
        let output: String
        let error: String?
        let exitCode: Int
        let executionTime: Int
    }

    private func parseToolOutput(_ json: String) -> ParsedOutput {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ParsedOutput(success: false, output: json, error: nil, exitCode: -1, executionTime: 0)
        }

        return ParsedOutput(
            success: parsed["success"] as? Bool ?? false,
            output: parsed["output"] as? String ?? "",
            error: parsed["error"] as? String,
            exitCode: parsed["exitCode"] as? Int ?? 0,
            executionTime: parsed["executionTimeMs"] as? Int ?? 0
        )
    }
}
