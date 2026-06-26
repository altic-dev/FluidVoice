import AppKit
import Carbon
import Foundation

struct HotkeyShortcut: Codable, Equatable {
    enum ShortcutKind: String, Codable {
        case keyboard
        case mouse
    }

    private(set) var kind: ShortcutKind
    var keyCode: UInt16
    var modifierFlags: NSEvent.ModifierFlags
    var modifierKeyCodes: [UInt16]
    private(set) var mouseButton: Int?
    enum CodingKeys: String, CodingKey { case kind, keyCode, modifierFlagsRawValue, modifierKeyCodes, mouseButton }

    var displayString: String {
        if self.isMouseShortcut, let mouseButton {
            var parts = Self.modifierDisplayParts(for: self.relevantModifierFlags)
            parts.append(Self.mouseButtonToString(mouseButton))
            return parts.joined(separator: " + ")
        }

        let modifierKeyCodes = self.normalizedModifierKeyCodes
        let modifierParts = modifierKeyCodes.compactMap(Self.keyCodeToString)
        if !modifierParts.isEmpty {
            return modifierParts.joined(separator: " + ")
        }

        var parts = Self.modifierDisplayParts(for: self.modifierFlags)
        parts.append(Self.keyCodeToString(self.keyCode) ?? "?")

        if self.modifierFlags.isEmpty {
            return parts.last ?? "Unknown"
        }

        return parts.joined(separator: " + ")
    }

    static func keyCodeToString(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"
        case 53: return "Escape"
        case 55: return "Left ⌘"
        case 54: return "Right ⌘"
        case 58: return "Left ⌥"
        case 61: return "Right ⌥"
        case 59: return "Left ⌃"
        case 62: return "Right ⌃"
        case 56: return "Left ⇧"
        case 60: return "Right ⇧"
        case 63: return "fn"
        case 123: return "Left"
        case 124: return "Right"
        case 125: return "Down"
        case 126: return "Up"
        default: return self.characterForKeyCode(keyCode) ?? self.qwertyFallback[keyCode]
        }
    }

    static func mouseButtonToString(_ button: Int) -> String {
        switch button {
        case 0: return "Left Click"
        case 1: return "Right Click"
        case 2: return "Middle Click"
        default: return "Mouse \(button + 1)"
        }
    }

    private static func modifierDisplayParts(for flags: NSEvent.ModifierFlags) -> [String] {
        var parts: [String] = []
        if flags.contains(.function) { parts.append("🌐") }
        if flags.contains(.command) { parts.append("⌘") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.shift) { parts.append("⇧") }
        return parts
    }

    /// US QWERTY names used when TIS layout data is unavailable (e.g. emoji/CJK input sources).
    private static let qwertyFallback: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 10: "§", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
        32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K",
        41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
    ]

    /// Uses the current keyboard layout to resolve a key code to its displayed character.
    static func characterForKeyCode(_ keyCode: UInt16) -> String? {
        guard let sourceRef = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawPtr = TISGetInputSourceProperty(sourceRef, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = Unmanaged<CFData>.fromOpaque(rawPtr).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { buffer -> String? in
            guard let layoutPtr = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layoutPtr,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
            guard status == noErr, length > 0 else { return nil }
            let raw = String(utf16CodeUnits: chars, count: length)
            guard !raw.isEmpty, !raw.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
                return nil
            }
            let upper = raw.uppercased()
            return upper.count == raw.count ? upper : raw
        }
    }

    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, modifierKeyCodes: [UInt16] = []) {
        self.kind = .keyboard
        self.mouseButton = nil
        let normalizedModifierKeyCodes = Self.normalizedModifierKeyCodes(from: modifierKeyCodes)
        if !normalizedModifierKeyCodes.isEmpty {
            self.modifierKeyCodes = normalizedModifierKeyCodes
            self.keyCode = normalizedModifierKeyCodes.first ?? keyCode

            let combinedFlags = normalizedModifierKeyCodes.reduce(into: NSEvent.ModifierFlags()) { flags, modifierKeyCode in
                if let flag = Self.modifierFlag(forKeyCode: modifierKeyCode) {
                    flags.insert(flag)
                }
            }
            if let triggerFlag = Self.modifierFlag(forKeyCode: self.keyCode) {
                self.modifierFlags = combinedFlags.subtracting(triggerFlag)
            } else {
                self.modifierFlags = modifierFlags.intersection(Self.relevantModifierMask)
            }
        } else {
            self.keyCode = keyCode
            self.modifierFlags = modifierFlags
            self.modifierKeyCodes = []
        }
    }

    init(mouseButton: Int, modifierFlags: NSEvent.ModifierFlags) {
        self.kind = .mouse
        self.keyCode = 0
        self.modifierFlags = modifierFlags.intersection(Self.relevantModifierMask)
        self.modifierKeyCodes = []
        self.mouseButton = mouseButton
    }
}

extension HotkeyShortcut {
    static let relevantModifierMask: NSEvent.ModifierFlags = [.function, .command, .option, .control, .shift]

    static func modifierFlag(forKeyCode keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 63:
            return .function
        case 54, 55:
            return .command
        case 58, 61:
            return .option
        case 59, 62:
            return .control
        case 56, 60:
            return .shift
        default:
            return nil
        }
    }

    private static func modifierSortPriority(forKeyCode keyCode: UInt16) -> Int? {
        switch keyCode {
        case 63: return 0
        case 55: return 1
        case 54: return 2
        case 58: return 3
        case 61: return 4
        case 59: return 5
        case 62: return 6
        case 56: return 7
        case 60: return 8
        default: return nil
        }
    }

    static func normalizedModifierKeyCodes(from modifierKeyCodes: [UInt16]) -> [UInt16] {
        Array(Set(modifierKeyCodes)).compactMap { keyCode -> (UInt16, Int)? in
            guard let priority = modifierSortPriority(forKeyCode: keyCode) else { return nil }
            return (keyCode, priority)
        }
        .sorted { lhs, rhs in
            lhs.1 < rhs.1
        }
        .map(\.0)
    }

    var relevantModifierFlags: NSEvent.ModifierFlags {
        self.modifierFlags.intersection(Self.relevantModifierMask)
    }

    var isMouseShortcut: Bool {
        self.kind == .mouse
    }

    var isUnmodifiedLeftOrRightClick: Bool {
        guard self.isMouseShortcut, let mouseButton else { return false }
        return (mouseButton == 0 || mouseButton == 1) && self.relevantModifierFlags.isEmpty
    }

    var normalizedModifierKeyCodes: [UInt16] {
        guard !self.isMouseShortcut else { return [] }
        let normalized = Self.normalizedModifierKeyCodes(from: self.modifierKeyCodes)
        if !normalized.isEmpty { return normalized }

        if self.modifierTriggerFlag != nil, self.relevantModifierFlags.isEmpty {
            return [self.keyCode]
        }

        return []
    }

    var modifierTriggerFlag: NSEvent.ModifierFlags? {
        guard !self.isMouseShortcut else { return nil }
        return Self.modifierFlag(forKeyCode: self.keyCode)
    }

    /// True when shortcut presses can race because one begins as the other's modifier prefix.
    func conflictsWith(_ other: HotkeyShortcut) -> Bool {
        if self.isModifierOnlyShortcut, other.isModifierOnlyShortcut {
            let lhs = Set(self.normalizedModifierKeyCodes)
            let rhs = Set(other.normalizedModifierKeyCodes)

            guard !lhs.isEmpty, !rhs.isEmpty else { return false }

            return lhs.isSubset(of: rhs) || rhs.isSubset(of: lhs)
        }

        if self.isMouseShortcut, other.isModifierOnlyShortcut {
            return self.mouseModifiersOverlap(modifierOnlyShortcut: other)
        }

        if other.isMouseShortcut, self.isModifierOnlyShortcut {
            return other.mouseModifiersOverlap(modifierOnlyShortcut: self)
        }

        return false
    }

    private func mouseModifiersOverlap(modifierOnlyShortcut: HotkeyShortcut) -> Bool {
        guard self.isMouseShortcut,
              let expectedModifiers = modifierOnlyShortcut.expectedModifierFlags,
              !expectedModifiers.isEmpty
        else { return false }

        return expectedModifiers.isSubset(of: self.relevantModifierFlags)
    }

    var isModifierOnlyShortcut: Bool {
        self.modifierTriggerFlag != nil
    }

    var expectedModifierFlags: NSEvent.ModifierFlags? {
        guard let triggerFlag = self.modifierTriggerFlag else { return nil }
        return self.relevantModifierFlags.union(triggerFlag)
    }

    func matches(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard !self.isMouseShortcut else { return false }
        return keyCode == self.keyCode && modifiers.intersection(Self.relevantModifierMask) == self.relevantModifierFlags
    }

    func matchesMouse(button: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard self.isMouseShortcut, let mouseButton else { return false }
        guard !self.isUnmodifiedLeftOrRightClick else { return false }
        return mouseButton == button && modifiers.intersection(Self.relevantModifierMask) == self.relevantModifierFlags
    }

    static func == (lhs: HotkeyShortcut, rhs: HotkeyShortcut) -> Bool {
        guard lhs.kind == rhs.kind else { return false }

        switch lhs.kind {
        case .mouse:
            return lhs.mouseButton == rhs.mouseButton &&
                lhs.relevantModifierFlags == rhs.relevantModifierFlags
        case .keyboard:
            let lhsModifierKeyCodes = lhs.normalizedModifierKeyCodes
            let rhsModifierKeyCodes = rhs.normalizedModifierKeyCodes
            if !lhsModifierKeyCodes.isEmpty, !rhsModifierKeyCodes.isEmpty {
                return lhsModifierKeyCodes == rhsModifierKeyCodes
            }

            return lhs.keyCode == rhs.keyCode && lhs.relevantModifierFlags == rhs.relevantModifierFlags
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(ShortcutKind.self, forKey: .kind) ?? .keyboard
        let raw = try c.decodeIfPresent(UInt.self, forKey: .modifierFlagsRawValue) ?? 0

        switch kind {
        case .keyboard:
            let keyCode = try c.decode(UInt16.self, forKey: .keyCode)
            let modifierKeyCodes = try c.decodeIfPresent([UInt16].self, forKey: .modifierKeyCodes) ?? []
            self.init(keyCode: keyCode, modifierFlags: NSEvent.ModifierFlags(rawValue: raw), modifierKeyCodes: modifierKeyCodes)
        case .mouse:
            let mouseButton = try c.decode(Int.self, forKey: .mouseButton)
            self.init(mouseButton: mouseButton, modifierFlags: NSEvent.ModifierFlags(rawValue: raw))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.kind, forKey: .kind)
        try c.encode(self.modifierFlags.rawValue, forKey: .modifierFlagsRawValue)
        switch self.kind {
        case .keyboard:
            try c.encode(self.keyCode, forKey: .keyCode)
            if !self.normalizedModifierKeyCodes.isEmpty {
                try c.encode(self.normalizedModifierKeyCodes, forKey: .modifierKeyCodes)
            }
        case .mouse:
            guard let mouseButton = self.mouseButton else {
                let context = EncodingError.Context(
                    codingPath: c.codingPath + [CodingKeys.mouseButton],
                    debugDescription: "Mouse shortcut is missing a mouse button"
                )
                throw EncodingError.invalidValue(self, context)
            }
            try c.encode(mouseButton, forKey: .mouseButton)
        }
    }
}
