import CoreGraphics
import Foundation

final class DictationStartProbe: @unchecked Sendable {
    static let shared = DictationStartProbe()

    private struct InputEvent {
        let kind: String
        let uptime: TimeInterval
    }

    private let lock = NSLock()
    private var lastInputEvent: InputEvent?
    private var activeEvent: InputEvent?
    private var activeTriggerLabel: String?
    private var firstTapBufferLogged = false
    private var firstAudioLogged = false

    private init() {}

    func markInputEvent(type: CGEventType, uptime: TimeInterval) {
        self.lock.lock()
        self.lastInputEvent = InputEvent(kind: Self.eventName(type), uptime: uptime)
        self.lock.unlock()
    }

    func markStartTrigger(label: String) {
        let now = ProcessInfo.processInfo.systemUptime
        self.lock.lock()
        self.activeEvent = self.lastInputEvent
        self.activeTriggerLabel = label
        self.firstTapBufferLogged = false
        self.firstAudioLogged = false
        let event = self.activeEvent
        self.lock.unlock()

        let eventDelta = Self.deltaMilliseconds(from: event?.uptime, to: now)
        DebugLogger.shared.benchmark(
            "START_LATENCY",
            message: "trigger label=\(label) event=\(event?.kind ?? "unknown") eventToTriggerMs=\(eventDelta)",
            source: "DictationStartProbe"
        )
    }

    func markASRStart(session: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        let snapshot = self.snapshot()
        DebugLogger.shared.benchmark(
            "START_LATENCY",
            message: "asr_start_enter session=\(session) label=\(snapshot.label) eventToASRStartMs=\(Self.deltaMilliseconds(from: snapshot.eventUptime, to: now))",
            source: "DictationStartProbe"
        )
    }

    func markCaptureEnabled(session: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        let snapshot = self.snapshot()
        DebugLogger.shared.benchmark(
            "START_LATENCY",
            message: "capture_enabled session=\(session) label=\(snapshot.label) eventToCaptureEnabledMs=\(Self.deltaMilliseconds(from: snapshot.eventUptime, to: now))",
            source: "DictationStartProbe"
        )
    }

    func markTapInstalled(session: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        let snapshot = self.snapshot()
        DebugLogger.shared.benchmark(
            "START_LATENCY",
            message: "tap_installed session=\(session) label=\(snapshot.label) eventToTapInstalledMs=\(Self.deltaMilliseconds(from: snapshot.eventUptime, to: now))",
            source: "DictationStartProbe"
        )
    }

    func markFirstTapBuffer(frameLength: Int, sampleRate: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        self.lock.lock()
        guard self.firstTapBufferLogged == false else {
            self.lock.unlock()
            return
        }
        self.firstTapBufferLogged = true
        let event = self.activeEvent
        let label = self.activeTriggerLabel ?? "unknown"
        self.lock.unlock()

        let callbackDelta = Self.deltaMilliseconds(from: event?.uptime, to: now)
        let bufferDuration = Self.bufferDurationMilliseconds(frameLength: frameLength, sampleRate: sampleRate)
        let estimatedFirstSampleDelta = callbackDelta >= 0 && bufferDuration >= 0
            ? callbackDelta - bufferDuration
            : -1
        DebugLogger.shared.benchmark(
            "START_LATENCY",
            message: "first_tap_buffer label=\(label) frames=\(frameLength) " +
                "sampleRate=\(Int(sampleRate.rounded())) event=\(event?.kind ?? "unknown") " +
                "eventToFirstTapBufferMs=\(callbackDelta) bufferMs=\(bufferDuration) " +
                "estimatedEventToFirstSampleMs=\(estimatedFirstSampleDelta)",
            source: "DictationStartProbe"
        )
    }

    func markFirstAudio(sampleCount: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        self.lock.lock()
        guard self.firstAudioLogged == false else {
            self.lock.unlock()
            return
        }
        self.firstAudioLogged = true
        let event = self.activeEvent
        let label = self.activeTriggerLabel ?? "unknown"
        self.lock.unlock()

        DebugLogger.shared.benchmark(
            "START_LATENCY",
            message: "first_audio label=\(label) samples=\(sampleCount) event=\(event?.kind ?? "unknown") eventToFirstAudioMs=\(Self.deltaMilliseconds(from: event?.uptime, to: now))",
            source: "DictationStartProbe"
        )
    }

    private func snapshot() -> (eventUptime: TimeInterval?, label: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        return (self.activeEvent?.uptime, self.activeTriggerLabel ?? "unknown")
    }

    private static func deltaMilliseconds(from start: TimeInterval?, to end: TimeInterval) -> Int {
        guard let start else { return -1 }
        return Int(((end - start) * 1000).rounded())
    }

    private static func bufferDurationMilliseconds(frameLength: Int, sampleRate: Double) -> Int {
        guard sampleRate > 0 else { return -1 }
        return Int(((Double(frameLength) / sampleRate) * 1000).rounded())
    }

    private static func eventName(_ type: CGEventType) -> String {
        switch type {
        case .keyDown: return "keyDown"
        case .keyUp: return "keyUp"
        case .flagsChanged: return "flagsChanged"
        case .leftMouseDown: return "leftMouseDown"
        case .leftMouseUp: return "leftMouseUp"
        case .rightMouseDown: return "rightMouseDown"
        case .rightMouseUp: return "rightMouseUp"
        case .otherMouseDown: return "otherMouseDown"
        case .otherMouseUp: return "otherMouseUp"
        default: return "event\(type.rawValue)"
        }
    }
}
