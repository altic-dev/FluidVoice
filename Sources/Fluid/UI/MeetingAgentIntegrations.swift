import AppKit
import Combine
import SwiftUI

/// Tracks which coding agents have the `fluidmeet` skill and whether the meeting reader answers.
/// File checks, writes and the command run happen off the main thread, and only when the page
/// appears or the user presses a button; nothing polls.
///
/// There is no separate switch. Meetings are shared while Claude Code or Codex has the skill, or
/// while the user has copied instructions for another agent and not stopped that since.
@MainActor
final class FluidServeSettingsModel: ObservableObject {
    // Explicitly nonisolated: on macOS 15.4+ the synthesized main-actor deinit can abort until the OS runtime has the fix (swiftlang/swift#88036).
    nonisolated deinit {}

    typealias Agent = FluidServeSkillInstaller.Agent
    typealias Status = FluidServeSkillInstaller.Status

    /// What the last button press did, shown under that row until the next press.
    enum Notice: Equatable {
        case added
        case updated
        case removed
    }

    @Published private(set) var statuses: [Agent: Status] = [:]
    @Published private(set) var notices: [Agent: Notice] = [:]
    @Published private(set) var toolIsBundled = true
    /// Whether an app on this Mac opens `codex://` links, so the row can offer to start a chat.
    @Published private(set) var codexAppIsInstalled = false
    /// The answer from running the real command. Nil while nothing is shared or before the first run.
    @Published private(set) var check: FluidServeSelfCheck.Outcome?
    @Published private(set) var isChecking = false
    @Published private(set) var issue: String?
    /// Which row the current issue came from, so another row's success does not wipe it.
    private var issueAgent: Agent?
    /// True once the instructions for another agent are on the clipboard, so the row can say so.
    @Published private(set) var copiedAgentInstructions = false
    /// Whether meetings are shared with agents FluidVoice cannot see. Those agents keep their own
    /// copy of the skill, so only the user can say when this ends.
    @Published private(set) var otherAgentsShared = false

    /// True when agents set up from copied instructions are the only reason meetings are shared.
    /// Access is one switch for the whole Mac, so only then does stopping them stop anything.
    var sharedOnlyWithOtherAgents: Bool {
        self.otherAgentsShared && !self.statuses.values.contains { $0 == .installed || $0 == .needsUpdate }
    }

    private let home: URL
    private let toolURL: () -> URL?
    private let selfCheck: @Sendable (URL) -> FluidServeSelfCheck.Outcome
    private let copyToClipboard: (String) -> Bool
    private let isSharing: () -> Bool
    private let setSharing: (Bool) -> Void
    private let isOtherAgentsShared: () -> Bool
    private let setOtherAgentsShared: (Bool) -> Void
    /// Counts refreshes so a slow one that finishes late cannot overwrite a newer answer.
    private var refreshGeneration = 0
    /// The state found on first look is adopted once. After that only the user's presses change it.
    private var adoptedStateFoundOnDisk = false
    /// The latest add, remove or stop. Each waits for the one before it, so a slow one cannot
    /// finish late and undo what a quicker one decided about sharing.
    private var lastChange: Task<Void, Never>?

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        toolURL: @escaping () -> URL? = { FluidServeSkillInstaller.bundledToolURL() },
        selfCheck: @escaping @Sendable (URL) -> FluidServeSelfCheck.Outcome = { FluidServeSelfCheck.run(tool: $0) },
        copyToClipboard: @escaping (String) -> Bool = { text in
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string)
        },
        isSharing: @escaping () -> Bool = { SettingsStore.shared.fluidServeMeetingAccessEnabled },
        setSharing: @escaping (Bool) -> Void = { SettingsStore.shared.fluidServeMeetingAccessEnabled = $0 },
        isOtherAgentsShared: @escaping () -> Bool = { SettingsStore.shared.fluidServeOtherAgentsShared },
        setOtherAgentsShared: @escaping (Bool) -> Void = { SettingsStore.shared.fluidServeOtherAgentsShared = $0 }
    ) {
        self.home = home
        self.toolURL = toolURL
        self.selfCheck = selfCheck
        self.copyToClipboard = copyToClipboard
        self.isSharing = isSharing
        self.setSharing = setSharing
        self.isOtherAgentsShared = isOtherAgentsShared
        self.setOtherAgentsShared = setOtherAgentsShared
        self.otherAgentsShared = isOtherAgentsShared()
    }

    /// Puts a short message on the clipboard for any coding agent the page has no row for, and
    /// starts sharing so that agent can read meetings. It says "copied" only when the clipboard took it.
    func copyAgentInstructions() {
        guard let tool = self.toolURL() else {
            self.copiedAgentInstructions = false
            self.issue = FluidServeSkillInstaller.InstallError.toolMissing.localizedDescription
            return
        }
        self.copiedAgentInstructions = self.copyToClipboard(FluidServeSkill.agentInstructions(toolPath: tool.path))
        if !self.copiedAgentInstructions {
            self.issueAgent = nil
            self.issue = "Could not copy to the clipboard."
            return
        }
        if self.issueAgent == nil { self.issue = nil }
        self.setOtherAgentsShared(true)
        self.otherAgentsShared = true
        self.setSharing(true)
        Task { await self.refresh() }
    }

    /// Ends sharing with agents set up from copied instructions. The page offers this only when
    /// no Claude Code or Codex skill is left, so it turns meeting access off for every agent.
    func stopSharingWithOtherAgents() async {
        await self.inTurn {
            self.adoptedStateFoundOnDisk = true
            self.setOtherAgentsShared(false)
            self.otherAgentsShared = false
            self.copiedAgentInstructions = false
            let onDisk = await self.refresh()
            self.applySharing(for: onDisk)
            await self.refresh()
        }
    }

    /// Runs one change after the changes already under way have finished.
    private func inTurn(_ work: @escaping @MainActor () async -> Void) async {
        let previous = self.lastChange
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        self.lastChange = task
        await task.value
    }

    /// Meetings are shared exactly while some agent is entitled to read them.
    private func applySharing(for statuses: [Agent: Status]) {
        let anySkill = statuses.values.contains { $0 == .installed || $0 == .needsUpdate }
        let shouldShare = anySkill || self.isOtherAgentsShared()
        if self.isSharing() != shouldShare { self.setSharing(shouldShare) }
    }

    /// Returns what it read from disk, so a caller can confirm its own change even when a newer
    /// refresh has already replaced what the page shows. The command is only run while meetings are shared.
    @discardableResult
    func refresh() async -> [Agent: Status] {
        let home = self.home
        let tool = self.toolURL()
        let selfCheck = self.selfCheck
        let sharing = self.isSharing()
        self.refreshGeneration += 1
        let generation = self.refreshGeneration
        self.toolIsBundled = tool != nil
        self.isChecking = sharing && tool != nil
        let codexLink = FluidServeSkillInstaller.codexNewChatURL()
        let found = await Self.offThePool {
            let statuses = Dictionary(uniqueKeysWithValues: Agent.allCases.map { agent in
                (agent, FluidServeSkillInstaller.status(for: agent, toolPath: tool?.path ?? "", home: home))
            })
            let codexApp = codexLink.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
            let check = sharing ? tool.map(selfCheck) : nil
            return (statuses, codexApp != nil, check)
        }
        guard generation == self.refreshGeneration else { return found.0 }
        // Sharing found on with no skill installed means an agent was set up some other way, or a
        // skill file was deleted by hand. Show it as shared with other agents so it can be stopped.
        if !self.adoptedStateFoundOnDisk {
            self.adoptedStateFoundOnDisk = true
            let anySkill = found.0.values.contains { $0 == .installed || $0 == .needsUpdate }
            if sharing, !anySkill, !self.isOtherAgentsShared() { self.setOtherAgentsShared(true) }
        }
        self.otherAgentsShared = self.isOtherAgentsShared()
        self.statuses = found.0
        self.codexAppIsInstalled = found.1
        self.check = found.2
        self.isChecking = false
        return found.0
    }

    /// Runs blocking file and process work on a dispatch queue, so waiting on the command never
    /// parks one of Swift concurrency's few threads.
    private nonisolated static func offThePool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) }
        }
    }

    /// Opens a new Codex chat with a starter prompt typed in. The user still presses send.
    func openCodexChat() {
        guard let url = FluidServeSkillInstaller.codexNewChatURL() else { return }
        if !NSWorkspace.shared.open(url) {
            self.issueAgent = .codex
            self.issue = "Could not open Codex."
        }
    }

    func install(_ agent: Agent) async {
        guard let tool = self.toolURL() else {
            self.issue = FluidServeSkillInstaller.InstallError.toolMissing.localizedDescription
            return
        }
        await self.inTurn {
            let wasPresent = self.statuses[agent] == .needsUpdate
            await self.change(agent, notice: wasPresent ? .updated : .added, expecting: .installed) { home in
                try FluidServeSkillInstaller.install(for: agent, toolPath: tool.path, home: home)
            }
        }
    }

    func remove(_ agent: Agent) async {
        await self.inTurn {
            await self.change(agent, notice: .removed, expecting: .notInstalled) { home in
                try FluidServeSkillInstaller.remove(for: agent, home: home)
            }
        }
    }

    /// Does the work, re-reads the disk, and only then says it worked: the notice is shown when the
    /// file is really in the state the button promised. Sharing then follows who still has access.
    private func change(
        _ agent: Agent,
        notice: Notice,
        expecting expected: Status,
        _ work: @escaping @Sendable (URL) throws -> Void
    ) async {
        self.adoptedStateFoundOnDisk = true
        let home = self.home
        let failure: String? = await Self.offThePool {
            do {
                try work(home)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        var onDisk = await self.refresh()
        let succeeded = failure == nil && onDisk[agent] == expected
        if succeeded {
            let wasSharing = self.isSharing()
            self.applySharing(for: onDisk)
            if self.isSharing() != wasSharing { onDisk = await self.refresh() }
            self.notices[agent] = notice
            if self.issueAgent == agent || self.issueAgent == nil { self.issue = nil }
            if self.issueAgent == agent { self.issueAgent = nil }
        } else {
            self.notices[agent] = nil
            self.issueAgent = agent
            self.issue = failure ?? "\(agent.displayName): the skill file is not in the expected place. Nothing was confirmed."
        }
    }
}

/// The coding-agent rows on FluidMeet settings > Integrations: add the `fluidmeet` skill to
/// Claude Code or Codex, or copy instructions for any other agent.
struct MeetingAgentIntegrations: View {
    @Environment(\.theme) private var theme
    @StateObject private var model: FluidServeSettingsModel

    init(model: FluidServeSettingsModel? = nil) {
        _model = StateObject(wrappedValue: model ?? FluidServeSettingsModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            FluidManagementGroup(title: "Coding agents") {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                    if self.model.toolIsBundled {
                        self.agentRow(.claudeCode, assetName: "Provider_Anthropic")
                        Divider()
                        self.agentRow(.codex, assetName: "Provider_OpenAI")
                        Divider()
                        self.otherAgentsRow
                    } else {
                        self.statusLabel("This build of FluidVoice cannot share meetings with coding agents.", symbol: "exclamationmark.circle.fill", color: .orange)
                    }
                }
            }
            self.checkLine
            if let issue = self.model.issue {
                self.statusLabel(issue, symbol: "exclamationmark.circle.fill", color: .orange)
                    .textSelection(.enabled)
            }
        }
        .task { await self.model.refresh() }
    }

    /// The real command is run behind the scenes; the page only speaks up when it is not working.
    @ViewBuilder
    private var checkLine: some View {
        switch self.model.check {
        case .accessOff:
            self.statusLabel("Meetings are not reaching your agents yet. Remove the skill and add it again.", symbol: "exclamationmark.circle.fill", color: .orange)
        case let .failed(reason):
            self.statusLabel(reason, symbol: "exclamationmark.circle.fill", color: .orange)
        case .working, nil:
            EmptyView()
        }
    }

    private func statusLabel(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(self.theme.typography.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func tile(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(width: 44, height: 44)
            .background(Color(nsColor: .white), in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.md))
            .accessibilityHidden(true)
    }

    private func agentRow(_ agent: FluidServeSkillInstaller.Agent, assetName: String) -> some View {
        let status = self.model.statuses[agent]
        let state = Self.state(for: status)
        return HStack(spacing: self.theme.metrics.spacing.md) {
            self.tile {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                Text(agent.displayName)
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(self.theme.palette.primaryText)
                Label(state.title, systemImage: state.symbol)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.color(for: state.tone))
                    .accessibilityLabel("\(agent.displayName): \(state.title)")
            }
            Spacer(minLength: self.theme.metrics.spacing.md)
            switch status {
            case .notInstalled:
                Button("Add skill") { Task { await self.model.install(agent) } }
                    .meetingGlassAction(prominent: true)
            case .needsUpdate:
                Button("Update skill") { Task { await self.model.install(agent) } }
                    .meetingGlassAction(prominent: true)
                Button("Remove skill") { Task { await self.model.remove(agent) } }
                    .meetingGlassAction()
            case .installed:
                if agent == .codex, self.model.codexAppIsInstalled {
                    Button("Open Codex") { self.model.openCodexChat() }
                        .meetingGlassAction(prominent: true)
                        .help("Starts a new Codex chat with a first question typed in. Nothing is sent until you send it.")
                }
                Button("Remove skill") { Task { await self.model.remove(agent) } }
                    .meetingGlassAction()
            case .agentNotFound, .foreign, nil:
                EmptyView()
            }
        }
        .padding(.vertical, self.theme.metrics.spacing.sm)
        .accessibilityElement(children: .contain)
    }

    /// For Cursor, Gemini and the rest: one message to paste, and the agent adds the skill itself.
    private var otherAgentsRow: some View {
        HStack(spacing: self.theme.metrics.spacing.md) {
            self.tile {
                Image(systemName: "terminal")
                    .font(.fluidSystem(size: 20, weight: .medium))
                    .foregroundStyle(Color.black)
            }
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                Text("Other agents")
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(self.theme.palette.primaryText)
                if self.model.copiedAgentInstructions {
                    Label("Copied. Now paste it.", systemImage: "checkmark.circle.fill")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(Color.fluidGreen)
                        .lineLimit(1)
                } else if self.model.sharedOnlyWithOtherAgents {
                    Label("Sharing is on", systemImage: "checkmark.circle.fill")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(Color.fluidGreen)
                        .lineLimit(1)
                } else {
                    Text("Cursor, Gemini and others")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
            }
            Spacer(minLength: self.theme.metrics.spacing.md)
            Button("Copy instructions") { self.model.copyAgentInstructions() }
                .meetingGlassAction()
            if self.model.sharedOnlyWithOtherAgents {
                Button("Stop sharing") { Task { await self.model.stopSharingWithOtherAgents() } }
                    .meetingGlassAction()
                    .help("No agent can read your meetings until you add one again.")
            }
        }
        .padding(.vertical, self.theme.metrics.spacing.sm)
        .accessibilityElement(children: .contain)
    }

    private func color(for tone: Tone) -> Color {
        switch tone {
        case .good: return Color.fluidGreen
        case .attention: return .orange
        case .neutral: return self.theme.palette.secondaryText
        }
    }

    enum Tone: Equatable {
        case good
        case attention
        case neutral
    }

    /// The word and mark next to each agent's name: the state, never the next action.
    static func state(for status: FluidServeSkillInstaller.Status?) -> (title: String, symbol: String, tone: Tone) {
        switch status {
        case nil: return ("Checking…", "arrow.triangle.2.circlepath", .neutral)
        case .agentNotFound: return ("Not on this Mac", "minus.circle", .neutral)
        case .notInstalled: return ("Not added", "circle", .neutral)
        case .installed: return ("Skill added", "checkmark.circle.fill", .good)
        case .needsUpdate: return ("Needs update", "exclamationmark.circle.fill", .attention)
        case .foreign: return ("Another fluidmeet skill is already there", "exclamationmark.circle.fill", .attention)
        }
    }
}
