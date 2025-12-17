import Combine
import SwiftUI

// MARK: - Observable state for notch content (Singleton)

@MainActor
class NotchContentState: ObservableObject {
    static let shared = NotchContentState()

    @Published var transcriptionText: String = ""
    @Published var mode: OverlayMode = .dictation
    @Published var isProcessing: Bool = false // AI processing state

    // Cached transcription lines to avoid recomputing on every render
    @Published private(set) var cachedLine1: String = ""
    @Published private(set) var cachedLine2: String = ""

    // MARK: - Expanded Command Output State

    @Published var isExpandedForCommandOutput: Bool = false
    @Published var commandOutput: String = "" // Final or streaming output
    @Published var commandStreamingText: String = "" // Real-time streaming text
    @Published var commandInputText: String = "" // User's follow-up input
    @Published var commandConversationHistory: [CommandOutputMessage] = []
    @Published var isCommandProcessing: Bool = false

    // MARK: - Chat History State

    @Published var recentChats: [ChatSession] = []
    @Published var currentChatTitle: String = "New Chat"

    // Command output message model
    struct CommandOutputMessage: Identifiable, Equatable {
        let id = UUID()
        let role: Role
        let content: String
        let timestamp: Date = .init()

        enum Role: Equatable {
            case user
            case assistant
            case status // For "Running...", "Checking...", etc.
        }
    }

    // Callback for submitting follow-up commands from the notch
    var onSubmitFollowUp: ((String) async -> Void)?

    private init() {}

    /// Set AI processing state
    func setProcessing(_ processing: Bool) {
        self.isProcessing = processing
    }

    /// Update transcription and recompute cached lines
    func updateTranscription(_ text: String) {
        guard text != self.transcriptionText else { return }
        self.transcriptionText = text
        self.recomputeTranscriptionLines()
    }

    /// Recompute cached transcription lines (called only when text changes)
    private func recomputeTranscriptionLines() {
        let text = self.transcriptionText

        guard !text.isEmpty else {
            self.cachedLine1 = ""
            self.cachedLine2 = ""
            return
        }

        // Show last ~100 characters
        let maxChars = 100
        let displayText = text.count > maxChars ? String(text.suffix(maxChars)) : text

        // Split into words
        let words = displayText.split(separator: " ").map(String.init)

        if words.count <= 6 {
            // Short: only line 2
            self.cachedLine1 = ""
            self.cachedLine2 = displayText
        } else {
            // Long: split roughly in half
            let midPoint = words.count / 2
            self.cachedLine1 = words[..<midPoint].joined(separator: " ")
            self.cachedLine2 = words[midPoint...].joined(separator: " ")
        }
    }

    // MARK: - Recording State for Expanded View

    @Published var isRecordingInExpandedMode: Bool = false
    @Published var expandedModeAudioLevel: CGFloat = 0 // Audio level for waveform in expanded mode

    /// Set recording state (for waveform visibility in expanded view)
    func setRecordingInExpandedMode(_ recording: Bool) {
        self.isRecordingInExpandedMode = recording
        if !recording {
            self.expandedModeAudioLevel = 0
        }
    }

    /// Update audio level for expanded mode waveform
    func updateExpandedModeAudioLevel(_ level: CGFloat) {
        guard self.isRecordingInExpandedMode else { return }
        self.expandedModeAudioLevel = level
    }

    // MARK: - Command Output Methods

    /// Show expanded output view with content
    func showExpandedCommandOutput(output: String) {
        self.commandOutput = output
        self.commandStreamingText = ""
        self.isExpandedForCommandOutput = true
        self.isRecordingInExpandedMode = false // Not recording when first showing output
    }

    /// Update streaming text in real-time
    func updateCommandStreamingText(_ text: String) {
        self.commandStreamingText = text
    }

    /// Add a message to the conversation history
    func addCommandMessage(role: CommandOutputMessage.Role, content: String) {
        let message = CommandOutputMessage(role: role, content: content)
        self.commandConversationHistory.append(message)
    }

    /// Set command processing state
    func setCommandProcessing(_ processing: Bool) {
        self.isCommandProcessing = processing
    }

    /// Clear command output and hide expanded view
    func clearCommandOutput() {
        self.isExpandedForCommandOutput = false
        self.commandOutput = ""
        self.commandStreamingText = ""
        self.commandInputText = ""
        self.commandConversationHistory.removeAll()
        self.isCommandProcessing = false
    }

    /// Hide expanded view but keep history
    func collapseCommandOutput() {
        self.isExpandedForCommandOutput = false
    }

    // MARK: - Chat History Methods

    /// Refresh recent chats from store
    func refreshRecentChats() {
        self.recentChats = ChatHistoryStore.shared.getRecentChats(excludingCurrent: false)
        if let current = ChatHistoryStore.shared.currentSession {
            self.currentChatTitle = current.title
        }
    }
}

// MARK: - Shared Mode Color Helper

extension OverlayMode {
    /// Mode-specific color for notch UI elements
    var notchColor: Color {
        switch self {
        case .dictation:
            return Color.white.opacity(0.85)
        case .rewrite:
            return Color(red: 0.45, green: 0.55, blue: 1.0) // Lighter blue
        case .write:
            return Color(red: 0.4, green: 0.6, blue: 1.0) // Blue
        case .command:
            return Color(red: 1.0, green: 0.35, blue: 0.35) // Red
        }
    }
}

// MARK: - Shimmer Text (Cursor-style thinking animation)

struct ShimmerText: View {
    let text: String
    let color: Color

    @State private var shimmerPhase: CGFloat = 0

    var body: some View {
        Text(self.text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(LinearGradient(
                colors: [
                    self.color.opacity(0.4),
                    self.color.opacity(0.4),
                    self.color.opacity(1.0),
                    self.color.opacity(0.4),
                    self.color.opacity(0.4),
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

// MARK: - Expanded View (Main Content) - Minimal Design

struct NotchExpandedView: View {
    let audioPublisher: AnyPublisher<CGFloat, Never>
    @ObservedObject private var contentState = NotchContentState.shared

    private var modeColor: Color {
        self.contentState.mode.notchColor
    }

    private var modeLabel: String {
        switch self.contentState.mode {
        case .dictation: return "Dictate"
        case .rewrite: return "Rewrite"
        case .write: return "Write"
        case .command: return "Command"
        }
    }

    private var processingLabel: String {
        switch self.contentState.mode {
        case .dictation: return "Refining..."
        case .rewrite: return "Thinking..."
        case .write: return "Thinking..."
        case .command: return "Working..."
        }
    }

    private var hasTranscription: Bool {
        !self.contentState.transcriptionText.isEmpty
    }

    // Check if there's command history that can be expanded
    private var canExpandCommandHistory: Bool {
        self.contentState.mode == .command && !self.contentState.commandConversationHistory.isEmpty
    }

    var body: some View {
        VStack(spacing: 4) {
            // Visualization + Mode label row
            HStack(spacing: 6) {
                NotchWaveformView(
                    audioPublisher: self.audioPublisher,
                    color: self.modeColor
                )
                .frame(width: 80, height: 22)

                // Mode label - shimmer effect when processing
                if self.contentState.isProcessing {
                    ShimmerText(text: self.processingLabel, color: self.modeColor)
                } else {
                    Text(self.modeLabel)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(self.modeColor)
                        .opacity(0.9)
                }
            }

            // Transcription preview (single line, minimal)
            if self.hasTranscription && !self.contentState.isProcessing {
                Text(self.contentState.cachedLine2)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 180)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.black)
        .contentShape(Rectangle()) // Make entire area tappable
        .onTapGesture {
            // If in command mode with history, clicking expands the conversation
            if self.canExpandCommandHistory {
                NotchOverlayManager.shared.onNotchClicked?()
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: self.hasTranscription)
        .animation(.easeInOut(duration: 0.2), value: self.contentState.mode)
        .animation(.easeInOut(duration: 0.25), value: self.contentState.isProcessing)
    }
}

// MARK: - Minimal Notch Waveform (Color-matched)

struct NotchWaveformView: View {
    let audioPublisher: AnyPublisher<CGFloat, Never>
    let color: Color

    @StateObject private var data: AudioVisualizationData
    @ObservedObject private var contentState = NotchContentState.shared
    @State private var barHeights: [CGFloat] = Array(repeating: 3, count: 7)
    @State private var glowPhase: CGFloat = 0 // 0 to 1, controls glow intensity
    @State private var glowTimer: Timer? = nil
    @State private var noiseThreshold: CGFloat = .init(SettingsStore.shared.visualizerNoiseThreshold)

    private let barCount = 7
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 4
    private let minHeight: CGFloat = 3
    private let maxHeight: CGFloat = 20

    // Computed glow values based on phase (sine wave for smooth pulsing)
    private var currentGlowIntensity: CGFloat {
        self.contentState.isProcessing ? 0.4 + 0.4 * sin(self.glowPhase * .pi * 2) : 0.4
    }

    private var currentGlowRadius: CGFloat {
        self.contentState.isProcessing ? 2 + 4 * sin(self.glowPhase * .pi * 2) : 2
    }

    private var currentOuterGlowRadius: CGFloat {
        self.contentState.isProcessing ? 6 * sin(self.glowPhase * .pi * 2) : 0
    }

    init(audioPublisher: AnyPublisher<CGFloat, Never>, color: Color, isProcessing: Bool = false) {
        self.audioPublisher = audioPublisher
        self.color = color
        _data = StateObject(wrappedValue: AudioVisualizationData(audioLevelPublisher: audioPublisher))
    }

    var body: some View {
        HStack(spacing: self.barSpacing) {
            ForEach(0..<self.barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: self.barWidth / 2)
                    .fill(self.color)
                    .frame(width: self.barWidth, height: self.barHeights[index])
                    .shadow(
                        color: self.color.opacity(self.currentGlowIntensity),
                        radius: self.currentGlowRadius,
                        x: 0,
                        y: 0
                    )
                    .shadow(
                        color: self.color.opacity(self.currentGlowIntensity * 0.5),
                        radius: self.currentOuterGlowRadius,
                        x: 0,
                        y: 0
                    )
            }
        }
        .onChange(of: self.data.audioLevel) { _, level in
            if !self.contentState.isProcessing {
                self.updateBars(level: level)
            }
        }
        .onChange(of: self.contentState.isProcessing) { _, processing in
            if processing {
                self.setStaticProcessingBars()
                self.startGlowAnimation()
            } else {
                self.stopGlowAnimation()
            }
        }
        .onAppear {
            if self.contentState.isProcessing {
                self.setStaticProcessingBars()
                self.startGlowAnimation()
            } else {
                self.updateBars(level: 0)
            }
        }
        .onDisappear {
            self.stopGlowAnimation()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            // Update threshold when user changes sensitivity setting
            let newThreshold = CGFloat(SettingsStore.shared.visualizerNoiseThreshold)
            if newThreshold != self.noiseThreshold {
                self.noiseThreshold = newThreshold
            }
        }
    }

    private func startGlowAnimation() {
        self.stopGlowAnimation() // Clean up any existing timer
        self.glowPhase = 0

        // Timer-based animation for explicit control
        self.glowTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            withAnimation(.linear(duration: 1.0 / 30.0)) {
                self.glowPhase += 1.0 / 30.0 / 1.5 // Complete cycle in 1.5 seconds
                if self.glowPhase >= 1.0 {
                    self.glowPhase = 0
                }
            }
        }
    }

    private func stopGlowAnimation() {
        self.glowTimer?.invalidate()
        self.glowTimer = nil
        self.glowPhase = 0
    }

    private func setStaticProcessingBars() {
        // Set bars to a nice static shape (taller in center)
        withAnimation(.easeInOut(duration: 0.3)) {
            for i in 0..<self.barCount {
                let centerDistance = abs(CGFloat(i) - CGFloat(self.barCount - 1) / 2)
                let centerFactor = 1.0 - (centerDistance / CGFloat(self.barCount / 2)) * 0.4
                self.barHeights[i] = self.minHeight + (self.maxHeight - self.minHeight) * 0.5 * centerFactor
            }
        }
    }

    private func updateBars(level: CGFloat) {
        let normalizedLevel = min(max(level, 0), 1)
        let isActive = normalizedLevel > self.noiseThreshold // Use user's sensitivity setting

        withAnimation(.spring(response: 0.15, dampingFraction: 0.6)) {
            for i in 0..<self.barCount {
                let centerDistance = abs(CGFloat(i) - CGFloat(self.barCount - 1) / 2)
                let centerFactor = 1.0 - (centerDistance / CGFloat(self.barCount / 2)) * 0.4

                if isActive {
                    // Scale audio level relative to threshold for smoother response
                    let adjustedLevel = (normalizedLevel - self.noiseThreshold) / (1.0 - self.noiseThreshold)
                    let randomVariation = CGFloat.random(in: 0.7...1.0)
                    self.barHeights[i] = self
                        .minHeight + (self.maxHeight - self.minHeight) * adjustedLevel * centerFactor * randomVariation
                } else {
                    // Complete stillness when below threshold
                    self.barHeights[i] = self.minHeight
                }
            }
        }
    }
}

// MARK: - Compact Views (Small States)

struct NotchCompactLeadingView: View {
    @ObservedObject private var contentState = NotchContentState.shared
    @State private var isPulsing = false

    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(self.contentState.mode.notchColor)
            .scaleEffect(self.isPulsing ? 1.1 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: self.isPulsing)
            .onAppear { self.isPulsing = true }
            .onDisappear { self.isPulsing = false }
    }
}

struct NotchCompactTrailingView: View {
    @ObservedObject private var contentState = NotchContentState.shared
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(self.contentState.mode.notchColor)
            .frame(width: 5, height: 5)
            .opacity(self.isPulsing ? 0.5 : 1.0)
            .scaleEffect(self.isPulsing ? 0.85 : 1.0)
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: self.isPulsing)
            .onAppear { self.isPulsing = true }
            .onDisappear { self.isPulsing = false }
    }
}

// MARK: - Expanded Command Output View (Interactive Notch)

struct NotchCommandOutputExpandedView: View {
    let audioPublisher: AnyPublisher<CGFloat, Never>
    let onDismiss: () -> Void
    let onSubmit: (String) async -> Void
    let onNewChat: () -> Void
    let onSwitchChat: (String) -> Void
    let onClearChat: () -> Void

    @ObservedObject private var contentState = NotchContentState.shared
    @State private var inputText: String = ""
    @FocusState private var isInputFocused: Bool
    @State private var scrollProxy: ScrollViewProxy?
    @State private var isHoveringNewChat = false
    @State private var isHoveringRecent = false
    @State private var isHoveringClear = false
    @State private var isHoveringDismiss = false

    private let commandRed = Color(red: 1.0, green: 0.35, blue: 0.35)

    // Dynamic height based on content (max half screen)
    private var dynamicHeight: CGFloat {
        let baseHeight: CGFloat = 120 // Minimum height
        let contentHeight = self.estimateContentHeight()
        let maxHeight = (NSScreen.main?.frame.height ?? 800) * 0.45 // 45% of screen
        return min(max(baseHeight, contentHeight), maxHeight)
    }

    private func estimateContentHeight() -> CGFloat {
        var height: CGFloat = 80 // Header + input area

        // Estimate based on conversation history
        for message in self.contentState.commandConversationHistory {
            let lineCount = max(1, message.content.count / 60) // ~60 chars per line
            height += CGFloat(lineCount) * 18 + 16 // Line height + padding
        }

        // Add streaming text height
        if !self.contentState.commandStreamingText.isEmpty {
            let lineCount = max(1, contentState.commandStreamingText.count / 60)
            height += CGFloat(lineCount) * 18 + 16
        }

        return height
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with waveform and dismiss
            self.headerView

            // Transcription preview (shown while recording)
            self.transcriptionPreview

            Divider()
                .background(self.commandRed.opacity(0.3))

            // Scrollable conversation area
            self.conversationArea

            // Input area for follow-up commands
            self.inputArea
        }
        .frame(width: 380, height: self.dynamicHeight)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .animation(
            .spring(response: 0.3, dampingFraction: 0.8),
            value: self.contentState.commandConversationHistory.count
        )
        // No animation on streamingText - it updates too frequently, animations add overhead
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: self.contentState.isRecordingInExpandedMode)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 8) {
            // Left: Waveform + Mode label
            HStack(spacing: 6) {
                // Waveform - only show when recording, otherwise show static indicator
                if self.contentState.isRecordingInExpandedMode {
                    ExpandedModeWaveformView(color: self.commandRed)
                        .frame(width: 50, height: 18)
                } else {
                    // Static indicator when not recording
                    HStack(spacing: 3) {
                        ForEach(0..<5, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(self.commandRed.opacity(0.4))
                                .frame(width: 3, height: 6)
                        }
                    }
                    .frame(width: 50, height: 18)
                }

                // Mode label
                if self.contentState.isRecordingInExpandedMode {
                    Text("Listening...")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(self.commandRed)
                } else if self.contentState.isCommandProcessing {
                    ShimmerText(text: "Working...", color: self.commandRed)
                } else {
                    Text("Command")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(self.commandRed.opacity(0.7))
                }
            }

            Spacer()

            // Right: Chat management buttons + Dismiss
            HStack(spacing: 6) {
                // New Chat Button (+)
                Button(action: self.onNewChat) {
                    ZStack {
                        Circle()
                            .fill(self.isHoveringNewChat ? self.commandRed.opacity(0.25) : self.commandRed
                                .opacity(0.12))
                            .frame(width: 22, height: 22)
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(self.contentState.isCommandProcessing ? .white.opacity(0.3) : self
                                .commandRed.opacity(0.85))
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .onHover { self.isHoveringNewChat = $0 }
                .disabled(self.contentState.isCommandProcessing)
                .help("New chat")

                // Recent Chats Menu
                Menu {
                    let recentChats = self.contentState.recentChats
                    let currentID = ChatHistoryStore.shared.currentChatID
                    if recentChats.isEmpty {
                        Text("No recent chats")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(recentChats) { chat in
                            Button(action: {
                                if chat.id != currentID {
                                    self.onSwitchChat(chat.id)
                                }
                            }) {
                                HStack {
                                    if chat.id == currentID {
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
                            .disabled(self.contentState.isCommandProcessing)
                        }
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(self.isHoveringRecent ? self.commandRed.opacity(0.25) : self.commandRed.opacity(0.12))
                            .frame(width: 22, height: 22)
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(self.commandRed.opacity(0.85))
                    }
                }
                .menuIndicator(.hidden)
                .menuStyle(.button)
                .buttonStyle(.plain)
                .frame(width: 22, height: 22)
                .onHover { self.isHoveringRecent = $0 }
                .help("Recent chats")

                // Delete Chat Button - deletes the current chat entirely
                Button(action: self.onClearChat) {
                    ZStack {
                        Circle()
                            .fill(self.isHoveringClear ? self.commandRed.opacity(0.25) : self.commandRed.opacity(0.12))
                            .frame(width: 22, height: 22)
                        Image(systemName: "trash")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(self.contentState.isCommandProcessing ? .white.opacity(0.3) : self
                                .commandRed.opacity(0.85))
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .onHover { self.isHoveringClear = $0 }
                .disabled(self.contentState.isCommandProcessing)
                .help("Delete chat")

                // Vertical divider
                Rectangle()
                    .fill(.white.opacity(0.15))
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 2)

                // Dismiss Button (X)
                Button(action: self.onDismiss) {
                    ZStack {
                        Circle()
                            .fill(self.isHoveringDismiss ? self.commandRed.opacity(0.25) : self.commandRed
                                .opacity(0.12))
                            .frame(width: 22, height: 22)
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(self.commandRed.opacity(0.85))
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .onHover { self.isHoveringDismiss = $0 }
                .help("Close (Escape)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear {
            self.contentState.refreshRecentChats()
        }
    }

    // MARK: - Transcription Preview (shown while recording)

    private var transcriptionPreview: some View {
        Group {
            if self.contentState.isRecordingInExpandedMode && !self.contentState.transcriptionText.isEmpty {
                VStack(spacing: 2) {
                    if !self.contentState.cachedLine1.isEmpty {
                        Text(self.contentState.cachedLine1)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                    Text(self.contentState.cachedLine2)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(self.commandRed.opacity(0.1))
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: self.contentState.isRecordingInExpandedMode)
        .animation(.easeInOut(duration: 0.15), value: self.contentState.transcriptionText)
    }

    // MARK: - Conversation Area

    private var conversationArea: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(self.contentState.commandConversationHistory) { message in
                        self.messageView(for: message)
                            .id(message.id)
                    }

                    // Streaming text (real-time)
                    if !self.contentState.commandStreamingText.isEmpty {
                        self.streamingMessageView
                            .id("streaming")
                    }

                    // Processing indicator
                    if self.contentState.isCommandProcessing && self.contentState.commandStreamingText.isEmpty {
                        self.processingIndicator
                            .id("processing")
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onAppear {
                self.scrollProxy = proxy
                // Always scroll to bottom when view appears
                self.scrollToBottom(proxy, animated: false)
            }
            .onChange(of: self.contentState.commandConversationHistory.count) { _, _ in
                self.scrollToBottom(proxy, animated: true)
            }
            .onChange(of: self.contentState.commandStreamingText) { _, _ in
                self.scrollToBottom(proxy, animated: true)
            }
            .onChange(of: self.contentState.isCommandProcessing) { _, _ in
                // Scroll when processing state changes
                self.scrollToBottom(proxy, animated: true)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if animated {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: - Message Views

    private func messageView(for message: NotchContentState.CommandOutputMessage) -> some View {
        HStack(alignment: .top, spacing: 6) {
            switch message.role {
            case .user:
                Spacer()
                Text(message.content)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(self.commandRed.opacity(0.25))
                    .cornerRadius(8)
                    .frame(maxWidth: 280, alignment: .trailing)
                    .textSelection(.enabled)

            case .assistant:
                Text(message.content)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(8)
                    .frame(maxWidth: 320, alignment: .leading)
                    .textSelection(.enabled)
                Spacer()

            case .status:
                HStack(spacing: 4) {
                    Circle()
                        .fill(self.commandRed.opacity(0.6))
                        .frame(width: 4, height: 4)
                    Text(message.content)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.vertical, 2)
                Spacer()
            }
        }
    }

    private var streamingMessageView: some View {
        HStack(alignment: .top) {
            Text(self.contentState.commandStreamingText)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08))
                .cornerRadius(8)
                .frame(maxWidth: 320, alignment: .leading)
                .drawingGroup() // Flatten to bitmap for faster streaming updates
            // textSelection disabled during streaming for performance
            Spacer()
        }
    }

    private var processingIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(self.commandRed.opacity(0.6))
                    .frame(width: 4, height: 4)
                    .offset(y: self.processingOffset(for: index))
            }
        }
        .padding(.vertical, 4)
    }

    @State private var processingAnimation = false

    private func processingOffset(for index: Int) -> CGFloat {
        // Offset varies by index for staggered animation effect
        _ = Double(index) * 0.15 // Reserved for future animation timing
        return self.processingAnimation ? -3 : 3
    }

    // MARK: - Input Area

    private var inputArea: some View {
        HStack(spacing: 8) {
            TextField("Ask follow-up...", text: self.$inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08))
                .cornerRadius(8)
                .focused(self.$isInputFocused)
                .onSubmit {
                    self.submitFollowUp()
                }

            Button(action: self.submitFollowUp) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(self.inputText.isEmpty ? .white.opacity(0.3) : self.commandRed)
            }
            .buttonStyle(.plain)
            .disabled(self.inputText.isEmpty || self.contentState.isCommandProcessing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.03))
    }

    private func submitFollowUp() {
        guard !self.inputText.isEmpty else { return }
        let text = self.inputText
        self.inputText = ""

        Task {
            await self.onSubmit(text)
        }
    }
}

// MARK: - Expanded Mode Waveform (Reads from NotchContentState)

struct ExpandedModeWaveformView: View {
    let color: Color

    @ObservedObject private var contentState = NotchContentState.shared
    @State private var barHeights: [CGFloat] = Array(repeating: 3, count: 5)

    private let barCount = 5
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 3
    private let minHeight: CGFloat = 4
    private let maxHeight: CGFloat = 16
    private let noiseThreshold: CGFloat = 0.05

    var body: some View {
        HStack(spacing: self.barSpacing) {
            ForEach(0..<self.barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: self.barWidth / 2)
                    .fill(self.color)
                    .frame(width: self.barWidth, height: self.barHeights[index])
                    .shadow(color: self.color.opacity(0.4), radius: 2, x: 0, y: 0)
            }
        }
        .onChange(of: self.contentState.expandedModeAudioLevel) { _, level in
            self.updateBars(level: level)
        }
        .onAppear {
            self.updateBars(level: self.contentState.expandedModeAudioLevel)
        }
    }

    private func updateBars(level: CGFloat) {
        let normalizedLevel = min(max(level, 0), 1)
        let isActive = normalizedLevel > self.noiseThreshold

        withAnimation(.spring(response: 0.12, dampingFraction: 0.6)) {
            for i in 0..<self.barCount {
                let centerDistance = abs(CGFloat(i) - CGFloat(self.barCount - 1) / 2)
                let centerFactor = 1.0 - (centerDistance / CGFloat(self.barCount / 2)) * 0.35

                if isActive {
                    let adjustedLevel = (normalizedLevel - self.noiseThreshold) / (1.0 - self.noiseThreshold)
                    let randomVariation = CGFloat.random(in: 0.75...1.0)
                    self.barHeights[i] = self
                        .minHeight + (self.maxHeight - self.minHeight) * adjustedLevel * centerFactor * randomVariation
                } else {
                    self.barHeights[i] = self.minHeight
                }
            }
        }
    }
}
