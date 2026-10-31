import AppKit
import Combine
@testable import FluidVoice_Debug
import SwiftUI
import XCTest

final class LowMemorySlowdownPolicyTests: XCTestCase {
    private func reading(_ pressure: CleanupMemoryReading.Pressure? = .warning, pages: UInt64 = 0) -> CleanupMemoryReading {
        CleanupMemoryReading(pressure: pressure, swapIns: pages, compressions: 0, pageSize: 16_384)
    }

    private func record(
        _ policy: inout LowMemorySlowdownPolicy,
        model: String = "mini",
        speed: Double? = 20,
        seconds: TimeInterval = 4,
        pressure: CleanupMemoryReading.Pressure? = .warning,
        at time: TimeInterval = 100,
        movingMemory: Bool = true
    ) {
        let warm = policy.begin(model: model, at: time - seconds)
        policy.record(.init(
            model: model,
            isWarm: warm,
            tokensPerSecond: speed,
            seconds: seconds,
            start: self.reading(pressure),
            end: self.reading(pressure, pages: movingMemory ? 2048 : 0),
            completedAt: time
        ))
    }

    private func learnedPolicy(speed: Double = 100) -> LowMemorySlowdownPolicy {
        var policy = LowMemorySlowdownPolicy()
        for index in 0..<6 {
            self.record(&policy, speed: speed, seconds: 1, pressure: .normal, at: Double(index * 10 + 10))
        }
        return policy
    }

    func testRequiresRepeatedSlowCleanupsAndFreshEvidence() {
        var policy = self.learnedPolicy()
        for time in [100.0, 110] {
            self.record(&policy, at: time)
            XCTAssertNil(policy.noticeDelay(model: "mini", at: time))
        }
        self.record(&policy, at: 120)
        XCTAssertEqual(policy.noticeDelay(model: "mini", at: 121), 3)
        XCTAssertNil(policy.noticeDelay(model: "mini", at: 421), "Old pressure must not follow the user into a later session")
        XCTAssertNil(policy.noticeDelay(model: "other", at: 121))
    }

    func testNaturallySlowerMacAndLongHealthyOutputStayQuiet() {
        var policy = self.learnedPolicy(speed: 15)
        for time in [100.0, 140, 180, 220] {
            self.record(&policy, speed: 14, seconds: 25, at: time)
        }
        XCTAssertNil(policy.noticeDelay(model: "mini", at: 221), "A universal tokens/sec floor would falsely warn here")
    }

    func testPressureWithoutMemoryMovementAndSlowdownWithoutPressureStayQuiet() {
        for pressure in [CleanupMemoryReading.Pressure.normal, .warning] {
            var policy = self.learnedPolicy()
            for time in [100.0, 110, 120, 130] {
                self.record(&policy, pressure: pressure, at: time, movingMemory: pressure == .normal)
            }
            XCTAssertNil(policy.noticeDelay(model: "mini", at: 131))
        }
    }

    func testHealthyCleanupBreaksStreakWithoutTeachingPressuredSpeeds() {
        var policy = self.learnedPolicy()
        self.record(&policy, at: 100)
        self.record(&policy, at: 110)
        self.record(&policy, speed: 100, pressure: .normal, at: 120)
        self.record(&policy, at: 130)
        self.record(&policy, at: 140)
        XCTAssertNil(policy.noticeDelay(model: "mini", at: 141))
        self.record(&policy, at: 150)
        XCTAssertNotNil(policy.noticeDelay(model: "mini", at: 151))
    }

    func testFirstLoadLongIdleAndModelSwitchCannotCountAsSlowEvidence() {
        var policy = self.learnedPolicy()
        self.record(&policy, at: 100)
        self.record(&policy, at: 110)
        self.record(&policy, at: 500)
        XCTAssertNil(policy.noticeDelay(model: "mini", at: 501))
        self.record(&policy, model: "splash", seconds: 10, pressure: .critical, at: 520)
        self.record(&policy, model: "splash", seconds: 10, pressure: .critical, at: 540)
        self.record(&policy, model: "splash", seconds: 10, pressure: .critical, at: 560)
        XCTAssertNil(policy.noticeDelay(model: "splash", at: 561), "The first request on the new model was cold")
    }

    func testMissingBaselineRequiresRepeatedSeverePressureAndLongWaits() {
        for pressure in [CleanupMemoryReading.Pressure.warning, .critical] {
            var policy = LowMemorySlowdownPolicy()
            for time in [20.0, 40, 60, 80] {
                self.record(&policy, seconds: 10, pressure: pressure, at: time)
            }
            XCTAssertEqual(policy.noticeDelay(model: "mini", at: 81), pressure == .critical ? 8 : nil)
        }
    }

    func testUnknownOrInvalidMetricsAndTinyWaitsBreakStreak() {
        for speed in [Double?.none, .nan, .infinity, 0, -1] {
            var policy = self.learnedPolicy()
            self.record(&policy, at: 100)
            self.record(&policy, at: 110)
            self.record(&policy, speed: speed, at: 120)
            self.record(&policy, at: 130)
            XCTAssertNil(policy.noticeDelay(model: "mini", at: 131))
        }
        var policy = self.learnedPolicy()
        self.record(&policy, at: 100)
        self.record(&policy, pressure: nil, at: 110)
        self.record(&policy, at: 120)
        self.record(&policy, seconds: 0.5, at: 130)
        XCTAssertNil(policy.noticeDelay(model: "mini", at: 131))
    }

    func testCompressionCountsButRecoveryAndUnavailableCountersDoNot() {
        let start = self.reading()
        let compressing = CleanupMemoryReading(pressure: .warning, swapIns: 0, compressions: 8192, pageSize: 16_384)
        XCTAssertTrue(compressing.hasActivePressure(since: start))
        XCTAssertFalse(self.reading(.normal, pages: 2048).hasActivePressure(since: start))
        XCTAssertFalse(self.reading(pages: 2048).hasActivePressure(since: self.reading(.normal)))
        XCTAssertFalse(self.reading(pages: 10).hasActivePressure(since: self.reading(pages: 10_000)))
        let unavailable = CleanupMemoryReading(pressure: .critical, swapIns: nil, compressions: nil, pageSize: 16_384)
        XCTAssertFalse(unavailable.hasActivePressure(since: start))
        let unknown = CleanupMemoryReading(pressure: nil, swapIns: 10_000, compressions: 10_000, pageSize: 16_384)
        XCTAssertFalse(unknown.hasActivePressure(since: start))
        XCTAssertFalse(self.reading(pages: 100).hasActivePressure(since: start), "Small background churn is insufficient")
    }

    func testCooldownSurvivesRelaunchAndBackwardClockChanges() {
        let shown = Date(timeIntervalSince1970: 100_000)
        XCTAssertTrue(LowMemorySlowdownPolicy.cooldownAllowsNotice(lastShown: nil, now: shown))
        XCTAssertFalse(LowMemorySlowdownPolicy.cooldownAllowsNotice(lastShown: shown, now: shown.addingTimeInterval(3600)))
        XCTAssertFalse(LowMemorySlowdownPolicy.cooldownAllowsNotice(lastShown: shown, now: shown.addingTimeInterval(-3600)))
        XCTAssertTrue(LowMemorySlowdownPolicy.cooldownAllowsNotice(lastShown: shown, now: shown.addingTimeInterval(86_400)))
    }
}

private actor CleanupMemorySampler {
    private var readings: [CleanupMemoryReading] = []

    func append(_ readings: [CleanupMemoryReading]) { self.readings += readings }

    func sample() -> CleanupMemoryReading {
        if !self.readings.isEmpty { return self.readings.removeFirst() }
        return CleanupMemoryReading(pressure: nil, swapIns: nil, compressions: nil, pageSize: 16_384)
    }
}

private actor CleanupNoticeSleeper {
    private var continuations: [CheckedContinuation<Void, Error>] = []
    private(set) var durations: [TimeInterval] = []

    func sleep(_ seconds: TimeInterval) async throws {
        self.durations.append(seconds)
        try await withCheckedThrowingContinuation { self.continuations.append($0) }
    }

    func advance() {
        if !self.continuations.isEmpty { self.continuations.removeFirst().resume() }
    }
}

@MainActor
final class LowMemorySlowdownMonitorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var time: TimeInterval = 0
    private var sampler = CleanupMemorySampler()
    private var sleeper = CleanupNoticeSleeper()
    private var monitor: LowMemorySlowdownMonitor!

    override func setUp() {
        super.setUp()
        self.suite = "LowMemorySlowdownTests.\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: self.suite)
        self.sampler = CleanupMemorySampler()
        self.sleeper = CleanupNoticeSleeper()
        self.monitor = self.makeMonitor()
    }

    override func tearDown() {
        self.monitor.cancelCleanup()
        self.monitor = nil
        self.defaults.removePersistentDomain(forName: self.suite)
        super.tearDown()
    }

    private func makeMonitor() -> LowMemorySlowdownMonitor {
        let sampler = self.sampler
        let sleeper = self.sleeper
        return LowMemorySlowdownMonitor(
            defaults: self.defaults,
            sampleMemory: { await sampler.sample() },
            uptime: { [unowned self] in self.time },
            now: { Date(timeIntervalSince1970: 100_000) },
            sleep: { try await sleeper.sleep($0) }
        )
    }

    private func readings(pressure: CleanupMemoryReading.Pressure = .warning) -> [CleanupMemoryReading] {
        [0, 2048].map { CleanupMemoryReading(pressure: pressure, swapIns: $0, compressions: 0, pageSize: 16_384) }
    }

    private func seedEvidence() async {
        for index in 0..<9 {
            await self.sampler.append(self.readings(pressure: index < 6 ? .normal : .warning))
            let id = self.monitor.beginCleanup(model: "mini", isLocal: true, isModelReady: true, inputCharacters: 100)
            self.time += 4
            await self.monitor.finishCleanup(id: id, tokensPerSecond: index < 6 ? 100 : 20, succeeded: true)?.value
            self.time += 6
        }
    }

    private func waitUntil(_ predicate: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for monitor", file: file, line: line)
    }

    private func requestNotice() async throws -> UUID? {
        await self.sampler.append(self.readings())
        let id = self.monitor.beginCleanup(model: "mini", isLocal: true, isModelReady: true, inputCharacters: 100)
        try await self.waitUntil { await self.sleeper.durations.count == 1 }
        XCTAssertFalse(self.monitor.isNoticeVisible, "Nothing appears while a cleanup may still finish quickly")
        await self.sleeper.advance()
        try await self.waitUntil { self.monitor.isNoticeVisible }
        return id
    }

    func testVisibleNoticeStartsPersistentCooldownAndExpires() async throws {
        await self.seedEvidence()
        _ = try await self.requestNotice()
        XCTAssertNil(self.defaults.object(forKey: LowMemorySlowdownMonitor.lastShownKey))
        self.monitor.noticeDidAppear()
        XCTAssertNotNil(self.defaults.object(forKey: LowMemorySlowdownMonitor.lastShownKey))
        try await self.waitUntil { await self.sleeper.durations.count == 2 }
        await self.sleeper.advance()
        try await self.waitUntil { !self.monitor.isNoticeVisible }
        self.monitor.cancelCleanup()
        self.monitor = self.makeMonitor()
        await self.seedEvidence()
        let count = await self.sleeper.durations.count
        _ = self.monitor.beginCleanup(model: "mini", isLocal: true, isModelReady: true, inputCharacters: 100)
        for _ in 0..<20 {
            await Task.yield()
        }
        let after = await self.sleeper.durations.count
        XCTAssertEqual(after, count, "Relaunch must not reset the daily limit")
    }

    func testHiddenNoticeExpiresWithoutSpendingCooldown() async throws {
        await self.seedEvidence()
        _ = try await self.requestNotice()
        try await self.waitUntil { await self.sleeper.durations.count == 2 }
        await self.sleeper.advance()
        try await self.waitUntil { !self.monitor.isNoticeVisible }
        self.monitor.noticeDidAppear()
        XCTAssertNil(self.defaults.object(forKey: LowMemorySlowdownMonitor.lastShownKey), "A hidden notice must not appear much later or spend the daily allowance")
    }

    func testCancellationAndFastCompletionCannotShowALateWarning() async throws {
        for finish in [false, true] {
            self.sampler = CleanupMemorySampler()
            self.sleeper = CleanupNoticeSleeper()
            self.monitor = self.makeMonitor()
            await self.seedEvidence()
            await self.sampler.append(self.readings())
            let expected = await self.sleeper.durations.count + 1
            let id = self.monitor.beginCleanup(model: "mini", isLocal: true, isModelReady: true, inputCharacters: 100)
            try await self.waitUntil { await self.sleeper.durations.count == expected }
            if finish {
                self.time += 0.2
                await self.monitor.finishCleanup(id: id, tokensPerSecond: 100, succeeded: true)?.value
            } else {
                self.monitor.cancelCleanup()
            }
            await self.sleeper.advance()
            for _ in 0..<20 {
                await Task.yield()
            }
            XCTAssertFalse(self.monitor.isNoticeVisible)
            XCTAssertNil(self.defaults.object(forKey: LowMemorySlowdownMonitor.lastShownKey))
        }
    }

    func testRecoveryBeforePresentationAndColdModelStayQuiet() async throws {
        await self.seedEvidence()
        await self.sampler.append(self.readings(pressure: .normal))
        _ = self.monitor.beginCleanup(model: "mini", isLocal: true, isModelReady: true, inputCharacters: 100)
        try await self.waitUntil { await self.sleeper.durations.count == 1 }
        await self.sleeper.advance()
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertFalse(self.monitor.isNoticeVisible)
        self.monitor.cancelCleanup()
        await self.seedEvidence()
        _ = self.monitor.beginCleanup(model: "mini", isLocal: true, isModelReady: false, inputCharacters: 100)
        for _ in 0..<20 {
            await Task.yield()
        }
        let count = await self.sleeper.durations.count
        XCTAssertEqual(count, 1, "Manual unload or a newly loaded model must not trigger a warning")
    }

    func testIneligibleProvidersTinySamplesAndFailuresResetEvidence() async {
        await self.seedEvidence()
        XCTAssertNil(self.monitor.beginCleanup(model: "mini", isLocal: false, isModelReady: true, inputCharacters: 100))
        XCTAssertNil(self.monitor.beginCleanup(model: "mini", isLocal: true, isModelReady: true, inputCharacters: 10))
        await self.sampler.append(self.readings())
        let id = self.monitor.beginCleanup(model: "mini", isLocal: true, isModelReady: true, inputCharacters: 100)
        await self.monitor.finishCleanup(id: id, tokensPerSecond: nil, succeeded: false)?.value
        XCTAssertFalse(self.monitor.isNoticeVisible)
        let delays = await self.sleeper.durations
        XCTAssertTrue(delays.isEmpty)
    }

    func testOverlayKeepsCaptionsAndControlsAndOnlyCountsVisibleNotices() async throws {
        let settings = SettingsStore.shared
        let manager = NotchOverlayManager.shared
        let state = NotchContentState.shared
        let previousPosition = settings.overlayPosition
        let previousSize = settings.overlaySize
        let previousPreview = settings.enableStreamingPreview
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        panel.contentView = host
        defer {
            self.monitor.cancelCleanup()
            manager.hideImmediately()
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
            settings.overlayPosition = previousPosition
            settings.overlaySize = previousSize
            settings.enableStreamingPreview = previousPreview
        }
        settings.overlayPosition = .bottom
        settings.overlaySize = .medium
        settings.enableStreamingPreview = true
        manager.show(audioLevelPublisher: Just(CGFloat.zero).eraseToAnyPublisher(), mode: .dictation)
        manager.setProcessing(true)
        manager.updateTranscriptionText("Refining")
        await self.seedEvidence()
        _ = try await self.requestNotice()
        let keyWindow = NSApp.keyWindow
        host.rootView = AnyView(BottomOverlayView(lowMemory: self.monitor).frame(width: 380).transaction { $0.disablesAnimations = true })

        state.mode = .command
        try await self.capture(host, panel: panel, name: "command-suppressed")
        guard panel.occlusionState.contains(.visible) else {
            await self.sleeper.advance()
            throw XCTSkip("Visible overlay verification requires an unlocked, unobscured desktop")
        }
        XCTAssertNil(self.defaults.object(forKey: LowMemorySlowdownMonitor.lastShownKey))
        state.mode = .dictation
        state.isProcessing = false
        try await self.capture(host, panel: panel, name: "recording-suppressed")
        XCTAssertNil(self.defaults.object(forKey: LowMemorySlowdownMonitor.lastShownKey))
        state.isProcessing = true
        state.updateTranscription("Your words remain visible while cleanup continues.")
        try await self.capture(host, panel: panel, name: "captions-take-priority")
        XCTAssertNil(self.defaults.object(forKey: LowMemorySlowdownMonitor.lastShownKey))
        state.updateTranscription("Refining")
        settings.enableStreamingPreview = false
        try await self.capture(host, panel: panel, name: "preview-disabled")
        XCTAssertNil(self.defaults.object(forKey: LowMemorySlowdownMonitor.lastShownKey))
        settings.enableStreamingPreview = true
        settings.overlaySize = .pill
        try await self.capture(host, panel: panel, name: "pill-suppressed")
        XCTAssertNil(self.defaults.object(forKey: LowMemorySlowdownMonitor.lastShownKey))
        for size in [SettingsStore.OverlaySize.small, .medium, .large] {
            settings.overlaySize = size
            let width = BottomOverlayView.LayoutConstants.get(for: size).overlayWidth
            host.rootView = AnyView(BottomOverlayView(lowMemory: self.monitor).frame(width: width).transaction { $0.disablesAnimations = true })
            try await self.capture(host, panel: panel, name: "bottom-\(size)")
            XCTAssertNotNil(self.defaults.object(forKey: LowMemorySlowdownMonitor.lastShownKey))
        }
        host.rootView = AnyView(NotchExpandedView(lowMemory: self.monitor, audioPublisher: Just(CGFloat.zero).eraseToAnyPublisher()).padding(12).background(Color.black))
        try await self.capture(host, panel: panel, name: "standard-notch")
        host.rootView = AnyView(NotchCompactBottomView(lowMemory: self.monitor).background(Color.black))
        try await self.capture(host, panel: panel, name: "compact-notch-preview")
        XCTAssertTrue(NSApp.keyWindow === keyWindow, "The passive notice must not take keyboard focus")
        try await self.waitUntil { await self.sleeper.durations.count == 2 }
        await self.sleeper.advance()
        try await self.waitUntil { !self.monitor.isNoticeVisible }
        host.rootView = AnyView(EmptyView())
        try await Task.sleep(for: .milliseconds(300))
    }

    private func capture(_ host: NSHostingView<AnyView>, panel: NSPanel, name: String) async throws {
        host.layoutSubtreeIfNeeded()
        panel.setContentSize(host.fittingSize)
        panel.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        self.add(attachment)
    }
}
