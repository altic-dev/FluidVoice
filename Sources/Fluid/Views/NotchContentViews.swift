//
//  NotchContentViews.swift
//  Fluid
//
//  Created by Assistant
//

import Combine
import SwiftUI

// MARK: - Observable state for notch content (Singleton)

@MainActor
class NotchContentState: ObservableObject {
    static let shared = NotchContentState()
    // Keep overlay state bounded even during very long recordings.
    private static let maxStoredTranscriptionCharacters = SettingsStore.transcriptionPreviewCharLimitRange.upperBound

    @Published var transcriptionText: String = ""
    @Published var mode: OverlayMode = .dictation
    @Published var promptPickerMode: SettingsStore.PromptMode = .dictate
    @Published var isProcessing: Bool = false // AI processing state

    // Icon of the target app (where text will be typed)
    @Published var targetAppIcon: NSImage?

    /// The PID of the app we should restore focus to after interacting with overlays.
    /// Captured at recording start to keep the target stable for the session.
    @Published var recordingTargetPID: pid_t? = nil

    // Cached transcription preview text to avoid recomputing on every render
    @Published private(set) var cachedPreviewText: String = ""

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

    private var cancellables = Set<AnyCancellable>()

    private init() {
        let previewLimitChanged = NotificationCenter.default.publisher(
            for: NSNotification.Name("TranscriptionPreviewCharLimitChanged")
        )
        let defaultsChanged = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)

        Publishers.Merge(previewLimitChanged, defaultsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recomputeTranscriptionLines()
            }
            .store(in: &self.cancellables)
    }

    /// Set AI processing state
    func setProcessing(_ processing: Bool) {
        self.isProcessing = processing
    }

    /// Update transcription and recompute cached lines
    func updateTranscription(_ text: String) {
        let boundedText = Self.tailCharacters(in: text, maxCharacters: Self.maxStoredTranscriptionCharacters)
        guard boundedText != self.transcriptionText else { return }

        self.transcriptionText = boundedText
        self.recomputeTranscriptionLines()
    }

    /// Recompute cached transcription lines (called only when text changes)
    private func recomputeTranscriptionLines() {
        let text = self.transcriptionText

        guard !text.isEmpty else {
            if !self.cachedPreviewText.isEmpty {
                self.cachedPreviewText = ""
            }
            return
        }

        let maxChars = SettingsStore.shared.transcriptionPreviewCharLimit
        let previewText = Self.tailCharacters(in: text, maxCharacters: maxChars)
        guard previewText != self.cachedPreviewText else { return }
        self.cachedPreviewText = previewText
    }

    private static func tailCharacters(in text: String, maxCharacters: Int) -> String {
        guard maxCharacters > 0, !text.isEmpty else { return "" }

        let start = text.index(text.endIndex, offsetBy: -maxCharacters, limitedBy: text.startIndex) ?? text.startIndex
        return String(text[start..<text.endIndex])
    }

    // MARK: - Recording State for Expanded View

    @Published var isRecordingInExpandedMode: Bool = false
    @Published var expandedModeAudioLevel: CGFloat = 0 // Audio level for waveform in expanded mode

    // MARK: - Bottom Overlay Audio Level

    @Published var bottomOverlayAudioLevel: CGFloat = 0 // Audio level for bottom overlay waveform

    /// Called when the user requests a live mode switch from the prompt picker tabs.
    var onPromptModeSwitchRequested: ((SettingsStore.PromptMode) -> Void)?
    /// Called when the user requests a live overlay mode switch from the mode picker.
    var onOverlayModeSwitchRequested: ((OverlayMode) -> Void)?
    /// Called when the user requests reprocessing the latest saved dictation entry.
    var onReprocessLastRequested: (() -> Void)?
    /// Called when the user requests copying the latest saved transcription entry.
    var onCopyLastRequested: (() -> Void)?
    /// Called when the user requests undoing AI processing for the latest entry.
    var onUndoLastAIRequested: (() -> Void)?
    /// Called when the user requests toggling dictation AI enhancement.
    var onToggleAIProcessingRequested: (() -> Void)?
    /// Called when the user requests opening Preferences.
    var onOpenPreferencesRequested: (() -> Void)?

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
        case .edit:
            return Color(red: 0.4, green: 0.6, blue: 1.0) // Blue (Edit)
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
    var font: Font = .system(size: 9, weight: .medium)

    /// Seconds per shimmer sweep.
    /// Lower is faster.
    private let periodSeconds: Double = 0.85
    private let bandHalfWidth: CGFloat = 0.32

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let progress = (t / self.periodSeconds).truncatingRemainder(dividingBy: 1.0)
            // Sweep from slightly before to slightly after to avoid hard edges.
            let centerX = CGFloat(-0.25 + progress * 1.5) // -0.25 -> 1.25

            Text(self.text)
                .font(self.font)
                .foregroundColor(
                    LinearGradient(
                        colors: [
                            self.color.opacity(0.35),
                            self.color.opacity(0.35),
                            self.color.opacity(1.0),
                            self.color.opacity(0.35),
                            self.color.opacity(0.35),
                        ],
                        startPoint: UnitPoint(x: centerX - self.bandHalfWidth, y: 0.5),
                        endPoint: UnitPoint(x: centerX + self.bandHalfWidth, y: 0.5)
                    )
                )
        }
    }
}

// MARK: - Expanded View (Main Content) - Minimal Design

struct NotchExpandedView: View {
    let audioPublisher: AnyPublisher<CGFloat, Never>
    @ObservedObject private var contentState = NotchContentState.shared
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme
    @State private var showPromptHoverMenu = false
    @State private var promptHoverWorkItem: DispatchWorkItem?

    private var modeColor: Color {
        self.contentState.mode.notchColor
    }

    private var modeLabel: String {
        switch self.contentState.mode {
        case .dictation: return "Dictate"
        case .edit, .rewrite, .write: return "Edit"
        case .command: return "Command"
        }
    }

    private var processingLabel: String {
        switch self.contentState.mode {
        case .dictation: return "Refining..."
        case .edit, .rewrite, .write: return "Thinking..."
        case .command: return "Working..."
        }
    }

    // ContentView writes transient status strings into transcriptionText while processing
    // (e.g. "Transcribing...", "Refining..."). Prefer that when present.
    private var processingStatusText: String {
        let t = self.contentState.transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? self.processingLabel : t
    }

    private var hasTranscription: Bool {
        !self.contentState.transcriptionText.isEmpty
    }

    // Check if there's command history that can be expanded
    private var canExpandCommandHistory: Bool {
        self.contentState.mode == .command && !self.contentState.commandConversationHistory.isEmpty
    }

    private var normalizedOverlayMode: OverlayMode {
        switch self.contentState.mode {
        case .dictation:
            return .dictation
        case .edit, .write, .rewrite:
            return .edit
        case .command:
            return .command
        }
    }

    private var activePromptMode: SettingsStore.PromptMode? {
        switch self.normalizedOverlayMode {
        case .dictation:
            return .dictate
        case .edit:
            return .edit
        case .command, .write, .rewrite:
            return nil
        }
    }

    private var isPromptSelectableMode: Bool {
        self.activePromptMode != nil
    }

    private var selectedPromptLabel: String {
        guard let activePromptMode else { return "N/A" }
        if let profile = self.settings.selectedPromptProfile(for: activePromptMode) {
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Untitled" : name
        }
        return "Default"
    }

    private var previewMaxHeight: CGFloat {
        60
    }

    private var previewMaxWidth: CGFloat {
        180
    }

    private func handlePromptHover(_ hovering: Bool) {
        guard self.isPromptSelectableMode, !self.contentState.isProcessing else {
            self.showPromptHoverMenu = false
            return
        }
        self.promptHoverWorkItem?.cancel()
        let task = DispatchWorkItem {
            self.showPromptHoverMenu = hovering
        }
        self.promptHoverWorkItem = task
        DispatchQueue.main.asyncAfter(deadline: .now() + (hovering ? 0.05 : 0.15), execute: task)
    }

    private func promptMenuContent() -> some View {
        let promptMode = self.activePromptMode ?? .dictate

        return VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                self.settings.setSelectedPromptID(nil, for: promptMode)
                let pid = NotchContentState.shared.recordingTargetPID
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if let pid { _ = TypingService.activateApp(pid: pid) }
                }
                self.showPromptHoverMenu = false
            }) {
                HStack {
                    Text("Default")
                    Spacer()
                    if self.settings.selectedPromptID(for: promptMode) == nil {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)

            if !self.settings.promptProfiles(for: promptMode).isEmpty {
                Divider()
                    .padding(.vertical, 4)

                ForEach(self.settings.promptProfiles(for: promptMode)) { profile in
                    Button(action: {
                        self.settings.setSelectedPromptID(profile.id, for: promptMode)
                        let pid = NotchContentState.shared.recordingTargetPID
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            if let pid { _ = TypingService.activateApp(pid: pid) }
                        }
                        self.showPromptHoverMenu = false
                    }) {
                        HStack {
                            Text(profile.name.isEmpty ? "Untitled" : profile.name)
                            Spacer()
                            if self.settings.selectedPromptID(for: promptMode) == profile.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.black)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .onHover { hovering in
            self.handlePromptHover(hovering)
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            // Visualization + Mode label row
            HStack(spacing: 6) {
                // Target app icon (the app where text will be typed)
                if let appIcon = self.contentState.targetAppIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                NotchWaveformView(
                    audioPublisher: self.audioPublisher,
                    color: self.modeColor
                )
                .frame(width: 80, height: 22)

                // Mode label - shimmer effect when processing
                if self.contentState.isProcessing {
                    ShimmerText(text: self.processingStatusText, color: self.modeColor)
                } else {
                    Text(self.modeLabel)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(self.modeColor)
                        .opacity(0.9)
                        .onHover { hovering in
                            self.handlePromptHover(hovering)
                        }
                }
            }

            // Prompt selector
            if !self.contentState.isProcessing {
                ZStack(alignment: .top) {
                    HStack(spacing: 6) {
                        Text("Prompt:")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                        Text(self.selectedPromptLabel)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.00))
                    .cornerRadius(6)
                    .opacity(self.isPromptSelectableMode ? 1.0 : 0.6)
                    .onHover { hovering in
                        self.handlePromptHover(hovering)
                    }

                    if self.showPromptHoverMenu {
                        self.promptMenuContent()
                            .padding(.top, 26)
                            .transition(.opacity)
                            .zIndex(10)
                    }
                }
                .frame(maxWidth: 180, alignment: .top)
                .transition(.opacity)
            }

            // Transcription preview (wrapped, fixed width)
            if self.hasTranscription && !self.contentState.isProcessing {
                let previewText = self.contentState.cachedPreviewText
                if !previewText.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            Text(previewText)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white.opacity(0.75))
                                .multilineTextAlignment(.leading)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .frame(width: self.previewMaxWidth, alignment: .leading)
                        .frame(maxHeight: self.previewMaxHeight, alignment: .leading)
                        .clipped()
                        .onAppear {
                            DispatchQueue.main.async {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                        .onChange(of: previewText) { _ in
                            DispatchQueue.main.async {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.black) // Must be pure black to blend with macOS notch
        .contentShape(Rectangle()) // Make entire area tappable
        .onTapGesture {
            // If in command mode with history, clicking expands the conversation
            if self.canExpandCommandHistory {
                NotchOverlayManager.shared.onNotchClicked?()
            }
        }
        .onChange(of: self.contentState.mode) { _ in
            if !self.isPromptSelectableMode {
                self.showPromptHoverMenu = false
            }
            switch self.contentState.mode {
            case .dictation: self.contentState.promptPickerMode = .dictate
            case .edit, .write, .rewrite: self.contentState.promptPickerMode = .edit
            case .command: break
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
    @State private var noiseThreshold: CGFloat = .init(SettingsStore.shared.visualizerNoiseThreshold)

    private let barCount = 7
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 4
    private let minHeight: CGFloat = 3
    private let maxHeight: CGFloat = 20

    private var currentGlowIntensity: CGFloat {
        self.contentState.isProcessing ? 0.0 : 0.35
    }

    private var currentGlowRadius: CGFloat {
        self.contentState.isProcessing ? 0.0 : 1.5
    }

    private var currentOuterGlowRadius: CGFloat {
        0
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
                    .shadow(color: self.color.opacity(self.currentGlowIntensity), radius: self.currentGlowRadius, x: 0, y: 0)
                    .shadow(color: self.color.opacity(self.currentGlowIntensity * 0.5), radius: self.currentOuterGlowRadius, x: 0, y: 0)
            }
        }
        .onChange(of: self.data.audioLevel) { level in
            if !self.contentState.isProcessing {
                self.updateBars(level: level)
            }
        }
        .onChange(of: self.contentState.isProcessing) { processing in
            if processing {
                self.setFlatProcessingBars()
            } else {
                // Resume from silence; next audio tick will animate up.
                self.updateBars(level: 0)
            }
        }
        .onAppear {
            if self.contentState.isProcessing {
                self.setFlatProcessingBars()
            } else {
                self.updateBars(level: 0)
            }
        }
        .onDisappear {
            // No timers to clean up.
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            // Update threshold when user changes sensitivity setting
            let newThreshold = CGFloat(SettingsStore.shared.visualizerNoiseThreshold)
            if newThreshold != self.noiseThreshold {
                self.noiseThreshold = newThreshold
            }
        }
    }

    private func setFlatProcessingBars() {
        // During AI processing we want the visualizer to settle to silence (flat).
        withAnimation(.easeOut(duration: 0.18)) {
            for i in 0..<self.barCount {
                self.barHeights[i] = self.minHeight
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
                    self.barHeights[i] = self.minHeight + (self.maxHeight - self.minHeight) * adjustedLevel * centerFactor * randomVariation
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
            .foregroundColor(self.contentState.mode.notchColor)
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
    @Environment(\.theme) private var theme
    @State private var inputText: String = ""
    @State private var isInputFocused: Bool = false
    @State private var scrollProxy: ScrollViewProxy?
    @State private var isHoveringNewChat = false
    @State private var isHoveringRecent = false
    @State private var isHoveringClear = false
    @State private var isHoveringDismiss = false

    private let commandRed = Color(red: 1.0, green: 0.35, blue: 0.35)

    private var previewMaxHeight: CGFloat {
        70
    }

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
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: self.contentState.commandConversationHistory.count)
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
                        .foregroundColor(self.commandRed)
                } else if self.contentState.isCommandProcessing {
                    ShimmerText(text: "Working...", color: self.commandRed)
                } else {
                    Text("Command")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(self.commandRed.opacity(0.7))
                }
            }

            Spacer()

            // Right: Chat management buttons + Dismiss
            HStack(spacing: 6) {
                // New Chat Button (+)
                Button(action: self.onNewChat) {
                    ZStack {
                        Circle()
                            .fill(self.isHoveringNewChat ? self.commandRed.opacity(0.25) : self.commandRed.opacity(0.12))
                            .frame(width: 22, height: 22)
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(self.contentState.isCommandProcessing ? .white.opacity(0.3) : self.commandRed.opacity(0.85))
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
                            .foregroundColor(.secondary)
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
                                        .foregroundColor(.secondary)
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
                            .foregroundColor(self.commandRed.opacity(0.85))
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
                            .foregroundColor(self.contentState.isCommandProcessing ? .white.opacity(0.3) : self.commandRed.opacity(0.85))
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
                            .fill(self.isHoveringDismiss ? self.commandRed.opacity(0.25) : self.commandRed.opacity(0.12))
                            .frame(width: 22, height: 22)
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(self.commandRed.opacity(0.85))
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
                let previewText = self.contentState.cachedPreviewText
                if !previewText.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            Text(previewText)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.75))
                                .multilineTextAlignment(.leading)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .frame(maxWidth: .infinity, maxHeight: self.previewMaxHeight)
                        .clipped()
                        .onAppear {
                            DispatchQueue.main.async {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                        .onChange(of: previewText) { _ in
                            DispatchQueue.main.async {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(self.commandRed.opacity(0.1))
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
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
            .onChange(of: self.contentState.commandConversationHistory.count) { _ in
                self.scrollToBottom(proxy, animated: true)
            }
            .onChange(of: self.contentState.commandStreamingText) { _ in
                // Disable animation for streaming text to prevent scroll bar jitter
                self.scrollToBottom(proxy, animated: false)
            }
            .onChange(of: self.contentState.isCommandProcessing) { _ in
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
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(self.commandRed.opacity(0.25))
                    .cornerRadius(8)
                    .frame(maxWidth: 280, alignment: .trailing)
                    

            case .assistant:
                Text(message.content)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(8)
                    .frame(maxWidth: 320, alignment: .leading)
                    
                Spacer()

            case .status:
                HStack(spacing: 4) {
                    Circle()
                        .fill(self.commandRed.opacity(0.6))
                        .frame(width: 4, height: 4)
                    Text(message.content)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
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
                .foregroundColor(.white.opacity(0.85))
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
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08))
                .cornerRadius(8)
                // Note: .focused() requires macOS 12+, omitted for Big Sur compatibility

            Button(action: self.submitFollowUp) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(self.inputText.isEmpty ? .white.opacity(0.3) : self.commandRed)
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
        .onChange(of: self.contentState.expandedModeAudioLevel) { level in
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
                    self.barHeights[i] = self.minHeight + (self.maxHeight - self.minHeight) * adjustedLevel * centerFactor * randomVariation
                } else {
                    self.barHeights[i] = self.minHeight
                }
            }
        }
    }
}
