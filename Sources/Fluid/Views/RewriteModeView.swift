import SwiftUI

struct RewriteModeView: View {
    @ObservedObject var service: RewriteModeService
    @EnvironmentObject var appServices: AppServices
    private var asr: ASRService {
        self.appServices.asr
    }

    @ObservedObject var settings = SettingsStore.shared
    @EnvironmentObject var menuBarManager: MenuBarManager
    @Environment(\.theme) private var theme
    var onClose: (() -> Void)?

    @State private var inputText: String = ""
    @State private var showOriginal: Bool = true
    @State private var showHowTo: Bool = false
    @State private var isThinkingExpanded: Bool = false
    @FocusState private var inputFocused: Bool

    /// Local state for available models (derived from shared AI Settings pool)
    @State private var availableModels: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            // The top bar already names the page, so this line carries only the note and the close button.
            HStack {
                Text("Edit Mode is powered by Custom Prompts.")
                    .fluidText(.label)
                    .foregroundStyle(self.theme.look.secondaryText)

                Spacer()

                Button(action: { self.onClose?() }) {
                    Image(systemName: "xmark")
                        .font(.fluidSystem(size: 12, weight: .semibold))
                }
                .fluidGlassAction(circular: true, quiet: true)
                .accessibilityLabel("Close Edit Mode")
            }
            .padding(.horizontal)
            .padding(.vertical, self.theme.metrics.spacing.sm)

            // How To (collapsible)
            self.howToSection

            FluidHairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Original Text Section
                    if !self.service.originalText.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Original Text")
                                    .fluidText(.label)
                                    .foregroundStyle(self.theme.look.secondaryText)
                                Spacer()
                                if !self.service.rewrittenText.isEmpty {
                                    Button(self.showOriginal ? "Hide" : "Show") {
                                        withAnimation { self.showOriginal.toggle() }
                                    }
                                    .fluidGlassAction(quiet: true)
                                }
                            }

                            if self.showOriginal {
                                Text(self.service.originalText)
                                    .fluidText(.body)
                                    .foregroundStyle(self.theme.look.text)
                                    .padding()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(self.theme.look.surface, in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous))
                                    .textSelection(.enabled)
                            }
                        }
                    } else {
                        // The header already names the mode, so the empty state only says what it does.
                        VStack(spacing: self.theme.metrics.spacing.md) {
                            Image(systemName: "text.bubble")
                                .font(.fluidSystem(size: 40, weight: .light))
                                .foregroundStyle(self.theme.look.tertiaryText)
                                .accessibilityHidden(true)
                            Text("Ask the AI to write anything for you - emails, replies, summaries, answers, and more.")
                                .fluidText(.body)
                                .foregroundStyle(self.theme.look.secondaryText)
                                .multilineTextAlignment(.center)

                            Text("Or select text first to rewrite existing content.")
                                .fluidText(.label)
                                .foregroundStyle(self.theme.look.tertiaryText)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }

                    // Rewritten Text Section
                    if !self.service.rewrittenText.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Rewritten Text")
                                .fluidText(.label)
                                .foregroundStyle(self.theme.look.secondaryText)

                            Text(self.service.rewrittenText)
                                .fluidText(.body)
                                .foregroundStyle(self.theme.look.text)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(self.theme.look.highlightFill, in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous))
                                .textSelection(.enabled)

                            HStack {
                                Button("Try Again") {
                                    self.service.rewrittenText = ""
                                }
                                .fluidAction()

                                Spacer()

                                Button("Replace Original") {
                                    let text = self.service.rewrittenText
                                    Task { @MainActor in
                                        await self.service.acceptRewrite(text)
                                    }
                                    self.onClose?()
                                }
                                .fluidAction(.primary)
                            }
                            .padding(.top, 8)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // Conversation History (optional, maybe just last error)
                    if let lastMsg = service.conversationHistory.last, lastMsg.role == .assistant,
                       service.rewrittenText.isEmpty
                    {
                        Label(lastMsg.content, systemImage: "exclamationmark.triangle") // Error message usually
                            .fluidText(.body)
                            .foregroundStyle(self.theme.look.text)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(self.theme.look.surface, in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous))
                    }
                }
                .padding()
            }
            .padding(.horizontal, self.theme.metrics.spacing.lg)
            .padding(.vertical, self.theme.metrics.spacing.sm)

            FluidHairline()

            // Input Area with model selectors inline
            HStack(spacing: 8) {
                // Provider Selector (compact, searchable)
                SearchableProviderPicker(
                    builtInProviders: self.builtInProvidersList,
                    savedProviders: self.settings.savedProviders,
                    selectedProviderID: Binding(
                        get: { self.settings.rewriteModeSelectedProviderID },
                        set: { newValue in
                            self.settings.rewriteModeSelectedProviderID = newValue
                            self.updateAvailableModels()
                        }
                    )
                )

                SearchableModelPicker(
                    models: self.availableModels,
                    selectedModel: Binding(
                        get: { self.settings.rewriteModeSelectedModel ?? self.availableModels.first ?? "" },
                        set: { self.settings.rewriteModeSelectedModel = $0 }
                    ),
                    onRefresh: nil,
                    isRefreshing: false
                )

                // Input field (flexible)
                TextField(
                    self.service.originalText.isEmpty
                        ? "Ask me to write or edit..."
                        : "How should I edit this?",
                    text: self.$inputText
                )
                .textFieldStyle(.plain)
                .fluidText(.body)
                .focused(self.$inputFocused)
                .fluidFieldChrome(isFocused: self.inputFocused, padding: self.theme.metrics.spacing.sm)
                .onSubmit(self.submitRequest)

                Button(action: self.submitRequest) {
                    Image(systemName: "arrow.up")
                        .font(.fluidSystem(size: 13, weight: .semibold))
                }
                .fluidAction(.primary)
                .disabled(self.inputText.isEmpty || self.service.isProcessing)
                .accessibilityLabel("Send")

                // Voice Input
                Button(action: self.toggleRecording) {
                    Image(systemName: self.asr.isRunning ? "stop.fill" : "mic")
                        .foregroundStyle(self.theme.look.text)
                }
                .fluidGlassAction(circular: true, quiet: true)
                .accessibilityLabel(self.asr.isRunning ? "Stop recording" : "Speak an instruction")

                if self.service.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                        .fixedSize()
                }
            }
            .padding()

            // Thinking view (real-time, during processing)
            if self.service.isProcessing && self.settings.showThinkingTokens && !self.service.streamingThinkingText.isEmpty {
                self.thinkingView
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
        .fluidCanvas()
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
            Task {
                _ = await self.asr.stop()
                _ = self.asr.consumeLastCompletedAudioSnapshot()
            }
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
        let currentModel = self.settings.rewriteModeSelectedModel ?? ""
        guard !currentProviderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.availableModels = []
            return
        }

        // Pull models from the shared pool configured in AI Settings
        self.availableModels = self.settings.availableModels(for: currentProviderID, task: .edit)

        // If current model not in list, select first available
        if !self.availableModels.contains(currentModel) {
            self.settings.rewriteModeSelectedModel = self.availableModels.first
        }
    }

    private var builtInProvidersList: [(id: String, name: String)] {
        ModelRepository.shared.builtInProvidersList()
    }

    private var shortcutDisplay: String {
        self.settings.rewriteModeHotkeyShortcut.displayString
    }

    private var howToSection: some View {
        let look = self.theme.look
        return VStack(spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { self.showHowTo.toggle() } }) {
                HStack {
                    Text("How to use")
                    Spacer()
                    Image(systemName: self.showHowTo ? "chevron.up" : "chevron.down")
                        .font(.fluidSystem(size: 10, weight: .semibold))
                }
                .fluidText(.label)
                .foregroundStyle(look.secondaryText)
                .padding(.horizontal, self.theme.metrics.spacing.lg)
                .padding(.vertical, self.theme.metrics.spacing.sm)
                .contentShape(Rectangle())
            }
            .fluidSelectableRow(isSelected: false)

            if self.showHowTo {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                    self.howToGroup(
                        title: "Create New Text",
                        lead: "Press",
                        trail: "and speak what you want to write.",
                        examples: ["\"Write an email asking for time off\"", "\"Draft a thank you note\""]
                    )
                    self.howToGroup(
                        title: "Edit Selected Text",
                        lead: "Select text first, then press",
                        trail: "and speak your instruction.",
                        examples: ["\"Make this more formal\"", "\"Fix grammar and spelling\"", "\"Summarize this\""]
                    )
                }
                .padding(.horizontal, self.theme.metrics.spacing.lg)
                .padding(.bottom, self.theme.metrics.spacing.md)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// One way to use Edit Mode: a title, the shortcut in a sentence, then example phrases.
    private func howToGroup(title: String, lead: String, trail: String, examples: [String]) -> some View {
        let look = self.theme.look
        return VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
            Text(title)
                .fluidText(.rowTitle)
                .foregroundStyle(look.text)
            HStack(spacing: self.theme.metrics.spacing.xs) {
                Text(lead)
                Text(self.shortcutDisplay)
                    .foregroundStyle(look.text)
                    .padding(.horizontal, self.theme.metrics.spacing.xs + 2)
                    .padding(.vertical, 2)
                    .background(look.quietFill, in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous))
                Text(trail)
            }
            .fluidText(.label)
            .foregroundStyle(look.secondaryText)
            ForEach(examples, id: \.self) { example in
                Text(example)
                    .fluidText(.label)
                    .foregroundStyle(look.tertiaryText)
            }
        }
    }

    // MARK: - Thinking View (Cursor-style shimmer)

    private var thinkingView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with shimmer effect - tap to expand/collapse
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { self.isThinkingExpanded.toggle() } }) {
                HStack(spacing: 8) {
                    CommandShimmerText(text: "Thinking")

                    Spacer()

                    Image(systemName: self.isThinkingExpanded ? "chevron.up" : "chevron.down")
                        .font(.fluidSystem(size: 10, weight: .semibold))
                        .foregroundStyle(self.theme.look.tertiaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .fluidSelectableRow(isSelected: false)

            // Expanded content
            if self.isThinkingExpanded {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(self.service.streamingThinkingText)
                        .fluidText(.label)
                        .foregroundStyle(self.theme.look.secondaryText)
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
                        .fluidText(.label)
                        .foregroundStyle(self.theme.look.tertiaryText)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }
        }
        .background(self.theme.look.surface, in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous))
    }
}
