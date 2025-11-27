import SwiftUI

struct CommandModeView: View {
    @ObservedObject var service: CommandModeService
    @ObservedObject var asr: ASRService
    @ObservedObject var settings = SettingsStore.shared
    @EnvironmentObject var menuBarManager: MenuBarManager
    var onClose: (() -> Void)?
    @State private var inputText: String = ""
    
    // Local state for available models (derived from shared AI Settings pool)
    @State private var availableModels: [String] = []
    
    // UI State
    @State private var showingClearConfirmation = false
    
    @Environment(\.theme) private var theme
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
            Divider()
            
            // Chat Area
            chatArea
            
            // Pending Command Confirmation (if any)
            if let pending = service.pendingCommand {
                pendingCommandView(pending)
            }
            
            Divider()
            
            // Input Area
            inputArea
        }
        .onAppear {
            updateAvailableModels()
            // Set overlay mode to command when this view appears
            menuBarManager.setOverlayMode(.command)
        }
        .onDisappear {
            // Reset overlay mode to dictation when leaving
            menuBarManager.setOverlayMode(.dictation)
        }
        .onChange(of: asr.finalText) { newText in
            if !newText.isEmpty {
                inputText = newText
            }
        }
        .onChange(of: settings.commandModeSelectedProviderID) { _ in 
            updateAvailableModels() 
        }
        .onExitCommand {
            onClose?()
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            Text("Command Mode")
                .font(.title2)
                .fontWeight(.bold)
            
            Spacer()
            
            // Confirm Before Execute Toggle
            Toggle(isOn: $settings.commandModeConfirmBeforeExecute) {
                Label("Confirm", systemImage: "checkmark.shield")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .help("Ask for confirmation before running commands")
            
            Divider()
                .frame(height: 20)
                .padding(.horizontal, 8)
            
            // Provider Selector (independent for Command Mode)
            Picker("", selection: $settings.commandModeSelectedProviderID) {
                Text("OpenAI").tag("openai")
                Text("Groq").tag("groq")
                
                // Apple Intelligence - disabled for Command Mode (no tool support)
                Text("Apple Intelligence (No tools)")
                    .foregroundColor(.secondary)
                    .tag("apple-intelligence-disabled")
                
                ForEach(settings.savedProviders) { provider in
                    Text(provider.name).tag(provider.id)
                }
            }
            .frame(width: 140)
            .onChange(of: settings.commandModeSelectedProviderID) { newValue in
                // Prevent selecting disabled Apple Intelligence
                if newValue == "apple-intelligence-disabled" || newValue == "apple-intelligence" {
                    settings.commandModeSelectedProviderID = "openai"
                }
            }
            
            // Model Selector
            Picker("", selection: Binding(
                get: { settings.commandModeSelectedModel ?? availableModels.first ?? "gpt-4o" },
                set: { settings.commandModeSelectedModel = $0 }
            )) {
                ForEach(availableModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .frame(width: 160)
            
            // Clear Chat
            Button(action: { showingClearConfirmation = true }) {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .help("Clear conversation")
            .disabled(service.conversationHistory.isEmpty)
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            "Clear conversation?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                service.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
    
    // MARK: - Chat Area
    
    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(service.conversationHistory) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    
                    if service.isProcessing {
                        processingIndicator
                            .id("processing")
                    }
                    
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .onChange(of: service.conversationHistory.count) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: service.isProcessing) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: service.currentStep) { _ in
                scrollToBottom(proxy)
            }
        }
    }
    
    // MARK: - Processing Indicator (Minimal with Shimmer)
    
    private var processingIndicator: some View {
        CommandShimmerText(text: currentStepLabel)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            .cornerRadius(6)
    }
    
    private var currentStepLabel: String {
        guard let step = service.currentStep else { return "Working..." }
        switch step {
        case .thinking: return "Thinking..."
        case .checking(let cmd): return "Checking \(truncateCommand(cmd, to: 30))"
        case .executing(let cmd): return "Running \(truncateCommand(cmd, to: 30))"
        case .verifying: return "Verifying..."
        case .completed(let success): return success ? "Done" : "Stopped"
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
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.orange.opacity(0.5), lineWidth: 1)
            )
            
            HStack(spacing: 12) {
                Button(action: { service.cancelPendingCommand() }) {
                    Label("Cancel", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape, modifiers: [])
                
                Button(action: {
                    Task { await service.confirmAndExecute() }
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
        HStack {
            TextField("Type a command or ask a question...", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    submitCommand()
                }
            
            Button(action: submitCommand) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(inputText.isEmpty || service.isProcessing)
            
            // Voice Input
            Button(action: toggleRecording) {
                Image(systemName: asr.isRunning ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.title2)
                    .foregroundStyle(asr.isRunning ? Color.red : Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - Actions
    
    private func toggleRecording() {
        if asr.isRunning {
            Task { await asr.stop() }
        } else {
            asr.start()
        }
    }
    
    private func submitCommand() {
        guard !inputText.isEmpty else { return }
        let text = inputText
        inputText = ""
        Task {
            await service.processUserCommand(text)
        }
    }
    
    private func updateAvailableModels() {
        let currentProviderID = settings.commandModeSelectedProviderID
        let currentModel = settings.commandModeSelectedModel ?? "gpt-4o"
        
        // Pull models from the shared pool configured in AI Settings
        let possibleKeys = providerKeys(for: currentProviderID)
        let storedList = possibleKeys.lazy
            .compactMap { SettingsStore.shared.availableModelsByProvider[$0] }
            .first { !$0.isEmpty }
        
        if let stored = storedList {
            availableModels = stored
        } else {
            availableModels = defaultModels(for: currentProviderID)
        }
        
        // If current model not in list, select first available
        if !availableModels.contains(currentModel) {
            settings.commandModeSelectedModel = availableModels.first ?? "gpt-4o"
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
        case "openai": return ["gpt-4o", "gpt-4-turbo", "gpt-3.5-turbo"]
        case "groq": return ["llama-3.3-70b-versatile", "llama3-70b-8192", "mixtral-8x7b-32768"]
        default: return ["gpt-4o"]
        }
    }
}

// MARK: - Shimmer Effect (Cursor-style)

struct CommandShimmerText: View {
    let text: String
    
    @State private var shimmerPhase: CGFloat = 0
    
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        Color.primary.opacity(0.4),
                        Color.primary.opacity(0.4),
                        Color.primary.opacity(0.8),
                        Color.primary.opacity(0.4),
                        Color.primary.opacity(0.4)
                    ],
                    startPoint: UnitPoint(x: shimmerPhase - 0.3, y: 0.5),
                    endPoint: UnitPoint(x: shimmerPhase + 0.3, y: 0.5)
                )
            )
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    shimmerPhase = 1.3
                }
            }
    }
}

// MARK: - Message Bubble (Minimal Design)

struct MessageBubble: View {
    let message: CommandModeService.Message
    
    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user {
                Spacer()
                userMessageView
            } else {
                agentMessageView
                Spacer()
            }
        }
    }
    
    // MARK: - User Message
    
    private var userMessageView: some View {
        Text(message.content)
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
            if message.role == .tool {
                toolOutputView
            } else if let tc = message.toolCall {
                commandCallView(tc)
            } else if !message.content.isEmpty {
                textContentView
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
    
    // MARK: - Command Call View (Minimal)
    
    private func commandCallView(_ tc: CommandModeService.Message.ToolCall) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Reasoning text (if meaningful)
            if !message.content.isEmpty && 
               !message.content.lowercased().starts(with: "checking") && 
               !message.content.lowercased().starts(with: "executing") &&
               !message.content.lowercased().starts(with: "i'll") {
                Text(message.content)
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
        let parsed = parseToolOutput(message.content)
        
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
                            Text(markdownAttributedString(from: parsed.output))
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
        Text(markdownAttributedString(from: message.content))
            .font(.system(size: 13))
            .textSelection(.enabled)
    }
    
    // MARK: - Markdown Rendering
    
    private func markdownAttributedString(from text: String) -> AttributedString {
        do {
            let attributed = try AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            ))
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
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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
