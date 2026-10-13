import Foundation

/// The `fv-serve` command, kept apart from `main.swift` so the app's tests can run it directly.
/// It reads, prints and returns: no state is kept between calls and nothing is written.
nonisolated enum FluidServeCommand {
    struct Result: Equatable {
        var output: String
        var exitCode: Int32

        static func failure(_ message: String, code: Int32 = 1) -> Result {
            Result(output: message, exitCode: code)
        }
    }

    static let usage = """
    fv-serve reads FluidVoice meetings. It is read-only.

      fv-serve meet list [--since 7d|24h|YYYY-MM-DD] [--limit N] [--json]
      fv-serve meet show <id|latest> [--from MM:SS] [--to MM:SS] [--json]
      fv-serve meet summary <id|latest> [--style NAME]
      fv-serve meet search [--since 7d|24h|YYYY-MM-DD] [--limit N] [--] text
      fv-serve status [--json]
      fv-serve skill          (prints the skill file for a coding agent)

    An id is the first column of `meet list`; its first characters are enough.
    """

    static func run(
        arguments: [String],
        root: URL,
        accessEnabled: Bool,
        toolPath: String = FluidServeMeetings.toolName,
        customPrompt: String = "",
        now: Date = Date(),
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default
    ) -> Result {
        var arguments = arguments
        guard let area = arguments.first else { return Result(output: self.usage, exitCode: 0) }
        arguments.removeFirst()
        switch area {
        case "help", "--help", "-h":
            return Result(output: self.usage, exitCode: 0)
        case "skill":
            // Instructions only, no meeting data, so it answers whatever the switch says.
            return Result(output: FluidServeSkill.document(toolPath: toolPath).trimmingCharacters(in: .newlines), exitCode: 0)
        case "status":
            let count = accessEnabled ? FluidServeMeetings.entries(root: root, fileManager: fileManager).count : 0
            if arguments == ["--json"] {
                let object: [String: Any] = ["access": accessEnabled, "meetings": count]
                return Result(output: (try? self.json(object)) ?? "{}", exitCode: 0)
            }
            return Result(
                output: accessEnabled
                    ? "Meeting access: on\nMeetings available: \(count)"
                    : "Meeting access: off\n\(FluidServeMeetings.ReadError.accessOff.localizedDescription)",
                exitCode: 0
            )
        case "meet":
            guard accessEnabled else {
                return .failure(FluidServeMeetings.ReadError.accessOff.localizedDescription, code: 2)
            }
            do {
                return try self.meet(arguments, root: root, customPrompt: customPrompt, now: now, timeZone: timeZone, fileManager: fileManager)
            } catch let error as UsageError {
                return .failure("\(error.message)\n\n\(self.usage)")
            } catch {
                return .failure(error.localizedDescription)
            }
        default:
            return .failure("Unknown command \"\(area)\".\n\n\(self.usage)")
        }
    }

    private struct UsageError: Error {
        var message: String
    }

    private struct Options {
        var positional: [String] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []
    }

    private static func parse(_ arguments: [String], valued: Set<String>, flags: Set<String>) throws -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                // Everything after `--` is text, so a search can begin with a dash.
                options.positional.append(contentsOf: arguments[(index + 1)...])
                break
            }
            if valued.contains(argument) {
                guard index + 1 < arguments.count else { throw UsageError(message: "\(argument) needs a value.") }
                options.values[argument] = arguments[index + 1]
                index += 2
            } else if flags.contains(argument) {
                options.flags.insert(argument)
                index += 1
            } else if argument.hasPrefix("-"), argument.count > 1 {
                throw UsageError(message: "Unknown option \(argument). Put -- before text that begins with a dash.")
            } else {
                options.positional.append(argument)
                index += 1
            }
        }
        return options
    }

    private static func meet(
        _ arguments: [String],
        root: URL,
        customPrompt: String,
        now: Date,
        timeZone: TimeZone,
        fileManager: FileManager
    ) throws -> Result {
        guard let action = arguments.first else { throw UsageError(message: "Say what to do with meetings.") }
        let rest = Array(arguments.dropFirst())

        func since(_ options: Options) throws -> Date? {
            guard let text = options.values["--since"] else { return nil }
            guard let date = FluidServeMeetings.sinceDate(from: text, now: now, timeZone: timeZone) else {
                throw UsageError(message: "--since takes 7d, 24h or a date like 2026-10-01.")
            }
            return date
        }

        func limit(_ options: Options, default fallback: Int) throws -> Int {
            guard let text = options.values["--limit"] else { return fallback }
            guard let value = Int(text), value > 0 else { throw UsageError(message: "--limit takes a number above zero.") }
            return value
        }

        func clock(_ options: Options, _ name: String) throws -> TimeInterval? {
            guard let text = options.values[name] else { return nil }
            guard let value = FluidServeMeetings.seconds(fromClock: text) else {
                throw UsageError(message: "\(name) takes a time like 12:30.")
            }
            return value
        }

        switch action {
        case "list":
            let options = try self.parse(rest, valued: ["--since", "--limit"], flags: ["--json"])
            let entries = try Array(FluidServeMeetings.entries(root: root, since: since(options), fileManager: fileManager)
                .prefix(limit(options, default: 20)))
            if options.flags.contains("--json") {
                return try Result(output: self.json(entries.map { self.summaryObject($0, customPrompt: customPrompt, fileManager: fileManager) }), exitCode: 0)
            }
            return Result(output: FluidServeMeetings.listing(entries, customPrompt: customPrompt, timeZone: timeZone, fileManager: fileManager), exitCode: 0)

        case "show":
            let options = try self.parse(rest, valued: ["--from", "--to"], flags: ["--json"])
            let entry = try FluidServeMeetings.resolve(
                options.positional.first ?? "latest",
                in: FluidServeMeetings.entries(root: root, fileManager: fileManager)
            )
            let from = try clock(options, "--from")
            let to = try clock(options, "--to")
            if let from, let to, from > to { throw UsageError(message: "--from must be earlier than --to.") }
            if options.flags.contains("--json") {
                var object = self.summaryObject(entry, customPrompt: customPrompt, fileManager: fileManager)
                object["turns"] = entry.meeting.turns
                    .filter { $0.start.seconds >= (from ?? 0) && $0.start.seconds <= (to ?? .infinity) }
                    .map { [
                        "startSeconds": $0.start.seconds,
                        "endSeconds": $0.end.seconds,
                        "speaker": FluidServeMeetings.speakerLabel(for: $0, in: entry.meeting),
                        "text": $0.text,
                    ] as [String: Any] }
                return try Result(output: self.json(object), exitCode: 0)
            }
            let transcript = FluidServeMeetings.transcript(for: entry.meeting, from: from, to: to)
            return Result(
                output: FluidServeMeetings.header(for: entry, timeZone: timeZone) + "\n----------\n"
                    + (transcript.isEmpty ? "No turns in that time range." : transcript),
                exitCode: 0
            )

        case "summary":
            let options = try self.parse(rest, valued: ["--style"], flags: [])
            let entry = try FluidServeMeetings.resolve(
                options.positional.first ?? "latest",
                in: FluidServeMeetings.entries(root: root, fileManager: fileManager)
            )
            var summaries = FluidServeMeetings.savedSummaries(for: entry, customPrompt: customPrompt, fileManager: fileManager)
            if let style = options.values["--style"] {
                summaries = summaries.filter { $0.style == style.lowercased() }
            }
            guard !summaries.isEmpty else {
                return .failure(
                    "No current saved summary for this meeting. Summaries are written in FluidVoice; "
                        + "`\(FluidServeMeetings.toolName) meet show \(entry.meeting.id.uuidString.prefix(8))` prints the transcript."
                )
            }
            let body = summaries.map { summary in
                var facts = ["Style: \(summary.style)"]
                if let modelName = summary.modelName { facts.append("Written by: \(modelName)") }
                if let generatedAt = summary.generatedAt {
                    facts.append("Saved: \(FluidServeMeetings.dateText(generatedAt, timeZone: timeZone))")
                }
                return facts.joined(separator: "\n") + "\n\n" + summary.text
            }.joined(separator: "\n\n==========\n\n")
            return Result(output: FluidServeMeetings.header(for: entry, timeZone: timeZone) + "\n----------\n" + body, exitCode: 0)

        case "search":
            let options = try self.parse(rest, valued: ["--since", "--limit"], flags: [])
            // Unquoted words are one phrase: `meet search budget review` looks for "budget review".
            let query = options.positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { throw UsageError(message: "Say what to search for.") }
            let hits = try FluidServeMeetings.search(
                query,
                in: FluidServeMeetings.entries(root: root, since: since(options), fileManager: fileManager),
                limit: limit(options, default: 30)
            )
            guard !hits.isEmpty else { return Result(output: "No transcript mentions \"\(query)\".", exitCode: 0) }
            var lines: [String] = []
            var lastID: UUID?
            for hit in hits {
                if hit.meeting.id != lastID {
                    if lastID != nil { lines.append("") }
                    lines.append(
                        "\(hit.meeting.id.uuidString.prefix(8))  "
                            + "\(FluidServeMeetings.dateText(hit.meeting.startedAt, timeZone: timeZone))  \(hit.meeting.title)"
                    )
                    lastID = hit.meeting.id
                }
                lines.append("  " + hit.line)
            }
            return Result(output: lines.joined(separator: "\n"), exitCode: 0)

        default:
            throw UsageError(message: "Unknown meeting command \"\(action)\".")
        }
    }

    private static func summaryObject(_ entry: FluidServeMeetings.Entry, customPrompt: String, fileManager: FileManager) -> [String: Any] {
        let meeting = entry.meeting
        let formatter = ISO8601DateFormatter()
        return [
            "id": meeting.id.uuidString,
            "title": meeting.title,
            "startedAt": formatter.string(from: meeting.startedAt),
            "durationSeconds": meeting.durationSeconds.rounded(),
            "languageCode": meeting.languageCode,
            "speakers": meeting.activeSpeakers.map(\.displayName),
            "summaries": FluidServeMeetings.savedSummaries(for: entry, customPrompt: customPrompt, fileManager: fileManager).map(\.style),
        ]
    }

    private static func json(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? ""
    }
}
