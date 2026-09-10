import Foundation

/// Standalone, deterministic tests of the production boundary. No app launch, defaults, keys or models.
@main
struct PrivateAISettingsBoundaryTests {
    enum Failure: Error { case expected }

    @MainActor
    static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        for gigabytes: UInt64 in [4, 8, 12] {
            check(PrivateAIModelRecommendation.modelID(physicalMemory: gigabytes * 1024 * 1024 * 1024) == "fluid-1-pico-96k-dflash", "Below 16 GB recommends Pico")
        }
        for gigabytes: UInt64 in [16, 24, 32, 64, 128] {
            check(PrivateAIModelRecommendation.modelID(physicalMemory: gigabytes * 1024 * 1024 * 1024) == "fluid-1-mini-96k-dflash", "16 GB and above recommends Mini")
        }
        check(PrivateAIModelRecommendation.modelID(physicalMemory: 16 * 1024 * 1024 * 1024 - 1) == "fluid-1-pico-96k-dflash", "Recommendation uses the exact 16 GB boundary")

        check(PrivateAIModelCarouselNavigation.next(in: [], current: "missing", forward: true) == nil, "Empty catalog has no navigation target")
        check(PrivateAIModelCarouselNavigation.next(in: ["mini"], current: "mini", forward: false) == "mini", "One model never fabricates a neighbor")
        check(PrivateAIModelCarouselNavigation.next(in: ["pico", "mini"], current: "mini", forward: true) == "pico", "Two-model carousel wraps forward")
        check(PrivateAIModelCarouselNavigation.next(in: ["pico", "mini"], current: "pico", forward: false) == "mini", "Two-model carousel wraps backward")
        check(PrivateAIModelCarouselNavigation.next(in: ["pico", "mini"], current: "deleted", forward: true) == "pico", "Stale preview recovers to a real model")
        check(PrivateAIModelCarouselNavigation.position(of: "pico", in: ["pico", "mini", "full"], current: "mini") == -1, "Three-model carousel places the previous card left")
        check(PrivateAIModelCarouselNavigation.position(of: "full", in: ["pico", "mini", "full"], current: "mini") == 1, "Three-model carousel places the next card right")
        var session = PrivateAISettingsSession(selectedModelID: "mini")
        let initialRevision = session.revision
        for id in ["pico", "mini", "pico"] { session.preview(id) }
        check(session.previewModelID == "pico", "Preview follows browsing")
        check(session.selectedModelID == "mini", "Browsing must not activate")
        check(session.revision == initialRevision, "Browsing must not invalidate active work")
        check(session.acceptsRead(initialRevision), "Read-only browsing retains current status")
        check(session.select(session.previewModelID), "Explicit activation is accepted")
        check(session.selectedModelID == "pico", "Activation changes selection")
        check(!session.acceptsRead(initialRevision), "Old model status must be rejected")

        let beforeOperation = session.revision
        guard let first = session.begin() else { preconditionFailure("Expected first operation") }
        check(session.begin() == nil, "Duplicate operation must not start")
        check(!session.select("mini"), "Model activation must wait during mutation")
        session.preview("mini")
        check(session.previewModelID == "mini" && session.selectedModelID == "pico", "Browsing remains available during work")
        check(!session.acceptsRead(beforeOperation), "Old refresh cannot erase loading/progress")
        session.finish(UUID())
        check(session.isBusy, "Foreign completion cannot release the current operation")
        session.finish(first)
        check(!session.isBusy, "Completion releases mutation slot")
        check(!session.acceptsRead(beforeOperation), "Pre-operation refresh stays stale after completion")
        guard let second = session.begin() else { preconditionFailure("Expected second operation") }
        session.finish(first)
        check(session.isBusy, "Late first completion cannot release second operation")
        session.finish(second)

        var events: [String] = []
        let success = try await PrivateAISettingsUpdateTransaction.run(
            update: { events.append("download"); return 7 },
            verify: { events.append("verify"); return true },
            commit: { check($0 == 7, "Commit exact update token"); events.append("commit") },
            rollback: { _ in events.append("rollback") }
        )
        check(success && events == ["download", "verify", "commit"], "Success commits once, never rolls back")

        events = []
        let failedVerification = try await PrivateAISettingsUpdateTransaction.run(
            update: { events.append("download"); return 8 },
            verify: { events.append("verify"); return false },
            commit: { _ in events.append("commit") },
            rollback: { check($0 == 8, "Rollback exact update token"); events.append("rollback") }
        )
        check(!failedVerification && events == ["download", "verify", "rollback"], "Verification failure preserves previous artifact")

        events = []
        guard let failedOperation = session.begin() else { preconditionFailure("Expected failure operation") }
        do {
            defer { session.finish(failedOperation) }
            _ = try await PrivateAISettingsUpdateTransaction.run(
                update: { () async throws -> Int in events.append("download"); throw Failure.expected },
                verify: { events.append("verify"); return true },
                commit: { _ in events.append("commit") },
                rollback: { _ in events.append("rollback") }
            )
            preconditionFailure("Download error must propagate")
        } catch Failure.expected {}
        check(events == ["download"], "Failed download must not verify/commit or roll back a nonexistent token")
        check(!session.isBusy && session.select("mini"), "Failure permits retry/activation")

        events = []
        let cancelled = Task { @MainActor in
            try await PrivateAISettingsUpdateTransaction.run(
                update: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    events.append("download")
                    return 9
                },
                verify: { events.append("verify"); return true },
                commit: { _ in events.append("commit") },
                rollback: { _ in events.append("rollback") }
            )
        }
        do {
            _ = try await cancelled.value
            preconditionFailure("Cancellation must propagate")
        } catch is CancellationError {}
        check(events == ["download", "rollback"], "Cancellation after staging rolls back without verification")

        events = []
        let cancelDuringVerification = Task { @MainActor in
            try await PrivateAISettingsUpdateTransaction.run(
                update: { 10 },
                verify: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return true
                },
                commit: { _ in events.append("commit") },
                rollback: { _ in events.append("rollback") }
            )
        }
        do {
            _ = try await cancelDuringVerification.value
            preconditionFailure("Cancellation must propagate")
        } catch is CancellationError {}
        check(events == ["rollback"], "Cancellation during verification never commits")

        guard let rollbackOperation = session.begin() else { preconditionFailure("Expected rollback operation") }
        _ = try await PrivateAISettingsUpdateTransaction.run(
            update: { 11 },
            verify: { false },
            commit: { _ in preconditionFailure("Must not commit") },
            rollback: { _ in
                await Task.yield()
                check(session.isBusy && session.begin() == nil, "Slot stays occupied across asynchronous rollback")
                check(!session.select("pico"), "Selection cannot race rollback")
            }
        )
        session.finish(rollbackOperation)
        check(!session.isBusy, "Rollback completion allows another operation")
        await PrivateAIControllerChecks.run(check: check)
        let section = try String(contentsOfFile: "Sources/Fluid/UI/AISettings/FluidIntelligenceLiveSection.swift", encoding: .utf8)
        check(section.contains("Label(\"Active\", systemImage: \"checkmark.circle.fill\")"), "Active is informational, not a disabled action")
        check(!section.contains("onReady: self.makePrimary"), "Model activation must not silently assign the main shortcut")
        check(!section.contains("modelPanel") && !section.contains("Model details…"), "Model menu never opens a duplicate management sheet")
        check(!section.contains("Reset verification") && !section.contains("Troubleshooting"), "Model menu exposes no reset or troubleshooting submenu")
        check(section.contains(".alert(\"Delete downloaded model?\""), "Deletion requires explicit confirmation")
        check(section.components(separatedBy: "Open models folder").count == 2, "Shared Manage sheet owns the only folder action")
        check(section.contains("if files?.installed == false, let bytes"), "Download size is visible before installation")
        let card = try String(contentsOfFile: "Sources/Fluid/UI/AISettings/FluidModelShowcaseCard.swift", encoding: .utf8)
        check(!card.contains(".popover("), "Model information stays inside its card")
        check(card.contains("Button { self.showsInfo.toggle() }"), "Information toggles only local presentation state")
        check(card.contains("self.reduceMotion ? nil") && card.contains("ZStack(alignment: .topLeading)"), "Inline information respects reduced motion and shares stable content bounds")
        print("Passed \(checks) FI boundary/controller assertions")
    }
}
