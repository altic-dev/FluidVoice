import AppKit
import Combine
import SwiftUI

// Only UI presentation, app settings and capture models are doubles. Production detector inputs
// use the existing hardware-free fixtures, and every countdown/controller method compiles unchanged.
typealias MeetingSessionID = UUID
struct MeetingApplicationIdentity {
    let bundleIdentifier: String
    let processID: Int32?
    let displayName: String
    var capturesAllInstances: Bool? = nil
}

struct MeetingSession {
    enum Mode {
        case onlineCall, inRoom, systemAudio
        var capturesComputerAudio: Bool { self != .inRoom }
    }

    let id: UUID
    let mode: Mode
    var capturedApplication: MeetingApplicationIdentity? = nil
}

enum MeetingCoordinatorState: Equatable {
    case idle, preparing, recording(UUID), recordingDegraded(UUID), stopping(UUID), processing(UUID), completed(UUID), interrupted(UUID), failed(UUID)
}

@MainActor final class SettingsStore {
    static let shared = SettingsStore()
    var fluidMeetEnabled = true
    var accentColor: Color { .cyan }
}

final class DebugLogger {
    static let shared = DebugLogger()
    func log(_: String, source _: String) {}
    func warning(_: String, source _: String) {}
    func info(_: String, source _: String) {}
    func error(_: String, source _: String) {}
}

@MainActor final class MeetingSessionCoordinator {
    enum TestError: Error { case captureStopFailed }
    var state = MeetingCoordinatorState.idle
    var activeSession: MeetingSession?
    var stopped: [UUID] = []
    var failStop = false
    func stopAndTranscribe() async throws {
        guard let session = self.activeSession else { return }
        self.stopped.append(session.id)
        self.state = self.failStop ? .interrupted(session.id) : .processing(session.id)
        if self.failStop { throw TestError.captureStopFailed }
    }
}

@MainActor final class MeetingFloatingCaptionsPanel {
    func setFrame(_: NSRect, display _: Bool) {}
    func orderFrontRegardless() {}
    func orderOut(_: Any?) {}
}

@MainActor enum MeetingFloatingPanelFactory {
    static func make(size _: NSSize, resizable _: Bool, content _: AnyView, allowsKeyboardFocus _: Bool = false) -> MeetingFloatingCaptionsPanel { .init() }
}

@MainActor final class MeetingRecordingPillController {
    static let shared = MeetingRecordingPillController()
    var currentOverlayFrame: NSRect? { NSRect(x: 400, y: 64, width: 84, height: 32) }
}

@MainActor enum OverlayScreenResolver {
    static func screenForCurrentPointer() -> NSScreen? { nil }
}

struct AdaptiveAppTheme<Content: View>: View {
    let content: Content
    init(accent _: Color, @ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View { self.content }
}

struct MeetingStillRecordingNudgeContent: View {
    let controller: MeetingStillRecordingNudgeController
    var body: some View { EmptyView() }
}

@main @MainActor enum MeetingEndCountdownTests {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        self.checks += 1
        guard condition() else { fatalError(message) }
    }

    static func waitUntil(_ message: String, condition: () -> Bool) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        self.check(condition(), message)
    }

    static func main() async {
        self.deadlinesAndStaleTasks()
        self.sessionGate()
        self.systemAudioEndWatch()
        await self.callJoinedAfterRecordingStarts()
        await self.lateCallEvidenceMustBeUnambiguous()
        self.targetWithdrawalCannotRearmShutdown()
        await self.detectorEvidence()
        await self.controllerActions()
        await self.stopAction()
        print("PASS: \(self.checks) meeting end checks; real countdown/controller/detector, no capture or user defaults")
    }

    static func deadlinesAndStaleTasks() {
        var countdown = MeetingEndCountdown()
        let session = UUID()
        let ticket = countdown.begin(sessionID: session, now: 100)
        self.check(countdown.advance(ticket, now: 100, isEligible: true) == .waiting(30), "Starts at 30")
        self.check(countdown.advance(ticket, now: 100.01, isEligible: true) == .waiting(30), "Rounds remaining time up")
        self.check(countdown.advance(ticket, now: 129.99, isEligible: true) == .waiting(1), "Does not stop early")
        self.check(countdown.begin(sessionID: session, now: 120) == ticket, "Repeated evidence cannot restart the deadline")
        self.check(countdown.advance(ticket, now: 130, isEligible: true) == .stop(session), "Stops at the deadline")
        self.check(countdown.advance(ticket, now: 131, isEligible: true) == .stale, "Expiry is single-shot")
        let cancelled = countdown.begin(sessionID: session, now: 200)
        countdown.cancel()
        self.check(countdown.advance(cancelled, now: 240, isEligible: true) == .stale, "Dismissal invalidates the timer")
        let restarted = countdown.begin(sessionID: session, now: 250)
        self.check(restarted.generation != cancelled.generation, "Re-presentation of the same session has a new generation")
        self.check(countdown.advance(cancelled, now: 300, isEligible: true) == .stale, "Old same-session task cannot stop re-presentation")
        let next = countdown.begin(sessionID: UUID(), now: 260)
        self.check(countdown.advance(restarted, now: 300, isEligible: true) == .stale, "Old meeting cannot stop the next meeting")
        self.check(countdown.ticket == next, "Stale tasks cannot clear the current deadline")
        self.check(countdown.advance(next, now: 300, isEligible: false) == .cancelled, "Invalid evidence cancels even after expiry")
        self.check(countdown.ticket == nil, "Invalid evidence leaves no armed timer")
        let manual = countdown.begin(sessionID: session, now: 400)
        self.check(countdown.advance(manual, now: 401, isEligible: true, stopNow: true) == .stop(session), "Stop now uses the same single-shot action")
    }

    static func sessionGate() {
        let id = UUID()
        let call = MeetingSession(id: id, mode: .onlineCall)
        self.check(AppServices.recordingSessionID(state: .recording(id), session: call) == id, "Recording is eligible")
        self.check(AppServices.recordingSessionID(state: .recordingDegraded(id), session: call) == id, "Degraded recording is eligible")
        self.check(AppServices.recordingSessionID(state: .recording(UUID()), session: call) == nil, "Stale coordinator state cannot select the current session")
        self.check(AppServices.recordingSessionID(state: .recording(id), session: nil) == nil, "Missing session is ineligible")
        self.check(AppServices.recordingSessionID(state: .recording(id), session: .init(id: id, mode: .inRoom)) == nil, "In-room recordings never auto-stop")
        for state in [MeetingCoordinatorState.idle, .preparing, .stopping(id), .processing(id), .completed(id), .interrupted(id), .failed(id)] {
            self.check(AppServices.recordingSessionID(state: state, session: call) == nil, "Only a current recording is eligible")
        }
    }

    static func systemAudioEndWatch() {
        let h = DetectorHarness()
        _ = h.confirmChromeMeet()
        let id = UUID()
        let session = MeetingSession(id: id, mode: .systemAudio)
        self.check(AppServices.recordingSessionID(state: .recording(id), session: session) == id, "System audio is eligible for the countdown")
        self.check(AppServices.meetingEndWatchApplication(session: session, target: nil) == nil, "No detected call means no arbitrary end watch")
        let target = MeetingAutoDetector.ResolvedTarget(bundleIdentifier: "com.google.Chrome", pid: 8, windowID: nil)
        self.check(AppServices.meetingEndWatchApplication(session: session, target: target)?.processID == 8, "System capture watches the detected process")
        let appSession = MeetingSession(id: id, mode: .onlineCall, capturedApplication: .init(bundleIdentifier: "com.microsoft.teams2", processID: nil, displayName: "Teams", capturesAllInstances: true))
        self.check(AppServices.meetingEndWatchApplication(session: appSession, target: target) == nil, "App recording cannot watch another app's call")
        h.gate.isIdle = false
        AppServices.synchronizeMeetingEndWatch(state: .recording(id), session: session, detector: h.detector)
        h.detector.handleWorkspaceEvent(.init(kind: .terminated, bundleIdentifier: "com.google.Chrome", processID: 8), at: h.clock.now())
        h.detector.tick(at: h.clock.now())
        h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
        h.detector.tick(at: h.clock.now())
        self.check(h.detector.pendingEndConfirmationSessionID == id, "Detected call ending offers countdown for whole-computer recording")
        AppServices.synchronizeMeetingEndWatch(state: .recording(id), session: session, detector: h.detector)
        self.check(h.detector.pendingEndConfirmationSessionID == id, "Target disappearing does not detach an established watch")
        h.detector.stillRecordingNudgeDismissed(sessionID: id)
        self.check(!h.detector.canStopAfterEndConfirmation(sessionID: id), "Keep recording cancels system audio auto-stop")
        AppServices.synchronizeMeetingEndWatch(state: .completed(id), session: session, detector: h.detector)
        self.check(h.detector.pendingEndConfirmationSessionID == nil, "Finishing system audio tears down its watch")
    }

    static func callJoinedAfterRecordingStarts() async {
        for selectedApp in [nil, "com.google.Chrome"] as [String?] {
            let h = DetectorHarness()
            let id = UUID()
            let session = MeetingSession(
                id: id,
                mode: selectedApp == nil ? .systemAudio : .onlineCall,
                capturedApplication: selectedApp.map {
                    .init(bundleIdentifier: $0, processID: nil, displayName: "Chrome", capturesAllInstances: true)
                }
            )
            h.gate.isIdle = false
            AppServices.synchronizeMeetingEndWatch(state: .recording(id), session: session, detector: h.detector)
            // No device-wide microphone edge: FluidVoice already owns an open mic.
            h.workspace.frontmostProcessID = 8
            h.detector.handleBackfill([.init(kind: .launched, bundleIdentifier: "com.google.Chrome", processID: 8)])
            h.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: "/abc-defg-hij", callState: .inCall), pid: 8, bundleIdentifier: "com.google.Chrome", at: h.clock.now())
            await h.pollChrome(microphoneInUse: true)
            self.check(h.prompts.isEmpty && h.detector.automaticTarget == nil, "Late call observation cannot prompt or change the capture source")
            h.detector.handleWorkspaceEvent(.init(kind: .terminated, bundleIdentifier: "com.google.Chrome", processID: 8), at: h.clock.now())
            h.detector.tick(at: h.clock.now())
            h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
            h.detector.tick(at: h.clock.now())
            self.check(h.detector.pendingEndConfirmationSessionID == id, "Recording before joining still offers the call-end countdown")
            h.detector.stillRecordingNudgeDismissed(sessionID: id)
            self.check(!h.detector.canStopAfterEndConfirmation(sessionID: id), "Keep recording silences a late-attached watch")
        }
        for teardown in 0..<3 {
            let h = DetectorHarness()
            let id = UUID()
            h.gate.isIdle = false
            AppServices.synchronizeMeetingEndWatch(state: .recording(id), session: .init(id: id, mode: .systemAudio), detector: h.detector)
            switch teardown {
            case 0: h.detector.stop()
            case 1: h.detector.disarmAndClearTransientState()
            default: AppServices.synchronizeMeetingEndWatch(state: .completed(id), session: .init(id: id, mode: .systemAudio), detector: h.detector)
            }
            _ = h.confirmChromeMeet()
            await h.pollChrome(microphoneInUse: true)
            h.detector.handleWorkspaceEvent(.init(kind: .terminated, bundleIdentifier: "com.google.Chrome", processID: 8), at: h.clock.now())
            h.detector.tick(at: h.clock.now())
            h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
            h.detector.tick(at: h.clock.now())
            self.check(h.nudges == 0 && h.detector.pendingEndConfirmationSessionID == nil, "Teardown clears pending observation before a late call appears")
        }
        let other = DetectorHarness()
        let id = UUID()
        other.gate.isIdle = false
        let session = MeetingSession(id: id, mode: .onlineCall, capturedApplication: .init(bundleIdentifier: "us.zoom.xos", processID: nil, displayName: "Zoom", capturesAllInstances: true))
        AppServices.synchronizeMeetingEndWatch(state: .recording(id), session: session, detector: other.detector)
        _ = other.confirmChromeMeet()
        await other.pollChrome(microphoneInUse: true)
        other.detector.handleWorkspaceEvent(.init(kind: .terminated, bundleIdentifier: "com.google.Chrome", processID: 8), at: other.clock.now())
        other.detector.tick(at: other.clock.now())
        other.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
        other.detector.tick(at: other.clock.now())
        self.check(other.nudges == 0, "A call in another app cannot end the selected app's recording")
    }

    static func lateCallEvidenceMustBeUnambiguous() async {
        let h = DetectorHarness()
        h.nativeEnabled = false
        h.gate.isIdle = false
        let oldID = UUID(), id = UUID()
        AppServices.synchronizeMeetingEndWatch(state: .recording(oldID), session: .init(id: oldID, mode: .systemAudio), detector: h.detector)
        AppServices.synchronizeMeetingEndWatch(state: .recording(id), session: .init(id: id, mode: .systemAudio), detector: h.detector)
        h.workspace.frontmostProcessID = 8
        for (pid, bundle) in [(Int32(8), "com.google.Chrome"), (Int32(9), "com.apple.Safari")] {
            h.detector.handleBackfill([.init(kind: .launched, bundleIdentifier: bundle, processID: pid)])
            h.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: "/abc-defg-hij", callState: .inCall), pid: pid, bundleIdentifier: bundle, at: h.clock.now())
        }
        await h.pollChrome(microphoneInUse: true, readable: false)
        h.detector.tick(at: h.clock.now())
        self.check(h.detector.pendingEndConfirmationSessionID == nil && h.prompts.isEmpty, "Unknown audio cannot attach a late watch or raise a prompt")
        let owners = [
            MeetingProcessOwner(processID: 8, bundleIdentifier: "com.google.Chrome", bundlePath: "/Applications/Chrome.app"),
            MeetingProcessOwner(processID: 9, bundleIdentifier: "com.apple.Safari", bundlePath: "/Applications/Safari.app"),
        ]
        let processes = [
            AudioProcessDescriptor(processID: 80, bundleIdentifier: "com.google.Chrome.helper", executablePath: "/Applications/Chrome.app/Contents/Helpers/audio", isInputRunning: true, isOutputRunning: true),
            AudioProcessDescriptor(processID: 90, bundleIdentifier: "com.apple.Safari", executablePath: "/Applications/Safari.app/Contents/MacOS/Safari", isInputRunning: true, isOutputRunning: true),
        ]
        h.audioProcessActivity.snapshotOverride = .init(processes: processes, owners: owners, queryState: .valid)
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        // Ending Chrome would offer a countdown if dictionary iteration chose it arbitrarily.
        h.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: "/abc-defg-hij", callState: .ended), pid: 8, bundleIdentifier: "com.google.Chrome", at: h.clock.now())
        h.advance(MeetingAutoDetector.browserPostCallGraceSeconds + 1)
        h.detector.tick(at: h.clock.now())
        self.check(h.nudges == 0, "Two live calls cannot arbitrarily select one for automatic stop")
        h.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: "/abc-defg-hij", callState: .inCall), pid: 8, bundleIdentifier: "com.google.Chrome", at: h.clock.now())
        h.audioProcessActivity.snapshotOverride = .init(processes: [processes[0]], owners: owners, queryState: .valid)
        await h.detector.pollAudioProcessActivity(at: h.clock.now())
        h.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: "/abc-defg-hij", callState: .ended), pid: 8, bundleIdentifier: "com.google.Chrome", at: h.clock.now())
        h.advance(MeetingAutoDetector.browserPostCallGraceSeconds + 1)
        h.detector.tick(at: h.clock.now())
        self.check(h.detector.pendingEndConfirmationSessionID == id, "A single attributable browser call attaches to the latest session with native detection disabled")
        self.check(!h.detector.canStopAfterEndConfirmation(sessionID: oldID), "Replaced pending session cannot receive the end countdown")
        self.check(h.prompts.isEmpty && h.detector.automaticTarget == nil, "Late watch never changes automatic source or admits a start prompt")

        let native = DetectorHarness()
        native.gate.isIdle = false
        let nativeID = UUID()
        AppServices.synchronizeMeetingEndWatch(state: .recording(nativeID), session: .init(id: nativeID, mode: .systemAudio), detector: native.detector)
        _ = native.confirmTeams()
        native.detector.handleAudioProcessActivity(true, pid: 300, at: native.clock.now())
        native.detector.handleAudioProcessActivity(false, pid: 300, at: native.clock.now())
        native.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
        native.detector.tick(at: native.clock.now())
        self.check(native.detector.pendingEndConfirmationSessionID == nativeID && native.prompts.isEmpty, "Late native call uses attributed process audio without a start prompt")
    }

    static func targetWithdrawalCannotRearmShutdown() {
        let h = DetectorHarness()
        _ = h.confirmChromeMeet()
        let services = AppServices()
        let coordinator = MeetingSessionCoordinator()
        let id = UUID()
        coordinator.state = .recording(id)
        coordinator.activeSession = .init(id: id, mode: .onlineCall, capturedApplication: .init(bundleIdentifier: "com.google.Chrome", processID: 8, displayName: "Chrome"))
        services._meetingSessionCoordinator = coordinator
        services._meetingAutoDetector = h.detector
        services.wireTarget(h.detector)
        AppServices.synchronizeMeetingEndWatch(state: coordinator.state, session: coordinator.activeSession, detector: h.detector)
        h.detector.stop()
        self.check(services.meetingAutomaticTarget == nil, "Detector teardown clears the displayed suggestion")
        h.detector.handleWorkspaceEvent(.init(kind: .terminated, bundleIdentifier: "com.google.Chrome", processID: 8), at: h.clock.now())
        h.detector.tick(at: h.clock.now())
        h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
        h.detector.tick(at: h.clock.now())
        self.check(h.nudges == 0, "Target withdrawal during shutdown must not re-arm automatic stop")
    }

    static func pendingCall() -> (DetectorHarness, UUID) {
        let h = DetectorHarness()
        let session = UUID()
        h.gate.isIdle = false
        h.detector.recordingStarted(sessionID: session, application: .init(bundleIdentifier: "com.microsoft.teams2", processID: 300, displayName: "Teams"))
        h.detector.handleAudioProcessActivity(true, pid: 300, at: h.clock.now())
        h.detector.handleAudioProcessActivity(false, pid: 300, at: h.clock.now())
        h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
        h.detector.tick(at: h.clock.now())
        self.check(h.nudges == 1, "Observed end offers one countdown")
        self.check(h.prompts.isEmpty && !h.gate.isIdle, "End observation does not start capture or release its activity")
        return (h, session)
    }

    static func detectorEvidence() async {
        do {
            let (h, session) = self.pendingCall()
            self.check(h.detector.pendingEndConfirmationSessionID == session, "Prompt belongs to the recording")
            self.check(!h.detector.canStopAfterEndConfirmation(sessionID: UUID()), "Other session cannot consume end evidence")
            h.detector.stillRecordingNudgeDismissed(sessionID: UUID())
            self.check(h.detector.canStopAfterEndConfirmation(sessionID: session), "Stale dismissal cannot silence the recording")
            h.detector.stillRecordingNudgeDismissed(sessionID: session)
            self.check(!h.detector.canStopAfterEndConfirmation(sessionID: session), "Keep recording disarms automatic stop")
            h.advance(600)
            h.detector.tick(at: h.clock.now())
            self.check(h.nudges == 1, "Keep recording stays honored for this recording")
        }
        do {
            let (h, session) = self.pendingCall()
            h.detector.handleAudioProcessActivity(true, pid: 300, at: h.clock.now())
            self.check(!h.detector.canStopAfterEndConfirmation(sessionID: session), "Expiry rechecks a resumed call without waiting for another tick")
            self.check(h.withdrawals == 1, "Resumed call withdraws countdown exactly once")
            h.detector.tick(at: h.clock.now())
            self.check(h.withdrawals == 1, "Repeated resume evidence does not repeat withdrawal")
        }
        do {
            let (h, session) = self.pendingCall()
            h.flags.lastSpeechAt = h.clock.now()
            self.check(!h.detector.canStopAfterEndConfirmation(sessionID: session), "New speech cancels ambiguous end evidence")
            self.check(h.withdrawals == 1, "Fresh speech hides countdown")
        }
        do {
            let (h, session) = self.pendingCall()
            h.audioProcessActivity.snapshotOverride = .init(processes: [], owners: [], queryState: .unknown)
            await h.detector.pollAudioProcessActivity(at: h.clock.now())
            self.check(!h.detector.canStopAfterEndConfirmation(sessionID: session), "Unknown audio cannot authorize automatic stop")
            self.check(h.withdrawals == 1, "Unknown query withdraws countdown")
        }
        for stop in 0..<3 {
            let (h, session) = self.pendingCall()
            switch stop {
            case 0: h.detector.disarmAndClearTransientState()
            case 1: h.detector.stop()
            default: h.detector.recordingStopped()
            }
            self.check(!h.detector.canStopAfterEndConfirmation(sessionID: session), "Lock, disable and stop invalidate end evidence")
            self.check(h.withdrawals == 1, "Teardown withdraws pending countdown")
        }
        do {
            let (h, session) = self.pendingCall()
            let next = UUID()
            h.detector.recordingStarted(sessionID: next, application: .init(bundleIdentifier: "com.microsoft.teams2", processID: 300, displayName: "Teams"))
            self.check(!h.detector.canStopAfterEndConfirmation(sessionID: session), "Replacement recording invalidates prior end evidence")
            self.check(h.withdrawals == 1, "Replacement hides old countdown")
            self.check(!h.detector.canStopAfterEndConfirmation(sessionID: next), "New recording needs its own end evidence")
        }
        do {
            let h = DetectorHarness()
            _ = h.confirmChromeMeet()
            let session = UUID()
            h.gate.isIdle = false
            h.detector.recordingStarted(sessionID: session, application: .init(bundleIdentifier: "com.google.Chrome", processID: 8, displayName: "Chrome"))
            await h.pollChrome(microphoneInUse: true)
            await h.pollChrome(microphoneInUse: false)
            h.advance(MeetingAutoDetector.endSignalGraceSeconds + 1)
            h.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: "/abc-defg-hij", callState: .ended), pid: 8, bundleIdentifier: "com.google.Chrome", at: h.clock.now())
            h.advance(MeetingAutoDetector.browserPostCallGraceSeconds + 1)
            h.detector.tick(at: h.clock.now())
            self.check(h.detector.canStopAfterEndConfirmation(sessionID: session), "Positive browser end starts countdown")
            h.detector.handleBrowserTabURL(.init(host: "meet.google.com", path: "/abc-defg-hij", callState: .inCall), pid: 8, bundleIdentifier: "com.google.Chrome", at: h.clock.now())
            self.check(h.withdrawals == 1, "Positive rejoin immediately cancels countdown")
            self.check(!h.detector.canStopAfterEndConfirmation(sessionID: session), "Old microphone-release evidence cannot stop a rejoined call")
        }
    }

    static func controllerActions() async {
        var clock: TimeInterval = 100
        var stopped: [UUID] = []
        var dismissed: [UUID] = []
        var eligible = true
        let controller = MeetingStillRecordingNudgeController(now: { clock })
        controller.shouldContinueCountdown = { _ in eligible }
        controller.onStop = { stopped.append($0) }
        controller.onDismiss = { dismissed.append($0) }
        let first = UUID()
        controller.present(sessionID: first)
        self.check(controller.isPresented && controller.secondsRemaining == 30, "Controller starts a visible 30-second countdown")
        clock = 110
        controller.present(sessionID: first)
        clock = 130
        await self.waitUntil("Controller fires the original deadline") { stopped == [first] }
        self.check(!controller.isPresented && dismissed.isEmpty, "Expiry hides without recording a user dismissal")
        controller.stopNow()
        self.check(stopped == [first], "Repeated Stop now cannot stop again")

        let second = UUID()
        controller.present(sessionID: second)
        controller.dismiss(presentationID: controller.presentationID)
        self.check(dismissed == [second] && !controller.isPresented, "Keep recording cancels and identifies the recording")
        controller.dismiss()
        self.check(dismissed == [second], "Stale Keep recording is ignored")
        clock = 200
        controller.present(sessionID: second)
        let oldPresentation = controller.presentationID
        clock = 210
        let third = UUID()
        controller.present(sessionID: third)
        controller.dismiss(presentationID: oldPresentation)
        controller.stopNow(presentationID: oldPresentation)
        self.check(controller.isPresented && dismissed == [second] && stopped == [first], "Stale button actions cannot dismiss or stop replacement")
        clock = 230
        await self.waitUntil("Replacement has its own full deadline") { controller.secondsRemaining == 10 }
        self.check(stopped == [first], "Old deadline cannot stop replacement")
        controller.stopNow(presentationID: controller.presentationID)
        self.check(stopped == [first, third], "Stop now targets the replacement only")

        controller.present(sessionID: UUID())
        eligible = false
        clock += 31
        await self.waitUntil("Eligibility loss cancels controller") { !controller.isPresented }
        self.check(stopped == [first, third], "Invalid expiry never stops recording")
        eligible = true
        controller.present(sessionID: first)
        controller.synchronizeRecording(sessionID: UUID())
        self.check(!controller.isPresented, "Rapid coordinator session replacement cancels countdown")
        controller.present(sessionID: first)
        SettingsStore.shared.fluidMeetEnabled = false
        clock += 31
        await self.waitUntil("Feature disable cancels controller") { !controller.isPresented }
        self.check(stopped == [first, third], "Disabling feature cannot stop a meeting")
        SettingsStore.shared.fluidMeetEnabled = true
    }

    static func stopAction() async {
        for scenario in 0..<6 {
            let (h, id) = self.pendingCall()
            let services = AppServices()
            let coordinator = MeetingSessionCoordinator()
            coordinator.state = .recording(id)
            coordinator.activeSession = MeetingSession(id: id, mode: .onlineCall)
            services._meetingSessionCoordinator = coordinator
            services._meetingAutoDetector = h.detector
            switch scenario {
            case 1:
                let next = UUID()
                coordinator.activeSession = .init(id: next, mode: .onlineCall)
                coordinator.state = .recording(next)
            case 2: coordinator.state = .processing(id)
            case 3: SettingsStore.shared.fluidMeetEnabled = false
            case 4: h.detector.handleAudioProcessActivity(true, pid: 300, at: h.clock.now())
            case 5: coordinator.failStop = true
            default: break
            }
            await services.stopMeetingAfterEndConfirmation(sessionID: id)
            await services.stopMeetingAfterEndConfirmation(sessionID: id)
            let expected = scenario == 0 || scenario == 5 ? [id] : []
            self.check(coordinator.stopped == expected, "Stop action rechecks current session, recording state, feature and evidence; no duplicate/retry (\(scenario))")
            if scenario == 5 { self.check(coordinator.state == .interrupted(id), "Capture failure leaves existing recovery state visible") }
            SettingsStore.shared.fluidMeetEnabled = true
        }
        let services = AppServices()
        await services.stopMeetingAfterEndConfirmation(sessionID: UUID())
        self.check(services._meetingSessionCoordinator == nil, "Stop never materializes a missing coordinator")
    }
}
