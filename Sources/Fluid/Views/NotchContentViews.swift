//
//  NotchContentViews.swift
//  Fluid
//
//  Created by Assistant
//

import SwiftUI
import Combine

// MARK: - Observable state for notch content (Singleton)

@MainActor
class NotchContentState: ObservableObject {
    static let shared = NotchContentState()
    
    @Published var transcriptionText: String = ""
    @Published var mode: OverlayMode = .dictation
    @Published var isProcessing: Bool = false  // AI processing state
    
    // Cached transcription lines to avoid recomputing on every render
    @Published private(set) var cachedLine1: String = ""
    @Published private(set) var cachedLine2: String = ""
    
    // MARK: - Expanded Command Output State
    @Published var isExpandedForCommandOutput: Bool = false
    @Published var commandOutput: String = ""  // Final or streaming output
    @Published var commandStreamingText: String = ""  // Real-time streaming text
    @Published var commandInputText: String = ""  // User's follow-up input
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
        let timestamp: Date = Date()
        
        enum Role: Equatable {
            case user
            case assistant
            case status  // For "Running...", "Checking...", etc.
        }
    }
    
    // Callback for submitting follow-up commands from the notch
    var onSubmitFollowUp: ((String) async -> Void)?
    
    private init() {}
    
    /// Set AI processing state
    func setProcessing(_ processing: Bool) {
        isProcessing = processing
    }
    
    /// Update transcription and recompute cached lines
    func updateTranscription(_ text: String) {
        guard text != transcriptionText else { return }
        transcriptionText = text
        recomputeTranscriptionLines()
    }
    
    /// Recompute cached transcription lines (called only when text changes)
    private func recomputeTranscriptionLines() {
        let text = transcriptionText
        
        guard !text.isEmpty else {
            cachedLine1 = ""
            cachedLine2 = ""
            return
        }
        
        // Show last ~100 characters
        let maxChars = 100
        let displayText = text.count > maxChars ? String(text.suffix(maxChars)) : text
        
        // Split into words
        let words = displayText.split(separator: " ").map(String.init)
        
        if words.count <= 6 {
            // Short: only line 2
            cachedLine1 = ""
            cachedLine2 = displayText
        } else {
            // Long: split roughly in half
            let midPoint = words.count / 2
            cachedLine1 = words[..<midPoint].joined(separator: " ")
            cachedLine2 = words[midPoint...].joined(separator: " ")
        }
    }
    
    // MARK: - Recording State for Expanded View
    @Published var isRecordingInExpandedMode: Bool = false
    @Published var expandedModeAudioLevel: CGFloat = 0  // Audio level for waveform in expanded mode

    // MARK: - Bottom Overlay Audio Level
    @Published var bottomOverlayAudioLevel: CGFloat = 0  // Audio level for bottom overlay waveform

    /// Set recording state (for waveform visibility in expanded view)
    func setRecordingInExpandedMode(_ recording: Bool) {
        isRecordingInExpandedMode = recording
        if !recording {
            expandedModeAudioLevel = 0
        }
    }
    
    /// Update audio level for expanded mode waveform
    func updateExpandedModeAudioLevel(_ level: CGFloat) {
        guard isRecordingInExpandedMode else { return }
        expandedModeAudioLevel = level
    }
    
    // MARK: - Command Output Methods
    
    /// Show expanded output view with content
    func showExpandedCommandOutput(output: String) {
        commandOutput = output
        commandStreamingText = ""
        isExpandedForCommandOutput = true
        isRecordingInExpandedMode = false  // Not recording when first showing output
    }
    
    /// Update streaming text in real-time
    func updateCommandStreamingText(_ text: String) {
        commandStreamingText = text
    }
    
    /// Add a message to the conversation history
    func addCommandMessage(role: CommandOutputMessage.Role, content: String) {
        let message = CommandOutputMessage(role: role, content: content)
        commandConversationHistory.append(message)
    }
    
    /// Set command processing state
    func setCommandProcessing(_ processing: Bool) {
        isCommandProcessing = processing
    }
    
    /// Clear command output and hide expanded view
    func clearCommandOutput() {
        isExpandedForCommandOutput = false
        commandOutput = ""
        commandStreamingText = ""
        commandInputText = ""
        commandConversationHistory.removeAll()
        isCommandProcessing = false
    }
    
    /// Hide expanded view but keep history
    func collapseCommandOutput() {
        isExpandedForCommandOutput = false
    }
    
    // MARK: - Chat History Methods
    
    /// Refresh recent chats from store
    func refreshRecentChats() {
        recentChats = ChatHistoryStore.shared.getRecentChats(excludingCurrent: false)
        if let current = ChatHistoryStore.shared.currentSession {
            currentChatTitle = current.title
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
            return Color(red: 0.4, green: 0.6, blue: 1.0)   // Blue
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
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        color.opacity(0.4),
                        color.opacity(0.4),
                        color.opacity(1.0),
                        color.opacity(0.4),
                        color.opacity(0.4)
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

// MARK: - Expanded View (Main Content) - Minimal Design

struct NotchExpandedView: View {
    let audioPublisher: AnyPublisher<CGFloat, Never>
    @ObservedObject private var contentState = NotchContentState.shared
    
    private var modeColor: Color {
        contentState.mode.notchColor
    }
    
    private var modeLabel: String {
        switch contentState.mode {
        case .dictation: return "Dictate"
        case .rewrite: return "Rewrite"
        case .write: return "Write"
        case .command: return "Command"
        }
    }
    
    private var processingLabel: String {
        switch contentState.mode {
        case .dictation: return "Refining..."
        case .rewrite: return "Thinking..."
        case .write: return "Thinking..."
        case .command: return "Working..."
        }
    }
    
    private var hasTranscription: Bool {
        !contentState.transcriptionText.isEmpty
    }
    
    // Check if there's command history that can be expanded
    private var canExpandCommandHistory: Bool {
        contentState.mode == .command && !contentState.commandConversationHistory.isEmpty
    }
    
    var body: some View {
        VStack(spacing: 4) {
            // Visualization + Mode label row
            HStack(spacing: 6) {
                NotchWaveformView(
                    audioPublisher: audioPublisher,
                    color: modeColor
                )
                .frame(width: 80, height: 22)
                
                // Mode label - shimmer effect when processing
                if contentState.isProcessing {
                    ShimmerText(text: processingLabel, color: modeColor)
                } else {
                    Text(modeLabel)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(modeColor)
                        .opacity(0.9)
                }
            }
            
            // Transcription preview (single line, minimal)
            if hasTranscription && !contentState.isProcessing {
                Text(contentState.cachedLine2)
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
        .contentShape(Rectangle())  // Make entire area tappable
        .onTapGesture {
            // If in command mode with history, clicking expands the conversation
            if canExpandCommandHistory {
                NotchOverlayManager.shared.onNotchClicked?()
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hasTranscription)
        .animation(.easeInOut(duration: 0.2), value: contentState.mode)
        .animation(.easeInOut(duration: 0.25), value: contentState.isProcessing)
    }
}

// MARK: - Minimal Notch Waveform (Color-matched)

struct NotchWaveformView: View {
    let audioPublisher: AnyPublisher<CGFloat, Never>
    let color: Color
    
    @StateObject private var data: AudioVisualizationData
    @ObservedObject private var contentState = NotchContentState.shared
    @State private var barHeights: [CGFloat] = Array(repeating: 3, count: 7)
    @State private var glowPhase: CGFloat = 0  // 0 to 1, controls glow intensity
    @State private var glowTimer: Timer? = nil
    @State private var noiseThreshold: CGFloat = CGFloat(SettingsStore.shared.visualizerNoiseThreshold)
    
    private let barCount = 7
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 4
    private let minHeight: CGFloat = 3
    private let maxHeight: CGFloat = 20
    
    // Computed glow values based on phase (sine wave for smooth pulsing)
    private var currentGlowIntensity: CGFloat {
        contentState.isProcessing ? 0.4 + 0.4 * sin(glowPhase * .pi * 2) : 0.4
    }
    
    private var currentGlowRadius: CGFloat {
        contentState.isProcessing ? 2 + 4 * sin(glowPhase * .pi * 2) : 2
    }
    
    private var currentOuterGlowRadius: CGFloat {
        contentState.isProcessing ? 6 * sin(glowPhase * .pi * 2) : 0
    }
    
    init(audioPublisher: AnyPublisher<CGFloat, Never>, color: Color, isProcessing: Bool = false) {
        self.audioPublisher = audioPublisher
        self.color = color
        self._data = StateObject(wrappedValue: AudioVisualizationData(audioLevelPublisher: audioPublisher))
    }
    
    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(color)
                    .frame(width: barWidth, height: barHeights[index])
                    .shadow(color: color.opacity(currentGlowIntensity), radius: currentGlowRadius, x: 0, y: 0)
                    .shadow(color: color.opacity(currentGlowIntensity * 0.5), radius: currentOuterGlowRadius, x: 0, y: 0)
            }
        }
        .onChange(of: data.audioLevel) { level in
            if !contentState.isProcessing {
                updateBars(level: level)
            }
        }
        .onChange(of: contentState.isProcessing) { processing in
            if processing {
                setStaticProcessingBars()
                startGlowAnimation()
            } else {
                stopGlowAnimation()
            }
        }
        .onAppear {
            if contentState.isProcessing {
                setStaticProcessingBars()
                startGlowAnimation()
            } else {
                updateBars(level: 0)
            }
        }
        .onDisappear {
            stopGlowAnimation()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            // Update threshold when user changes sensitivity setting
            let newThreshold = CGFloat(SettingsStore.shared.visualizerNoiseThreshold)
            if newThreshold != noiseThreshold {
                noiseThreshold = newThreshold
            }
        }
    }
    
    private func startGlowAnimation() {
        stopGlowAnimation() // Clean up any existing timer
        glowPhase = 0
        
        // Timer-based animation for explicit control
        glowTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            withAnimation(.linear(duration: 1.0 / 30.0)) {
                glowPhase += 1.0 / 30.0 / 1.5  // Complete cycle in 1.5 seconds
                if glowPhase >= 1.0 {
                    glowPhase = 0
                }
            }
        }
    }
    
    private func stopGlowAnimation() {
        glowTimer?.invalidate()
        glowTimer = nil
        glowPhase = 0
    }
    
    private func setStaticProcessingBars() {
        // Set bars to a nice static shape (taller in center)
        withAnimation(.easeInOut(duration: 0.3)) {
            for i in 0..<barCount {
                let centerDistance = abs(CGFloat(i) - CGFloat(barCount - 1) / 2)
                let centerFactor = 1.0 - (centerDistance / CGFloat(barCount / 2)) * 0.4
                barHeights[i] = minHeight + (maxHeight - minHeight) * 0.5 * centerFactor
            }
        }
    }
    
    private func updateBars(level: CGFloat) {
        let normalizedLevel = min(max(level, 0), 1)
        let isActive = normalizedLevel > noiseThreshold  // Use user's sensitivity setting
        
        withAnimation(.spring(response: 0.15, dampingFraction: 0.6)) {
            for i in 0..<barCount {
                let centerDistance = abs(CGFloat(i) - CGFloat(barCount - 1) / 2)
                let centerFactor = 1.0 - (centerDistance / CGFloat(barCount / 2)) * 0.4
                
                if isActive {
                    // Scale audio level relative to threshold for smoother response
                    let adjustedLevel = (normalizedLevel - noiseThreshold) / (1.0 - noiseThreshold)
                    let randomVariation = CGFloat.random(in: 0.7...1.0)
                    barHeights[i] = minHeight + (maxHeight - minHeight) * adjustedLevel * centerFactor * randomVariation
                } else {
                    // Complete stillness when below threshold
                    barHeights[i] = minHeight
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
            .foregroundStyle(contentState.mode.notchColor)
            .scaleEffect(isPulsing ? 1.1 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
            .onDisappear { isPulsing = false }
    }
}

struct NotchCompactTrailingView: View {
    @ObservedObject private var contentState = NotchContentState.shared
    @State private var isPulsing = false
    
    var body: some View {
        Circle()
            .fill(contentState.mode.notchColor)
            .frame(width: 5, height: 5)
            .opacity(isPulsing ? 0.5 : 1.0)
            .scaleEffect(isPulsing ? 0.85 : 1.0)
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
            .onDisappear { isPulsing = false }
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
        let baseHeight: CGFloat = 120  // Minimum height
        let contentHeight = estimateContentHeight()
        let maxHeight = (NSScreen.main?.frame.height ?? 800) * 0.45  // 45% of screen
        return min(max(baseHeight, contentHeight), maxHeight)
    }
    
    private func estimateContentHeight() -> CGFloat {
        var height: CGFloat = 80  // Header + input area
        
        // Estimate based on conversation history
        for message in contentState.commandConversationHistory {
            let lineCount = max(1, message.content.count / 60)  // ~60 chars per line
            height += CGFloat(lineCount) * 18 + 16  // Line height + padding
        }
        
        // Add streaming text height
        if !contentState.commandStreamingText.isEmpty {
            let lineCount = max(1, contentState.commandStreamingText.count / 60)
            height += CGFloat(lineCount) * 18 + 16
        }
        
        return height
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with waveform and dismiss
            headerView
            
            // Transcription preview (shown while recording)
            transcriptionPreview
            
            Divider()
                .background(commandRed.opacity(0.3))
            
            // Scrollable conversation area
            conversationArea
            
            // Input area for follow-up commands
            inputArea
        }
        .frame(width: 380, height: dynamicHeight)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: contentState.commandConversationHistory.count)
        // No animation on streamingText - it updates too frequently, animations add overhead
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: contentState.isRecordingInExpandedMode)
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack(spacing: 8) {
            // Left: Waveform + Mode label
            HStack(spacing: 6) {
                // Waveform - only show when recording, otherwise show static indicator
                if contentState.isRecordingInExpandedMode {
                    ExpandedModeWaveformView(color: commandRed)
                        .frame(width: 50, height: 18)
                } else {
                    // Static indicator when not recording
                    HStack(spacing: 3) {
                        ForEach(0..<5, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(commandRed.opacity(0.4))
                                .frame(width: 3, height: 6)
                        }
                    }
                    .frame(width: 50, height: 18)
                }
                
                // Mode label
                if contentState.isRecordingInExpandedMode {
                    Text("Listening...")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(commandRed)
                } else if contentState.isCommandProcessing {
                    ShimmerText(text: "Working...", color: commandRed)
                } else {
                    Text("Command")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(commandRed.opacity(0.7))
                }
            }
            
            Spacer()
            
            // Right: Chat management buttons + Dismiss
            HStack(spacing: 6) {
                // New Chat Button (+)
                Button(action: onNewChat) {
                    ZStack {
                        Circle()
                            .fill(isHoveringNewChat ? commandRed.opacity(0.25) : commandRed.opacity(0.12))
                            .frame(width: 22, height: 22)
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(contentState.isCommandProcessing ? .white.opacity(0.3) : commandRed.opacity(0.85))
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .onHover { isHoveringNewChat = $0 }
                .disabled(contentState.isCommandProcessing)
                .help("New chat")
                
                // Recent Chats Menu
                Menu {
                    let recentChats = contentState.recentChats
                    let currentID = ChatHistoryStore.shared.currentChatID
                    if recentChats.isEmpty {
                        Text("No recent chats")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(recentChats) { chat in
                            Button(action: { 
                                if chat.id != currentID {
                                    onSwitchChat(chat.id) 
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
                            .disabled(contentState.isCommandProcessing)
                        }
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(isHoveringRecent ? commandRed.opacity(0.25) : commandRed.opacity(0.12))
                            .frame(width: 22, height: 22)
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(commandRed.opacity(0.85))
                    }
                }
                .menuIndicator(.hidden)
                .menuStyle(.button)
                .buttonStyle(.plain)
                .frame(width: 22, height: 22)
                .onHover { isHoveringRecent = $0 }
                .help("Recent chats")
                
                // Delete Chat Button - deletes the current chat entirely
                Button(action: onClearChat) {
                    ZStack {
                        Circle()
                            .fill(isHoveringClear ? commandRed.opacity(0.25) : commandRed.opacity(0.12))
                            .frame(width: 22, height: 22)
                        Image(systemName: "trash")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(contentState.isCommandProcessing ? .white.opacity(0.3) : commandRed.opacity(0.85))
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .onHover { isHoveringClear = $0 }
                .disabled(contentState.isCommandProcessing)
                .help("Delete chat")
                
                // Vertical divider
                Rectangle()
                    .fill(.white.opacity(0.15))
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 2)
                
                // Dismiss Button (X)
                Button(action: onDismiss) {
                    ZStack {
                        Circle()
                            .fill(isHoveringDismiss ? commandRed.opacity(0.25) : commandRed.opacity(0.12))
                            .frame(width: 22, height: 22)
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(commandRed.opacity(0.85))
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .onHover { isHoveringDismiss = $0 }
                .help("Close (Escape)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear {
            contentState.refreshRecentChats()
        }
    }
    
    // MARK: - Transcription Preview (shown while recording)
    
    private var transcriptionPreview: some View {
        Group {
            if contentState.isRecordingInExpandedMode && !contentState.transcriptionText.isEmpty {
                VStack(spacing: 2) {
                    if !contentState.cachedLine1.isEmpty {
                        Text(contentState.cachedLine1)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                    Text(contentState.cachedLine2)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(commandRed.opacity(0.1))
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: contentState.isRecordingInExpandedMode)
        .animation(.easeInOut(duration: 0.15), value: contentState.transcriptionText)
    }
    
    // MARK: - Conversation Area
    
    private var conversationArea: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(contentState.commandConversationHistory) { message in
                        messageView(for: message)
                            .id(message.id)
                    }
                    
                    // Streaming text (real-time)
                    if !contentState.commandStreamingText.isEmpty {
                        streamingMessageView
                            .id("streaming")
                    }
                    
                    // Processing indicator
                    if contentState.isCommandProcessing && contentState.commandStreamingText.isEmpty {
                        processingIndicator
                            .id("processing")
                    }
                    
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onAppear {
                scrollProxy = proxy
                // Always scroll to bottom when view appears
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: contentState.commandConversationHistory.count) { _ in
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: contentState.commandStreamingText) { _ in
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: contentState.isCommandProcessing) { _ in
                // Scroll when processing state changes
                scrollToBottom(proxy, animated: true)
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
                    .background(commandRed.opacity(0.25))
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
                        .fill(commandRed.opacity(0.6))
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
            Text(contentState.commandStreamingText)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08))
                .cornerRadius(8)
                .frame(maxWidth: 320, alignment: .leading)
                .drawingGroup()  // Flatten to bitmap for faster streaming updates
                // textSelection disabled during streaming for performance
            Spacer()
        }
    }
    
    private var processingIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(commandRed.opacity(0.6))
                    .frame(width: 4, height: 4)
                    .offset(y: processingOffset(for: index))
            }
        }
        .padding(.vertical, 4)
    }
    
    @State private var processingAnimation = false
    
    private func processingOffset(for index: Int) -> CGFloat {
        // Offset varies by index for staggered animation effect
        _ = Double(index) * 0.15  // Reserved for future animation timing
        return processingAnimation ? -3 : 3
    }
    
    // MARK: - Input Area
    
    private var inputArea: some View {
        HStack(spacing: 8) {
            TextField("Ask follow-up...", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08))
                .cornerRadius(8)
                .focused($isInputFocused)
                .onSubmit {
                    submitFollowUp()
                }
            
            Button(action: submitFollowUp) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(inputText.isEmpty ? .white.opacity(0.3) : commandRed)
            }
            .buttonStyle(.plain)
            .disabled(inputText.isEmpty || contentState.isCommandProcessing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.03))
    }
    
    private func submitFollowUp() {
        guard !inputText.isEmpty else { return }
        let text = inputText
        inputText = ""
        
        Task {
            await onSubmit(text)
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
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(color)
                    .frame(width: barWidth, height: barHeights[index])
                    .shadow(color: color.opacity(0.4), radius: 2, x: 0, y: 0)
            }
        }
        .onChange(of: contentState.expandedModeAudioLevel) { level in
            updateBars(level: level)
        }
        .onAppear {
            updateBars(level: contentState.expandedModeAudioLevel)
        }
    }
    
    private func updateBars(level: CGFloat) {
        let normalizedLevel = min(max(level, 0), 1)
        let isActive = normalizedLevel > noiseThreshold
        
        withAnimation(.spring(response: 0.12, dampingFraction: 0.6)) {
            for i in 0..<barCount {
                let centerDistance = abs(CGFloat(i) - CGFloat(barCount - 1) / 2)
                let centerFactor = 1.0 - (centerDistance / CGFloat(barCount / 2)) * 0.35
                
                if isActive {
                    let adjustedLevel = (normalizedLevel - noiseThreshold) / (1.0 - noiseThreshold)
                    let randomVariation = CGFloat.random(in: 0.75...1.0)
                    barHeights[i] = minHeight + (maxHeight - minHeight) * adjustedLevel * centerFactor * randomVariation
                } else {
                    barHeights[i] = minHeight
                }
            }
        }
    }
}
