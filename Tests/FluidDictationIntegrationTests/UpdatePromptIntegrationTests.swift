import AppKit
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class UpdatePromptIntegrationTests: XCTestCase {
    func testPopupPreferenceBackupDecodesFalseAndMissingLegacyField() throws {
        var payload = SettingsStore.shared.makeBackupPayload()
        payload.showUpdatePopups = false
        let encoded = try JSONEncoder().encode(payload)
        XCTAssertEqual(try JSONDecoder().decode(SettingsBackupPayload.self, from: encoded).showUpdatePopups, false)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "showUpdatePopups")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertNil(try JSONDecoder().decode(SettingsBackupPayload.self, from: legacyData).showUpdatePopups)
    }

    func testOnlyOlderCopiesOfTheAppAreSuperseded() {
        let launch = Date(timeIntervalSinceReferenceDate: 1000)
        let instances = [
            SupersededInstanceRetirement.Instance(processID: 10, launchDate: launch.addingTimeInterval(-60)),
            SupersededInstanceRetirement.Instance(processID: 20, launchDate: launch),
            SupersededInstanceRetirement.Instance(processID: 30, launchDate: launch.addingTimeInterval(60)),
            SupersededInstanceRetirement.Instance(processID: 40, launchDate: nil),
            SupersededInstanceRetirement.Instance(processID: 50, launchDate: launch),
        ]
        let superseded = SupersededInstanceRetirement.superseded(among: instances, currentProcessID: 20, currentLaunchDate: launch)
        XCTAssertEqual(superseded, [10], "only the copy that was already running is retired")
        XCTAssertEqual(
            SupersededInstanceRetirement.superseded(among: [instances[1]], currentProcessID: 20, currentLaunchDate: launch),
            [],
            "a lone instance never retires itself"
        )
        XCTAssertEqual(
            SupersededInstanceRetirement.superseded(among: instances, currentProcessID: 10, currentLaunchDate: launch.addingTimeInterval(-60)),
            [],
            "the older copy never retires the newer ones"
        )
    }

    func testOfferWithQueuedFailureTransitionsToOnlyInstallStatus() async throws {
        let presenter = UpdatePromptPresenter.shared
        let updater = SimpleUpdater()
        presenter.dismissAll()
        defer {
            presenter.dismissAll()
            updater.dismissUpdateInstallStatus()
        }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let keyWindow = NSApp.keyWindow
        let firstResponder = keyWindow?.firstResponder
        var installActions = 0
        var failureActions = 0
        let version = "offer-test-\(UUID().uuidString)"

        presenter.presentFloatingPrompt(title: "Update Available", message: "Your dictation can continue.", actions: [
            FloatingPromptAction(title: "Install Now") {
                installActions += 1
                updater.showUpdateInstallStatus(version: version)
            },
            FloatingPromptAction(title: "Later") {},
        ])
        let offer = try self.visibleWindow("Update Available")
        let install = try self.button("Install Now", in: offer)
        presenter.presentFloatingPrompt(title: "Update Check Failed", message: "Queued notice", actions: [
            FloatingPromptAction(title: "OK") { failureActions += 1 },
        ])
        install.performClick(nil)

        XCTAssertEqual(installActions, 1)
        XCTAssertFalse(offer.isVisible)
        XCTAssertFalse(self.isVisible("Update Check Failed"))
        let status = try self.visibleWindow("Installing FluidVoice \(version)")
        let progress = try XCTUnwrap(status.contentView?.subviews.compactMap { $0 as? NSProgressIndicator }.first)
        XCTAssertTrue(progress.isIndeterminate)
        XCTAssertFalse(progress.isHidden)
        XCTAssertFalse(updater.isUpdateInProgress, "UI-only status must not begin an install or download")
        XCTAssertNil(NSApp.modalWindow)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmostPID)
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        XCTAssertTrue(keyWindow?.firstResponder === firstResponder)

        var mainActorRan = false
        await Task { @MainActor in mainActorRan = true }.value
        XCTAssertTrue(mainActorRan && status.isVisible)
        install.performClick(nil)
        XCTAssertEqual(installActions, 1, "A retained button cannot start installation twice")

        // Mirror failure cleanup: progress closes before the nonmodal error opens.
        updater.dismissUpdateInstallStatus()
        XCTAssertFalse(status.isVisible)
        presenter.presentFloatingPrompt(title: "Update Check Failed", message: "Simulated failure", actions: [
            FloatingPromptAction(title: "OK") { failureActions += 1 },
        ])
        let failure = try self.visibleWindow("Update Check Failed")
        XCTAssertNil(NSApp.modalWindow)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmostPID)
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        XCTAssertTrue(keyWindow?.firstResponder === firstResponder)
        mainActorRan = false
        await Task { @MainActor in mainActorRan = true }.value
        XCTAssertTrue(mainActorRan && failure.isVisible)
        failure.cancelOperation(nil)
        XCTAssertEqual(failureActions, 1, "Discarded queued notice must never run its handler")
        XCTAssertFalse(failure.isVisible)
    }

    func testDirectInstallStatusInvalidatesOutstandingOfferAndQueue() throws {
        let presenter = UpdatePromptPresenter.shared
        let updater = SimpleUpdater()
        presenter.dismissAll()
        defer {
            presenter.dismissAll()
            updater.dismissUpdateInstallStatus()
        }
        var staleActions = 0
        presenter.presentFloatingPrompt(title: "Update Available", message: "Outstanding offer", actions: [
            FloatingPromptAction(title: "Install Now") { staleActions += 1 },
        ])
        let offer = try self.visibleWindow("Update Available")
        let staleInstall = try self.button("Install Now", in: offer)
        presenter.presentFloatingPrompt(title: "Update Check Failed", message: "Queued notice", actions: [
            FloatingPromptAction(title: "OK") { staleActions += 1 },
        ])
        let version = "direct-test-\(UUID().uuidString)"
        updater.showUpdateInstallStatus(version: version)
        let status = try self.visibleWindow("Installing FluidVoice \(version)")
        XCTAssertFalse(offer.isVisible)
        XCTAssertFalse(self.isVisible("Update Check Failed"))
        staleInstall.performClick(nil)
        XCTAssertEqual(staleActions, 0)
        XCTAssertTrue(status.isVisible)
        updater.dismissUpdateInstallStatus()
        XCTAssertFalse(status.isVisible)
        XCTAssertFalse(updater.isUpdateInProgress)
        XCTAssertNil(NSApp.modalWindow)
    }

    private func visibleWindow(_ title: String) throws -> NSWindow {
        try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.title == title })
    }

    private func isVisible(_ title: String) -> Bool {
        NSApp.windows.contains { $0.isVisible && $0.title == title }
    }

    private func button(_ title: String, in window: NSWindow) throws -> NSButton {
        try XCTUnwrap(window.contentView?.subviews.compactMap { $0 as? NSButton }.first { $0.title == title })
    }

    func testDefaultAutomaticOfferAndDisabledPopupsStillDiscover() async throws {
        let context = try UpdateTestContext()
        defer { context.cleanup() }
        context.fixture.setReply(version: "v99.0.0")
        XCTAssertNil(context.defaults.object(forKey: SettingsStore.UpdateKeys.showUpdatePopups))
        context.updater.checkForUpdatesAutomatically()
        try await self.finishCheck(context)
        XCTAssertEqual(context.updater.availableUpdateVersion, "v99.0.0")
        XCTAssertTrue(self.isVisible("Update Available"))
        XCTAssertNotNil(context.defaults.object(forKey: SettingsStore.UpdateKeys.lastUpdateCheckDate))
        XCTAssertFalse(context.updater.isUpdateInProgress)

        context.defaults.set(false, forKey: SettingsStore.UpdateKeys.showUpdatePopups)
        context.updater.automaticUpdatePopupPreferenceDidChange(isEnabled: false)
        XCTAssertFalse(self.isVisible("Update Available"))
        context.defaults.removeObject(forKey: SettingsStore.UpdateKeys.lastUpdateCheckDate)
        context.fixture.setReply(version: "v100.0.0")
        context.updater.checkForUpdatesAutomatically()
        try await self.finishCheck(context, requests: 2)
        XCTAssertEqual(context.updater.availableUpdateVersion, "v100.0.0")
        XCTAssertFalse(self.isVisible("Update Available"))
        XCTAssertNotNil(context.defaults.object(forKey: SettingsStore.UpdateKeys.lastUpdateCheckDate))
        XCTAssertNil(context.defaults.object(forKey: SettingsStore.UpdateKeys.updatePromptSnoozedUntil))
        XCTAssertNil(context.defaults.object(forKey: SettingsStore.UpdateKeys.snoozedUpdateVersion))
    }

    func testExplicitCheckOffersBeforeInstallingWhenPopupsAreDisabled() async throws {
        let context = try UpdateTestContext()
        defer { context.cleanup() }
        context.defaults.set(false, forKey: SettingsStore.UpdateKeys.showUpdatePopups)
        context.fixture.setReply(version: "v99.0.0")
        var installs = 0
        context.updater.simulationInstallHandler = { installs += 1 }
        context.updater.checkForUpdatesManually()
        try await self.finishCheck(context)
        let offer = try self.visibleWindow("Update Available")
        let install = try self.button("Install Now", in: offer)
        XCTAssertEqual(installs, 0)
        XCTAssertEqual(context.fixture.requestCount, 1, "Discovery must not fetch assets or start installation before approval")
        XCTAssertFalse(context.updater.isUpdateInProgress)
        context.updater.automaticUpdatePopupPreferenceDidChange(isEnabled: false)
        XCTAssertTrue(offer.isVisible, "Turning automatic popups off must preserve explicit offers")
        try self.button("Later", in: offer).performClick(nil)
        install.performClick(nil)
        XCTAssertEqual(installs, 0)
        XCTAssertEqual(context.updater.availableUpdateVersion, "v99.0.0")
        context.updater.showAvailableUpdate()
        let cachedOffer = try self.visibleWindow("Update Available")
        try self.button("Install Now", in: cachedOffer).performClick(nil)
        try await self.waitFor { installs == 1 }
        install.performClick(nil)
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(context.fixture.requestCount, 2, "Confirmation revalidates the release; the simulated installer never downloads")
    }

    func testPopupTogglesDuringHeldCheckUseFinalPreferenceWithoutExtraRequests() async throws {
        let context = try UpdateTestContext()
        defer { context.cleanup() }
        context.fixture.setReply(version: "v99.0.0", held: true)
        context.updater.checkForUpdatesAutomatically()
        try await self.waitFor { context.fixture.requestCount == 1 }
        for enabled in [false, true, false] {
            context.defaults.set(enabled, forKey: SettingsStore.UpdateKeys.showUpdatePopups)
            let revision = context.defaults.integer(forKey: SettingsStore.UpdateKeys.popupPreferenceRevision)
            context.defaults.set(revision &+ 1, forKey: SettingsStore.UpdateKeys.popupPreferenceRevision)
            context.updater.automaticUpdatePopupPreferenceDidChange(isEnabled: enabled)
        }
        context.fixture.release()
        try await self.finishCheck(context)
        XCTAssertEqual(context.updater.availableUpdateVersion, "v99.0.0")
        XCTAssertFalse(self.isVisible("Update Available"))
        context.defaults.set(true, forKey: SettingsStore.UpdateKeys.showUpdatePopups)
        context.updater.automaticUpdatePopupPreferenceDidChange(isEnabled: true)
        XCTAssertFalse(self.isVisible("Update Available"), "Enabling popups must not unexpectedly display cached offers")
        XCTAssertEqual(context.fixture.requestCount, 1)
        XCTAssertFalse(context.updater.isUpdateInProgress)
    }

    func testRepeatedManualRequestsClaimAutomaticCheckWithoutDuplicateFetch() async throws {
        let context = try UpdateTestContext()
        defer { context.cleanup() }
        context.defaults.set(false, forKey: SettingsStore.UpdateKeys.showUpdatePopups)
        context.fixture.setReply(version: "v99.0.0", held: true)
        context.updater.checkForUpdatesAutomatically()
        try await self.waitFor { context.fixture.requestCount == 1 }
        for _ in 0..<8 {
            context.updater.checkForUpdatesManually()
        }
        XCTAssertEqual(context.fixture.requestCount, 1)
        context.fixture.release()
        try await self.finishCheck(context)
        let offer = try self.visibleWindow("Update Available")
        XCTAssertEqual(NSApp.windows.filter { $0.isVisible && $0.title == "Update Available" }.count, 1)
        context.updater.automaticUpdatePopupPreferenceDidChange(isEnabled: false)
        XCTAssertTrue(offer.isVisible)
        XCTAssertFalse(context.updater.isUpdateInProgress)
    }

    func testNoUpdateAndFailedRefreshClearStaleAvailability() async throws {
        let context = try UpdateTestContext()
        defer { context.cleanup() }
        context.defaults.set(false, forKey: SettingsStore.UpdateKeys.showUpdatePopups)
        context.fixture.setReply(version: "v99.0.0")
        context.updater.checkForUpdatesAutomatically()
        try await self.finishCheck(context)
        context.defaults.removeObject(forKey: SettingsStore.UpdateKeys.lastUpdateCheckDate)
        context.fixture.setReply(version: nil, status: 503)
        context.updater.checkForUpdatesAutomatically()
        try await self.finishCheck(context, requests: 2)
        XCTAssertNil(context.updater.availableUpdateVersion)
        XCTAssertFalse(self.isVisible("Update Check Failed"))
        context.updater.checkForUpdatesManually()
        try await self.finishCheck(context, requests: 3)
        XCTAssertTrue(self.isVisible("Update Check Failed"))
        XCTAssertNil(context.updater.availableUpdateVersion)
        context.presenter.dismissAll()
        context.fixture.setReply(version: nil)
        context.updater.checkForUpdatesManually()
        try await self.finishCheck(context, requests: 4)
        XCTAssertNil(context.updater.availableUpdateVersion)
        XCTAssertFalse(self.isVisible("Update Available"))
        XCTAssertFalse(context.updater.isUpdateInProgress)
        XCTAssertNil(NSApp.modalWindow)
    }

    func testChannelChangeRejectsHeldOldResult() async throws {
        let context = try UpdateTestContext()
        defer { context.cleanup() }
        context.fixture.setReply(version: "v99.0.0", held: true)
        context.updater.checkForUpdatesAutomatically()
        try await self.waitFor { context.fixture.requestCount == 1 }
        context.defaults.set(true, forKey: SettingsStore.UpdateKeys.betaReleasesEnabled)
        let revision = context.defaults.integer(forKey: SettingsStore.UpdateKeys.channelPreferenceRevision)
        context.defaults.set(revision &+ 1, forKey: SettingsStore.UpdateKeys.channelPreferenceRevision)
        context.updater.updateChannelDidChange()
        XCTAssertNil(context.updater.availableUpdateVersion)
        XCTAssertFalse(self.isVisible("Update Available"))
        context.fixture.setReply(version: "v100.0.0")
        context.updater.checkForUpdatesManually()
        try await self.finishCheck(context, requests: 2)
        context.fixture.release()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(context.updater.availableUpdateVersion, "v100.0.0")
        let offer = try self.visibleWindow("Update Available")
        XCTAssertTrue(offer.contentView?.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("v100.0.0") } == true)
        XCTAssertFalse(context.updater.isUpdateInProgress)
    }

    func testChangedReleaseRequiresFreshApprovalBeforeInstalling() async throws {
        let context = try UpdateTestContext()
        defer { context.cleanup() }
        context.fixture.setReply(version: "v99.0.0")
        var installs = 0
        context.updater.simulationInstallHandler = { installs += 1 }
        context.updater.checkForUpdatesManually()
        try await self.finishCheck(context)
        let oldOffer = try self.visibleWindow("Update Available")
        let oldInstall = try self.button("Install Now", in: oldOffer)
        context.fixture.setReply(version: "v100.0.0")
        oldInstall.performClick(nil)
        try await self.waitFor { context.fixture.requestCount == 2 && !context.updater.isUpdateInProgress }
        XCTAssertEqual(installs, 0, "A release discovered after approval must not install silently")
        let freshOffer = try self.visibleWindow("Update Available")
        XCTAssertTrue(freshOffer.contentView?.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("v100.0.0") } == true)
        oldInstall.performClick(nil)
        XCTAssertEqual(installs, 0)
        try self.button("Install Now", in: freshOffer).performClick(nil)
        try await self.waitFor { installs == 1 && !context.updater.isUpdateInProgress }
        XCTAssertEqual(context.fixture.requestCount, 3)
    }

    func testChannelChangeDuringApprovedInstallRechecksAndRequiresFreshApproval() async throws {
        for currentChannelVersion in ["v100.0.0", nil] as [String?] {
            let context = try UpdateTestContext()
            defer { context.cleanup() }
            context.fixture.setReply(version: "v99.0.0")
            var installs = 0
            context.updater.simulationInstallHandler = { installs += 1 }
            context.updater.checkForUpdatesManually()
            try await self.finishCheck(context)
            let oldOffer = try self.visibleWindow("Update Available")
            let oldInstall = try self.button("Install Now", in: oldOffer)
            context.fixture.setReply(version: "v99.0.0", held: true)
            oldInstall.performClick(nil)
            try await self.waitFor { context.fixture.requestCount == 2 && context.updater.isUpdateInProgress }
            context.defaults.set(true, forKey: SettingsStore.UpdateKeys.betaReleasesEnabled)
            let revision = context.defaults.integer(forKey: SettingsStore.UpdateKeys.channelPreferenceRevision)
            context.defaults.set(revision &+ 1, forKey: SettingsStore.UpdateKeys.channelPreferenceRevision)
            context.updater.updateChannelDidChange()
            context.fixture.setReply(version: currentChannelVersion)
            context.fixture.release()
            try await self.finishCheck(context, requests: 3)
            XCTAssertFalse(context.updater.isUpdateInProgress)
            XCTAssertEqual(installs, 0, "A channel change must invalidate approval before installation")
            oldInstall.performClick(nil)
            XCTAssertEqual(installs, 0)
            if let currentChannelVersion {
                let freshOffer = try self.visibleWindow("Update Available")
                XCTAssertTrue(freshOffer.contentView?.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains(currentChannelVersion) } == true)
                try self.button("Install Now", in: freshOffer).performClick(nil)
                try await self.waitFor { installs == 1 && !context.updater.isUpdateInProgress }
                XCTAssertEqual(context.fixture.requestCount, 4)
            } else {
                XCTAssertTrue(self.isVisible("No Beta Updates"))
                XCTAssertFalse(self.isVisible("Update Available"))
                XCTAssertNil(context.updater.availableUpdateVersion)
                XCTAssertEqual(context.fixture.requestCount, 3)
            }
        }
    }

    func testInstallRejectsResultFromPreviouslyPendingDiscovery() async throws {
        let context = try UpdateTestContext()
        defer { context.cleanup() }
        context.defaults.set(false, forKey: SettingsStore.UpdateKeys.showUpdatePopups)
        context.fixture.setReply(version: "v99.0.0")
        context.updater.checkForUpdatesAutomatically()
        try await self.finishCheck(context)
        context.fixture.setReply(version: "v100.0.0", held: true)
        context.updater.checkForUpdatesManually()
        try await self.waitFor { context.fixture.requestCount == 2 }
        context.updater.showAvailableUpdate()
        let cachedOffer = try self.visibleWindow("Update Available")
        context.fixture.setReply(version: "v99.0.0")
        var installs = 0
        context.updater.simulationInstallHandler = {
            installs += 1
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        try self.button("Install Now", in: cachedOffer).performClick(nil)
        try await self.waitFor { installs == 1 && context.updater.isUpdateInProgress }
        context.fixture.release()
        try await self.waitFor { !context.updater.isCheckingForUpdates }
        XCTAssertFalse(self.isVisible("Update Available"), "A stale discovery cannot reopen an offer during installation")
        try await self.waitFor { !context.updater.isUpdateInProgress }
        XCTAssertFalse(self.isVisible("Update Available"))
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(context.fixture.requestCount, 3)
    }

    func testFailedInstallReleasesGateAndAllowsExplicitRetry() async throws {
        let context = try UpdateTestContext()
        defer { context.cleanup() }
        context.fixture.setReply(version: "v99.0.0")
        var attempts = 0
        context.updater.simulationInstallHandler = {
            attempts += 1
            throw URLError(.cannotConnectToHost)
        }
        context.updater.checkForUpdatesManually()
        try await self.finishCheck(context)
        let offer = try self.visibleWindow("Update Available")
        let staleInstall = try self.button("Install Now", in: offer)
        staleInstall.performClick(nil)
        try await self.waitFor { attempts == 1 && !context.updater.isUpdateInProgress }
        let failure = try self.visibleWindow("Update Failed")
        XCTAssertFalse(offer.isVisible)
        XCTAssertNil(NSApp.modalWindow)
        staleInstall.performClick(nil)
        XCTAssertEqual(attempts, 1)
        failure.cancelOperation(nil)
        context.updater.simulationInstallHandler = { attempts += 1 }
        context.updater.showAvailableUpdate()
        let retry = try self.visibleWindow("Update Available")
        try self.button("Install Now", in: retry).performClick(nil)
        try await self.waitFor { attempts == 2 && !context.updater.isUpdateInProgress }
        XCTAssertEqual(context.fixture.requestCount, 3)
        XCTAssertFalse(self.isVisible("Update Failed"))
        XCTAssertFalse(self.isVisible("Update Available"))
    }

    func testNewExplicitCheckReplacesOldResultAndPreservesUnrelatedInstallFailure() async throws {
        let context = try UpdateTestContext()
        defer { context.cleanup() }
        context.fixture.setReply(version: nil)
        context.updater.checkForUpdatesManually()
        try await self.finishCheck(context)
        let noUpdates = try self.visibleWindow("No Updates")
        context.fixture.setReply(version: "v99.0.0")
        context.updater.checkForUpdatesManually()
        try await self.finishCheck(context, requests: 2)
        XCTAssertFalse(noUpdates.isVisible)
        let offer = try self.visibleWindow("Update Available")
        XCTAssertTrue(offer.contentView?.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("v99.0.0") } == true)
        offer.cancelOperation(nil)

        context.fixture.setReply(version: nil)
        context.updater.checkForUpdatesManually()
        try await self.finishCheck(context, requests: 3)
        let secondResult = try self.visibleWindow("No Updates")
        context.presenter.presentFloatingPrompt(title: "Update Failed", message: "Unrelated installation failure", actions: [FloatingPromptAction(title: "OK") {}])
        context.fixture.setReply(version: "v100.0.0")
        context.updater.checkForUpdatesManually()
        try await self.finishCheck(context, requests: 4)
        XCTAssertFalse(secondResult.isVisible)
        let installFailure = try self.visibleWindow("Update Failed")
        context.defaults.set(false, forKey: SettingsStore.UpdateKeys.showUpdatePopups)
        context.updater.automaticUpdatePopupPreferenceDidChange(isEnabled: false)
        XCTAssertTrue(installFailure.isVisible, "Check-result cleanup and popup preference changes must preserve unrelated installation errors")
        installFailure.cancelOperation(nil)
        let freshOffer = try self.visibleWindow("Update Available")
        XCTAssertTrue(freshOffer.contentView?.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("v100.0.0") } == true)
        XCTAssertFalse(context.updater.isUpdateInProgress)
    }

    private func finishCheck(_ context: UpdateTestContext, requests: Int = 1) async throws {
        try await self.waitFor { context.fixture.requestCount >= requests && !context.updater.isCheckingForUpdates }
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Isolated update fixture did not finish within two seconds")
        throw URLError(.timedOut)
    }
}

private final nonisolated class UpdateFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(UpdateFixtureURLProtocol, Int, String)] = []
    private var count = 0
    private var held = false
    private var body = "[]"
    private var status = 200

    var requestCount: Int { self.lock.withLock { self.count } }

    func setReply(version: String?, status: Int = 200, held: Bool = false) {
        self.lock.withLock {
            self.status = status
            self.held = held
            self.body = version.map {
                """
                [{"tag_name":"\($0)","prerelease":false,"assets":[]}]
                """
            } ?? "[{\"tag_name\":\"v0.0.1\",\"prerelease\":false,\"assets\":[]}]"
        }
    }

    func receive(_ loading: UpdateFixtureURLProtocol) {
        let (held, status, body) = self.lock.withLock {
            self.count += 1
            if self.held { self.pending.append((loading, self.status, self.body)) }
            return (self.held, self.status, self.body)
        }
        if !held { self.respond(to: loading, status: status, body: body) }
    }

    func release() {
        let pending = self.lock.withLock {
            self.held = false
            let result = self.pending
            self.pending.removeAll()
            return result
        }
        for (loading, status, body) in pending {
            self.respond(to: loading, status: status, body: body)
        }
    }

    private func respond(to loading: UpdateFixtureURLProtocol, status: Int, body: String) {
        guard let url = loading.request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        else { loading.client?.urlProtocol(loading, didFailWithError: URLError(.badURL)); return }
        loading.client?.urlProtocol(loading, didReceive: response, cacheStoragePolicy: .notAllowed)
        loading.client?.urlProtocol(loading, didLoad: Data(body.utf8))
        loading.client?.urlProtocolDidFinishLoading(loading)
    }
}

private nonisolated class UpdateFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var fixtures: [String: UpdateFixture] = [:]

    static func register(_ fixture: UpdateFixture, token: String) {
        self.lock.withLock { self.fixtures[token] = fixture }
    }

    static func remove(token: String) {
        _ = self.lock.withLock { self.fixtures.removeValue(forKey: token) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard self.request.url?.host == "api.github.com", self.request.url?.path.hasSuffix("/releases") == true,
              let token = self.request.value(forHTTPHeaderField: "X-Update-Test"),
              let fixture = Self.lock.withLock({ Self.fixtures[token] })
        else {
            XCTFail("Unexpected network/download request: \(self.request.url?.absoluteString ?? "nil")")
            self.client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        fixture.receive(self)
    }

    override func stopLoading() {}
}

@MainActor
private final class UpdateTestContext {
    let token = UUID().uuidString
    let defaults: UserDefaults
    let session: URLSession
    let presenter = UpdatePromptPresenter()
    let fixture = UpdateFixture()
    let updater: SimpleUpdater

    init() throws {
        self.defaults = try XCTUnwrap(UserDefaults(suiteName: self.token))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateFixtureURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Update-Test": self.token]
        self.session = URLSession(configuration: configuration)
        UpdateFixtureURLProtocol.register(self.fixture, token: self.token)
        self.updater = SimpleUpdater(session: self.session, defaults: self.defaults, promptPresenter: self.presenter)
        self.updater.simulationInstallHandler = {}
    }

    func cleanup() {
        let revision = self.defaults.integer(forKey: SettingsStore.UpdateKeys.channelPreferenceRevision)
        self.defaults.set(revision &+ 1, forKey: SettingsStore.UpdateKeys.channelPreferenceRevision)
        self.updater.updateChannelDidChange()
        self.updater.dismissUpdateInstallStatus()
        self.presenter.dismissAll()
        self.session.invalidateAndCancel()
        UpdateFixtureURLProtocol.remove(token: self.token)
        self.defaults.removePersistentDomain(forName: self.token)
    }
}
