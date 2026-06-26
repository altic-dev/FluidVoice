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
        .onChange(of: self.settings.commandModeLinkedToGlobal) { _, _ in
            self.updateAvailableModels()
        }
        .onChange(of: self.settings.selectedProviderID) { _, _ in
            self.updateAvailableModels()
        }
        .onChange(of: self.settings.selectedModelByProvider) { _, _ in
            self.updateAvailableModels()
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
        .background(self.theme.palette.windowBackground)
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
                .background(self.isHoveringHowTo ? self.theme.palette.cardBackground.opacity(0.6) : Color.clear)
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
                                .background(self.theme.palette.cardBackground.opacity(0.8))
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
        .background(self.theme.palette.contentBackground)
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

    @State private var isThinkingExpanded = false

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(self.service.conversationHistory) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    if self.service.isProcessing {
                        self.processingIndicator
                            .id("processing")
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(self.theme.palette.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1)
                    )
            )
            .onChange(of: self.service.conversationHistory.count) { _, _ in
                self.scrollToBottom(proxy)
            }
            .onChange(of: self.service.isProcessing) { _, isProcessing in
                // Scroll when processing starts, not on every streaming update
                if isProcessing {
                    self.scrollToBottom(proxy)
                    self.isThinkingExpanded = false // Collapse thinking for new request
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
        VStack(alignment: .leading, spacing: 10) {
            CommandShimmerText(text: "Thinking")
                .padding(.horizontal, 12)

            if self.settings.showThinkingTokens && !self.service.streamingThinkingText.isEmpty {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(self.service.streamingThinkingText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: 520, minHeight: 72, alignment: .leading)
        .padding(.top, 8)
        .padding(.bottom, 10)
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
                .background(self.theme.palette.cardBackground)

                Divider()

                Text(pending.command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(self.theme.palette.contentBackground)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.orange.opacity(0.5), lineWidth: 1)
            )

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
        VStack(alignment: .leading, spacing: 10) {
            if let issue = self.settings.commandModeReadinessIssue {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    Spacer(minLength: 8)

                    Button("AI Settings") {
                        AppNavigationRouter.shared.request(.aiEnhancements)
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 14) {
                TextField("Type a command or ask a question...", text: self.$inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .lineLimit(1...4)
                    .onSubmit {
                        self.submitCommand()
                    }

                HStack(spacing: 10) {
                    Toggle("Sync", isOn: self.$settings.commandModeLinkedToGlobal)
                        .toggleStyle(.checkbox)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                        .help("Use the same provider and model selected in AI Enhancement.")

                    SearchableProviderPicker(
                        builtInProviders: self.verifiedBuiltInProvidersList,
                        savedProviders: self.verifiedSavedProviders,
                        selectedProviderID: Binding(
                            get: { self.settings.effectiveCommandModeProviderID },
                            set: { newValue in
                                guard !self.settings.commandModeLinkedToGlobal else { return }
                                if newValue == "apple-intelligence-disabled" || newValue == "apple-intelligence" {
                                    return
                                }
                                guard !self.isPrivateAIProviderID(newValue) else { return }
                                self.settings.commandModeSelectedProviderID = newValue
                                self.updateAvailableModels()
                            }
                        ),
                        controlWidth: 140,
                        controlHeight: 30
                    )
                    .disabled(self.settings.commandModeLinkedToGlobal)
                    .opacity(self.settings.commandModeLinkedToGlobal ? 0.55 : 1)

                    SearchableModelPicker(
                        models: self.availableModels,
                        selectedModel: Binding(
                            get: { self.settings.effectiveCommandModeSelectedModel },
                            set: { newValue in
                                guard !self.settings.commandModeLinkedToGlobal else { return }
                                self.settings.commandModeSelectedModel = newValue
                            }
                        ),
                        onRefresh: nil,
                        isRefreshing: false,
                        selectionEnabled: !self.settings.commandModeLinkedToGlobal && !self.availableModels.isEmpty,
                        controlWidth: 180,
                        controlHeight: 30
                    )
                    .disabled(self.settings.commandModeLinkedToGlobal)

                    Spacer(minLength: 12)

                    Button(action: self.toggleRecording) {
                        Image(systemName: self.asr.isRunning ? "stop.fill" : "mic")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .foregroundStyle(self.asr.isRunning ? Color.red : .secondary)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(self.service.isProcessing)
                    .help(self.asr.isRunning ? "Stop voice command" : "Start voice command")

                    Button(action: self.submitCommand) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .foregroundStyle(self.canSubmitCommand ? Color.white : .secondary)
                            .background(
                                Circle()
                                    .fill(self.canSubmitCommand ? self.theme.palette.accent : self.theme.palette.cardBackground)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!self.canSubmitCommand)
                    .help("Run command")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(self.theme.palette.contentBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(self.theme.palette.cardBorder.opacity(0.55), lineWidth: 1)
                    )
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(self.theme.palette.windowBackground)
    }

    // MARK: - Actions

    private var canSubmitCommand: Bool {
        !self.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !self.service.isProcessing &&
            self.settings.commandModeReadinessIssue == nil
    }

    private func toggleRecording() {
        if self.asr.isRunning {
            Task {
                let command = await self.asr.stop().trimmingCharacters(in: .whitespacesAndNewlines)
                _ = self.asr.consumeLastCompletedAudioSnapshot()
                guard !command.isEmpty else { return }
                await MainActor.run {
                    self.inputText = command
                }
                guard self.settings.commandModeReadinessIssue == nil else { return }
                await self.service.processUserCommand(command)
                await MainActor.run {
                    self.inputText = ""
                }
            }
        } else {
            Task { await self.asr.start() }
        }
    }

    private func submitCommand() {
        let text = self.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard self.settings.commandModeReadinessIssue == nil else { return }
        self.inputText = ""
        Task {
            await self.service.processUserCommand(text)
        }
    }

    private func updateAvailableModels() {
        let currentProviderID = self.settings.effectiveCommandModeProviderID
        let currentModel = self.settings.commandModeSelectedModel ?? ""
        guard !currentProviderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.availableModels = []
            return
        }
        self.availableModels = self.settings.commandModeModels(for: currentProviderID)

        // If current model not in list, select first available
        if !self.settings.commandModeLinkedToGlobal, !self.availableModels.contains(currentModel) {
            self.settings.commandModeSelectedModel = self.availableModels.first
        }
    }

    private var builtInProvidersList: [(id: String, name: String)] {
        // Apple Intelligence disabled for Command Mode (no tool support)
        ModelRepository.shared.builtInProvidersList(
            includeAppleIntelligence: true,
            appleIntelligenceAvailable: false,
            appleIntelligenceDisabledReason: "No tools"
        ).filter { !self.isPrivateAIProviderID($0.id) }
    }

    private var verifiedBuiltInProvidersList: [(id: String, name: String)] {
        self.builtInProvidersList.filter { self.settings.isCommandModeProviderVerified($0.id) }
    }

    private var verifiedSavedProviders: [SettingsStore.SavedProvider] {
        self.settings.savedProviders.filter { self.settings.isCommandModeProviderVerified($0.id) }
    }

    private func isPrivateAIProviderID(_ providerID: String) -> Bool {
        PrivateFeatures.privateAIProvider &&
            providerID.trimmingCharacters(in: .whitespacesAndNewlines) == PrivateAIProviderFeature.shared.providerID
    }
}

// MARK: - Shimmer Effect (Cursor-style)

struct CommandShimmerText: View {
    let text: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let duration = 1.15
            let progress = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: duration) / duration
            let center = CGFloat(progress)
            let leadingEdge = max(0, center - 0.18)
            let trailingEdge = min(1, center + 0.18)

            Text(self.text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: Color.secondary.opacity(0.42), location: 0),
                            .init(color: Color.secondary.opacity(0.42), location: leadingEdge),
                            .init(color: Color.primary.opacity(0.98), location: center),
                            .init(color: Color.secondary.opacity(0.42), location: trailingEdge),
                            .init(color: Color.secondary.opacity(0.42), location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
        .accessibilityLabel(Text(self.text))
    }
}

// MARK: - Message Bubble (Minimal Design)

struct MessageBubble: View {
    let message: CommandModeService.Message
    @Environment(\.theme) private var theme
    @State private var isThinkingExpanded: Bool = false

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
            .background(self.theme.palette.accent.opacity(0.15))
            .cornerRadius(10)
            .frame(maxWidth: 380, alignment: .trailing)
    }

    // MARK: - Agent Message

    private var agentMessageView: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Thinking section (collapsible) - only if setting is enabled
            if let thinking = message.thinking, !thinking.isEmpty, SettingsStore.shared.showThinkingTokens {
                self.thinkingSection(thinking)
            }

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

    // MARK: - Thinking Section (Persisted, Collapsible)

    private func thinkingSection(_ thinking: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { self.isThinkingExpanded.toggle() } }) {
                HStack(spacing: 6) {
                    Text("Thinking")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    if self.isThinkingExpanded {
                        Text("\(thinking.count) chars")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }

                    Image(systemName: self.isThinkingExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            // Expanded content
            if self.isThinkingExpanded {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(thinking)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                }
                .frame(maxHeight: 150)
            }
        }
        .background(self.theme.palette.cardBackground.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
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
                .background(self.theme.palette.contentBackground)
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
        .background(self.theme.palette.cardBackground.opacity(0.85))
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
