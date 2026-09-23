import Foundation

@main
struct ReleaseHighlightsPolicyTests {
    static func main() throws {
        let owner = UUID()
        let other = UUID()
        var policy = ReleaseHighlightsPolicy()
        for version in ["1.6.9", "1.6.11", "1.6.100", "", "unknown"] {
            precondition(policy.request(owner: owner, version: version, release: "1.6.10", eligible: true) == nil)
        }
        precondition(policy.request(owner: owner, version: "1.6.10-beta.7", release: "1.6.10", eligible: false) == nil)
        let first = try require(policy.request(owner: owner, version: "1.6.10-beta.7", release: "1.6.10", eligible: true))
        precondition(policy.seenVersions.isEmpty, "Opening alone must not acknowledge an interrupted popup")
        precondition(policy.request(owner: other, version: first.version, release: "1.6.10", eligible: true) == nil, "One presentation across windows")
        precondition(policy.beginDismiss(id: first.id, acknowledge: true))
        precondition(!policy.beginDismiss(id: first.id, acknowledge: true), "A double click cannot replace the first destination")
        precondition(policy.request(owner: owner, version: first.version, release: "1.6.10", eligible: true, manual: true) == nil, "Dismissal keeps ownership until completion")
        precondition(policy.finishDismiss(id: UUID(), eligible: true) == nil)
        precondition(policy.session?.id == first.id, "Stale callbacks cannot release another sheet")
        precondition(policy.finishDismiss(id: first.id, eligible: true) == true)
        precondition(policy.seenVersions == [first.version])
        precondition(policy.request(owner: owner, version: first.version, release: "1.6.10", eligible: true) == nil)

        // A Help click during refinement survives ineligibility and replays an acknowledged version.
        policy.requestManual(owner: owner)
        precondition(policy.request(owner: owner, version: first.version, release: "1.6.10", eligible: false) == nil)
        let deferred = try require(policy.request(owner: owner, version: first.version, release: "1.6.10", eligible: true))
        policy.requestManual(owner: owner)
        precondition(policy.finishDismiss(id: deferred.id, eligible: true) == true)
        precondition(policy.request(owner: owner, version: first.version, release: "1.6.10", eligible: true) == nil, "An open-sheet request must not reopen after dismissal")
        policy.requestManual(owner: owner)
        policy.abandon(owner: owner)
        precondition(policy.request(owner: owner, version: first.version, release: "1.6.10", eligible: true) == nil, "Closing the host cancels deferred manual intent")

        // Manual replay, interruption during dismissal, and safe deferred retry.
        let replay = try require(policy.request(owner: owner, version: first.version, release: "1.6.10", eligible: true, manual: true))
        precondition(policy.beginDismiss(id: replay.id, acknowledge: true))
        policy.interrupt(id: replay.id)
        precondition(policy.finishDismiss(id: replay.id, eligible: false) == false)
        precondition(policy.seenVersions == [first.version])
        let resumedReplay = try require(policy.request(owner: owner, version: first.version, release: "1.6.10", eligible: true))
        precondition(policy.finishDismiss(id: resumedReplay.id, eligible: true) == true)
        let next = try require(policy.request(owner: other, version: "1.6.10-beta.8", release: "1.6.10", eligible: true))
        policy.interrupt(id: next.id)
        precondition(policy.finishDismiss(id: next.id, eligible: true) == false, "Recovery before onDismiss must not acknowledge an interruption")
        let retry = try require(policy.request(owner: other, version: next.version, release: "1.6.10", eligible: true))
        policy.abandon(owner: owner)
        precondition(policy.session?.id == retry.id, "Another window cannot cancel this owner")
        policy.abandon(owner: other)
        precondition(policy.session == nil)
        precondition(policy.finishDismiss(id: retry.id, eligible: true) == nil)
        precondition(!policy.seenVersions.contains(next.version), "Closing the host must not lose unseen updates")

        // Every shipped version is independent; rebuilds of the same version do not repeat.
        for version in ["1.6.10-beta.8", "1.6.10", "1.6.11"] {
            let release = version == "1.6.11" ? "1.6.11" : "1.6.10"
            let session = try require(policy.request(owner: owner, version: version, release: release, eligible: true))
            precondition(policy.finishDismiss(id: session.id, eligible: true) == true)
            precondition(policy.request(owner: owner, version: version, release: release, eligible: true) == nil)
        }
        precondition(policy.request(owner: owner, version: first.version, release: "1.6.10", eligible: true) == nil, "Downgrades do not repeat an acknowledged update")
        var bounded = ReleaseHighlightsPolicy(seenVersions: [""] + (0..<80).map { "1.0.\($0)" } + ["1.0.79"])
        precondition(bounded.seenVersions.count == ReleaseHighlightsPolicy.historyLimit)
        let boundedSession = try require(bounded.request(owner: owner, version: "2.0.0", release: "2.0.0", eligible: true))
        precondition(bounded.finishDismiss(id: boundedSession.id, eligible: true) == true)
        precondition(bounded.seenVersions.count == ReleaseHighlightsPolicy.historyLimit)
        precondition(bounded.seenVersions.last == "2.0.0")

        // Durable round-trip uses the same standard UserDefaults array representation as production.
        let suite = "ReleaseHighlightsTests.\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(policy.seenVersions, forKey: ReleaseHighlightsPolicy.seenKey)
        let restored = ReleaseHighlightsPolicy(seenVersions: defaults.stringArray(forKey: ReleaseHighlightsPolicy.seenKey) ?? [])
        precondition(restored.seenVersions == policy.seenVersions)

        let plist = try Data(contentsOf: URL(fileURLWithPath: "Info.plist"))
        let info = try require(PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])
        let version = try require(info["CFBundleShortVersionString"] as? String)
        for privateAI in [false, true] {
            let content = ReleaseHighlightsContent.current(hasPrivateAI: privateAI)
            precondition(ReleaseHighlightsPolicy.matches(version: version, release: content.release), "Update release highlights when bumping the app version")
            precondition((1...3).contains(content.features.count))
            precondition(Set(content.features.map(\.id)).count == content.features.count)
            for feature in content.features {
                precondition(!feature.title.isEmpty && !feature.detail.isEmpty && !feature.action.isEmpty)
            }
            if !privateAI {
                let last = try require(content.features.last)
                precondition(!last.title.contains("Fluid models"))
            }
        }
        print("PASS: version ledger, persistence, multiple owners, rapid dismissal, interruption/retry, stale callbacks, bounded history, and release content")
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw TestFailure.missingValue }
        return value
    }

    private enum TestFailure: Error { case missingValue }
}
