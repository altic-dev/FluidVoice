import SwiftUI

struct CommandModeView: View {
    @ObservedObject var service: CommandModeService
    @ObservedObject var asr: ASRService
    @ObservedObject var settings = SettingsStore.shared
    var onClose: (() -> Void)?
    @State private var inputText: String = ""
    
    // Local state for available models (derived)
    @State private var availableModels: [String] = []
    
    // Computed Bindings
    private var selectedProviderIDBinding: Binding<String> {
        Binding(
            get: { settings.commandModeLinkedToGlobal ? settings.selectedProviderID : settings.commandModeSelectedProviderID },
            set: { newValue in
                if settings.commandModeLinkedToGlobal {
                    settings.selectedProviderID = newValue
                } else {
                    settings.commandModeSelectedProviderID = newValue
                }
                updateAvailableModels()
            }
        )
    }
    
    private var selectedModelBinding: Binding<String> {
        Binding(
            get: { (settings.commandModeLinkedToGlobal ? settings.selectedModel : settings.commandModeSelectedModel) ?? "gpt-4o" },
            set: { newValue in
                if settings.commandModeLinkedToGlobal {
                    settings.selectedModel = newValue
                } else {
                    settings.commandModeSelectedModel = newValue
                }
            }
        )
    }
    
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
        }
        .onChange(of: asr.finalText) { newText in
            if !newText.isEmpty {
                inputText = newText
            }
        }
        // React to external changes (e.g. if global settings change while linked)
        .onChange(of: settings.selectedProviderID) { _ in if settings.commandModeLinkedToGlobal { updateAvailableModels() } }
        .onChange(of: settings.commandModeLinkedToGlobal) { _ in updateAvailableModels() }
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
            
            // Link to AI Settings Toggle
            Toggle(isOn: $settings.commandModeLinkedToGlobal) {
                Label("Sync Settings", systemImage: "link")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .help("Use same provider and model as main AI settings")
            
            Divider()
                .frame(height: 20)
                .padding(.horizontal, 4)
            
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
            
            // Provider Selector
            Picker("", selection: selectedProviderIDBinding) {
                Text("OpenAI").tag("openai")
                Text("Groq").tag("groq")
                ForEach(settings.savedProviders) { provider in
                    Text(provider.name).tag(provider.id)
                }
            }
            .frame(width: 120)
            
            // Model Selector
            Picker("", selection: selectedModelBinding) {
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
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Processing...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading)
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
        }
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
        VStack(spacing: 8) {
            Divider()
            
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Confirm command execution?")
                    .fontWeight(.medium)
            }
            
            Text(pending.command)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
            
            HStack(spacing: 12) {
                Button("Cancel") {
                    service.cancelPendingCommand()
                }
                .buttonStyle(.bordered)
                
                Button("Run") {
                    Task {
                        await service.confirmAndExecute()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
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
        let currentProviderID = settings.commandModeLinkedToGlobal ? settings.selectedProviderID : settings.commandModeSelectedProviderID
        let currentModel = (settings.commandModeLinkedToGlobal ? settings.selectedModel : settings.commandModeSelectedModel) ?? "gpt-4o"
        
        let possibleKeys = providerKeys(for: currentProviderID)
        let storedList = possibleKeys.lazy
            .compactMap { SettingsStore.shared.availableModelsByProvider[$0] }
            .first { !$0.isEmpty }
        
        if let stored = storedList {
            availableModels = stored
        } else {
            availableModels = defaultModels(for: currentProviderID)
        }
        
        if !availableModels.contains(currentModel) {
            let newModel = availableModels.first ?? "gpt-4o"
            if settings.commandModeLinkedToGlobal {
                settings.selectedModel = newModel
            } else {
                settings.commandModeSelectedModel = newModel
            }
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

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: CommandModeService.Message
    
    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user {
                Spacer()
                Text(message.content)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.2))
                    .cornerRadius(12)
                    .frame(maxWidth: 400, alignment: .trailing)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    // Role indicator
                    HStack(spacing: 4) {
                        Image(systemName: iconName)
                            .font(.caption)
                        Text(roleName)
                            .font(.caption)
                            .fontWeight(.bold)
                    }
                    .foregroundStyle(.secondary)
                    
                    // Content
                    if message.role == .tool {
                        // Show tool output in code block style
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(formatToolOutput(message.content))
                                .font(.system(.caption, design: .monospaced))
                                .padding(8)
                                .background(Color(nsColor: .textBackgroundColor))
                                .cornerRadius(8)
                        }
                        .frame(maxWidth: 500)
                    } else {
                        Text(message.content)
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(12)
                            .textSelection(.enabled)
                    }
                    
                    // Show command if present
                    if let tc = message.toolCall {
                        HStack(spacing: 4) {
                            Image(systemName: "terminal.fill")
                                .font(.caption2)
                            Text(tc.command)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                        }
                        .padding(6)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(6)
                        .foregroundStyle(.blue)
                    }
                }
                .frame(maxWidth: 500, alignment: .leading)
                Spacer()
            }
        }
    }
    
    private var iconName: String {
        switch message.role {
        case .assistant: return "sparkles"
        case .tool: return "terminal"
        default: return "person"
        }
    }
    
    private var roleName: String {
        switch message.role {
        case .assistant: return "Assistant"
        case .tool: return "Output"
        default: return "You"
        }
    }
    
    private func formatToolOutput(_ json: String) -> String {
        // Try to extract just the output field for cleaner display
        if let data = json.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let output = parsed["output"] as? String, !output.isEmpty {
                return output
            }
            if let error = parsed["error"] as? String {
                return "Error: \(error)"
            }
        }
        return json
    }
}
