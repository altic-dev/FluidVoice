import Foundation

/// Adds or removes the `fluidmeet` skill that tells Claude Code and Codex how to call `fv-serve`.
/// It only ever touches the one file it wrote: a skill of the same name from somewhere else is left alone.
nonisolated enum FluidServeSkillInstaller {
    static let skillName = FluidServeSkill.name
    static let marker = FluidServeSkill.marker

    enum Agent: String, CaseIterable, Identifiable, Sendable {
        case claudeCode
        case codex

        var id: String { self.rawValue }

        var displayName: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .codex: return "Codex"
            }
        }

        /// Both tools keep personal skills in `<home folder>/skills/<name>/SKILL.md`.
        var homeFolderName: String {
            switch self {
            case .claudeCode: return ".claude"
            case .codex: return ".codex"
            }
        }
    }

    enum Status: Equatable, Sendable {
        /// The tool has never been set up on this Mac.
        case agentNotFound
        case notInstalled
        case installed
        /// Ours, but written by an older build or for an app that has since moved.
        case needsUpdate
        /// A `fluidmeet` skill that FluidVoice did not write.
        case foreign
    }

    enum InstallError: LocalizedError, Equatable {
        case foreignSkill(String)
        case toolMissing

        var errorDescription: String? {
            switch self {
            case let .foreignSkill(path):
                return "A different \(FluidServeSkillInstaller.skillName) skill is already at \(path). FluidVoice left it untouched."
            case .toolMissing:
                return "This build of FluidVoice does not include \(FluidServeMeetings.toolName)."
            }
        }
    }

    /// What a new chat is started with: enough for the agent to pick the skill, and nothing is sent until the user does.
    static let starterPrompt = "Use the \(skillName) skill to list my recent meetings."

    /// A link that opens a new Codex chat with `prompt` typed in but not sent.
    /// The Codex app handles `codex://threads/new`; `mode=codex` picks the agent that reads local skills.
    static func codexNewChatURL(prompt: String = starterPrompt) -> URL? {
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/new"
        components.queryItems = [URLQueryItem(name: "prompt", value: prompt), URLQueryItem(name: "mode", value: "codex")]
        return components.url
    }

    /// The command inside this copy of the app, or nil for a build that does not ship it.
    static func bundledToolURL(bundle: Bundle = .main, fileManager: FileManager = .default) -> URL? {
        let url = bundle.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(FluidServeMeetings.toolName, isDirectory: false)
        return fileManager.isExecutableFile(atPath: url.path) ? url : nil
    }

    static func skillFile(for agent: Agent, home: URL) -> URL {
        home.appendingPathComponent(agent.homeFolderName, isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(self.skillName, isDirectory: true)
            .appendingPathComponent("SKILL.md", isDirectory: false)
    }

    static func status(for agent: Agent, toolPath: String, home: URL, fileManager: FileManager = .default) -> Status {
        var isDirectory: ObjCBool = false
        let agentHome = home.appendingPathComponent(agent.homeFolderName, isDirectory: true)
        guard fileManager.fileExists(atPath: agentHome.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .agentNotFound
        }
        guard let existing = self.text(at: self.skillFile(for: agent, home: home), fileManager: fileManager) else {
            return .notInstalled
        }
        guard FluidServeSkill.isOurs(existing) else { return .foreign }
        return existing == self.skillDocument(toolPath: toolPath) ? .installed : .needsUpdate
    }

    static func install(for agent: Agent, toolPath: String, home: URL, fileManager: FileManager = .default) throws {
        let file = self.skillFile(for: agent, home: home)
        if let existing = self.text(at: file, fileManager: fileManager), !FluidServeSkill.isOurs(existing) {
            throw InstallError.foreignSkill(file.path)
        }
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(self.skillDocument(toolPath: toolPath).utf8).write(to: file, options: .atomic)
    }

    static func remove(for agent: Agent, home: URL, fileManager: FileManager = .default) throws {
        let file = self.skillFile(for: agent, home: home)
        guard let existing = self.text(at: file, fileManager: fileManager) else { return }
        guard FluidServeSkill.isOurs(existing) else {
            throw InstallError.foreignSkill(file.path)
        }
        try fileManager.removeItem(at: file)
        let folder = file.deletingLastPathComponent()
        if (try? fileManager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? fileManager.removeItem(at: folder)
        }
    }

    /// The file's text, nil when it is missing. Bytes that are not UTF-8 read as empty, which is not ours.
    /// A file that exists but cannot be read counts the same way, so it is never replaced.
    private static func text(at file: URL, fileManager: FileManager) -> String? {
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        guard let data = fileManager.contents(atPath: file.path) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func skillDocument(toolPath: String) -> String {
        FluidServeSkill.document(toolPath: toolPath)
    }
}
