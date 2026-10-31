@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class FluidServeTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    /// Stands in for the app's "meetings are shared" setting, so tests never touch the real one.
    private let sharing = SharingBox()

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("FluidServeTests-\(UUID().uuidString)", isDirectory: true)
        self.root = base.appendingPathComponent("Meetings", isDirectory: true)
        self.home = base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.home, withIntermediateDirectories: true)
        self.sharing.value = false
        self.sharing.otherAgents = false
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.root.deletingLastPathComponent())
    }

    // MARK: - Reader

    func testReaderPrintsTheSameTranscriptAsTheApp() throws {
        let session = self.session(title: "Weekly sync")
        try self.save(session)

        let entries = FluidServeMeetings.entries(root: self.root)
        XCTAssertEqual(entries.count, 1)
        let meeting = try XCTUnwrap(entries.first).meeting
        XCTAssertEqual(meeting.id, session.id)
        XCTAssertEqual(meeting.title, "Weekly sync")
        XCTAssertEqual(meeting.activeSpeakers.map(\.displayName), session.activeSpeakers.map(\.displayName))
        XCTAssertEqual(FluidServeMeetings.transcript(for: meeting), MeetingTranscriptExporter.text(for: session))
        XCTAssertFalse(FluidServeMeetings.transcript(for: meeting).contains("echo of the far side"))
        XCTAssertTrue(FluidServeMeetings.transcript(for: meeting).contains("[00:20] Priya: merged speaker keeps the name"))
        XCTAssertTrue(FluidServeMeetings.transcript(for: meeting).contains("[00:30] Unknown speaker: two people at once"))
    }

    func testMeetingsStillRecordingEmptyOrUnreadableAreNotServed() throws {
        var recording = self.session(title: "Still recording")
        recording.state = .recording
        recording.endedAt = nil
        try self.save(recording)
        var empty = self.session(title: "No words")
        empty.transcriptSegments = []
        try self.save(empty)
        let broken = self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: broken.appendingPathComponent("session.json"))
        try self.save(self.session(title: "Finished"))

        XCTAssertEqual(FluidServeMeetings.entries(root: self.root).map(\.meeting.title), ["Finished"])
    }

    func testNewestMeetingIsFirstAndSinceLeavesOlderOnesOut() throws {
        try self.save(self.session(title: "Old", startedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        try self.save(self.session(title: "New", startedAt: Date(timeIntervalSince1970: 1_700_500_000)))

        XCTAssertEqual(FluidServeMeetings.entries(root: self.root).map(\.meeting.title), ["New", "Old"])
        let since = Date(timeIntervalSince1970: 1_700_400_000)
        XCTAssertEqual(FluidServeMeetings.entries(root: self.root, since: since).map(\.meeting.title), ["New"])
    }

    func testArgumentParsing() {
        XCTAssertEqual(FluidServeMeetings.seconds(fromClock: "90"), 90)
        XCTAssertEqual(FluidServeMeetings.seconds(fromClock: "12:30"), 750)
        XCTAssertEqual(FluidServeMeetings.seconds(fromClock: "1:02:03"), 3723)
        XCTAssertNil(FluidServeMeetings.seconds(fromClock: "soon"))
        XCTAssertNil(FluidServeMeetings.seconds(fromClock: "1:2:3:4"))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(FluidServeMeetings.sinceDate(from: "7d", now: now), now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(FluidServeMeetings.sinceDate(from: "24h", now: now), now.addingTimeInterval(-86_400))
        XCTAssertNotNil(FluidServeMeetings.sinceDate(from: "2026-10-01", now: now))
        XCTAssertNil(FluidServeMeetings.sinceDate(from: "last week", now: now))
    }

    // MARK: - Command

    func testCommandStaysClosedUntilAccessIsOn() throws {
        try self.save(self.session(title: "Private planning"))

        for arguments in [["meet", "list"], ["meet", "show", "latest"], ["meet", "search", "merged"], ["meet", "summary", "latest"]] {
            let result = FluidServeCommand.run(arguments: arguments, root: self.root, accessEnabled: false)
            XCTAssertEqual(result.exitCode, 2, "\(arguments)")
            XCTAssertFalse(result.output.contains("Private planning"), "\(arguments)")
            XCTAssertFalse(result.output.contains("merged speaker"), "\(arguments)")
        }
        let status = FluidServeCommand.run(arguments: ["status"], root: self.root, accessEnabled: false)
        XCTAssertEqual(status.exitCode, 0)
        XCTAssertTrue(status.output.contains("Meeting access: off"))
        XCTAssertFalse(status.output.contains("Meetings available"))
    }

    func testAccessSwitchIsOffUntilTheAppSetsIt() throws {
        let suite = "FluidServeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(FluidServeMeetings.isAccessEnabled(bundleIdentifier: suite))
        defaults.set(true, forKey: FluidServeMeetings.accessDefaultsKey)
        XCTAssertTrue(FluidServeMeetings.isAccessEnabled(bundleIdentifier: suite))
    }

    func testCommandListsShowsSearchesAndReadsSavedSummaries() throws {
        let session = self.session(title: "Weekly sync")
        try self.save(session)
        try self.saveSummary("## Overview\nShort and clear.", style: "executive", for: session)
        let prefix = String(session.id.uuidString.prefix(8))

        let list = self.run("meet", "list")
        XCTAssertEqual(list.exitCode, 0)
        XCTAssertTrue(list.output.contains(prefix))
        XCTAssertTrue(list.output.contains("Weekly sync"))
        XCTAssertTrue(list.output.hasSuffix("executive"))

        let show = self.run("meet", "show", prefix)
        XCTAssertEqual(show.exitCode, 0)
        XCTAssertTrue(show.output.contains("Title: Weekly sync"))
        XCTAssertTrue(show.output.hasSuffix(MeetingTranscriptExporter.text(for: session)))
        XCTAssertEqual(self.run("meet", "show").output, show.output, "No id means the newest meeting")

        let range = self.run("meet", "show", "latest", "--from", "0:15", "--to", "0:25")
        XCTAssertTrue(range.output.contains("merged speaker keeps the name"))
        XCTAssertFalse(range.output.contains("first words"))
        XCTAssertFalse(range.output.contains("two people at once"))

        let search = self.run("meet", "search", "MERGED")
        XCTAssertEqual(search.exitCode, 0)
        XCTAssertTrue(search.output.contains("[00:20] Priya: merged speaker keeps the name"))
        XCTAssertEqual(self.run("meet", "search", "speaker", "keeps").output, search.output, "Unquoted words are one phrase")
        XCTAssertTrue(self.run("meet", "search", "zebra").output.contains("No transcript mentions"))

        let summary = self.run("meet", "summary", "latest")
        XCTAssertEqual(summary.exitCode, 0)
        XCTAssertTrue(summary.output.contains("Style: executive"))
        XCTAssertTrue(summary.output.contains("Written by: Qwen3.5 9B"))
        XCTAssertTrue(summary.output.hasSuffix("## Overview\nShort and clear."))
        XCTAssertEqual(self.run("meet", "summary", "latest", "--style", "actions").exitCode, 1)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(self.run("meet", "show", "latest", "--json").output.utf8)) as? [String: Any])
        XCTAssertEqual(json["title"] as? String, "Weekly sync")
        XCTAssertEqual((json["turns"] as? [[String: Any]])?.count, 3)
    }

    func testCommandExplainsBadInput() throws {
        try self.save(self.session(title: "Weekly sync"))
        XCTAssertEqual(self.run("meet", "show", "ffffffff").exitCode, 1)
        XCTAssertTrue(self.run("meet", "show", "ffffffff").output.contains("No meeting matches"))
        XCTAssertEqual(self.run("meet", "list", "--since", "whenever").exitCode, 1)
        XCTAssertEqual(self.run("meet", "list", "--limit", "0").exitCode, 1)
        XCTAssertEqual(self.run("meet", "erase", "latest").exitCode, 1)
        XCTAssertEqual(self.run("meet", "search").exitCode, 1)
        XCTAssertEqual(self.run("meet", "show", "latest", "--from", "0:30", "--to", "0:10").exitCode, 1, "A backwards range is a mistake, not an empty answer")
        XCTAssertEqual(self.run("meet", "list", "--since", "26-1-1").exitCode, 1, "A two-digit year must not quietly mean the year 26")
        XCTAssertEqual(self.run("meet", "search", "--force").exitCode, 1)
        XCTAssertEqual(self.run("meet", "search", "--", "--force").exitCode, 0, "-- lets a search begin with a dash")
        XCTAssertEqual(self.run("dictate").exitCode, 1)
        XCTAssertEqual(self.run().exitCode, 0)
    }

    func testASingleDashArgumentCannotSwitchAccessOn() throws {
        try self.save(self.session(title: "Private planning"))
        let sneaky = FluidServeCommand.run(
            arguments: ["meet", "list", "-\(FluidServeMeetings.accessDefaultsKey)", "YES"],
            root: self.root,
            accessEnabled: false
        )
        XCTAssertEqual(sneaky.exitCode, 2)
        XCTAssertFalse(sneaky.output.contains("Private planning"))
        XCTAssertEqual(self.run("meet", "list", "-\(FluidServeMeetings.accessDefaultsKey)", "YES").exitCode, 1, "Even with access on, a stray dash option is an error")
    }

    func testOnlySummariesTheAppWouldStillShowAreServed() throws {
        var session = self.session(title: "Weekly sync")
        try self.save(session)
        let entry = try XCTUnwrap(FluidServeMeetings.entries(root: self.root).first)
        XCTAssertEqual(FluidServeMeetings.summaryInput(for: entry.meeting), MeetingSummaryInput.transcript(for: session), "Same text the app summarizes, so the same fingerprint")

        try self.saveSummary("Current.", style: "executive", for: session)
        try self.saveSummary("From a withdrawn model.", style: "topics", for: session, providerID: nil)
        try self.saveSummary("For an older transcript.", style: "actions", for: session, transcriptHash: "stale")
        XCTAssertEqual(FluidServeMeetings.savedSummaries(for: entry).map(\.style), ["executive"])

        // A custom summary counts only while the prompt box still holds the prompt it was written with.
        try self.saveSummary("Risks only.", style: "custom", for: session, promptHash: MeetingSummaryInput.fingerprint("Focus on risks"))
        try self.saveSummary("Carries a prompt it should not.", style: "detailed", for: session, promptHash: MeetingSummaryInput.fingerprint("Focus on risks"))
        XCTAssertEqual(FluidServeMeetings.savedSummaries(for: entry, customPrompt: "  Focus on risks\n").map(\.style), ["custom", "executive"])
        XCTAssertEqual(FluidServeMeetings.savedSummaries(for: entry, customPrompt: "Focus on dates").map(\.style), ["executive"])
        XCTAssertEqual(FluidServeMeetings.savedSummaries(for: entry).map(\.style), ["executive"])

        // Renaming a speaker changes the transcript, so the app hides the summary and so must the command.
        session.speakers[0].displayName = "Priya R."
        try self.save(session)
        let renamed = try XCTUnwrap(FluidServeMeetings.entries(root: self.root).first)
        XCTAssertEqual(FluidServeMeetings.savedSummaries(for: renamed), [])
        XCTAssertEqual(self.run("meet", "summary", "latest").exitCode, 1)
        XCTAssertFalse(self.run("meet", "summary", "latest").output.contains("Current."))
    }

    func testListKeepsLongAndEmojiTitlesWholeAndMeasuresAnInterruptedMeeting() throws {
        var interrupted = self.session(title: "Sync 🚀🚀 with a much longer title than the heading")
        interrupted.state = .interrupted
        interrupted.endedAt = nil
        try self.save(interrupted)

        let list = self.run("meet", "list")
        XCTAssertTrue(list.output.contains("Sync 🚀🚀 with a much longer title than the heading"))
        let row = try XCTUnwrap(list.output.split(separator: "\n").last)
        XCTAssertTrue(row.contains("  1 min  "), "With no end time the length comes from the last turn (35 s), not from zero or from now: \(row)")
        XCTAssertEqual(try XCTUnwrap(FluidServeMeetings.entries(root: self.root).first).meeting.durationSeconds, 35)
    }

    func testVersionedSummariesSurviveTitleChangesButNotTranscriptChanges() throws {
        var session = self.session(title: "Weekly sync")
        try self.save(session)
        let hash = MeetingSummaryInput.contentFingerprint(for: session)
        try self.saveSummary("Detailed recap.", style: "detailed", for: session, transcriptHash: hash, transcriptHashVersion: 2)
        try self.saveSummary("Custom recap.", style: "custom", for: session, transcriptHash: hash, promptHash: MeetingSummaryInput.fingerprint("Focus on risks"), transcriptHashVersion: 2)
        try self.saveSummary("Unknown format.", style: "topics", for: session, transcriptHash: hash, transcriptHashVersion: 99)
        try self.saveSummary("Legacy recap.", style: "executive", for: session)
        let original = try XCTUnwrap(FluidServeMeetings.entries(root: self.root).first)
        XCTAssertEqual(FluidServeMeetings.savedSummaries(for: original, customPrompt: "Focus on risks").map(\.style), ["custom", "detailed", "executive"])

        session.title = "Renamed weekly sync"
        try self.save(session)
        let renamed = try XCTUnwrap(FluidServeMeetings.entries(root: self.root).first)
        XCTAssertEqual(FluidServeMeetings.savedSummaries(for: renamed, customPrompt: "Focus on risks").map(\.style), ["custom", "detailed"])
        XCTAssertEqual(FluidServeMeetings.savedSummaries(for: renamed, customPrompt: "New prompt").map(\.style), ["detailed"])
        XCTAssertTrue(self.run("meet", "summary", "latest", "--style", "detailed").output.hasSuffix("Detailed recap."))

        session.transcriptSegments[0].text = "Corrected transcript"
        try self.save(session)
        let corrected = try XCTUnwrap(FluidServeMeetings.entries(root: self.root).first)
        XCTAssertTrue(FluidServeMeetings.savedSummaries(for: corrected, customPrompt: "Focus on risks").isEmpty)
    }

    func testCommandNeverChangesTheMeetingsFolder() throws {
        let session = self.session(title: "Weekly sync")
        try self.save(session)
        let before = try self.snapshot()

        _ = self.run("meet", "list")
        _ = self.run("meet", "show", "latest", "--json")
        _ = self.run("meet", "search", "merged")
        _ = self.run("meet", "summary", "latest")
        _ = self.run("status")

        XCTAssertEqual(try self.snapshot(), before)
    }

    // MARK: - Skill

    func testSkillIsAddedUpdatedAndRemovedOnlyWhereItBelongs() throws {
        let agent = FluidServeSkillInstaller.Agent.claudeCode
        let tool = "/Applications/FluidVoice.app/Contents/Helpers/fv-serve"
        XCTAssertEqual(FluidServeSkillInstaller.status(for: agent, toolPath: tool, home: self.home), .agentNotFound)

        try FileManager.default.createDirectory(at: self.home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        XCTAssertEqual(FluidServeSkillInstaller.status(for: agent, toolPath: tool, home: self.home), .notInstalled)
        XCTAssertEqual(FluidServeSkillInstaller.status(for: .codex, toolPath: tool, home: self.home), .agentNotFound)

        try FluidServeSkillInstaller.install(for: agent, toolPath: tool, home: self.home)
        let file = FluidServeSkillInstaller.skillFile(for: agent, home: self.home)
        XCTAssertEqual(file.path, self.home.path + "/.claude/skills/fluidmeet/SKILL.md")
        let written = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(written.hasPrefix("---\nname: fluidmeet\ndescription: \""))
        let description = try XCTUnwrap(written.split(separator: "\n").dropFirst(2).first)
        XCTAssertTrue(description.hasSuffix("\""), "The description is one quoted line, so a colon inside it cannot break the header")
        XCTAssertEqual(description.filter { $0 == "\"" }.count, 2)
        XCTAssertEqual(written.split(separator: "\n", omittingEmptySubsequences: false)[3], "---")
        XCTAssertTrue(written.contains("'\(tool)' meet list"))
        XCTAssertEqual(FluidServeSkillInstaller.status(for: agent, toolPath: tool, home: self.home), .installed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.home.appendingPathComponent(".codex").path), "Adding one tool's skill must not create the other tool's folder")

        let moved = "/Users/someone/Apps/FluidVoice.app/Contents/Helpers/fv-serve"
        XCTAssertEqual(FluidServeSkillInstaller.status(for: agent, toolPath: moved, home: self.home), .needsUpdate)
        try FluidServeSkillInstaller.install(for: agent, toolPath: moved, home: self.home)
        XCTAssertEqual(FluidServeSkillInstaller.status(for: agent, toolPath: moved, home: self.home), .installed)

        try FluidServeSkillInstaller.remove(for: agent, home: self.home)
        XCTAssertEqual(FluidServeSkillInstaller.status(for: agent, toolPath: moved, home: self.home), .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        XCTAssertNoThrow(try FluidServeSkillInstaller.remove(for: agent, home: self.home), "Removing twice is harmless")
    }

    func testASkillInstalledByAnEarlierBuildIsStillOursAndJustNeedsUpdating() throws {
        let file = FluidServeSkillInstaller.skillFile(for: .claudeCode, home: self.home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let earlier = "---\nname: fluidmeet\n---\n\(FluidServeSkill.earlierMarkers[0])\n\nOld text.\n"
        try Data(earlier.utf8).write(to: file)

        XCTAssertEqual(FluidServeSkillInstaller.status(for: .claudeCode, toolPath: "/x/fv-serve", home: self.home), .needsUpdate)
        try FluidServeSkillInstaller.install(for: .claudeCode, toolPath: "/x/fv-serve", home: self.home)
        XCTAssertEqual(FluidServeSkillInstaller.status(for: .claudeCode, toolPath: "/x/fv-serve", home: self.home), .installed)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains(FluidServeSkill.marker))
    }

    func testSomeoneElsesSkillOfTheSameNameIsLeftAlone() throws {
        let agent = FluidServeSkillInstaller.Agent.codex
        let file = FluidServeSkillInstaller.skillFile(for: agent, home: self.home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let theirs = "---\nname: fluidmeet\ndescription: mine\n---\nHand written.\n"
        try Data(theirs.utf8).write(to: file)

        XCTAssertEqual(FluidServeSkillInstaller.status(for: agent, toolPath: "/x/fv-serve", home: self.home), .foreign)
        XCTAssertThrowsError(try FluidServeSkillInstaller.install(for: agent, toolPath: "/x/fv-serve", home: self.home))
        XCTAssertThrowsError(try FluidServeSkillInstaller.remove(for: agent, home: self.home))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), theirs)
    }

    func testSkillCommandPrintsExactlyWhatTheAppInstallsEvenWithAccessOff() throws {
        let tool = "/Applications/FluidVoice.app/Contents/Helpers/fv-serve"
        try self.save(self.session(title: "Private planning"))
        let printed = FluidServeCommand.run(arguments: ["skill"], root: self.root, accessEnabled: false, toolPath: tool)

        XCTAssertEqual(printed.exitCode, 0)
        XCTAssertEqual(printed.output + "\n", FluidServeSkillInstaller.skillDocument(toolPath: tool), "Saved to a file, it is the same skill the buttons install")
        XCTAssertFalse(printed.output.contains("Private planning"), "The skill text carries no meeting data")

        // Saved by an agent into a skills folder, the app recognises it as its own and up to date.
        let file = FluidServeSkillInstaller.skillFile(for: .claudeCode, home: self.home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((printed.output + "\n").utf8).write(to: file)
        XCTAssertEqual(FluidServeSkillInstaller.status(for: .claudeCode, toolPath: tool, home: self.home), .installed)
    }

    func testCopyInstructionsGivesAnAgentTheCommandAndSaysCopiedOnlyIfItWas() {
        let tool = URL(fileURLWithPath: "/Applications/Fluid Voice.app/Contents/Helpers/fv-serve")
        var clipboard: String?
        let model = self.model(tool: tool, check: { _ in .working(meetings: 0) }, copy: {
            clipboard = $0
            return true
        })
        XCTAssertFalse(model.copiedAgentInstructions)
        model.copyAgentInstructions()
        XCTAssertTrue(model.copiedAgentInstructions)
        XCTAssertNil(model.issue)
        XCTAssertTrue(self.sharing.value, "Copying instructions for another agent starts sharing too")
        XCTAssertEqual(clipboard, FluidServeSkill.agentInstructions(toolPath: tool.path))
        XCTAssertEqual(clipboard?.contains("'/Applications/Fluid Voice.app/Contents/Helpers/fv-serve' skill"), true, "The path is quoted, so a space in it still works")
        XCTAssertEqual(clipboard?.contains("fluidmeet"), true)

        let refused = self.model(tool: tool, check: { _ in .working(meetings: 0) }, copy: { _ in false })
        self.sharing.value = false
        refused.copyAgentInstructions()
        XCTAssertFalse(refused.copiedAgentInstructions)
        XCTAssertNotNil(refused.issue)
        XCTAssertFalse(self.sharing.value, "A failed copy must not start sharing")

        let missing = self.model(tool: nil, check: { _ in .working(meetings: 0) }, copy: { _ in true })
        missing.copyAgentInstructions()
        XCTAssertFalse(missing.copiedAgentInstructions, "Nothing to copy when this build has no fv-serve")
    }

    func testAnOddlyNamedAppFolderCannotChangeWhatThePastedCommandRuns() {
        XCTAssertEqual(FluidServeSkill.shellQuoted("/Applications/FluidVoice.app/x"), "'/Applications/FluidVoice.app/x'")
        let nasty = "/Apps/It's \"mine\" $(touch /tmp/x) `id`/FluidVoice.app/Contents/Helpers/fv-serve"
        let quoted = FluidServeSkill.shellQuoted(nasty)
        XCTAssertEqual(quoted, "'/Apps/It'\\''s \"mine\" $(touch /tmp/x) `id`/FluidVoice.app/Contents/Helpers/fv-serve'")
        // Every single quote in the path is closed, escaped and reopened, so nothing sits outside quotes.
        XCTAssertEqual(quoted.components(separatedBy: "'\\''").joined().filter { $0 == "'" }.count, 2)
        XCTAssertTrue(FluidServeSkill.agentInstructions(toolPath: nasty).contains(quoted + " skill"))
        XCTAssertTrue(FluidServeSkill.document(toolPath: nasty).contains(quoted + " meet list"))
    }

    func testOneRowsSuccessDoesNotWipeAnotherRowsError() async throws {
        try FileManager.default.createDirectory(at: self.home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let theirs = FluidServeSkillInstaller.skillFile(for: .codex, home: self.home)
        try FileManager.default.createDirectory(at: theirs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("---\nname: fluidmeet\n---\nHand written.\n".utf8).write(to: theirs)
        let model = self.model(tool: URL(fileURLWithPath: "/x/fv-serve"), check: { _ in .working(meetings: 0) }, copy: { _ in true })
        await model.refresh()

        await model.install(.codex)
        let problem = try XCTUnwrap(model.issue)
        await model.install(.claudeCode)
        XCTAssertEqual(model.notices[.claudeCode], .added)
        XCTAssertEqual(model.issue, problem, "Claude Code succeeding says nothing about Codex")
        model.copyAgentInstructions()
        XCTAssertEqual(model.issue, problem)
    }

    func testCodexLinkOpensANewChatWithThePromptTypedIn() throws {
        let url = try XCTUnwrap(FluidServeSkillInstaller.codexNewChatURL(prompt: "List my meetings & notes?"))
        XCTAssertEqual(url.scheme, "codex")
        XCTAssertEqual(url.host, "threads")
        XCTAssertEqual(url.path, "/new")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "prompt" }?.value, "List my meetings & notes?", "The prompt survives encoding intact")
        XCTAssertEqual(items.first { $0.name == "mode" }?.value, "codex")
        XCTAssertEqual(url.absoluteString.components(separatedBy: "&").count, 2, "An ampersand in the prompt must not start a new parameter")
        XCTAssertTrue(FluidServeSkillInstaller.starterPrompt.contains(FluidServeSkillInstaller.skillName))
    }

    // MARK: - Settings feedback

    func testPressingAddConfirmsOnlyOnceTheFileIsThereAndRemoveSaysRemoved() async throws {
        try FileManager.default.createDirectory(at: self.home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let tool = URL(fileURLWithPath: "/Applications/FluidVoice.app/Contents/Helpers/fv-serve")
        let model = self.model(tool: tool, check: { _ in .working(meetings: 3) })
        let file = FluidServeSkillInstaller.skillFile(for: .claudeCode, home: self.home)

        await model.refresh()
        XCTAssertEqual(model.statuses[.claudeCode], .notInstalled)
        XCTAssertEqual(model.statuses[.codex], .agentNotFound)
        XCTAssertNil(model.check, "Nothing is shared, so the command is not even run")
        XCTAssertFalse(self.sharing.value)
        XCTAssertNil(model.notices[.claudeCode])

        await model.install(.claudeCode)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(model.statuses[.claudeCode], .installed)
        XCTAssertEqual(model.notices[.claudeCode], .added)
        XCTAssertNil(model.issue)
        XCTAssertNil(model.notices[.codex], "Adding one tool's skill says nothing about the other")
        XCTAssertTrue(self.sharing.value, "Adding an agent is what starts sharing; there is no separate switch")
        XCTAssertEqual(model.check, .working(meetings: 3))

        await model.remove(.claudeCode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(model.statuses[.claudeCode], .notInstalled)
        XCTAssertEqual(model.notices[.claudeCode], .removed)
        XCTAssertFalse(self.sharing.value, "Removing the last skill stops sharing")
        XCTAssertNil(model.check)
    }

    func testAnAgentSetUpFromCopiedInstructionsKeepsAccessUntilTheUserStopsIt() async throws {
        try FileManager.default.createDirectory(at: self.home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let model = self.model(tool: URL(fileURLWithPath: "/x/fv-serve"))
        await model.install(.claudeCode)
        model.copyAgentInstructions()
        XCTAssertTrue(model.otherAgentsShared)
        XCTAssertFalse(
            model.sharedOnlyWithOtherAgents,
            "Access is one switch: with a skill installed, stopping other agents would stop nothing, so it is not offered"
        )

        // Removing the last skill FluidVoice can see must not cut off the agent it cannot see.
        await model.remove(.claudeCode)
        XCTAssertEqual(model.statuses[.claudeCode], .notInstalled)
        XCTAssertTrue(self.sharing.value)
        XCTAssertTrue(model.otherAgentsShared)
        XCTAssertTrue(model.sharedOnlyWithOtherAgents, "Now stopping them turns access off, so it is offered")

        await model.stopSharingWithOtherAgents()
        XCTAssertFalse(model.otherAgentsShared)
        XCTAssertFalse(self.sharing.otherAgents)
        XCTAssertFalse(self.sharing.value, "With no skill left and other agents stopped, nothing is shared")
        XCTAssertNil(model.check)
    }

    func testStoppingOtherAgentsLeavesSharingOnForAnAgentThatStillHasTheSkill() async throws {
        try FileManager.default.createDirectory(at: self.home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let model = self.model(tool: URL(fileURLWithPath: "/x/fv-serve"))
        await model.install(.claudeCode)
        model.copyAgentInstructions()

        await model.stopSharingWithOtherAgents()
        XCTAssertFalse(model.otherAgentsShared)
        XCTAssertTrue(self.sharing.value, "Claude Code still has the skill")
    }

    func testSharingLeftOnByAnEarlierBuildWithNoSkillsShowsAsOtherAgentsSoItCanBeStopped() async {
        self.sharing.value = true
        let model = self.model(tool: URL(fileURLWithPath: "/x/fv-serve"))
        XCTAssertFalse(model.otherAgentsShared)

        await model.refresh()
        XCTAssertTrue(model.otherAgentsShared)
        XCTAssertTrue(self.sharing.otherAgents)

        await model.stopSharingWithOtherAgents()
        XCTAssertFalse(self.sharing.value)
    }

    func testASlowRemoveCannotSwitchSharingOffAfterAnotherAgentWasAdded() async throws {
        for folder in [".claude", ".codex"] {
            try FileManager.default.createDirectory(at: self.home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let tool = URL(fileURLWithPath: "/x/fv-serve")
        try FluidServeSkillInstaller.install(for: .claudeCode, toolPath: tool.path, home: self.home)
        self.sharing.value = true
        let gate = FirstCallGate()
        let model = self.model(tool: tool, check: { _ in
            gate.holdFirstCall()
            return .working(meetings: 0)
        })

        // The remove has read "no skill anywhere" and is stuck waiting on the meeting reader.
        let remove = Task { await model.remove(.claudeCode) }
        while !gate.firstCallIsWaiting {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let add = Task { await model.install(.codex) }
        try await Task.sleep(nanoseconds: 200_000_000)
        gate.release()
        await remove.value
        await add.value

        XCTAssertEqual(model.statuses[.codex], .installed)
        XCTAssertTrue(self.sharing.value, "Codex has the skill, so meetings stay shared")
        XCTAssertFalse(model.otherAgentsShared, "A remove must not be read as another agent being set up")
        XCTAssertNotNil(model.check)
    }

    func testSharingStaysOnWhileAnyAgentStillHasTheSkill() async throws {
        for folder in [".claude", ".codex"] {
            try FileManager.default.createDirectory(at: self.home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let model = self.model(tool: URL(fileURLWithPath: "/x/fv-serve"))
        await model.install(.claudeCode)
        await model.install(.codex)
        XCTAssertTrue(self.sharing.value)

        await model.remove(.claudeCode)
        XCTAssertTrue(self.sharing.value, "Codex still has the skill")
        XCTAssertEqual(model.statuses[.codex], .installed)

        await model.remove(.codex)
        XCTAssertFalse(self.sharing.value)
    }

    func testAnAddThatCannotHappenIsReportedAndNotConfirmed() async throws {
        let file = FluidServeSkillInstaller.skillFile(for: .codex, home: self.home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let theirs = "---\nname: fluidmeet\ndescription: mine\n---\nHand written.\n"
        try Data(theirs.utf8).write(to: file)
        let model = self.model(tool: URL(fileURLWithPath: "/x/fv-serve"), check: { _ in .working(meetings: 0) })

        await model.refresh()
        XCTAssertEqual(model.statuses[.codex], .foreign)
        await model.install(.codex)

        XCTAssertEqual(model.statuses[.codex], .foreign)
        XCTAssertNil(model.notices[.codex])
        XCTAssertNotNil(model.issue)
        XCTAssertFalse(self.sharing.value, "A failed add must not start sharing")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), theirs)
    }

    func testASkillFromAMovedAppIsReportedAsUpdatedNotAdded() async throws {
        try FluidServeSkillInstaller.install(for: .claudeCode, toolPath: "/Old/FluidVoice.app/Contents/Helpers/fv-serve", home: self.home)
        let model = self.model(tool: URL(fileURLWithPath: "/New/FluidVoice.app/Contents/Helpers/fv-serve"), check: { _ in .working(meetings: 1) })

        await model.refresh()
        XCTAssertEqual(model.statuses[.claudeCode], .needsUpdate)
        await model.install(.claudeCode)

        XCTAssertEqual(model.statuses[.claudeCode], .installed)
        XCTAssertEqual(model.notices[.claudeCode], .updated)
    }

    func testASlowCheckThatFinishesLateDoesNotOverwriteANewerAnswer() async throws {
        try FileManager.default.createDirectory(at: self.home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let tool = URL(fileURLWithPath: "/Applications/FluidVoice.app/Contents/Helpers/fv-serve")
        let gate = FirstCallGate()
        let model = self.model(tool: tool, check: { _ in
            gate.holdFirstCall()
            return .working(meetings: 2)
        })

        // The first refresh reads "not added", then waits inside the check.
        self.sharing.value = true
        let slow = Task { await model.refresh() }
        while !gate.firstCallIsWaiting {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        // Meanwhile the skill is added and a second refresh completes.
        await model.install(.claudeCode)
        XCTAssertEqual(model.statuses[.claudeCode], .installed)
        XCTAssertEqual(model.notices[.claudeCode], .added)

        gate.release()
        _ = await slow.value
        XCTAssertEqual(model.statuses[.claudeCode], .installed, "The late, older answer must be dropped")
        XCTAssertFalse(model.isChecking)
    }

    func testTheCommandIsNotRunWhileAccessIsOff() async {
        let calls = CallCounter()
        let model = self.model(tool: URL(fileURLWithPath: "/x/fv-serve"), check: { _ in
            calls.increment()
            return .working(meetings: 9)
        })

        await model.refresh()
        XCTAssertNil(model.check)
        XCTAssertEqual(calls.value, 0)

        self.sharing.value = true
        await model.refresh()
        XCTAssertEqual(model.check, .working(meetings: 9))
        XCTAssertEqual(calls.value, 1, "One run per refresh; nothing polls")
    }

    func testEachStateHasItsOwnWordAndNeverReadsLikeAButton() {
        let statuses: [FluidServeSkillInstaller.Status?] = [nil, .agentNotFound, .notInstalled, .installed, .needsUpdate, .foreign]
        let titles = statuses.map { MeetingAgentIntegrations.state(for: $0).title }
        XCTAssertEqual(Set(titles).count, titles.count)
        XCTAssertEqual(MeetingAgentIntegrations.state(for: .installed).title, "Skill added")
        XCTAssertEqual(MeetingAgentIntegrations.state(for: .notInstalled).title, "Not added")
        for title in titles {
            XCTAssertFalse(title.hasPrefix("Remove"), title)
            XCTAssertFalse(title.hasPrefix("Add "), title)
        }
    }

    func testStatusAnswersInAFormTheAppCanRead() throws {
        try self.save(self.session(title: "Weekly sync"))
        let on = FluidServeCommand.run(arguments: ["status", "--json"], root: self.root, accessEnabled: true)
        XCTAssertEqual(on.exitCode, 0)
        XCTAssertEqual(FluidServeSelfCheck.outcome(fromStatusJSON: Data(on.output.utf8)), .working(meetings: 1))
        let off = FluidServeCommand.run(arguments: ["status", "--json"], root: self.root, accessEnabled: false)
        XCTAssertEqual(FluidServeSelfCheck.outcome(fromStatusJSON: Data(off.output.utf8)), .accessOff)
        XCTAssertFalse(off.output.contains("Weekly sync"))
        guard case .failed = FluidServeSelfCheck.outcome(fromStatusJSON: Data("not json".utf8)) else {
            return XCTFail("An unreadable answer must not count as working")
        }
    }

    /// End to end: the real `fv-serve` inside this app is started as its own process and must obey
    /// the same switch the settings page writes.
    func testTheBundledCommandReallyRunsAndObeysTheSwitch() throws {
        let tool = try XCTUnwrap(FluidServeSkillInstaller.bundledToolURL(), "The app under test must contain fv-serve in Contents/Helpers")
        let key = FluidServeMeetings.accessDefaultsKey
        let before = UserDefaults.standard.object(forKey: key)
        defer {
            if let before { UserDefaults.standard.set(before, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        }

        UserDefaults.standard.set(false, forKey: key)
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        XCTAssertEqual(FluidServeSelfCheck.run(tool: tool), .accessOff)
        let sneaky = try self.output(of: tool, ["status", "-\(key)", "YES"])
        XCTAssertTrue(sneaky.contains("Meeting access: off"), "A defaults-style argument must not switch access on: \(sneaky)")

        UserDefaults.standard.set(true, forKey: key)
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        guard case .working = FluidServeSelfCheck.run(tool: tool) else {
            return XCTFail("With the switch on, the bundled command must answer: \(FluidServeSelfCheck.run(tool: tool))")
        }

        // The real program reports its own real location, which is what a pasted command must contain.
        let printed = try self.output(of: tool, ["skill"])
        XCTAssertEqual(printed, FluidServeSkillInstaller.skillDocument(toolPath: tool.resolvingSymlinksInPath().path))

        guard case .failed = FluidServeSelfCheck.run(tool: URL(fileURLWithPath: "/nonexistent/fv-serve")) else {
            return XCTFail("A missing command must be reported as a failure")
        }
    }

    // MARK: - Fixtures

    private final class SharingBox {
        var value = false
        var otherAgents = false
    }

    private func model(
        tool: URL?,
        check: @escaping @Sendable (URL) -> FluidServeSelfCheck.Outcome = { _ in .working(meetings: 0) },
        copy: @escaping (String) -> Bool = { _ in true }
    ) -> FluidServeSettingsModel {
        let sharing = self.sharing
        return FluidServeSettingsModel(
            home: self.home,
            toolURL: { tool },
            selfCheck: check,
            copyToClipboard: copy,
            isSharing: { sharing.value },
            setSharing: { sharing.value = $0 },
            isOtherAgentsShared: { sharing.otherAgents },
            setOtherAgentsShared: { sharing.otherAgents = $0 }
        )
    }

    /// Holds the first caller until released; later callers pass straight through.
    private final class FirstCallGate: @unchecked Sendable {
        private let lock = NSLock()
        private let released = DispatchSemaphore(value: 0)
        private var calls = 0
        private var waiting = false

        var firstCallIsWaiting: Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.waiting
        }

        func holdFirstCall() {
            self.lock.lock()
            self.calls += 1
            let isFirst = self.calls == 1
            if isFirst { self.waiting = true }
            self.lock.unlock()
            if isFirst { self.released.wait() }
        }

        func release() { self.released.signal() }
    }

    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.count
        }

        func increment() {
            self.lock.lock()
            self.count += 1
            self.lock.unlock()
        }
    }

    private func run(_ arguments: String...) -> FluidServeCommand.Result {
        FluidServeCommand.run(
            arguments: arguments,
            root: self.root,
            accessEnabled: true,
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current
        )
    }

    /// Writes a summary the way the app does. By default it is one the app would still show.
    private func saveSummary(
        _ text: String,
        style: String,
        for session: MeetingSession,
        providerID: String? = "on-device",
        transcriptHash: String? = nil,
        promptHash: String? = nil,
        transcriptHashVersion: Int? = nil
    ) throws {
        let saved = MeetingSummaryController.SavedSummary(
            transcriptHash: transcriptHash ?? MeetingSummaryInput.fingerprint(MeetingSummaryInput.transcript(for: session)),
            modelID: "model",
            text: text,
            providerID: providerID,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_500),
            promptHash: promptHash,
            modelName: "Qwen3.5 9B",
            transcriptHashVersion: transcriptHashVersion
        )
        try JSONEncoder().encode(saved).write(to: self.directory(for: session).appendingPathComponent("manual-summary-\(style).json"))
    }

    private func output(of tool: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = tool
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func directory(for session: MeetingSession) -> URL {
        self.root.appendingPathComponent(session.id.uuidString, isDirectory: true)
    }

    /// Writes the session the way the app's store does: ISO 8601 dates in `<id>/session.json`.
    private func save(_ session: MeetingSession) throws {
        let directory = self.directory(for: session)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: directory.appendingPathComponent("session.json"))
    }

    private func snapshot() throws -> [String: Date] {
        var result: [String: Date] = [:]
        let enumerator = FileManager.default.enumerator(at: self.root, includingPropertiesForKeys: [.contentModificationDateKey])
        while let url = enumerator?.nextObject() as? URL {
            result[url.path] = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return result
    }

    private func mediaTime(_ seconds: TimeInterval) -> MeetingMediaTime {
        MeetingMediaTime(value: Int64(seconds * 1000), timescale: 1000)
    }

    /// Three kept turns and one echo. One speaker was merged into Priya, and one turn has two voices.
    private func session(title: String, startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> MeetingSession {
        var session = MeetingSession(
            configuration: MeetingCaptureConfiguration(
                mode: .inRoom,
                title: title,
                microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic", displayName: "Mic")
            ),
            startedAt: startedAt,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 1,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: self.mediaTime(0)
            )
        )
        let trackID = UUID()
        let priya = UUID()
        let marcus = UUID()
        let mergedAway = UUID()
        func speaker(_ id: UUID, _ name: String, mergedInto: UUID? = nil) -> MeetingSessionSpeaker {
            var speaker = MeetingSessionSpeaker(
                id: id,
                displayName: name,
                diarizationClusterID: nil,
                trackKind: .microphone,
                isLocalUser: false,
                identityCandidates: []
            )
            speaker.mergedIntoSpeakerID = mergedInto
            return speaker
        }
        func turn(_ start: TimeInterval, _ speakerID: UUID?, _ text: String) -> MeetingTranscriptSegment {
            MeetingTranscriptSegment(
                id: UUID(),
                start: self.mediaTime(start),
                end: self.mediaTime(start + 5),
                sourceTrackID: trackID,
                speakerID: speakerID,
                text: text,
                revision: 0,
                status: .final,
                overlap: .none,
                completeness: .complete
            )
        }
        session.speakers = [speaker(priya, "Priya"), speaker(marcus, "Marcus"), speaker(mergedAway, "Speaker 3", mergedInto: priya)]
        var echo = turn(12, marcus, "echo of the far side")
        echo.isLikelyEcho = true
        var overlapping = turn(30, nil, "two people at once")
        overlapping.attributionState = .overlappingSpeakers
        var assigned = turn(20, mergedAway, "merged speaker keeps the name")
        assigned.attributionState = .assigned
        session.transcriptSegments = [overlapping, turn(10, marcus, "first words"), echo, assigned]
        session.state = .completed
        session.endedAt = startedAt.addingTimeInterval(600)
        return session
    }
}
