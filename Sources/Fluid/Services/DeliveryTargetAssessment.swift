import ApplicationServices
import Foundation

/// Decides, before pasting, whether the focused UI element can take text.
/// A button fallback requires a matching captured destination; unknown roles retain the chosen mode.
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

    struct DirectInsertionState {
        private(set) var wasRefused = false

        func canStart(_ decision: DeliveryDecision) -> Bool {
            !self.wasRefused && decision == .insert
        }

        mutating func canContinue(_ decision: DeliveryDecision) -> Bool {
            if decision == .refuse {
                self.wasRefused = true
            }
            return !self.wasRefused
        }
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
        case .notEditable(role: "AXButton"):
            // Web-view composers can report a button even while their editor has the caret.
            return capturedTarget?.hasFocusedElement == true ? .reliablePasteFallback : .refuse
        case .unknown:
            return capturedTarget?.hasFocusedElement == true ? .insert : .refuse
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

    nonisolated static func isSecureTextField(_ element: AXUIElement) -> Bool {
        let attributes = self.roleAttributes(of: element)
        return self.isSecureRole(attributes.role, subrole: attributes.subrole)
    }

    private nonisolated static func roleAttributes(of element: AXUIElement) -> (role: String?, subrole: String?) {
        var roleRef: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        var subroleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        return (roleResult == .success ? roleRef as? String : nil, subroleRef as? String)
    }

    private nonisolated static func isSecureRole(_ role: String?, subrole: String?) -> Bool {
        role == "AXSecureTextField" || subrole?.localizedCaseInsensitiveContains("secure") == true
    }

    nonisolated static func assess(_ element: AXUIElement) -> DeliveryTargetAssessment {
        let attributes = self.roleAttributes(of: element)
        if self.isSecureRole(attributes.role, subrole: attributes.subrole) {
            return .secure(role: attributes.role ?? "unknown")
        }
        guard let role = attributes.role else { return .unknown(reason: "role_unreadable") }
        let assessment = self.classify(role: role, valueSettable: false, subrole: attributes.subrole)
        if case .editable = assessment {
            return assessment
        }
        var valueSettable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)
        return settableResult == .success && valueSettable.boolValue ? .editable(role: role) : assessment
    }

    var isSecureTextField: Bool {
        if case .secure = self {
            return true
        }
        return false
    }

    /// Pure role decision, kept separate from the AX queries so it can be tested.
    nonisolated static func classify(role: String, valueSettable: Bool, subrole: String? = nil) -> DeliveryTargetAssessment {
        if self.isSecureRole(role, subrole: subrole) {
            return .secure(role: role)
        }
        if self.editableRoles.contains(role) || valueSettable {
            return .editable(role: role)
        }
        guard self.nonEditableRoles.contains(role) else { return .unknown(reason: "role_\(role)") }
        return .notEditable(role: role)
    }
}
