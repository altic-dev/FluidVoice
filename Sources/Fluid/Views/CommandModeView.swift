import Combine
import SwiftUI

enum CommandModeRecordingOwnershipPolicy {
    static func ownsRecording(after outcome: AudioCaptureStartOutcome, isRunning: Bool) -> Bool {
        outcome == .started && isRunning
    }

    static func shouldStopOnDeactivate(ownsRecording: Bool, isRunning: Bool) -> Bool {
        ownsRecording && isRunning
    }

    static func shouldStopAfterStart(ownsRecording: Bool, isPresentationActive: Bool) -> Bool {
        ownsRecording && !isPresentationActive
    }
}

struct CommandModeView: View {
    @ObservedObject var service: CommandModeService
    let isActive: Bool
    @EnvironmentObject var appServices: AppServices
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var chatStore = ChatHistoryStore.shared
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onClose: (() -> Void)?

    @AppStorage("CommandHistoryInspectorVisible") private var prefersHistoryVisible = true
    @State private var compactHistoryPresented = false
    @State private var drafts = CommandSessionDrafts()
    @State private var showingArchiveLimit = false
    @State private var showModelPicker = false
    @State private var modelOptions: [CommandModelOption] = []
    @State private var selectedModelProviderID = ""
    @State private var selectedModelID = ""
    @State private var ownsASRRecording = false
    @State private var isASRStartPending = false
    @State private var isASRStopPending = false
    @State private var recordingSessionID: String?
    @State private var isSubmissionPending = false
    @State private var isPresentationActive = false
    @State private var followsLatestMessage = true
    @State private var isUserScrolling = false
    @State private var isThinkingExpanded = false
    @FocusState private var composerFocused: Bool

    private var asr: ASRService { self.appServices.asr }
    private var inputText: Binding<String> {
        Binding(
            get: { self.drafts.text(for: self.service.currentChatID) },
            set: { self.drafts.set($0, for: self.service.currentChatID) }
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let isWide = geometry.size.width >= CommandWorkspaceLayout.dockedHistoryMinimumWidth
            let dockedHistory = CommandWorkspaceLayout.showsDockedHistory(width: geometry.size.width, preferred: self.prefersHistoryVisible)
            let overlayHistory = !isWide && self.compactHistoryPresented
            VStack(spacing: 0) {
                self.headerView(historyVisible: dockedHistory || overlayHistory, isWide: isWide)
                Divider()
                ZStack(alignment: .trailing) {
                    self.workspace
                        .padding(.trailing, dockedHistory ? CommandWorkspaceLayout.sidebarWidth : 0)
                        .allowsHitTesting(!overlayHistory)
                        .disabled(overlayHistory)
                        .accessibilityHidden(overlayHistory)
                    if overlayHistory {
                        Button { self.compactHistoryPresented = false } label: {
                            self.theme.palette.windowBackground.opacity(0.65)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close session history")
                    }
                    if dockedHistory || overlayHistory {
                        CommandSessionSidebar(
                            canChangeSession: self.canChangeSession,
                            blockingReason: self.sessionBlockingReason,
                            onSelect: { id in
                                guard self.canChangeSession, self.service.switchToChat(id: id) else { return }
                                self.compactHistoryPresented = false
                                if !isWide { self.composerFocused = true }
                            },
                            onArchive: self.archiveSession,
                            onRestore: { id in
                                guard self.canChangeSession else { return }
                                self.service.restoreChat(id: id)
                            }
                        )
                        .frame(width: min(CommandWorkspaceLayout.sidebarWidth, geometry.size.width))
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(self.theme.palette.separator)
                                .frame(width: 1)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            .onChange(of: isWide) { _, _ in self.compactHistoryPresented = false }
        }
        .background(self.theme.palette.windowBackground)
        .clipped()
        .onAppear {
            self.updatePresentationActivity(self.isActive)
        }
        .onDisappear { self.updatePresentationActivity(false) }
        .onChange(of: self.isActive) { _, active in self.updatePresentationActivity(active) }
        .onChange(of: self.compactHistoryPresented) { _, presented in
            if presented { self.composerFocused = false }
        }
        .onChange(of: self.asr.isRunning) { _, running in
            if !running { self.ownsASRRecording = false }
        }
        .onChange(of: self.service.currentChatID) { _, _ in
            self.followsLatestMessage = true
            self.isThinkingExpanded = false
        }
        .onChange(of: self.chatStore.sessions.map(\.id)) { _, ids in self.drafts.retain(sessionIDs: ids) }
        .onReceive(self.settings.objectWillChange.debounce(for: .milliseconds(80), scheduler: RunLoop.main)) { _ in
            if self.isPresentationActive { self.refreshModelCatalog() }
        }
        .onChange(of: self.canChangeSession) { _, canChange in
            if !canChange { self.showModelPicker = false }
        }
        .alert("Archive is full", isPresented: self.$showingArchiveLimit) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Restore a session from Archived before archiving another.")
        }
    }

    // MARK: - Workspace

    private var workspace: some View {
        VStack(spacing: 0) {
            self.chatArea
            if let pending = self.service.pendingCommand {
                self.pendingCommandView(pending)
                    .frame(maxWidth: CommandWorkspaceLayout.conversationMaximumWidth)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
            self.inputArea
                .frame(maxWidth: CommandWorkspaceLayout.conversationMaximumWidth)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }

    private func headerView(historyVisible: Bool, isWide: Bool) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Text("Command Mode").font(self.theme.typography.sectionTitle)
                Text("ALPHA")
                    .font(self.theme.typography.tinyStrong)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            Spacer(minLength: 12)
            FluidGlassControlGroup {
                HStack(spacing: 8) {
                    Button(action: self.newSession) {
                        Label("New session", systemImage: "square.and.pencil")
                    }
                    .fluidGlassAction()
                    .disabled(!self.canChangeSession)
                    .help(self.sessionBlockingReason ?? "Start a new session")
                    Button { self.toggleHistory(isWide: isWide) } label: {
                        Image(systemName: historyVisible ? "rectangle.righthalf.inset.filled" : "sidebar.right")
                            .foregroundStyle(historyVisible ? self.theme.palette.accent : self.theme.palette.secondaryText)
                    }
                    .fluidGlassAction(circular: true)
                    .help(historyVisible ? "Hide sessions" : "Show sessions")
                    .accessibilityLabel(historyVisible ? "Hide sessions" : "Show sessions")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if self.service.conversationHistory.isEmpty && !self.service.isProcessing {
                    self.emptyState
                        .frame(maxWidth: CommandWorkspaceLayout.conversationMaximumWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 56)
                        .padding(.horizontal, 20)
                } else {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if let session = self.chatStore.currentSession {
                            Text(session.title)
                                .font(self.theme.typography.sectionTitle)
                                .editableTitle(session.title, id: session.id, enabled: self.canChangeSession) {
                                    self.chatStore.renameChat(id: session.id, to: $0)
                                }
                        }
                        ForEach(self.service.conversationHistory) { message in
                            CommandMessageView(message: message, onExpand: { self.followsLatestMessage = false })
                                .id(message.id)
                        }
                        if self.service.isProcessing {
                            self.processingIndicator
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: CommandWorkspaceLayout.conversationMaximumWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                }
            }
            .onScrollPhaseChange { _, phase in
                self.isUserScrolling = phase == .interacting || phase == .decelerating
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY < 80
            } action: { _, nearBottom in
                if self.isUserScrolling { self.followsLatestMessage = nearBottom }
            }
            .onChange(of: self.service.conversationHistory.count) { _, _ in
                if self.followsLatestMessage { self.scrollToBottom(proxy) }
            }
            .onChange(of: self.service.currentChatID) { _, _ in self.scrollToBottom(proxy) }
            .onChange(of: self.service.isProcessing) { _, processing in
                if processing { self.isThinkingExpanded = false }
                if self.followsLatestMessage { self.scrollToBottom(proxy) }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
            } action: { _, _ in
                // Follow rendered block heights, including deferred Markdown, not individual tokens.
                if self.followsLatestMessage { self.scrollToBottom(proxy) }
            }
            .onAppear { self.scrollToBottom(proxy) }
            .overlay(alignment: .bottom) {
                if !self.followsLatestMessage {
                    Button {
                        self.followsLatestMessage = true
                        self.scrollToBottom(proxy)
                    } label: {
                        Label("Latest", systemImage: "arrow.down")
                    }
                    .fluidGlassAction()
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "terminal")
                .font(self.theme.typography.titleIcon)
                .foregroundStyle(self.theme.palette.secondaryText)
            Text("What would you like to do?")
                .font(self.theme.typography.title)
            Text("Ask a question, work with files, or run a command on your Mac.")
                .font(self.theme.typography.body)
                .foregroundStyle(self.theme.palette.secondaryText)
            VStack(alignment: .leading, spacing: 8) {
                self.suggestion("List files in my Downloads folder", icon: "folder")
                self.suggestion("Show my Mac’s storage usage", icon: "internaldrive")
                self.suggestion("Explain how to check a Git repository’s status", icon: "chevron.left.forwardslash.chevron.right")
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suggestion(_ text: String, icon: String) -> some View {
        Button {
            self.inputText.wrappedValue = text
            self.composerFocused = true
        } label: {
            Label(text, systemImage: icon)
                .font(self.theme.typography.bodySmall)
                .multilineTextAlignment(.leading)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(self.theme.palette.secondaryText)
        .help("Add this example to your message")
    }

    private var processingIndicator: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if self.reduceMotion {
                    Image(systemName: "ellipsis")
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(self.currentStepLabel)
                    .font(self.theme.typography.bodySmall)
                    .lineLimit(2)
            }
            .foregroundStyle(self.theme.palette.secondaryText)
            if self.settings.showThinkingTokens, !self.service.streamingThinkingText.isEmpty {
                DisclosureGroup("Thinking", isExpanded: self.$isThinkingExpanded) {
                    ScrollView {
                        Text(self.service.streamingThinkingText)
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.theme.palette.secondaryText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                }
                .font(self.theme.typography.caption)
            }
            if !self.service.streamingText.isEmpty {
                CommandMarkdownContent(text: self.service.streamingText)
            }
        }
    }

    private var currentStepLabel: String {
        guard let step = self.service.currentStep else { return "Working…" }
        switch step {
        case .thinking: return self.service.streamingText.isEmpty ? "Thinking…" : "Writing…"
        case let .checking(command): return "Checking · \(command.prefix(90))"
        case let .executing(command): return "Running · \(command.prefix(90))"
        case .verifying: return "Verifying…"
        case let .completed(success): return success ? "Done" : "Stopped"
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            guard self.followsLatestMessage else { return }
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    // MARK: - Approval

    private func pendingCommandView(_ pending: CommandModeService.PendingCommand) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Review command", systemImage: "checkmark.shield")
                .font(self.theme.typography.bodyStrong)
            if let purpose = pending.purpose {
                Text(purpose).font(self.theme.typography.bodySmall).foregroundStyle(self.theme.palette.secondaryText)
            }
            ScrollView {
                Text(pending.command)
                    .font(.fluidSystem(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 88)
            if let directory = pending.workingDirectory {
                Text(directory).font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText).lineLimit(1)
            }
            FluidGlassControlGroup {
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel") {
                        guard self.service.pendingCommand?.id == pending.id, !self.service.isProcessing else { return }
                        self.service.cancelPendingCommand()
                    }.fluidGlassAction()
                    Button {
                        Task {
                            guard self.service.pendingCommand?.id == pending.id, !self.service.isProcessing else { return }
                            await self.service.confirmAndExecute()
                        }
                    } label: {
                        Label("Run command", systemImage: "play.fill")
                    }
                    .fluidGlassAction(prominent: true)
                }
            }
        }
        .padding(16)
        .background(self.theme.palette.elevatedCardBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(self.theme.palette.warning.opacity(0.45)) }
    }

    // MARK: - Composer

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let issue = self.settings.commandModeReadinessIssue {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(self.theme.palette.warning)
                    Text(issue).font(self.theme.typography.caption)
                }
                .foregroundStyle(self.theme.palette.secondaryText)
            }
            VStack(alignment: .leading, spacing: 16) {
                TextField("Ask anything…", text: self.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(self.theme.typography.statement)
                    .lineLimit(3...8)
                    .focused(self.$composerFocused)
                    .onSubmit { self.submitCommand() }
                    .accessibilityLabel("Message")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        self.approvalMenu
                        Spacer(minLength: 8)
                        self.composerActions
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        self.approvalMenu
                        HStack { Spacer(minLength: 0); self.composerActions }
                    }
                }
            }
            .padding(20)
            .background(self.theme.palette.elevatedCardBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(self.theme.palette.cardBorder.opacity(self.composerFocused ? 0.9 : 0.55))
                    .allowsHitTesting(false)
            }
        }
    }

    private var approvalMenu: some View {
        Menu {
            Picker("Command approval", selection: self.$settings.commandModeConfirmBeforeExecute) {
                Text("Ask before risky commands").tag(true)
                Text("Run without asking").tag(false)
            }
            .pickerStyle(.inline)
        } label: {
            Label(self.settings.commandModeConfirmBeforeExecute ? "Ask first" : "Run directly", systemImage: self.settings.commandModeConfirmBeforeExecute ? "checkmark.shield" : "exclamationmark.shield")
        }
        .fluidDropdownStyle(appearance: .inline, tone: self.settings.commandModeConfirmBeforeExecute ? self.theme.palette.secondaryText : self.theme.palette.warning)
        .accessibilityLabel("Command approval")
        .accessibilityValue(self.settings.commandModeConfirmBeforeExecute ? "Ask before risky commands" : "Run without asking")
        .help("Choose whether potentially destructive commands require your approval")
    }

    private var composerActions: some View {
        HStack(spacing: 10) {
            self.modelSelector
            FluidGlassControlGroup {
                HStack(spacing: 8) {
                    Button(action: self.toggleRecording) {
                        Image(systemName: self.ownsASRRecording ? "mic.fill" : "mic")
                            .font(.fluidSystem(size: 20))
                            .frame(width: 24, height: 24)
                            .foregroundStyle(self.ownsASRRecording ? Color.red : self.theme.palette.secondaryText)
                    }
                    .fluidGlassAction(circular: true, quiet: true)
                    .disabled(self.isSubmissionPending || self.service.isProcessing || self.service.pendingCommand != nil || self.isASRStartPending || self.isASRStopPending || (self.asr.isRunning && !self.ownsASRRecording))
                    .help(self.ownsASRRecording ? "Stop recording and send" : "Speak a command")
                    .accessibilityLabel(self.ownsASRRecording ? "Stop recording and send" : "Speak a command")
                    Button {
                        if self.ownsASRRecording { self.toggleRecording() } else { self.submitCommand() }
                    } label: {
                        Image(systemName: self.ownsASRRecording ? "stop.fill" : "arrow.up")
                            .font(.fluidSystem(size: 17, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .foregroundStyle(self.theme.palette.windowBackground)
                    }
                    .fluidGlassAction(prominent: true, circular: true, tone: self.theme.palette.primaryText)
                    .disabled(self.ownsASRRecording ? self.isASRStopPending : !self.canSubmitCommand)
                    .help(self.ownsASRRecording ? "Stop recording and send" : "Send message")
                    .accessibilityLabel(self.ownsASRRecording ? "Stop recording and send" : "Send message")
                }
            }
        }
    }

    private var modelSelector: some View {
        Button {
            self.refreshModelCatalog()
            self.showModelPicker.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(self.selectedModelID.isEmpty ? "Choose model" : ModelDisplayName.forID(self.selectedModelID))
                    .lineLimit(1).truncationMode(.middle)
                FluidDropdownChevron()
            }
            .font(self.theme.typography.statement)
            .foregroundStyle(self.theme.palette.secondaryText)
            .padding(.horizontal, 12)
            .frame(width: 220, height: 36)
            .fluidDropdownSurface(appearance: .inline)
        }
        .buttonStyle(.plain)
        .disabled(!self.canChangeSession)
        .help(self.sessionBlockingReason ?? "Search models across verified providers")
        .accessibilityLabel("Choose model")
        .popover(isPresented: self.$showModelPicker, arrowEdge: .top) {
            CommandModelPicker(
                options: self.modelOptions,
                selectedProviderID: self.selectedModelProviderID,
                selectedModelID: self.selectedModelID,
                onSelect: self.selectModel,
                onDismiss: { self.showModelPicker = false }
            )
        }
    }

    // MARK: - Actions

    private var sessionBlockingReason: String? {
        if self.service.pendingCommand != nil { return "Run or cancel the pending command before switching sessions." }
        if self.service.isProcessing { return "You can switch sessions when this command finishes." }
        if self.isSubmissionPending { return "Sending your message…" }
        if self.asr.isRunning || self.isASRStartPending || self.isASRStopPending { return "Finish recording before switching sessions." }
        return nil
    }

    private var canChangeSession: Bool { self.sessionBlockingReason == nil }
    private var canSubmitCommand: Bool {
        !self.inputText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !self.compactHistoryPresented && self.canChangeSession && self.settings.commandModeReadinessIssue == nil
    }

    private func toggleHistory(isWide: Bool) {
        withAnimation(self.reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            if isWide { self.prefersHistoryVisible.toggle() } else { self.compactHistoryPresented.toggle() }
        }
    }

    private func newSession() {
        guard self.canChangeSession else { return }
        self.service.createNewChat()
        self.compactHistoryPresented = false
        self.composerFocused = true
    }

    private func archiveSession(_ id: String) {
        guard self.canChangeSession,
              self.chatStore.sessions.contains(where: { $0.id == id && !$0.isArchived }) else { return }
        if !self.service.archiveChat(id: id) { self.showingArchiveLimit = true }
    }

    private func updatePresentationActivity(_ active: Bool) {
        self.isPresentationActive = active
        self.service.enableNotchOutput = !active
        if active { self.refreshModelCatalog() }
        guard !active, CommandModeRecordingOwnershipPolicy.shouldStopOnDeactivate(ownsRecording: self.ownsASRRecording, isRunning: self.asr.isRunning) else { return }
        self.ownsASRRecording = false
        Task { await self.asr.stopWithoutTranscription() }
    }

    private func toggleRecording() {
        if self.asr.isRunning {
            guard self.ownsASRRecording, !self.isASRStopPending else { return }
            self.ownsASRRecording = false
            self.isASRStopPending = true
            let sessionID = self.recordingSessionID
            self.recordingSessionID = nil
            Task {
                defer { self.isASRStopPending = false }
                let command = await self.asr.stop().trimmingCharacters(in: .whitespacesAndNewlines)
                _ = self.asr.consumeLastCompletedAudioSnapshot()
                guard !command.isEmpty, let sessionID, self.chatStore.sessions.contains(where: { $0.id == sessionID }) else { return }
                self.drafts.set(command, for: sessionID)
                guard self.isPresentationActive, self.service.currentChatID == sessionID,
                      !self.service.isProcessing, self.service.pendingCommand == nil,
                      self.settings.commandModeReadinessIssue == nil else { return }
                self.drafts.set("", for: sessionID)
                self.followsLatestMessage = true
                await self.service.processUserCommand(command)
            }
        } else {
            guard !self.isSubmissionPending, !self.isASRStartPending, !self.isASRStopPending, !self.service.isProcessing,
                  self.service.pendingCommand == nil else { return }
            self.isASRStartPending = true
            self.recordingSessionID = self.service.currentChatID
            Task {
                defer { self.isASRStartPending = false }
                let outcome = await self.asr.start()
                self.ownsASRRecording = CommandModeRecordingOwnershipPolicy.ownsRecording(after: outcome, isRunning: self.asr.isRunning)
                if !self.ownsASRRecording { self.recordingSessionID = nil }
                if CommandModeRecordingOwnershipPolicy.shouldStopAfterStart(ownsRecording: self.ownsASRRecording, isPresentationActive: self.isPresentationActive) {
                    self.updatePresentationActivity(false)
                }
            }
        }
    }

    private func submitCommand() {
        guard self.canSubmitCommand else { return }
        let sessionID = self.service.currentChatID
        let draft = self.inputText.wrappedValue
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isSubmissionPending = true
        Task {
            defer { self.isSubmissionPending = false }
            guard self.isPresentationActive, self.service.currentChatID == sessionID,
                  !self.service.isProcessing, self.service.pendingCommand == nil,
                  self.settings.commandModeReadinessIssue == nil else { return }
            if self.drafts.text(for: sessionID) == draft { self.drafts.set("", for: sessionID) }
            self.followsLatestMessage = true
            await self.service.processUserCommand(text)
        }
    }

    private func refreshModelCatalog() {
        let options = self.settings.commandModeModelCatalog()
        let providerKey = ModelRepository.shared.providerKey(for: self.settings.effectiveCommandModeProviderID)
        let modelID = self.settings.effectiveCommandModeSelectedModel
        let selected = options.first {
            ModelRepository.shared.providerKey(for: $0.providerID) == providerKey && $0.modelID == modelID
        }
        self.modelOptions = options
        self.selectedModelProviderID = selected?.providerID ?? ""
        self.selectedModelID = selected?.modelID ?? ""
    }

    private func selectModel(_ option: CommandModelOption) {
        guard self.canChangeSession else { return }
        let didSelect = self.settings.selectCommandModeModel(option)
        self.refreshModelCatalog()
        if didSelect { self.showModelPicker = false }
    }
}
