import ApplicationServices
import Foundation

/// Decides, before pasting, whether the focused UI element can take text.
/// `notEditable` is only returned when the answer is certain; every ambiguous
/// case is `unknown` so delivery proceeds exactly as before.
enum DeliveryTargetAssessment: Equatable {
    case editable(role: String)
    case notEditable(role: String)
    case unknown(reason: String)

    var isCertainlyNotEditable: Bool {
        if case .notEditable = self { return true }
        return false
    }

    var logDescription: String {
        switch self {
        case let .editable(role): "editable role=\(role)"
        case let .notEditable(role): "notEditable role=\(role)"
        case let .unknown(reason): "unknown reason=\(reason)"
        }
    }

    /// Roles that never accept typed text. Containers are deliberately absent:
    /// AXGroup and AXWebArea are what web editors report, a selected spreadsheet
    /// cell reports AXCell or AXTable, and apps that draw their own UI
    /// (GPU terminals, remote desktops, VMs, games) report AXWindow, AXSheet or
    /// AXApplication while still accepting Cmd+V.
    private static let nonEditableRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXMenuItem", "AXMenu", "AXMenuBar", "AXMenuBarItem",
        "AXStaticText", "AXImage", "AXLink", "AXDisclosureTriangle",
        "AXScrollBar", "AXSlider", "AXIncrementor", "AXTabGroup", "AXToolbar",
        "AXSplitter", "AXDockItem",
    ]

    private static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField",
    ]

    nonisolated static func assessFocusedElement() -> DeliveryTargetAssessment {
        guard AXIsProcessTrusted() else { return .unknown(reason: "accessibility_not_trusted") }
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard result == .success, let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return .unknown(reason: "focused_element_\(result.rawValue)")
        }
        let element = unsafeBitCast(focusedRef, to: AXUIElement.self)

        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String
        else { return .unknown(reason: "role_unreadable") }

        var valueSettable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)
        return self.classify(role: role, valueSettable: settableResult == .success && valueSettable.boolValue)
    }

    /// Pure role decision, kept separate from the AX queries so it can be tested.
    nonisolated static func classify(role: String, valueSettable: Bool) -> DeliveryTargetAssessment {
        if self.editableRoles.contains(role) || valueSettable { return .editable(role: role) }
        guard self.nonEditableRoles.contains(role) else { return .unknown(reason: "role_\(role)") }
        return .notEditable(role: role)
    }
}
