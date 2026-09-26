import AppKit
import Foundation

// Temporary close-path diagnostics. Store checkpoints before emitting one line;
// never include transcript, application identity, or audio in these records.
struct OverlayCloseTrace {
    private let name: String
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var previous = ProcessInfo.processInfo.systemUptime
    private var checkpoints: [(String, Double)] = []

    init(_ name: String) { self.name = name }

    mutating func mark(_ phase: String, since: TimeInterval? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        self.checkpoints.append((phase, (now - (since ?? self.previous)) * 1000))
        self.previous = now
    }

    mutating func finish() {
        guard DebugLogger.diagnosticsEnabled else { return }
        let total = (ProcessInfo.processInfo.systemUptime - self.startedAt) * 1000
        let fields = self.checkpoints.map { "\($0.0)Ms=\(String(format: "%.3f", $0.1))" }.joined(separator: " ")
        DebugLogger.shared.debug("CLOSE_DETAIL scope=\(self.name) uptime=\(self.startedAt) totalMs=\(String(format: "%.3f", total)) \(fields)", source: "StopTiming")
    }
}

// Temporary, bounded main-run-loop probe. Both observer and removal run only
// on the main thread. Ignore sleep intervals; report occupied intervals >8ms.
@MainActor
enum OverlayCloseRunLoopProbe {
    private static var observer: CFRunLoopObserver?

    static func begin() {
        guard DebugLogger.diagnosticsEnabled, self.observer == nil else { return }
        let state = ProbeState()
        guard let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, 0, { _, activity in
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = (now - state.previousAt) * 1000
            if state.previousPhase != CFRunLoopActivity.beforeWaiting.rawValue, elapsed > 8 {
                DebugLogger.shared.debug(
                    "CLOSE_DETAIL runLoop fromPhase=\(state.previousPhase) toPhase=\(activity.rawValue) startUptime=\(state.previousAt) occupiedMs=\(elapsed)",
                    source: "StopTiming"
                )
            }
            state.previousAt = now
            state.previousPhase = activity.rawValue
        }) else { return }
        self.observer = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = nil
        }
    }

    private final class ProbeState: @unchecked Sendable {
        var previousAt = ProcessInfo.processInfo.systemUptime
        var previousPhase: CFOptionFlags = 0
    }
}

enum OverlayShortcutResolver {
    static func shortcutDisplay(for mode: OverlayMode, settings: SettingsStore = .shared) -> String {
        switch mode {
        case .dictation:
            return settings.primaryDictationShortcutDisplayString
        case .edit, .write, .rewrite:
            return settings.rewriteModeHotkeyShortcut.displayString
        case .command:
            return settings.commandModeHotkeyShortcut?.displayString ?? "Not set"
        }
    }
}

enum RecordingOverlayHideOutcome: Equatable {
    case hidden
    case superseded
}

final class BottomOverlayPanel: NSPanel {
    var allowsOffscreenParking = false

    /// Users drag the overlay off a screen edge to get it out of the way, so AppKit's
    /// default "keep the window on screen" clamping must be bypassed for user moves too.
    var allowsUserDragging = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        self.allowsOffscreenParking || self.allowsUserDragging
            ? frameRect
            : super.constrainFrameRect(frameRect, to: screen)
    }
}
