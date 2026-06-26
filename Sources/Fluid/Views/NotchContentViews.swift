//
//  NotchContentViews.swift
//  Fluid
//
//  Created by Assistant
//

import AppKit
import Combine
import QuartzCore
import SwiftUI

// MARK: - Observable state for notch content (Singleton)

@MainActor
class NotchContentState: ObservableObject {
    static let shared = NotchContentState()
    /// Keep overlay state bounded even during very long recordings.
    private static let maxStoredTranscriptionCharacters = SettingsStore.transcriptionPreviewCharLimitRange.upperBound

    @Published var transcriptionText: String = ""
    @Published var mode: OverlayMode = .dictation
    @Published var promptPickerMode: SettingsStore.PromptMode = .dictate
    @Published var isProcessing: Bool = false // AI processing state
    @Published var isAIProcessingFailureVisible: Bool = false
    @Published var activeDictationShortcutSlot: SettingsStore.DictationShortcutSlot? = nil
    @Published var promptModeOverrideProfileName: String? = nil // Name shown in overlay when prompt mode hotkey is active
    @Published var promptModeOverrideProfileID: String? = nil // ID of the active override profile (for checkmark in menu)
    @Published var isPromptModeActive: Bool = false // True for the entire prompt-mode session, even when no profile is selected

    /// Called when the user picks a different dictation prompt from the overlay during recording.
    var onDictationPromptSelectionRequested: ((SettingsStore.DictationPromptSelection) -> Void)?

    /// Icon of the target app (where text will be typed)
    @Published var targetAppIcon: NSImage?

    /// The PID of the app we should restore focus to after interacting with overlays.
    /// Captured at recording start to keep the target stable for the session.
    @Published var recordingTargetPID: pid_t? = nil

    /// Cached transcription preview text to avoid recomputing on every render
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

    /// Command output message model
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

    /// Callback for submitting follow-up commands from the notch
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
        if processing {
            self.clearAIProcessingFailure()
        }
        self.isProcessing = processing
    }

    func showAIProcessingFailure() {
        self.isAIProcessingFailureVisible = true
    }

    func clearAIProcessingFailure() {
        self.isAIProcessingFailureVisible = false
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
    @Published var isBottomOverlayReleaseTransitioning: Bool = false
    @Published var isBottomOverlayDismissing: Bool = false
    @Published var bottomOverlayDismissOffsetY: CGFloat = 8

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
    /// Called when the user requests opening Preferences.
    var onOpenPreferencesRequested: (() -> Void)?
    /// Called when the user requests cancelling the current recording or overlay session.
    var onCancelRequested: (() -> Void)?

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

    func setBottomOverlayReleaseTransitioning(_ transitioning: Bool) {
        guard self.isBottomOverlayReleaseTransitioning != transitioning else { return }
        self.isBottomOverlayReleaseTransitioning = transitioning
    }

    func setBottomOverlayDismissing(_ dismissing: Bool) {
        guard self.isBottomOverlayDismissing != dismissing else { return }
        self.isBottomOverlayDismissing = dismissing
    }

    func setBottomOverlayDismissOffsetY(_ offset: CGFloat) {
        let normalizedOffset = max(offset, 8)
        guard abs(self.bottomOverlayDismissOffsetY - normalizedOffset) > 0.5 else { return }
        self.bottomOverlayDismissOffsetY = normalizedOffset
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

    var body: some View {
        Text(self.text)
            .font(self.font)
            .foregroundStyle(self.color.opacity(0.35))
            .overlay {
                CompositorShimmerSweep(duration: 0.72, peakOpacity: 0.9)
                    .mask {
                        Text(self.text)
                            .font(self.font)
                    }
            }
    }
}

struct CompositorShimmerSweep: NSViewRepresentable {
    var duration: CFTimeInterval = 1.0
    var peakOpacity: CGFloat = 0.88

    func makeNSView(context: Context) -> CompositorShimmerSweepView {
        let view = CompositorShimmerSweepView()
        view.configure(duration: self.duration, peakOpacity: self.peakOpacity)
        return view
    }

    func updateNSView(_ nsView: CompositorShimmerSweepView, context: Context) {
        nsView.configure(duration: self.duration, peakOpacity: self.peakOpacity)
    }
}

final class CompositorShimmerSweepView: NSView {
    private let gradientLayer = CAGradientLayer()
    private var animationDuration: CFTimeInterval = 1.0
    private var peakOpacity: CGFloat = 0.88

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true

        let backingLayer = CALayer()
        backingLayer.masksToBounds = true
        self.layer = backingLayer

        self.gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        self.gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        self.gradientLayer.locations = [-0.45, -0.15, 0.15]
        backingLayer.addSublayer(self.gradientLayer)
        self.updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.gradientLayer.frame = self.bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if self.window == nil {
            self.gradientLayer.removeAnimation(forKey: "fluid.shimmer.locations")
        } else {
            self.startAnimationIfNeeded()
        }
    }

    func configure(duration: CFTimeInterval, peakOpacity: CGFloat) {
        let clampedDuration = max(duration, 0.2)
        let clampedOpacity = min(max(peakOpacity, 0.0), 1.0)
        let shouldRestart = abs(self.animationDuration - clampedDuration) > 0.01
        let shouldUpdateColors = abs(self.peakOpacity - clampedOpacity) > 0.01

        self.animationDuration = clampedDuration
        self.peakOpacity = clampedOpacity
        if shouldUpdateColors {
            self.updateColors()
        }
        if shouldRestart {
            self.startAnimationIfNeeded()
        }
    }

    private func updateColors() {
        self.gradientLayer.colors = [
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.withAlphaComponent(self.peakOpacity).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ]
    }

    private func startAnimationIfNeeded() {
        guard self.window != nil else { return }
        self.gradientLayer.removeAnimation(forKey: "fluid.shimmer.locations")

        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-0.45, -0.15, 0.15]
        animation.toValue = [0.85, 1.15, 1.45]
        animation.duration = self.animationDuration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false

        self.gradientLayer.add(animation, forKey: "fluid.shimmer.locations")
    }
}

// MARK: - Expanded View (Main Content) - Minimal Design

struct NotchExpandedView: View {
    let audioPublisher: AnyPublisher<CGFloat, Never>
    @ObservedObject private var contentState = NotchContentState.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var activeAppMonitor = ActiveAppMonitor.shared
    @Environment(\.theme) private var theme
    @State private var isHoveringPromptChip = false
    @State private var isHoveringPromptMenu = false
    @State private var hoveredPromptMenuRowID: String?
    @State private var showPromptHoverMenu = false
    @State private var promptHoverGeneration: UInt64 = 0
    @State private var promptSelectorLeading: CGFloat = 0

    private var modeColor: Color {
        self.contentState.mode.notchColor
    }

    private var presentationPolicy: NotchOverlayManager.NotchPresentationPolicy {
        NotchOverlayManager.shared.currentNotchPresentationPolicy
    }

    private var processingLabel: String {
        switch self.contentState.mode {
        case .dictation: return "Transcribing"
        case .edit, .rewrite, .write: return "Thinking"
        case .command: return "Working"
        }
    }

    private static let transientOverlayStatusTexts: Set<String> = [
        "Transcribing",
        "Refining",
        "Thinking",
        "Working",
        "Transcribing...",
        "Refining...",
        "Thinking...",
        "Working...",
    ]

    /// ContentView writes transient status strings into transcriptionText while processing
    /// (e.g. "Transcribing...", "Refining..."). Prefer that when present.
    private var processingStatusText: String {
        let t = self.contentState.transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.transientOverlayStatusTexts.contains(t) else { return self.processingLabel }
        return t
    }

    private var hasTranscription: Bool {
        !self.visiblePreviewText.isEmpty
    }

    private var visiblePreviewText: String {
        let previewText = self.contentState.cachedPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.transientOverlayStatusTexts.contains(previewText) else { return "" }
        return previewText
    }

    /// Check if there's command history that can be expanded
    private var canExpandCommandHistory: Bool {
        self.presentationPolicy.allowsCommandExpansion &&
            self.presentationPolicy.allowsCommandActions &&
            self.contentState.mode == .command &&
            !self.contentState.commandConversationHistory.isEmpty
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

    private var promptResolutionBundleID: String? {
        self.activeAppMonitor.activeAppBundleID
    }

    private var activeDictationShortcutSlot: SettingsStore.DictationShortcutSlot {
        self.contentState.activeDictationShortcutSlot ?? .primary
    }

    private var isAppPromptOverrideActive: Bool {
        guard let activePromptMode else { return false }
        if activePromptMode.normalized == .dictate {
            return self.settings.isAppDictationPromptBindingActive(
                for: self.activeDictationShortcutSlot,
                appBundleID: self.promptResolutionBundleID
            )
        }
        return self.settings.hasAppPromptBinding(
            for: activePromptMode,
            appBundleID: self.promptResolutionBundleID
        )
    }

    private var selectedPromptLabel: String {
        guard let activePromptMode else { return "N/A" }
        if activePromptMode.normalized == .dictate {
            return self.settings.dictationPromptDisplayName(
                for: self.activeDictationShortcutSlot,
                appBundleID: self.promptResolutionBundleID
            )
        }
        if let profile = self.settings.resolvedPromptProfile(
            for: activePromptMode,
            appBundleID: self.promptResolutionBundleID
        ) {
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Untitled" : name
        }
        return "Default"
    }

    private var compactPromptLabel: String {
        let label = self.selectedPromptLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard label.count > 7 else { return label }
        return String(label.prefix(7))
    }

    private var previewMaxHeight: CGFloat {
        60
    }

    private var previewMaxWidth: CGFloat {
        180
    }

    private var promptSelectorFixedWidth: CGFloat {
        52
    }

    private var promptMenuWidth: CGFloat {
        self.promptSelectorFixedWidth
    }

    private var promptMenuRowVerticalPadding: CGFloat {
        4
    }

    private var promptMenuMaxVisibleRows: CGFloat {
        3
    }

    private var promptMenuRowHeight: CGFloat {
        21
    }

    private var promptMenuListMaxHeight: CGFloat {
        self.promptMenuRowHeight * self.promptMenuMaxVisibleRows
    }

    private static let notchContentCoordinateSpace = "NotchExpandedContent"

    private var notchContentWidth: CGFloat {
        176
    }

    @ViewBuilder
    private var appIconView: some View {
        if let appIcon = self.contentState.targetAppIcon ?? self.activeAppMonitor.activeAppIcon {
            Image(nsImage: appIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }

    private func updatePromptMenuVisibility() {
        guard self.isPromptSelectableMode, !self.contentState.isProcessing else {
            self.dismissPromptHoverMenu()
            return
        }

        let shouldShow = self.isHoveringPromptChip || self.isHoveringPromptMenu
        self.promptHoverGeneration &+= 1
        let generation = self.promptHoverGeneration
        let delay = shouldShow ? 0.03 : 0.28
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard generation == self.promptHoverGeneration else { return }
            self.showPromptHoverMenu = shouldShow
        }
    }

    private func dismissPromptHoverMenu() {
        self.promptHoverGeneration &+= 1
        self.isHoveringPromptChip = false
        self.isHoveringPromptMenu = false
        self.hoveredPromptMenuRowID = nil
        self.showPromptHoverMenu = false
    }

    private func handlePromptChipHover(_ hovering: Bool) {
        self.isHoveringPromptChip = hovering
        self.updatePromptMenuVisibility()
    }

    private func handlePromptMenuHover(_ hovering: Bool) {
        self.isHoveringPromptMenu = hovering
        self.updatePromptMenuVisibility()
    }

    private func restoreRecordingTargetFocus() {
        let pid = NotchContentState.shared.recordingTargetPID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let pid { _ = TypingService.activateApp(pid: pid) }
        }
    }

    private func promptMenuRowBackground(isSelected: Bool, rowID: String) -> some View {
        let isHovered = self.hoveredPromptMenuRowID == rowID
        let fillColor: Color
        if isSelected {
            fillColor = Color.white.opacity(0.18)
        } else if isHovered {
            fillColor = Color.white.opacity(0.10)
        } else {
            fillColor = .clear
        }

        let strokeColor: Color
        if isSelected {
            strokeColor = Color.white.opacity(0.24)
        } else if isHovered {
            strokeColor = Color.white.opacity(0.14)
        } else {
            strokeColor = .clear
        }

        return RoundedRectangle(cornerRadius: 7)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(strokeColor, lineWidth: 1)
            )
    }

    @ViewBuilder
    private func promptMenuRow(
        _ title: String,
        rowID: String,
        isSelected: Bool,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            guard isEnabled else { return }
            action()
        }) {
            Text(title)
                .font(.system(size: 9, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(.white.opacity(isSelected ? 0.96 : 0.84))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, self.promptMenuRowVerticalPadding)
                .background(self.promptMenuRowBackground(isSelected: isSelected, rowID: rowID))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering in
            self.hoveredPromptMenuRowID = hovering && isEnabled ? rowID : nil
        }
    }

    private func promptMenuContent() -> some View {
        let promptMode = self.activePromptMode ?? .dictate
        let activeDictationSlot = self.activeDictationShortcutSlot
        let privateAILocked = promptMode.normalized == .dictate && PrivateAIProviderPromptFormat.isAvailable(settings: self.settings)
        return VStack(alignment: .leading, spacing: 2) {
            Text("AI Prompt")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.42))
                .padding(.horizontal, 6)
                .padding(.top, 2)
                .padding(.bottom, 3)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 2) {
                    let defaultSelected = promptMode.normalized == .dictate
                        ? (self.settings.dictationPromptSelection(for: activeDictationSlot) == .default)
                        : (self.settings.selectedPromptID(for: promptMode) == nil)

                    if promptMode.normalized == .dictate {
                        self.promptMenuRow(
                            "Off",
                            rowID: "off",
                            isSelected: self.settings.dictationPromptSelection(for: activeDictationSlot) == .off,
                            isEnabled: true
                        ) {
                            self.contentState.onDictationPromptSelectionRequested?(.off)
                            self.restoreRecordingTargetFocus()
                            self.dismissPromptHoverMenu()
                        }
                    }

                    if !privateAILocked {
                        self.promptMenuRow("Default", rowID: "default", isSelected: defaultSelected) {
                            if promptMode.normalized == .dictate {
                                self.contentState.onDictationPromptSelectionRequested?(.default)
                            } else {
                                self.settings.setSelectedPromptID(nil, for: promptMode)
                            }
                            self.restoreRecordingTargetFocus()
                            self.dismissPromptHoverMenu()
                        }
                    }

                    if promptMode.normalized == .dictate && PrivateFeatures.privateAIProvider {
                        let privateAIAvailable = PrivateAIProviderPromptFormat.isAvailable(settings: self.settings)
                        self.promptMenuRow(
                            PrivateAIProviderFeature.displayName,
                            rowID: PrivateAIProviderFeature.shared.providerID,
                            isSelected: self.settings.dictationPromptSelection(for: activeDictationSlot) == .privateAI,
                            isEnabled: privateAIAvailable
                        ) {
                            self.contentState.onDictationPromptSelectionRequested?(.privateAI)
                            self.restoreRecordingTargetFocus()
                            self.dismissPromptHoverMenu()
                        }
                    }

                    let profiles = privateAILocked ? [] : self.settings.promptProfiles(for: promptMode)
                    if !profiles.isEmpty {
                        ForEach(profiles) { profile in
                            let isSelected = promptMode.normalized == .dictate
                                ? (self.settings.dictationPromptSelection(for: activeDictationSlot) == .profile(profile.id))
                                : (self.settings.selectedPromptID(for: promptMode) == profile.id)
                            self.promptMenuRow(
                                profile.name.isEmpty ? "Untitled" : profile.name,
                                rowID: profile.id,
                                isSelected: isSelected
                            ) {
                                if promptMode.normalized == .dictate {
                                    self.contentState.onDictationPromptSelectionRequested?(.profile(profile.id))
                                } else {
                                    self.settings.setSelectedPromptID(profile.id, for: promptMode)
                                }
                                self.restoreRecordingTargetFocus()
                                self.dismissPromptHoverMenu()
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: self.promptMenuListMaxHeight)
        }
        .padding(3)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 8, x: 0, y: 5)
        .onHover { hovering in
            self.handlePromptMenuHover(hovering)
        }
    }

    @ViewBuilder
    private var promptSelectorControl: some View {
        if self.presentationPolicy.showsPromptSelector {
            HStack(spacing: 3) {
                Text(self.compactPromptLabel)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(self.isHoveringPromptChip ? .white.opacity(0.94) : .white.opacity(0.86))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(self.isHoveringPromptChip ? .white.opacity(0.78) : .white.opacity(0.62))
                if self.isAppPromptOverrideActive {
                    Text("App")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.82))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.12))
                        )
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .frame(width: self.promptSelectorFixedWidth, alignment: .leading)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(self.isHoveringPromptChip ? 0.96 : 0.92),
                                Color(white: self.isHoveringPromptChip ? 0.10 : 0.06),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .shadow(color: .black.opacity(0.28), radius: 8, x: 0, y: 4)
            .shadow(color: .white.opacity(self.isHoveringPromptChip ? 0.06 : 0.03), radius: 0, x: 0, y: 1)
            .opacity(self.isPromptSelectableMode ? (self.contentState.isProcessing ? 0.7 : 1.0) : 0.6)
            .allowsHitTesting(self.isPromptSelectableMode && !self.contentState.isProcessing)
            .onHover { hovering in
                self.handlePromptChipHover(hovering)
            }
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            self.promptSelectorLeading = geometry.frame(in: .named(Self.notchContentCoordinateSpace)).minX
                        }
                        .onChange(of: geometry.frame(in: .named(Self.notchContentCoordinateSpace)).minX) { _, newLeading in
                            self.promptSelectorLeading = newLeading
                        }
                }
            )
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var promptHoverMenuRow: some View {
        if self.showPromptHoverMenu {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: self.promptSelectorLeading)

                self.promptMenuContent()
                    .frame(width: self.promptMenuWidth, alignment: .leading)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, -2)
            .transition(.opacity)
        }
    }

    var body: some View {
        Group {
            if self.canExpandCommandHistory {
                self.notchBodyContent
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if NotchOverlayManager.shared.canHandleNotchCommandTap {
                            NotchOverlayManager.shared.onNotchClicked?()
                        }
                    }
            } else {
                self.notchBodyContent
            }
        }
        .onChange(of: self.contentState.mode) { _, _ in
            if !self.isPromptSelectableMode {
                self.dismissPromptHoverMenu()
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

    private var notchBodyContent: some View {
        VStack(alignment: .center, spacing: 6) {
            HStack(spacing: 4) {
                self.appIconView

                CompactNotchWaveformView(
                    audioPublisher: self.audioPublisher,
                    color: self.modeColor
                )
                .frame(width: 48, height: 18)

                self.promptSelectorControl
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .offset(x: 4, y: 0)

            self.promptHoverMenuRow

            if self.contentState.isAIProcessingFailureVisible && !self.contentState.isProcessing {
                HStack(spacing: 6) {
                    Text("AI Enhancement failed")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 2)

                    Button {
                        self.contentState.clearAIProcessingFailure()
                        self.contentState.onReprocessLastRequested?()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help("Try again")

                    Button {
                        self.contentState.clearAIProcessingFailure()
                        NotchOverlayManager.shared.hide()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: self.previewMaxWidth, alignment: .leading)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else if self.presentationPolicy.showsStreamingPreview && self.hasTranscription && !self.contentState.isProcessing {
                let previewText = self.visiblePreviewText
                if !previewText.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            Text(previewText)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.75))
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
                        .onChange(of: previewText) { _, _ in
                            DispatchQueue.main.async {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
        }
        .coordinateSpace(name: Self.notchContentCoordinateSpace)
        .frame(width: self.notchContentWidth)
        .padding(.horizontal, 6)
        .padding(.top, 0)
        .padding(.bottom, 4)
        .background(Color.black)
    }
}

// MARK: - Minimal Notch Waveform (Color-matched)

struct NotchWaveformView: View {
    let audioPublisher: AnyPublisher<CGFloat, Never>
    let color: Color

    @StateObject private var data: AudioVisualizationData
    @ObservedObject private var contentState = NotchContentState.shared
    @State private var barHeights: [CGFloat] = Array(repeating: 3, count: 5)
    @State private var noiseThreshold: CGFloat = .init(SettingsStore.shared.visualizerNoiseThreshold)

    private let barCount = 5
    private let barWidth: CGFloat = 2.5
    private let barSpacing: CGFloat = 2
    private let minHeight: CGFloat = 3
    private let maxHeight: CGFloat = 12
    private let processingFlatHeight: CGFloat = 3

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
        ZStack {
            self.barsView(using: { index in
                self.displayHeight(for: index)
            })
            .foregroundStyle(self.color.opacity(self.contentState.isProcessing ? 0.16 : 1.0))

            if self.contentState.isProcessing {
                CompositorShimmerSweep(duration: 1.05, peakOpacity: 0.9)
                    .mask {
                        self.barsView(using: { index in
                            self.displayHeight(for: index)
                        })
                    }
                    .shadow(color: .white.opacity(0.28), radius: 2.5, x: 0, y: 0)
            }
        }
        .onChange(of: self.data.audioLevel) { _, level in
            if !self.contentState.isProcessing {
                self.updateBars(level: level)
            }
        }
        .onChange(of: self.contentState.isProcessing) { _, processing in
            if processing {
                self.resetBarsToBaseline(animated: false)
            } else {
                self.updateBars(level: self.data.audioLevel)
            }
        }
        .onAppear {
            if self.contentState.isProcessing {
                self.resetBarsToBaseline(animated: false)
            } else {
                self.updateBars(level: self.data.audioLevel)
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

    @ViewBuilder
    private func barsView(using height: @escaping (Int) -> CGFloat) -> some View {
        HStack(spacing: self.barSpacing) {
            ForEach(0..<self.barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: self.barWidth / 2)
                    .frame(width: self.barWidth, height: height(index))
                    .shadow(color: self.color.opacity(self.currentGlowIntensity), radius: self.currentGlowRadius, x: 0, y: 0)
                    .shadow(color: self.color.opacity(self.currentGlowIntensity * 0.5), radius: self.currentOuterGlowRadius, x: 0, y: 0)
            }
        }
    }

    private func displayHeight(for index: Int) -> CGFloat {
        guard self.contentState.isProcessing else {
            return self.barHeights[index]
        }
        return self.processingFlatHeight
    }

    private func resetBarsToBaseline(animated: Bool) {
        let update = {
            for index in 0..<self.barCount {
                self.barHeights[index] = self.minHeight
            }
        }

        if animated {
            withAnimation(.easeOut(duration: 0.1)) {
                update()
            }
        } else {
            update()
        }
    }

    private func updateBars(level: CGFloat) {
        let normalizedLevel = min(max(level, 0), 1)
        let adjustedLevel = normalizedLevel > self.noiseThreshold
            ? (normalizedLevel - self.noiseThreshold) / (1.0 - self.noiseThreshold)
            : 0

        guard adjustedLevel > 0 else {
            self.resetBarsToBaseline(animated: false)
            return
        }

        withAnimation(.easeOut(duration: 0.1)) {
            for index in 0..<self.barCount {
                let centerDistance = abs(CGFloat(index) - CGFloat(self.barCount - 1) / 2)
                let centerFactor = 1.0 - (centerDistance / CGFloat(self.barCount / 2)) * 0.28
                self.barHeights[index] = self.minHeight + (self.maxHeight - self.minHeight) * adjustedLevel * centerFactor
            }
        }
    }
}

// MARK: - Compact Views (Small States)

struct NotchCompactLeadingView: View {
    @ObservedObject private var contentState = NotchContentState.shared
    @ObservedObject private var activeAppMonitor = ActiveAppMonitor.shared

    var body: some View {
        Group {
            if let appIcon = self.contentState.targetAppIcon ?? self.activeAppMonitor.activeAppIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Circle()
                    .fill(self.contentState.mode.notchColor.opacity(0.9))
                    .frame(width: 8, height: 8)
            }
        }
    }
}

struct NotchCompactTrailingView: View {
    let audioPublisher: AnyPublisher<CGFloat, Never>
    @ObservedObject private var contentState = NotchContentState.shared

    var body: some View {
        CompactNotchWaveformView(
            audioPublisher: self.audioPublisher,
            color: self.contentState.mode.notchColor
        )
        .frame(width: 34, height: 16)
    }
}

struct NotchCompactBottomView: View {
    @ObservedObject private var contentState = NotchContentState.shared

    private let previewWidth: CGFloat = 250
    private let previewHeight: CGFloat = 20
    private static let transientOverlayStatusTexts: Set<String> = [
        "Transcribing",
        "Refining",
        "Thinking",
        "Working",
        "Transcribing...",
        "Refining...",
        "Thinking...",
        "Working...",
    ]

    private var compactPreviewText: String {
        let source = self.contentState.isProcessing
            ? self.contentState.transcriptionText
            : self.contentState.cachedPreviewText
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.transientOverlayStatusTexts.contains(trimmed) else { return "" }
        return trimmed
    }

    private var shouldShowPreview: Bool {
        SettingsStore.shared.enableStreamingPreview && !self.compactPreviewText.isEmpty
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Text(self.compactPreviewText)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.head)
                .offset(y: self.shouldShowPreview ? 0 : -4)
                .opacity(self.shouldShowPreview ? 1 : 0)
        }
        .frame(width: self.previewWidth, height: SettingsStore.shared.enableStreamingPreview ? self.previewHeight : 0, alignment: .leading)
        .padding(.horizontal, SettingsStore.shared.enableStreamingPreview ? 10 : 0)
        .padding(.bottom, SettingsStore.shared.enableStreamingPreview ? 8 : 0)
        .clipped()
        .animation(.easeOut(duration: 0.2), value: self.shouldShowPreview)
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
    @FocusState private var isInputFocused: Bool
    @State private var scrollProxy: ScrollViewProxy?
    @State private var isHoveringNewChat = false
    @State private var isHoveringRecent = false
    @State private var isHoveringClear = false
    @State private var isHoveringDismiss = false

    private let commandRed = Color(red: 1.0, green: 0.35, blue: 0.35)

    private var previewMaxHeight: CGFloat {
        70
    }

    /// Dynamic height based on content (max half screen)
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
                            .fill(self.isHoveringNewChat ? self.commandRed.opacity(0.25) : self.commandRed.opacity(0.12))
                            .frame(width: 22, height: 22)
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(self.contentState.isCommandProcessing ? .white.opacity(0.3) : self.commandRed.opacity(0.85))
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
                            .foregroundStyle(self.contentState.isCommandProcessing ? .white.opacity(0.3) : self.commandRed.opacity(0.85))
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
                let previewText = self.contentState.cachedPreviewText
                if !previewText.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            Text(previewText)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.75))
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
                        .onChange(of: previewText) { _, _ in
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
            .onChange(of: self.contentState.commandConversationHistory.count) { _, _ in
                self.scrollToBottom(proxy, animated: true)
            }
            .onChange(of: self.contentState.commandStreamingText) { _, _ in
                // Disable animation for streaming text to prevent scroll bar jitter
                self.scrollToBottom(proxy, animated: false)
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
                    self.barHeights[i] = self.minHeight + (self.maxHeight - self.minHeight) * adjustedLevel * centerFactor * randomVariation
                } else {
                    self.barHeights[i] = self.minHeight
                }
            }
        }
    }
}

struct CompactNotchWaveformView: View {
    let audioPublisher: AnyPublisher<CGFloat, Never>
    let color: Color

    @StateObject private var data: AudioVisualizationData
    @ObservedObject private var contentState = NotchContentState.shared
    @State private var barHeights: [CGFloat] = Array(repeating: 3, count: 8)

    private let barCount = 8
    private let barWidth: CGFloat = 2.5
    private let barSpacing: CGFloat = 2
    private let minHeight: CGFloat = 3
    private let maxHeight: CGFloat = 15
    private let noiseThreshold: CGFloat = 0.05
    private let processingFlatHeight: CGFloat = 3

    init(audioPublisher: AnyPublisher<CGFloat, Never>, color: Color) {
        self.audioPublisher = audioPublisher
        self.color = color
        _data = StateObject(wrappedValue: AudioVisualizationData(audioLevelPublisher: audioPublisher))
    }

    var body: some View {
        ZStack {
            self.barsView(using: { index in
                self.displayHeight(for: index)
            })
            .foregroundStyle(self.color.opacity(self.contentState.isProcessing ? 0.16 : 1.0))

            if self.contentState.isProcessing {
                CompositorShimmerSweep(duration: 1.05, peakOpacity: 0.9)
                    .mask {
                        self.barsView(using: { index in
                            self.displayHeight(for: index)
                        })
                    }
                    .shadow(color: .white.opacity(0.28), radius: 2.5, x: 0, y: 0)
            }
        }
        .onChange(of: self.data.audioLevel) { _, level in
            if !self.contentState.isProcessing {
                self.updateBars(level: level)
            }
        }
        .onChange(of: self.contentState.isProcessing) { _, processing in
            if processing {
                self.resetBarsToBaseline(animated: false)
            } else {
                self.updateBars(level: self.data.audioLevel)
            }
        }
        .onAppear {
            if self.contentState.isProcessing {
                self.resetBarsToBaseline(animated: false)
            } else {
                self.updateBars(level: self.data.audioLevel)
            }
        }
    }

    @ViewBuilder
    private func barsView(using height: @escaping (Int) -> CGFloat) -> some View {
        HStack(spacing: self.barSpacing) {
            ForEach(0..<self.barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: self.barWidth / 2)
                    .frame(width: self.barWidth, height: height(index))
            }
        }
    }

    private func displayHeight(for index: Int) -> CGFloat {
        guard self.contentState.isProcessing else {
            return self.barHeights[index]
        }

        return self.processingFlatHeight
    }

    private func updateBars(level: CGFloat) {
        let normalizedLevel = min(max(level, 0), 1)
        let adjustedLevel = normalizedLevel > self.noiseThreshold
            ? (normalizedLevel - self.noiseThreshold) / (1.0 - self.noiseThreshold)
            : 0

        guard adjustedLevel > 0 else {
            self.resetBarsToBaseline(animated: false)
            return
        }

        withAnimation(.easeOut(duration: 0.1)) {
            for index in 0..<self.barCount {
                let centerDistance = abs(CGFloat(index) - CGFloat(self.barCount - 1) / 2)
                let centerFactor = 1.0 - (centerDistance / CGFloat(self.barCount / 2)) * 0.28
                self.barHeights[index] = self.minHeight + (self.maxHeight - self.minHeight) * adjustedLevel * centerFactor
            }
        }
    }

    private func resetBarsToBaseline(animated: Bool) {
        let apply = {
            self.barHeights = Array(repeating: self.minHeight, count: self.barCount)
        }

        if animated {
            withAnimation(.easeOut(duration: 0.08)) {
                apply()
            }
        } else {
            apply()
        }
    }
}
