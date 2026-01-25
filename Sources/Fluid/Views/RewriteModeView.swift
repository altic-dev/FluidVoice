import SwiftUI

struct RewriteModeView: View {
    @ObservedObject var service: RewriteModeService
    @EnvironmentObject var appServices: AppServices
    private var asr: ASRService { self.appServices.asr }
    @ObservedObject var settings = SettingsStore.shared
    @EnvironmentObject var menuBarManager: MenuBarManager
    @Environment(\.theme) private var theme
    var onClose: (() -> Void)?

    @State private var inputText: String = ""
    @State private var showOriginal: Bool = true
    @State private var showHowTo: Bool = false
    @State private var isHoveringHowTo: Bool = false
    @State private var isThinkingExpanded: Bool = false

    // Local state for available models (derived from shared AI Settings pool)
    @State private var availableModels: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            // Header - cleaner, just title and close
            HStack {
                Image(systemName: "pencil.and.outline")
                    .font(.title2)
                    .foregroundStyle(self.theme.palette.accent)
                Text("Write Mode")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                Button(action: { self.onClose?() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(self.theme.palette.windowBackground)

            // How To (collapsible)
            self.howToSection

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Original Text Section
                    if !self.service.originalText.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Original Text")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if !self.service.rewrittenText.isEmpty {
                                    Button(self.showOriginal ? "Hide" : "Show") {
                                        withAnimation { self.showOriginal.toggle() }
                                    }
                                    .font(.caption)
                                    .buttonStyle(.link)
                                }
                            }

                            if self.showOriginal {
                                Text(self.service.originalText)
                                    .padding()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(self.theme.palette.cardBackground)
                                    .cornerRadius(8)
                                    .textSelection(.enabled)
                            }
                        }
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 48))
                                .foregroundStyle(self.theme.palette.accent)
                            Text("Write Mode")
                                .font(.title2)
                                .fontWeight(.bold)
                            Text("Ask the AI to write anything for you - emails, replies, summaries, answers, and more.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)

                            Text("Or select text first to rewrite existing content.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                                .padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }

                    // Rewritten Text Section
                    if !self.service.rewrittenText.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Rewritten Text")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundStyle(self.theme.palette.accent)

                            Text(self.service.rewrittenText)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(self.theme.palette.accent.opacity(0.1))
                                .cornerRadius(8)
                                .textSelection(.enabled)

                            HStack {
                                Button("Try Again") {
                                    self.service.rewrittenText = ""
                                }
                                .buttonStyle(.bordered)

                                Spacer()

                                Button("Replace Original") {
                                    self.service.acceptRewrite()
                                    self.onClose?()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(self.theme.palette.accent)
                            }
                            .padding(.top, 8)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // Conversation History (optional, maybe just last error)
                    if let lastMsg = service.conversationHistory.last, lastMsg.role == .assistant,
                       service.rewrittenText.isEmpty
                    {
                        Text(lastMsg.content) // Error message usually
                            .foregroundStyle(.red)
                            .padding()
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(8)
                    }
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

            Divider()

            // Input Area with model selectors inline
            HStack(spacing: 8) {
                // Provider Selector (compact, searchable)
                SearchableProviderPicker(
                    builtInProviders: self.builtInProvidersList,
                    savedProviders: self.settings.savedProviders,
                    selectedProviderID: Binding(
                        get: { self.settings.rewriteModeSelectedProviderID },
                        set: { newValue in
                            // Prevent selecting disabled Apple Intelligence
                            if newValue == "apple-intelligence-disabled" {
                                self.settings.rewriteModeSelectedProviderID = "openai"
                            } else {
                                self.settings.rewriteModeSelectedProviderID = newValue
                            }
                            self.updateAvailableModels()
                        }
                    )
                )

                // Model Selector (hidden for Apple Intelligence)
                if self.settings.rewriteModeSelectedProviderID != "apple-intelligence" {
                    SearchableModelPicker(
                        models: self.availableModels,
                        selectedModel: Binding(
                            get: { self.settings.rewriteModeSelectedModel ?? self.availableModels.first ?? "" },
                            set: { self.settings.rewriteModeSelectedModel = $0 }
                        ),
                        onRefresh: nil,
                        isRefreshing: false
                    )
                }

                // Input field (flexible)
                TextField(
                    self.service.originalText.isEmpty
                        ? "Ask me to write anything..."
                        : "How should I rewrite this?",
                    text: self.$inputText
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit(self.submitRequest)

                Button(action: self.submitRequest) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(self.inputText.isEmpty || self.service.isProcessing)

                // Voice Input
                Button(action: self.toggleRecording) {
                    Image(systemName: self.asr.isRunning ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.title2)
                        .foregroundStyle(self.asr.isRunning ? Color.red : self.theme.palette.accent)
                }
                .buttonStyle(.plain)

                if self.service.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding()
            .background(self.theme.palette.windowBackground)

            // Thinking view (real-time, during processing)
            if self.service.isProcessing && self.settings.showThinkingTokens && !self.service.streamingThinkingText.isEmpty {
                self.thinkingView
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
        .onChange(of: self.asr.finalText) { _, newText in
            if !newText.isEmpty {
                self.inputText = newText
            }
        }
        .onExitCommand {
            self.onClose?()
        }
        .onAppear {
            // Note: Overlay mode is now set centrally by ContentView.handleModeTransition()
            self.updateAvailableModels()
        }
        // Note: onDisappear overlay mode handling removed - now handled centrally by ContentView
    }

    private func toggleRecording() {
        if self.asr.isRunning {
            Task { await self.asr.stop() }
        } else {
            Task { await self.asr.start() }
        }
    }

    private func submitRequest() {
        guard !self.inputText.isEmpty else { return }
        let prompt = self.inputText
        self.inputText = ""
        Task {
            await self.service.processRewriteRequest(prompt)
        }
    }

    // MARK: - Model Management (pulls from shared AI Settings pool)

    private func updateAvailableModels() {
        let currentProviderID = self.settings.rewriteModeSelectedProviderID
        let currentModel = self.settings.rewriteModeSelectedModel ?? "gpt-4.1"

        // Apple Intelligence has only one model
        if currentProviderID == "apple-intelligence" {
            self.availableModels = ["System Model"]
            return
        }

        // Pull models from the shared pool configured in AI Settings
        let possibleKeys = self.providerKeys(for: currentProviderID)
        let storedList = possibleKeys.lazy
            .compactMap { SettingsStore.shared.availableModelsByProvider[$0] }
            .first { !$0.isEmpty }

        if let stored = storedList {
            self.availableModels = stored
        } else {
            self.availableModels = ModelRepository.shared.defaultModels(for: currentProviderID)
        }

        // If current model not in list, select first available
        if !self.availableModels.contains(currentModel) {
            self.settings.rewriteModeSelectedModel = self.availableModels.first ?? "gpt-4.1"
        }
    }

    private func providerKeys(for providerID: String) -> [String] {
        return ModelRepository.shared.providerKeys(for: providerID)
    }

    private var builtInProvidersList: [(id: String, name: String)] {
        ModelRepository.shared.builtInProvidersList(
            includeAppleIntelligence: true,
            appleIntelligenceAvailable: AppleIntelligenceService.isAvailable
        )
    }

    private var shortcutDisplay: String {
        self.settings.rewriteModeHotkeyShortcut.displayString
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
                    // Write fresh
                    VStack(alignment: .leading, spacing: 4) {
                        Text("To Write Fresh")
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
                            Text("and speak what you want to write.")
                                .font(.caption)
                        }
                        .foregroundStyle(.primary.opacity(0.8))

                        self.howToItem("\"Write an email asking for time off\"")
                        self.howToItem("\"Draft a thank you note\"")
                    }

                    // Rewrite
                    VStack(alignment: .leading, spacing: 4) {
                        Text("To Rewrite/Edit")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 4) {
                            Text("Select text first, then press")
                                .font(.caption)
                            Text(self.shortcutDisplay)
                                .font(.caption)
                                .fontWeight(.medium)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.1))
                                .cornerRadius(4)
                            Text("and speak your instruction.")
                                .font(.caption)
                        }
                        .foregroundStyle(.primary.opacity(0.8))

                        self.howToItem("\"Make this more formal\"")
                        self.howToItem("\"Fix grammar and spelling\"")
                        self.howToItem("\"Summarize this\"")
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

    // MARK: - Thinking View (Cursor-style shimmer)

    private var thinkingView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with shimmer effect - tap to expand/collapse
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { self.isThinkingExpanded.toggle() } }) {
                HStack(spacing: 8) {
                    ThinkingShimmerLabel()

                    Spacer()

                    Image(systemName: self.isThinkingExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            // Expanded content
            if self.isThinkingExpanded {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(self.service.streamingThinkingText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
                .frame(maxHeight: 150)
            } else {
                // Preview - first 100 chars
                if !self.service.streamingThinkingText.isEmpty {
                    Text(String(self.service.streamingThinkingText.prefix(100)) + (self.service.streamingThinkingText.count > 100 ? "..." : ""))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary.opacity(0.7))
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }
        }
        .background(self.theme.palette.cardBackground.opacity(0.9))
        .cornerRadius(8)
    }
}
