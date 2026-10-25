import CryptoKit
import Foundation

/// Read-only view of saved meetings for the `fv-serve` command.
///
/// Foundation-only on purpose: the command line tool compiles this file alone, so it must not reach
/// into the app's meeting model. It decodes just the fields it prints and never writes, so running
/// it cannot change, lock or slow down anything the app owns.
nonisolated enum FluidServeMeetings {
    static let toolName = "fv-serve"
    static let accessDefaultsKey = "FluidServeMeetingAccessEnabled"
    static let releaseBundleIdentifier = "com.FluidApp.app"

    struct Speaker: Decodable, Equatable {
        var id: UUID
        var displayName: String
        var isLocalUser: Bool
        var mergedIntoSpeakerID: UUID?
    }

    struct MediaTime: Decodable, Equatable {
        var value: Int64
        var timescale: Int32

        var seconds: TimeInterval {
            self.timescale > 0 ? TimeInterval(self.value) / TimeInterval(self.timescale) : 0
        }
    }

    struct Segment: Decodable, Equatable {
        var start: MediaTime
        var end: MediaTime
        var speakerID: UUID?
        var text: String
        var isLikelyEcho: Bool?
        var attributionState: String?
    }

    struct Meeting: Decodable, Equatable {
        var id: UUID
        var title: String
        var languageCode: String
        var startedAt: Date
        var endedAt: Date?
        var state: String
        var speakers: [Speaker]
        var transcriptSegments: [Segment]

        /// Turns the reader prints: echoes of the other side dropped, oldest first.
        var turns: [Segment] {
            self.transcriptSegments
                .filter { $0.isLikelyEcho != true }
                .sorted { $0.start.seconds < $1.start.seconds }
        }

        var activeSpeakers: [Speaker] {
            self.speakers.filter { $0.mergedIntoSpeakerID == nil }
        }

        /// A meeting that was interrupted has no end time; its last turn is the best measure of its length.
        var durationSeconds: TimeInterval {
            if let endedAt = self.endedAt { return max(0, endedAt.timeIntervalSince(self.startedAt)) }
            return self.turns.map(\.end.seconds).max() ?? 0
        }

        /// A meeting that is still being recorded or processed is not served.
        var isFinished: Bool {
            ["completed", "interrupted", "failed"].contains(self.state)
        }
    }

    struct SavedSummary: Equatable {
        var style: String
        var text: String
        var modelName: String?
        var generatedAt: Date?
    }

    struct Entry: Equatable {
        var meeting: Meeting
        var directory: URL
    }

    struct SearchHit: Equatable {
        var meeting: Meeting
        var line: String
    }

    enum ReadError: LocalizedError, Equatable {
        case accessOff
        case noMeetings
        case notFound(String)
        case ambiguous(String, Int)

        var errorDescription: String? {
            switch self {
            case .accessOff:
                return "FluidVoice is not sharing meetings with any agent yet. In FluidVoice, open FluidMeet settings > Integrations and add your agent."
            case .noMeetings:
                return "No finished meetings with a transcript were found."
            case let .notFound(reference):
                return "No meeting matches \"\(reference)\". Run `\(FluidServeMeetings.toolName) meet list` to see the ids."
            case let .ambiguous(reference, count):
                return "\"\(reference)\" matches \(count) meetings. Use more characters of the id."
            }
        }
    }

    static func defaultRoot(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("FluidVoice", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
    }

    /// Reads the switch the way the app itself sees it (including a value an administrator has forced),
    /// but through CFPreferences rather than `UserDefaults`, which would also honour a
    /// `-FluidServeMeetingAccessEnabled YES` argument and let a caller switch it on.
    /// This is a consent switch, not a lock: anything running as the user could read the files anyway.
    static func isAccessEnabled(bundleIdentifier: String) -> Bool {
        (CFPreferencesCopyAppValue(self.accessDefaultsKey as CFString, bundleIdentifier as CFString) as? Bool) ?? false
    }

    static let customSummaryPromptDefaultsKey = "MeetingSummaryCustomPrompt"

    /// The prompt in the app's custom-summary box, needed to tell whether a saved custom summary is still the current one.
    static func customSummaryPrompt(bundleIdentifier: String) -> String {
        (CFPreferencesCopyAppValue(self.customSummaryPromptDefaultsKey as CFString, bundleIdentifier as CFString) as? String) ?? ""
    }

    /// This Mac's time zone as the app sees it. A `TZ` variable in an agent's shell must not change
    /// which summaries count as current, so the zone is read from the system setting, not the environment.
    static func systemTimeZone(fileManager: FileManager = .default) -> TimeZone {
        if let target = try? fileManager.destinationOfSymbolicLink(atPath: "/etc/localtime"),
           let range = target.range(of: "/zoneinfo/"),
           let zone = TimeZone(identifier: String(target[range.upperBound...]))
        {
            return zone
        }
        return .current
    }

    // MARK: - Reading

    /// Finished meetings that have a transcript, newest first. Reads one small file per meeting and
    /// skips any it cannot decode instead of failing the whole listing.
    static func entries(root: URL, since: Date? = nil, fileManager: FileManager = .default) -> [Entry] {
        let directories = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [Entry] = []
        for directory in directories {
            let manifest = directory.appendingPathComponent("session.json", isDirectory: false)
            guard let data = try? Data(contentsOf: manifest, options: .mappedIfSafe),
                  let meeting = try? decoder.decode(Meeting.self, from: data),
                  meeting.isFinished, !meeting.turns.isEmpty
            else { continue }
            if let since, meeting.startedAt < since { continue }
            entries.append(Entry(meeting: meeting, directory: directory))
        }
        return entries.sorted { $0.meeting.startedAt > $1.meeting.startedAt }
    }

    /// `reference` is `latest`, a full id, or the first characters of one.
    static func resolve(_ reference: String, in entries: [Entry]) throws -> Entry {
        guard !entries.isEmpty else { throw ReadError.noMeetings }
        let wanted = reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if wanted.isEmpty || wanted == "latest" { return entries[0] }
        let matches = entries.filter { $0.meeting.id.uuidString.lowercased().hasPrefix(wanted) }
        switch matches.count {
        case 1: return matches[0]
        case 0: throw ReadError.notFound(reference)
        default: throw ReadError.ambiguous(reference, matches.count)
        }
    }

    /// Saved summaries the app itself would still show for this meeting: written by a known provider,
    /// for the transcript as it is now, and (for a custom summary) with the prompt as it is now.
    /// A summary from before an edit, a speaker rename or a prompt change is left out.
    static func savedSummaries(for entry: Entry, customPrompt: String = "", fileManager: FileManager = .default) -> [SavedSummary] {
        struct Stored: Decodable {
            var transcriptHash: String
            var transcriptHashVersion: Int?
            var text: String
            var promptHash: String?
            var providerID: String?
            var providerName: String?
            var modelName: String?
            var generatedAt: Date?
        }
        let prefix = "manual-summary-"
        let names = ((try? fileManager.contentsOfDirectory(atPath: entry.directory.path)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }
            .sorted()
        guard !names.isEmpty else { return [] }
        let legacyHash = self.fingerprint(self.summaryInput(for: entry.meeting))
        var contentSource = entry.meeting
        contentSource.title = ""
        let contentHash = self.fingerprint(self.summaryInput(for: contentSource))
        let customPromptHash = self.fingerprint(customPrompt.trimmingCharacters(in: .whitespacesAndNewlines))
        return names.compactMap { name in
            let style = String(name.dropFirst(prefix.count).dropLast(".json".count))
            guard let data = try? Data(contentsOf: entry.directory.appendingPathComponent(name, isDirectory: false)),
                  let stored = try? JSONDecoder().decode(Stored.self, from: data),
                  stored.providerID != nil,
                  stored.promptHash == (style == "custom" ? customPromptHash : nil),
                  !stored.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            let currentHash: String
            switch stored.transcriptHashVersion {
            case nil: currentHash = legacyHash
            case 2: currentHash = contentHash
            default: return nil
            }
            guard stored.transcriptHash == currentHash else { return nil }
            return SavedSummary(
                style: style,
                text: stored.text,
                modelName: stored.modelName ?? stored.providerName,
                generatedAt: stored.generatedAt
            )
        }
    }

    /// The exact text the app summarizes, rebuilt here only to recognise which saved summaries are current.
    /// It uses this Mac's time zone because the app does, whatever zone the listing is printed in.
    static func summaryInput(for meeting: Meeting, timeZone: TimeZone = FluidServeMeetings.systemTimeZone()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        let date = formatter.string(from: meeting.startedAt)
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let time = formatter.string(from: meeting.startedAt)
        let minutes = max(0, (meeting.endedAt ?? meeting.startedAt).timeIntervalSince(meeting.startedAt) / 60)
        return """
        Title: \(meeting.title)
        Date: \(date)
        Time: \(time)
        Duration: \(Int(minutes)) minutes
        Participants: \(meeting.activeSpeakers.map(\.displayName).joined(separator: ", "))
        ----------
        """ + "\n" + meeting.turns.map { "**\(self.speakerLabel(for: $0, in: meeting))**: \($0.text)" }.joined(separator: "\n")
    }

    static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Rendering

    /// Same label rule as the app's transcript: a turn the app could not pin on one person stays unknown.
    static func speakerLabel(for segment: Segment, in meeting: Meeting) -> String {
        if let state = segment.attributionState, state != "assigned" { return "Unknown speaker" }
        guard var id = segment.speakerID else { return "Unknown speaker" }
        var hops = 0
        while let target = meeting.speakers.first(where: { $0.id == id })?.mergedIntoSpeakerID, hops < meeting.speakers.count {
            id = target
            hops += 1
        }
        return meeting.activeSpeakers.first(where: { $0.id == id })?.displayName ?? "Unknown speaker"
    }

    static func timestampText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    static func line(for segment: Segment, in meeting: Meeting) -> String {
        "[\(self.timestampText(segment.start.seconds))] \(self.speakerLabel(for: segment, in: meeting)): \(segment.text)"
    }

    /// The transcript as the app exports it, optionally limited to turns that start inside a time range.
    static func transcript(for meeting: Meeting, from: TimeInterval? = nil, to: TimeInterval? = nil) -> String {
        meeting.turns
            .filter { segment in
                if let from, segment.start.seconds < from { return false }
                if let to, segment.start.seconds > to { return false }
                return true
            }
            .map { self.line(for: $0, in: meeting) }
            .joined(separator: "\n\n")
    }

    static func header(for entry: Entry, timeZone: TimeZone = .current) -> String {
        let meeting = entry.meeting
        let speakers = meeting.activeSpeakers.map(\.displayName).joined(separator: ", ")
        return """
        Title: \(meeting.title)
        Id: \(meeting.id.uuidString)
        Date: \(self.dateText(meeting.startedAt, timeZone: timeZone))
        Length: \(self.lengthText(meeting.durationSeconds))
        Speakers: \(speakers.isEmpty ? "unknown" : speakers)
        """
    }

    static func listing(
        _ entries: [Entry],
        customPrompt: String = "",
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default
    ) -> String {
        guard !entries.isEmpty else { return "No finished meetings with a transcript were found." }
        var rows = [["ID", "DATE", "LENGTH", "SPEAKERS", "TITLE", "SUMMARIES"]]
        for entry in entries {
            let meeting = entry.meeting
            let summaries = self.savedSummaries(for: entry, customPrompt: customPrompt, fileManager: fileManager).map(\.style)
            rows.append([
                String(meeting.id.uuidString.prefix(8)),
                self.dateText(meeting.startedAt, timeZone: timeZone),
                self.lengthText(meeting.durationSeconds),
                String(meeting.activeSpeakers.count),
                meeting.title,
                summaries.isEmpty ? "-" : summaries.joined(separator: ", "),
            ])
        }
        // Widths are counted in characters and cells are only ever widened, so an emoji or a long
        // value is never cut. The last column is left unpadded.
        let widths = (0..<5).map { column in rows.map { $0[column].count }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { index, cell in
                index < widths.count ? cell + String(repeating: " ", count: widths[index] - cell.count) : cell
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    /// Case-insensitive search through transcripts, newest meeting first, stopping at `limit` lines.
    static func search(_ query: String, in entries: [Entry], limit: Int) -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, limit > 0 else { return [] }
        var hits: [SearchHit] = []
        for entry in entries {
            for segment in entry.meeting.turns where segment.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                hits.append(SearchHit(meeting: entry.meeting, line: self.line(for: segment, in: entry.meeting)))
                if hits.count == limit { return hits }
            }
        }
        return hits
    }

    static func dateText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func lengthText(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes < 1 ? "<1 min" : "\(minutes) min"
    }

    // MARK: - Arguments

    /// `90`, `12:30` or `1:02:03` as seconds from the start of the meeting.
    static func seconds(fromClock text: String) -> TimeInterval? {
        let fields = text.split(separator: ":", omittingEmptySubsequences: false)
        let parts = fields.compactMap { Int($0) }.filter { $0 >= 0 }
        guard !parts.isEmpty, parts.count <= 3, parts.count == fields.count else { return nil }
        return TimeInterval(parts.reduce(0) { $0 * 60 + $1 })
    }

    /// `7d`, `24h` or `2026-10-01` as the earliest start time to include.
    static func sinceDate(from text: String, now: Date = Date(), timeZone: TimeZone = .current) -> Date? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let unit = value.last, let amount = Double(value.dropLast()), amount >= 0 {
            switch unit {
            case "d": return now.addingTimeInterval(-amount * 86_400)
            case "h": return now.addingTimeInterval(-amount * 3600)
            default: break
            }
        }
        // Four-digit year only: "26-1-1" would otherwise parse as the year 26 and filter nothing.
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.isLenient = false
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}
