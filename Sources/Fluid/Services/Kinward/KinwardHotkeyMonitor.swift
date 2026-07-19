import AppKit
import Carbon

/// A single, dedicated system-wide hotkey for Kinward Mode, registered via the Carbon Event
/// Manager (RegisterEventHotKey) rather than by extending the existing GlobalHotkeyManager.
///
/// GlobalHotkeyManager already tracks several modifier-hold gestures (dictation, prompt mode,
/// command mode, rewrite mode) with a fair amount of interdependent state. Threading a fifth mode
/// through it blind - without being able to build and test on macOS from here - risked breaking
/// the existing shortcuts. This monitor is intentionally standalone: press-to-talk, not
/// hold-to-talk, on a fixed default combo (Option+Command+K). Making the combo user-customizable
/// (reusing HotkeyShortcut/the existing shortcut-recorder UI) is a reasonable follow-up once the
/// core loop is proven, not a blocker for it.
@MainActor
final class KinwardHotkeyMonitor {
    static let shared = KinwardHotkeyMonitor()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// 'KNWD' as a four-char-code OSType, Carbon's convention for identifying who owns a hotkey.
    private static let signature: OSType = 0x4B4E5744
    private static let hotKeyID = EventHotKeyID(signature: signature, id: 1)

    /// kVK_ANSI_K
    private static let defaultKeyCode: UInt32 = 40
    private static let defaultModifiers: UInt32 = UInt32(optionKey | cmdKey)

    private init() {}

    func start() {
        guard SettingsStore.shared.kinwardHotkeyEnabled else { return }
        guard self.hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData -> OSStatus in
                guard let eventRef, let userData else { return noErr }
                var receivedID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &receivedID
                )
                guard status == noErr, receivedID.id == KinwardHotkeyMonitor.hotKeyID.id else { return noErr }
                let monitor = Unmanaged<KinwardHotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in monitor.fire() }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &self.eventHandler
        )
        guard installStatus == noErr else {
            DebugLogger.shared.error("KinwardHotkeyMonitor: InstallEventHandler failed (\(installStatus))", source: "KinwardHotkey")
            return
        }

        let registerStatus = RegisterEventHotKey(
            Self.defaultKeyCode,
            Self.defaultModifiers,
            Self.hotKeyID,
            GetApplicationEventTarget(),
            0,
            &self.hotKeyRef
        )
        guard registerStatus == noErr else {
            DebugLogger.shared.error("KinwardHotkeyMonitor: RegisterEventHotKey failed (\(registerStatus)) - likely already claimed by another app", source: "KinwardHotkey")
            return
        }

        DebugLogger.shared.info("KinwardHotkeyMonitor: registered Option+Command+K", source: "KinwardHotkey")
    }

    func stop() {
        if let ref = self.hotKeyRef {
            UnregisterEventHotKey(ref)
            self.hotKeyRef = nil
        }
        if let handler = self.eventHandler {
            RemoveEventHandler(handler)
            self.eventHandler = nil
        }
    }

    func restart() {
        self.stop()
        self.start()
    }

    private func fire() {
        KinwardModeService.shared.toggleTurn()
    }
}
