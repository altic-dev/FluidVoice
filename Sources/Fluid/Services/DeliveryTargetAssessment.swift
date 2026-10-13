import ApplicationServices
import Foundation

/// Decides, before pasting, whether the focused UI element can take text.
/// Ambiguous roles can use Reliable Paste only with a matching captured destination.
enum DeliveryTargetAssessment: Equatable {
    struct Target {
        let pid: pid_t
        let bundleIdentifier: String?
        let hasFocusedElement: Bool
        var isSecureTextField = false
    }

    enum DeliveryDecision: Equatable {
        case insert
        case reliablePasteFallback
        case refuse
    }

    func deliveryDecision(capturedTarget: Target?, focusedTarget: Target?, frontmostPID: pid_t?, ownPID: pid_t) -> DeliveryDecision {
        guard let focusedTarget, focusedTarget.hasFocusedElement,
              focusedTarget.pid > 0, focusedTarget.pid != ownPID,
              frontmostPID == focusedTarget.pid,
              focusedTarget.bundleIdentifier != "com.FluidApp.app",
              focusedTarget.bundleIdentifier != "com.FluidApp.app.debug",
              !focusedTarget.isSecureTextField
        else { return .refuse }
        if let capturedTarget {
            guard capturedTarget.pid == focusedTarget.pid,
                  let bundleIdentifier = capturedTarget.bundleIdentifier, !bundleIdentifier.isEmpty,
                  bundleIdentifier == focusedTarget.bundleIdentifier,
                  !capturedTarget.isSecureTextField
            else { return .refuse }
        }
        switch self {
        case .editable:
            return .insert
        case .secure, .unavailable:
            return .refuse
        case .notEditable(role: "AXButton"), .unknown:
            // Web-view composers can report a button even while their editor has the caret.
            return capturedTarget?.hasFocusedElement == true ? .reliablePasteFallback : .refuse
        case .notEditable:
            return .refuse
        }
    }

    case editable(role: String)
    case notEditable(role: String)
    case unknown(reason: String)
    case secure(role: String)
    case unavailable(reason: String)

    var isCertainlyNotEditable: Bool {
        switch self {
        case .notEditable, .secure, .unavailable: true
        case .editable, .unknown: false
        }
    }

    var logDescription: String {
        switch self {
        case let .editable(role): "editable role=\(role)"
        case let .notEditable(role): "notEditable role=\(role)"
        case let .unknown(reason): "unknown reason=\(reason)"
        case let .secure(role): "secure role=\(role)"
        case let .unavailable(reason): "unavailable reason=\(reason)"
        }
    }

    /// Roles ordinarily unable to accept typed text. Containers are deliberately absent:
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
        "AXTextField", "AXTextArea", "AXComboBox",
    ]

    struct FocusObservation {
        let element: AXUIElement
        let pid: pid_t
        let assessment: DeliveryTargetAssessment
    }

    nonisolated static func assessFocusedElement() -> DeliveryTargetAssessment {
        self.observeFocusedElement()?.assessment ?? .unavailable(reason: "no_focused_element")
    }

    nonisolated static func observeFocusedElement() -> FocusObservation? {
        guard AXIsProcessTrusted() else { return nil }
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard result == .success, let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(focusedRef, to: AXUIElement.self)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return FocusObservation(element: element, pid: pid, assessment: self.assess(element))
    }

    nonisolated static func assess(_ element: AXUIElement) -> DeliveryTargetAssessment {
        var roleRef: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        var subroleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        let subrole = subroleRef as? String
        if subrole?.localizedCaseInsensitiveContains("secure") == true {
            return .secure(role: roleRef as? String ?? "unknown")
        }
        guard roleResult == .success, let role = roleRef as? String else { return .unknown(reason: "role_unreadable") }
        var valueSettable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)
        return self.classify(role: role, valueSettable: settableResult == .success && valueSettable.boolValue, subrole: subrole)
    }

    var isSecureTextField: Bool {
        if case .secure = self {
            return true
        }
        return false
    }

    /// Pure role decision, kept separate from the AX queries so it can be tested.
    nonisolated static func classify(role: String, valueSettable: Bool, subrole: String? = nil) -> DeliveryTargetAssessment {
        if role == "AXSecureTextField" || subrole?.localizedCaseInsensitiveContains("secure") == true {
            return .secure(role: role)
        }
        if self.editableRoles.contains(role) || valueSettable {
            return .editable(role: role)
        }
        guard self.nonEditableRoles.contains(role) else { return .unknown(reason: "role_\(role)") }
        return .notEditable(role: role)
    }
}
