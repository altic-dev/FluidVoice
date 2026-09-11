import AppKit
import Carbon

/// Only chords Carbon can represent belong here. Plain keys must remain available to
/// other apps, and Fn / side-specific modifiers still need the event-tap backend.
struct RegisteredHotkeyChord: Hashable {
    let keyCode: UInt16
    let modifiers: UInt32

    init?(_ shortcut: HotkeyShortcut) {
        let flags = shortcut.relevantModifierFlags
        guard !shortcut.isMouseShortcut, !shortcut.isModifierOnlyShortcut,
              shortcut.normalizedModifierKeyCodes.isEmpty,
              !flags.isEmpty, !flags.contains(.function)
        else { return nil }
        self.keyCode = shortcut.keyCode
        self.modifiers = (flags.contains(.command) ? UInt32(cmdKey) : 0)
            | (flags.contains(.option) ? UInt32(optionKey) : 0)
            | (flags.contains(.control) ? UInt32(controlKey) : 0)
            | (flags.contains(.shift) ? UInt32(shiftKey) : 0)
    }

    var shortcut: HotkeyShortcut {
        var flags: NSEvent.ModifierFlags = []
        if self.modifiers & UInt32(cmdKey) != 0 {
            flags.insert(.command)
        }
        if self.modifiers & UInt32(optionKey) != 0 {
            flags.insert(.option)
        }
        if self.modifiers & UInt32(controlKey) != 0 {
            flags.insert(.control)
        }
        if self.modifiers & UInt32(shiftKey) != 0 {
            flags.insert(.shift)
        }
        return HotkeyShortcut(keyCode: self.keyCode, modifierFlags: flags)
    }
}

@MainActor
protocol RegisteredHotkeyDriver: AnyObject {
    var onEvent: ((UInt32, Bool) -> Void)? { get set }
    func register(_ chord: RegisteredHotkeyChord, id: UInt32) -> OSStatus
    func unregister(id: UInt32)
}

/// Carbon delivers only the explicitly registered chord, including while Secure
/// Event Input prevents general keyboard observation. All calls run on the main loop.
@MainActor
final class CarbonHotkeyDriver: RegisteredHotkeyDriver {
    typealias RegisterHotkey = (UInt32, UInt32, EventHotKeyID, EventTargetRef?, OptionBits, UnsafeMutablePointer<EventHotKeyRef?>?) -> OSStatus

    private let registerHotkey: RegisterHotkey

    init(registerHotkey: @escaping RegisterHotkey = RegisterEventHotKey) {
        self.registerHotkey = registerHotkey
    }

    private let signature: OSType = UInt32.random(in: 1...UInt32.max)
    var onEvent: ((UInt32, Bool) -> Void)?
    private nonisolated(unsafe) var handler: EventHandlerRef?
    private nonisolated(unsafe) var references: [UInt32: EventHotKeyRef] = [:]

    func register(_ chord: RegisteredHotkeyChord, id: UInt32) -> OSStatus {
        if self.handler == nil {
            var types = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
            ]
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, context in
                    guard let event, let context else { return OSStatus(eventNotHandledErr) }
                    return MainActor.assumeIsolated {
                        let driver = Unmanaged<CarbonHotkeyDriver>.fromOpaque(context).takeUnretainedValue()
                        var hotkeyID = EventHotKeyID()
                        let result = GetEventParameter(
                            event,
                            EventParamName(kEventParamDirectObject),
                            EventParamType(typeEventHotKeyID),
                            nil,
                            MemoryLayout<EventHotKeyID>.size,
                            nil,
                            &hotkeyID
                        )
                        guard result == noErr, hotkeyID.signature == driver.signature,
                              driver.references[hotkeyID.id] != nil
                        else {
                            return OSStatus(eventNotHandledErr)
                        }
                        driver.onEvent?(hotkeyID.id, GetEventKind(event) == UInt32(kEventHotKeyPressed))
                        return noErr
                    }
                },
                types.count,
                &types,
                Unmanaged.passUnretained(self).toOpaque(),
                &self.handler
            )
            guard status == noErr else { return status }
        }
        var reference: EventHotKeyRef?
        let status = self.registerHotkey(
            UInt32(chord.keyCode),
            chord.modifiers,
            EventHotKeyID(signature: self.signature, id: id),
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &reference
        )
        if status == noErr, let reference {
            self.references[id] = reference
        }
        return status
    }

    func unregister(id: UInt32) {
        if let reference = self.references.removeValue(forKey: id) {
            UnregisterEventHotKey(reference)
        }
    }

    deinit {
        for reference in references.values {
            UnregisterEventHotKey(reference)
        }
        if let handler {
            RemoveEventHandler(handler)
        }
    }
}

/// Owns routing as well as registrations: a successfully registered chord is never
/// also handled by the event tap. Failed registrations retain the legacy path.
@MainActor
final class RegisteredHotkeys {
    private let driver: RegisteredHotkeyDriver
    private let notificationCenter: NotificationCenter
    private nonisolated(unsafe) var sessionObservers: [NSObjectProtocol] = []
    private var registrations: [RegisteredHotkeyChord: UInt32] = [:]
    private var pressed: Set<UInt32> = []
    private var bypassedKeyCodes: Set<UInt16> = []
    private var nextID: UInt32 = 1
    private(set) var isInterruptingPress = false
    var onEvent: ((HotkeyShortcut, Bool) -> Void)?
    var onFailure: ((HotkeyShortcut, OSStatus) -> Void)?

    init(driver: RegisteredHotkeyDriver, notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.driver = driver
        self.notificationCenter = notificationCenter
        driver.onEvent = { [weak self] id, down in self?.receive(id: id, down: down) }
        // Key-up can be lost across sleep or fast user switching. Finish held
        // actions both before leaving and on return, without rebuilding healthy
        // registrations or treating the interruption as an Automatic-mode tap.
        for name in [
            NSWorkspace.willSleepNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            self.sessionObservers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.releaseAll(interrupted: true)
                }
            })
        }
    }

    deinit {
        for observer in sessionObservers {
            notificationCenter.removeObserver(observer)
        }
    }

    func update(shortcuts: [HotkeyShortcut]) {
        let desired = Set(shortcuts.compactMap(RegisteredHotkeyChord.init))
        for (chord, id) in self.registrations where !desired.contains(chord) {
            // Complete a held shortcut before its configuration disappears.
            self.receive(id: id, down: false)
            self.driver.unregister(id: id)
            self.registrations.removeValue(forKey: chord)
        }
        for chord in desired where self.registrations[chord] == nil {
            let id = self.nextID
            self.nextID += 1
            let status = self.driver.register(chord, id: id)
            if status == noErr {
                self.registrations[chord] = id
            } else {
                self.onFailure?(chord.shortcut, status)
            }
        }
    }

    func receive(id: UInt32, down: Bool) {
        guard let chord = self.registrations.first(where: { $0.value == id })?.key else { return }
        if down {
            guard self.pressed.insert(id).inserted else { return } // no autorepeat
        } else {
            guard self.pressed.remove(id) != nil else { return }
        }
        self.onEvent?(chord.shortcut, down)
    }

    func shouldBypassEventTap(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, down: Bool) -> Bool {
        if !down {
            // Remember ownership even if modifiers are released first or the
            // Carbon release callback has already run.
            return self.bypassedKeyCodes.remove(keyCode) != nil
        }
        guard let chord = RegisteredHotkeyChord(HotkeyShortcut(keyCode: keyCode, modifierFlags: modifiers)),
              self.registrations[chord] != nil
        else { return false }
        self.bypassedKeyCodes.insert(keyCode)
        return true
    }

    var hasPressedShortcut: Bool {
        !self.pressed.isEmpty
    }

    func releaseAll(interrupted: Bool = false) {
        // The callback runs synchronously, so recording logic can distinguish an
        // interruption from a physical release without losing the held state.
        let previous = self.isInterruptingPress
        self.isInterruptingPress = interrupted
        defer { self.isInterruptingPress = previous }
        for id in self.pressed {
            self.receive(id: id, down: false)
        }
        self.bypassedKeyCodes.removeAll()
    }
}
