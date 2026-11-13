import AppKit
import Combine
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class AgentAPIControllerTests: XCTestCase {
    private let promptID = UUID()

    private func request(
        method: String = "POST",
        path: String = "/v1/agent/prompt",
        body: Data = Data()
    ) -> LocalAPI.Request {
        LocalAPI.Request(method: method, path: path, query: [:], headers: [:], body: body)
    }

    private func promptBody(message: String, status: String? = nil) -> Data {
        var dict: [String: Any] = ["id": self.promptID.uuidString, "message": message]
        if let status { dict["status"] = status }
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }

    private func json(_ response: LocalAPI.Response) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: response.body)
        return try XCTUnwrap(object as? [String: Any])
    }

    func testPromptReturns503WhenDisabled() async {
        let bridge = FakeAgentPromptBridge()
        let controller = AgentAPIController(bridge: bridge, isEnabled: { false })
        let response = await controller.handle(self.request(body: self.promptBody(message: "hi")))
        XCTAssertEqual(response.status, 503)
        XCTAssertFalse(bridge.promptCalled)
    }

    func testPromptRejectsInvalidJSON() async {
        let bridge = FakeAgentPromptBridge()
        let controller = AgentAPIController(bridge: bridge, isEnabled: { true })
        let response = await controller.handle(self.request(body: Data("not json".utf8)))
        XCTAssertEqual(response.status, 400)
    }

    func testPromptRejectsEmptyMessage() async {
        let bridge = FakeAgentPromptBridge()
        let controller = AgentAPIController(bridge: bridge, isEnabled: { true })
        let response = await controller.handle(self.request(body: self.promptBody(message: "   ")))
        XCTAssertEqual(response.status, 400)
    }

    func testPromptRejectsUnsupportedStatus() async {
        let bridge = FakeAgentPromptBridge()
        let controller = AgentAPIController(bridge: bridge, isEnabled: { true })
        let response = await controller.handle(self.request(body: self.promptBody(message: "hi", status: "permission")))
        XCTAssertEqual(response.status, 400)
        XCTAssertFalse(bridge.promptCalled)
    }

    func testPromptReturnsTranscribedReply() async throws {
        let bridge = FakeAgentPromptBridge()
        bridge.result = .replied("looks good, ship it")
        let controller = AgentAPIController(bridge: bridge, isEnabled: { true })
        let response = await controller.handle(
            self.request(body: self.promptBody(message: "done with the fix", status: "completed"))
        )
        XCTAssertEqual(response.status, 200)
        let body = try self.json(response)
        XCTAssertEqual(body["text"] as? String, "looks good, ship it")
        XCTAssertEqual(bridge.receivedID, self.promptID)
        XCTAssertEqual(bridge.receivedMessage, "done with the fix")
        XCTAssertEqual(bridge.receivedStatus, .completed)
    }

    func testPromptDefaultsStatusToCompleted() async {
        let bridge = FakeAgentPromptBridge()
        bridge.result = .replied("ok")
        let controller = AgentAPIController(bridge: bridge, isEnabled: { true })
        _ = await controller.handle(self.request(body: self.promptBody(message: "msg")))
        XCTAssertEqual(bridge.receivedStatus, .completed)
    }

    func testPromptCancelledReturns204() async {
        let bridge = FakeAgentPromptBridge()
        bridge.result = .cancelled
        let controller = AgentAPIController(bridge: bridge, isEnabled: { true })
        let response = await controller.handle(self.request(body: self.promptBody(message: "msg")))
        XCTAssertEqual(response.status, 204)
    }

    func testPromptBusyReturns409() async {
        let bridge = FakeAgentPromptBridge()
        bridge.result = .busy
        let controller = AgentAPIController(bridge: bridge, isEnabled: { true })
        let response = await controller.handle(self.request(body: self.promptBody(message: "msg")))
        XCTAssertEqual(response.status, 409)
    }

    func testPromptUnavailableReturns503WithReason() async throws {
        let bridge = FakeAgentPromptBridge()
        bridge.result = .unavailable("FluidVoice is already recording.")
        let controller = AgentAPIController(bridge: bridge, isEnabled: { true })
        let response = await controller.handle(self.request(body: self.promptBody(message: "msg")))
        XCTAssertEqual(response.status, 503)
        let body = try self.json(response)
        XCTAssertEqual(body["error"] as? String, "FluidVoice is already recording.")
    }

    func testCancelPassesTheRequestID() async {
        let bridge = FakeAgentPromptBridge()
        let controller = AgentAPIController(bridge: bridge, isEnabled: { true })
        let response = await controller.handle(self.request(path: "/v1/agent/cancel", body: self.promptBody(message: "msg")))
        XCTAssertEqual(response.status, 204)
        XCTAssertEqual(bridge.cancelledID, self.promptID)
    }

    func testCancelRejectsMissingRequestID() async {
        let bridge = FakeAgentPromptBridge()
        let controller = AgentAPIController(bridge: bridge, isEnabled: { true })
        let response = await controller.handle(self.request(path: "/v1/agent/cancel", body: Data("{}".utf8)))
        XCTAssertEqual(response.status, 400)
        XCTAssertNil(bridge.cancelledID)
    }

    func testUnknownPathReturns404() async {
        let controller = AgentAPIController(bridge: FakeAgentPromptBridge(), isEnabled: { true })
        let response = await controller.handle(self.request(path: "/v1/agent/unknown"))
        XCTAssertEqual(response.status, 404)
    }

    func testRouterRejectsGetOnPromptWith405() async {
        let router = LocalAPIRouter()
        let response = await router.route(self.request(method: "GET", path: "/v1/agent/prompt"))
        XCTAssertEqual(response.status, 405)
    }

    func testRouterMarksAgentPathsNoStore() async {
        let router = LocalAPIRouter()
        let response = await router.route(self.request(path: "/v1/agent/cancel"))
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(response.headers["Cache-Control"], "no-store")
    }
}

@MainActor
private final class FakeAgentPromptBridge: AgentPromptHandling {
    var result: AgentPromptResult = .cancelled
    var promptCalled: Bool { self.receivedID != nil }
    private(set) var receivedID: UUID?
    private(set) var receivedMessage: String?
    private(set) var receivedStatus: AgentPromptStatus?
    private(set) var cancelledID: UUID?

    func prompt(id: UUID, message: String, status: AgentPromptStatus) async -> AgentPromptResult {
        self.receivedID = id
        self.receivedMessage = message
        self.receivedStatus = status
        return self.result
    }

    func cancelPrompt(id: UUID) {
        self.cancelledID = id
    }
}

@MainActor
final class AgentBridgeServiceTests: XCTestCase {
    func testHUDShowsLiveTextAndCanReopenForTheNextTurn() async throws {
        let recorder = FakeAgentRecorder()
        let bridge = self.makeBridge(recorder: recorder)
        defer { bridge.cancelActivePrompt() }

        for index in 1 ... 2 {
            let task = Task { await bridge.prompt(id: UUID(), message: "Turn \(index)", status: .completed) }
            try await self.waitUntil { bridge.phase == .recording }
            XCTAssertTrue(self.isHUDVisible)
            recorder.transcript.send("Reply \(index)")
            XCTAssertEqual(bridge.liveTranscript, "Reply \(index)")
            bridge.finishRecordingAndReply()
            let result = await task.value
            XCTAssertEqual(result, .replied("Reply \(index)"))
            XCTAssertFalse(self.isHUDVisible)
        }
    }

    func testHUDHeaderDragMovesTheWindowWhileRecordingAndProcessing() async throws {
        let recorder = FakeAgentRecorder()
        recorder.pauseStop = true
        let bridge = self.makeBridge(recorder: recorder)
        defer {
            bridge.cancelActivePrompt()
            recorder.resumeStop()
        }
        let task = Task { await bridge.prompt(id: UUID(), message: "Drag check", status: .completed) }
        try await self.waitUntil { bridge.phase == .recording }
        let panel = try XCTUnwrap(NSApp.windows.first {
            $0.identifier == AgentPromptPanelController.windowIdentifier && $0.isVisible
        })
        let root = try XCTUnwrap(panel.contentView)
        root.layoutSubtreeIfNeeded()

        func findDragHandle(in view: NSView) -> NSView? {
            if view.toolTip == "Drag to move" { return view }
            return view.subviews.lazy.compactMap { findDragHandle(in: $0) }.first
        }
        let handle = try XCTUnwrap(findDragHandle(in: root))
        let center = NSPoint(x: handle.bounds.midX, y: handle.bounds.midY)
        XCTAssertTrue(root.hitTest(handle.convert(center, to: root.superview)) === handle)
        XCTAssertTrue(handle.acceptsFirstMouse(for: nil), "Dragging must work while FluidVoice is inactive")
        var eventNumber = 0
        func sendMouse(_ type: NSEvent.EventType, at screenPoint: NSPoint) throws {
            eventNumber += 1
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: panel.convertPoint(fromScreen: screenPoint),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: eventNumber,
                clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            ))
            panel.sendEvent(event)
        }
        func dragHeader(from windowPoint: NSPoint) throws {
            let startOrigin = panel.frame.origin
            let grabPoint = panel.convertPoint(toScreen: windowPoint)
            let endPoint = NSPoint(x: grabPoint.x + 120, y: grabPoint.y + 60)
            try sendMouse(.leftMouseDown, at: grabPoint)
            try sendMouse(.leftMouseDragged, at: NSPoint(x: grabPoint.x + 80, y: grabPoint.y + 40))
            try sendMouse(.leftMouseDragged, at: endPoint)
            try sendMouse(.leftMouseUp, at: endPoint)
            XCTAssertEqual(panel.frame.origin.x, startOrigin.x + 120, accuracy: 0.5)
            XCTAssertEqual(panel.frame.origin.y, startOrigin.y + 60, accuracy: 0.5)
        }

        try dragHeader(from: handle.convert(center, to: nil))
        let movedOrigin = panel.frame.origin
        recorder.transcript.send("Still listening after moving")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(panel.frame.origin, movedOrigin)
        XCTAssertEqual(bridge.phase, .recording)

        bridge.finishRecordingAndReply()
        try await self.waitUntil { recorder.stopWaiter != nil }
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(bridge.phase, .processing)
        let contentFrame = root.convert(root.bounds, to: nil)
        let headerFrame = handle.convert(handle.bounds, to: nil)
        try dragHeader(from: NSPoint(x: headerFrame.midX, y: (headerFrame.maxY + contentFrame.maxY) / 2))

        bridge.cancelActivePrompt()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        recorder.resumeStop()
        try await self.waitUntil { bridge.phase == .idle }
    }

    func testCancellationDuringStartupIsScopedToTheRequest() async throws {
        let recorder = FakeAgentRecorder()
        recorder.pauseStart = true
        let bridge = self.makeBridge(recorder: recorder)
        defer { bridge.cancelActivePrompt() }
        let id = UUID()
        let task = Task { await bridge.prompt(id: id, message: "Starting", status: .completed) }
        try await self.waitUntil { recorder.startWaiter != nil }

        let competing = await bridge.prompt(id: UUID(), message: "Competing", status: .completed)
        XCTAssertEqual(competing, .busy)
        bridge.cancelPrompt(id: UUID())
        XCTAssertTrue(self.isHUDVisible)
        XCTAssertEqual(bridge.phase, .starting)

        bridge.cancelPrompt(id: id)
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        try await self.waitUntil { bridge.phase == .idle }
        XCTAssertEqual(recorder.cancelCount, 1)
        XCTAssertFalse(self.isHUDVisible)
    }

    func testCancellationDuringFinalizationSuppressesTheLateTranscript() async throws {
        let recorder = FakeAgentRecorder()
        recorder.pauseStop = true
        let bridge = self.makeBridge(recorder: recorder)
        defer { recorder.resumeStop() }
        let id = UUID()
        let task = Task { await bridge.prompt(id: id, message: "Recording", status: .completed) }
        try await self.waitUntil { bridge.phase == .recording }

        recorder.transcript.send("Do not send")
        bridge.finishRecordingAndReply()
        try await self.waitUntil { recorder.stopWaiter != nil }
        bridge.cancelPrompt(id: id)

        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(self.isHUDVisible)
        let competing = await bridge.prompt(id: UUID(), message: "Competing", status: .completed)
        XCTAssertEqual(competing, .busy)

        recorder.resumeStop()
        try await self.waitUntil { bridge.phase == .idle }
        XCTAssertEqual(recorder.refineCount, 0)
    }

    func testUnexpectedCaptureEndDismissesHUDBeforeAnotherRecordingCanBeSent() async throws {
        let recorder = FakeAgentRecorder()
        let bridge = self.makeBridge(recorder: recorder)
        defer { bridge.cancelActivePrompt() }
        let task = Task { await bridge.prompt(id: UUID(), message: "Recording", status: .completed) }
        try await self.waitUntil { bridge.phase == .recording }

        recorder.ended.send(())
        recorder.transcript.send("Unrelated dictation")
        bridge.finishRecordingAndReply()

        XCTAssertEqual(bridge.phase, .idle)
        XCTAssertFalse(self.isHUDVisible)
        XCTAssertEqual(recorder.stopCount, 0)
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
    }

    func testLockedSessionRejectsPromptWithoutOpeningHUD() async {
        let recorder = FakeAgentRecorder()
        let bridge = self.makeBridge(recorder: recorder, isSessionLocked: { true })

        let result = await bridge.prompt(id: UUID(), message: "Locked", status: .completed)

        XCTAssertEqual(result, .unavailable("Unlock your Mac before replying by voice."))
        XCTAssertEqual(recorder.startCount, 0)
        XCTAssertFalse(self.isHUDVisible)
    }

    func testLockBeforeCaptureStartupCancelsWithoutStartingASR() async {
        let recorder = FakeAgentRecorder()
        var checkedAdmission = false
        let bridge = self.makeBridge(recorder: recorder, isSessionLocked: {
            defer { checkedAdmission = true }
            return checkedAdmission
        })

        let result = await bridge.prompt(id: UUID(), message: "Locking", status: .completed)

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(recorder.startCount, 0)
        XCTAssertFalse(self.isHUDVisible)
    }

    func testLockNotificationCancelsActiveRecording() async throws {
        let recorder = FakeAgentRecorder()
        let lock = PassthroughSubject<Void, Never>()
        let bridge = self.makeBridge(recorder: recorder, sessionDidLock: lock.eraseToAnyPublisher())
        defer { bridge.cancelActivePrompt() }
        let task = Task { await bridge.prompt(id: UUID(), message: "Recording", status: .completed) }
        try await self.waitUntil { bridge.phase == .recording }

        lock.send(())

        XCTAssertFalse(self.isHUDVisible)
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        try await self.waitUntil { bridge.phase == .idle }
        XCTAssertEqual(recorder.cancelCount, 1)
    }

    func testStaleAgentLeaseCannotStopNewDictation() async throws {
        let asr = ASRService()
        let agentLease = try asr.acquireExclusiveActivity(.agentPrompt)
        asr.releaseExclusiveActivity(agentLease)
        let dictationLease = try asr.acquireExclusiveActivity(.dictation)
        defer { asr.releaseExclusiveActivity(dictationLease) }
        asr.configureDictationModeSwitchForTesting(ownedLease: dictationLease)

        let transcript = await asr.stop(agentPromptLease: agentLease)
        await asr.stopWithoutTranscription(agentPromptLease: agentLease)

        XCTAssertEqual(transcript, "")
        XCTAssertEqual(asr.activeExclusiveActivity, .dictation)
    }

    func testOnlyMatchingAgentLeaseCanStopAgentCapture() async throws {
        let asr = ASRService()
        let oldLease = try asr.acquireExclusiveActivity(.agentPrompt)
        asr.releaseExclusiveActivity(oldLease)
        let lease = try asr.acquireExclusiveActivity(.agentPrompt)
        defer { asr.releaseExclusiveActivity(lease) }
        asr.configureDictationModeSwitchForTesting(ownedLease: lease)

        _ = await asr.stop()
        await asr.stopWithoutTranscription()
        _ = await asr.stop(agentPromptLease: oldLease)
        await asr.stopWithoutTranscription(agentPromptLease: oldLease)
        XCTAssertEqual(asr.activeExclusiveActivity, .agentPrompt)

        await asr.stopWithoutTranscription(agentPromptLease: lease)
        XCTAssertNil(asr.activeExclusiveActivity)
    }

    private func makeBridge(
        recorder: FakeAgentRecorder,
        isSessionLocked: @escaping () -> Bool = { false },
        sessionDidLock: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher()
    ) -> AgentBridgeService {
        AgentBridgeService(recorder: recorder, isSessionLocked: isSessionLocked, sessionDidLock: sessionDidLock)
    }

    private var isHUDVisible: Bool {
        NSApp.windows.contains { $0.identifier == AgentPromptPanelController.windowIdentifier && $0.isVisible }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The expected agent prompt state did not arrive.")
        throw CancellationError()
    }
}

@MainActor
private final class FakeAgentRecorder: AgentPromptRecording {
    let transcript = CurrentValueSubject<String, Never>("")
    let ended = PassthroughSubject<Void, Never>()
    var pauseStart = false
    var pauseStop = false
    private(set) var startWaiter: CheckedContinuation<Bool, Never>?
    private(set) var stopWaiter: CheckedContinuation<Void, Never>?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private(set) var refineCount = 0

    var unavailableReason: String? { nil }
    var liveTranscript: AnyPublisher<String, Never> { self.transcript.eraseToAnyPublisher() }
    var captureEnded: AnyPublisher<Void, Never> { self.ended.eraseToAnyPublisher() }

    func start() async -> Bool {
        self.startCount += 1
        self.transcript.send("")
        guard self.pauseStart else { return true }
        return await withCheckedContinuation { self.startWaiter = $0 }
    }

    func stop() async -> String {
        self.stopCount += 1
        if self.pauseStop {
            await withCheckedContinuation { self.stopWaiter = $0 }
        }
        return self.transcript.value
    }

    func cancel() async {
        self.cancelCount += 1
        self.startWaiter?.resume(returning: false)
        self.startWaiter = nil
    }

    func refine(_ transcript: String) async -> String {
        self.refineCount += 1
        return transcript
    }

    func resumeStop() {
        self.stopWaiter?.resume()
        self.stopWaiter = nil
    }
}
