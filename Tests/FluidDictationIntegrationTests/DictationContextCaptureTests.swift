import ApplicationServices
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class DictationContextCaptureTests: XCTestCase {
    func testScreenOffNeverInvokesOCRWithStoredToggleEnabled() async {
        let request = self.request(scope: .off, readsWindowImage: true)
        let context = await DictationContextReader.read(request) { _, _ in
            XCTFail("Screen words Off must prevent screenshots")
            return ["unexpected screen text"]
        }
        XCTAssertNil(context?.screenText)
        XCTAssertEqual(context?.textBeforeCursor, "Known cursor text")
    }

    func testMissingCapturedWindowNeverFallsBackToAnotherWindow() async {
        let context = await DictationContextReader.read(self.request(scope: .frontWindow, readsWindowImage: true)) { _, _ in
            XCTFail("A missing target window must not fall back to another window")
            return ["unexpected screen text"]
        }
        XCTAssertNil(context?.screenText)
    }

    func testPasswordManagerDropsCursorAndScreenContext() async {
        let context = await DictationContextReader.read(self.request(bundleID: "com.1password", scope: .frontWindow, readsWindowImage: true)) { _, _ in
            XCTFail("Private apps must not invoke OCR")
            return []
        }
        XCTAssertNil(context)
    }

    func testCursorContextIsBounded() async {
        let request = DictationContextReader.Request(
            pid: 999_999,
            bundleID: "test.context",
            window: nil,
            element: nil,
            textBeforeCursor: String(repeating: "a", count: 2100) + "end",
            scope: .off,
            readsWindowImage: false
        )
        let context = await DictationContextReader.read(request)
        XCTAssertEqual(context?.textBeforeCursor?.count, 2000)
        XCTAssertTrue(context?.textBeforeCursor?.hasSuffix("end") == true)
    }

    func testReadyContextReturnsAndCancelsItsTimeout() async throws {
        let expected = DictationTypingContext(textBeforeCursor: "ready", screenText: ["visible"])
        let task = Task<DictationTypingContext?, Never> { expected }
        _ = await task.value
        let capture = DictationContextCapture(target: self.target(), task: task)
        let result = await capture.result(timeout: .milliseconds(100))
        XCTAssertEqual(result, expected)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(task.isCancelled, "A finished read must not retain an active timeout")
    }

    func testCancellationBeforeWaitingDropsReadyContext() async {
        let task = Task<DictationTypingContext?, Never> { .init(textBeforeCursor: "stale", screenText: nil) }
        _ = await task.value
        let capture = DictationContextCapture(target: self.target(), task: task)
        capture.cancel()
        let result = await capture.result(timeout: .seconds(1))
        XCTAssertNil(result)
        XCTAssertTrue(task.isCancelled)
    }

    func testTimeoutDropsLateResultAndCancelsReader() async {
        let task = self.delayedRead()
        let capture = DictationContextCapture(target: self.target(), task: task)
        let result = await capture.result(timeout: .milliseconds(10))
        XCTAssertNil(result)
        XCTAssertTrue(task.isCancelled)
        _ = await task.value
    }

    func testCancellingWaiterCancelsReaderWithoutWaitingForTimeout() async {
        let task = self.delayedRead()
        let capture = DictationContextCapture(target: self.target(), task: task)
        let waiter = Task { await capture.result(timeout: .seconds(10)) }
        await Task.yield()
        waiter.cancel()
        let result = await waiter.value
        XCTAssertNil(result)
        XCTAssertTrue(task.isCancelled)
    }

    func testTargetMatchRequiresSameFieldAndWindow() {
        let field = AXUIElementCreateApplication(101)
        let window = AXUIElementCreateApplication(102)
        let original = self.target(window: window, element: field)
        let capture = DictationContextCapture(target: original, task: Task { nil })
        XCTAssertTrue(capture.matches(original))
        XCTAssertTrue(capture.matches(self.target(window: window, element: field)))
        XCTAssertFalse(capture.matches(self.target(window: window, element: AXUIElementCreateApplication(103))))
        XCTAssertFalse(capture.matches(self.target(window: AXUIElementCreateApplication(104), element: field)))
        XCTAssertFalse(capture.matches(self.target(pid: 2, window: window, element: field)))
        XCTAssertFalse(capture.matches(self.target()))
    }

    func testNewCaptureDoesNotReceiveCancelledResult() async {
        let stale = DictationContextCapture(target: self.target(), task: self.delayedRead())
        stale.cancel()
        let expected = DictationTypingContext(textBeforeCursor: "new recording", screenText: nil)
        let current = DictationContextCapture(target: self.target(), task: Task { expected })
        let result = await current.result(timeout: .seconds(1))
        let cancelledResult = await stale.result(timeout: .seconds(1))
        XCTAssertEqual(result, expected)
        XCTAssertNil(cancelledResult)
    }

    func testPermissionRefreshNeverPrompts() async {
        var requests = 0
        let permission = DictationScreenPermissionController(check: { false }, request: {
            requests += 1
            return false
        })
        await permission.refresh()
        XCTAssertTrue(permission.hasChecked)
        XCTAssertFalse(permission.isAllowed)
        XCTAssertEqual(requests, 0)
    }

    func testEnablingOCRRequestsMissingPermission() async {
        var requests = 0
        let permission = DictationScreenPermissionController(check: { false }, request: {
            requests += 1
            return true
        })
        await permission.requestIfNeeded { true }
        XCTAssertTrue(permission.isAllowed)
        XCTAssertFalse(permission.isRequesting)
        XCTAssertEqual(requests, 1)
    }

    func testDeniedPermissionReturnsToAnIdleState() async {
        let permission = DictationScreenPermissionController(check: { false }, request: { false })
        await permission.requestIfNeeded { true }
        XCTAssertTrue(permission.hasChecked)
        XCTAssertFalse(permission.isAllowed)
        XCTAssertFalse(permission.isRequesting)
    }

    func testGrantedPermissionDoesNotPromptAgain() async {
        let permission = DictationScreenPermissionController(check: { true }, request: {
            XCTFail("An existing grant must not prompt again")
            return false
        })
        await permission.requestIfNeeded { true }
        XCTAssertTrue(permission.isAllowed)
    }

    func testDisablingOCRBeforePermissionCheckCompletesDoesNotPrompt() async {
        let started = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        var enabled = true
        let permission = DictationScreenPermissionController(check: {
            started.signal()
            _ = resume.wait(timeout: .now() + 2)
            return false
        }, request: {
            XCTFail("Disabling OCR must cancel the pending permission request")
            return true
        })
        let request = Task { await permission.requestIfNeeded { enabled } }
        let didStart = await Task.detached { Self.waitForSignal(started) }.value
        XCTAssertTrue(didStart)
        enabled = false
        resume.signal()
        await request.value
        XCTAssertFalse(permission.isAllowed)
        XCTAssertFalse(permission.isRequesting)
    }

    func testSearchFindsOCRInExperimentalSettings() {
        let result = SettingsSearchIndex.results(for: "OCR", availability: self.searchAvailability(privateAIAvailable: true)).first
        XCTAssertEqual(result?.target, .dictationScreenContext)
        XCTAssertEqual(result?.section, .experimental)
    }

    func testPublicBuildSearchOmitsFluidIntelligenceContext() {
        let availability = self.searchAvailability(privateAIAvailable: false)
        for query in ["OCR", "screen words", "Fluid Intelligence"] {
            XCTAssertFalse(SettingsSearchIndex.results(for: query, availability: availability).contains { $0.target == .dictationScreenContext })
        }
        XCTAssertTrue(availability.includes(.experimental))
    }

    private func searchAvailability(privateAIAvailable: Bool) -> SettingsSearchAvailability {
        .init(
            microphoneAuthorized: true,
            accessibilityEnabled: true,
            savesTranscriptionHistory: true,
            savesAudioWithTranscriptionHistory: true,
            overlayAtBottom: false,
            privateAIAvailable: privateAIAvailable
        )
    }

    private nonisolated static func waitForSignal(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 2) == .success
    }

    private func target(pid: pid_t = 1, window: AXUIElement? = nil, element: AXUIElement? = nil) -> TypingService.RecordingTargetContext {
        .init(id: UUID(), pid: pid, bundleIdentifier: "test.context", window: window, element: element)
    }

    private func delayedRead() -> Task<DictationTypingContext?, Never> {
        Task {
            try? await Task.sleep(for: .seconds(10))
            return .init(textBeforeCursor: "late result", screenText: nil)
        }
    }

    private func request(bundleID: String = "test.context", scope: DictationScreenContextScope, readsWindowImage: Bool) -> DictationContextReader.Request {
        .init(
            pid: 999_999,
            bundleID: bundleID,
            window: nil,
            element: nil,
            textBeforeCursor: "Known cursor text",
            scope: scope,
            readsWindowImage: readsWindowImage
        )
    }
}
