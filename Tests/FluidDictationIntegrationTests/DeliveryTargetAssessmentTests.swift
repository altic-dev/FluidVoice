@testable import FluidVoice_Debug
import XCTest

final class DeliveryTargetAssessmentTests: XCTestCase {
    func testTextRolesAreEditable() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
            XCTAssertEqual(DeliveryTargetAssessment.classify(role: role, valueSettable: false), .editable(role: role))
        }
    }

    func testSecureFieldsAreRefusedEvenWhenValueIsSettable() {
        for valueSettable in [false, true] {
            XCTAssertEqual(DeliveryTargetAssessment.classify(role: "AXSecureTextField", valueSettable: valueSettable), .secure(role: "AXSecureTextField"))
            XCTAssertEqual(DeliveryTargetAssessment.classify(role: "AXTextField", valueSettable: valueSettable, subrole: "AXSecureTextField"), .secure(role: "AXTextField"))
        }
    }

    func testSettableValueWinsOverRole() {
        XCTAssertEqual(DeliveryTargetAssessment.classify(role: "AXStaticText", valueSettable: true), .editable(role: "AXStaticText"))
    }

    func testControlsAndStaticContentAreRefused() {
        for role in ["AXButton", "AXStaticText", "AXImage", "AXMenuItem", "AXSlider"] {
            XCTAssertTrue(DeliveryTargetAssessment.classify(role: role, valueSettable: false).isCertainlyNotEditable, role)
        }
    }

    func testContainersStayUnknownSoPasteProceeds() {
        // Apps that draw their own UI report the window or application as the
        // focused element and still accept Cmd+V.
        for role in ["AXWindow", "AXSheet", "AXDrawer", "AXApplication", "AXGroup", "AXWebArea", "AXCell", "AXUnknown"] {
            XCTAssertEqual(DeliveryTargetAssessment.classify(role: role, valueSettable: false), .unknown(reason: "role_\(role)"), role)
        }
    }

    func testDeliveryDecisionRequiresSafeFocusAndCapturedDestination() {
        let external = DeliveryTargetAssessment.Target(pid: 100, bundleIdentifier: "test.editor", hasFocusedElement: true)
        let otherApp = DeliveryTargetAssessment.Target(pid: 200, bundleIdentifier: "test.other", hasFocusedElement: true)
        let own = DeliveryTargetAssessment.Target(pid: 999, bundleIdentifier: "com.FluidApp.app", hasFocusedElement: true)
        let ownOtherProcess = DeliveryTargetAssessment.Target(pid: 300, bundleIdentifier: "com.FluidApp.app", hasFocusedElement: true)
        let missingElement = DeliveryTargetAssessment.Target(pid: 100, bundleIdentifier: "test.editor", hasFocusedElement: false)
        let changedBundle = DeliveryTargetAssessment.Target(pid: 100, bundleIdentifier: "test.changed", hasFocusedElement: true)
        let secureCapture = DeliveryTargetAssessment.Target(pid: 100, bundleIdentifier: "test.editor", hasFocusedElement: true, isSecureTextField: true)
        struct Case {
            let expectation: String
            let assessment: DeliveryTargetAssessment
            let captured: DeliveryTargetAssessment.Target?
            let focused: DeliveryTargetAssessment.Target?
            let frontmostPID: pid_t?
            let decision: DeliveryTargetAssessment.DeliveryDecision
        }
        let cases: [Case] = [
            .init(expectation: "editable inserts", assessment: .editable(role: "AXTextArea"), captured: external, focused: external, frontmostPID: 100, decision: .insert),
            .init(expectation: "editable without capture inserts", assessment: .editable(role: "AXTextField"), captured: nil, focused: external, frontmostPID: 100, decision: .insert),
            .init(expectation: "button with capture pastes", assessment: .notEditable(role: "AXButton"), captured: external, focused: external, frontmostPID: 100, decision: .reliablePasteFallback),
            .init(expectation: "unknown role with capture pastes", assessment: .unknown(reason: "role_AXWebArea"), captured: external, focused: external, frontmostPID: 100, decision: .reliablePasteFallback),
            .init(expectation: "unreadable role with capture pastes", assessment: .unknown(reason: "role_unreadable"), captured: external, focused: external, frontmostPID: 100, decision: .reliablePasteFallback),
            .init(expectation: "button without capture refuses", assessment: .notEditable(role: "AXButton"), captured: nil, focused: external, frontmostPID: 100, decision: .refuse),
            .init(expectation: "unknown without capture refuses", assessment: .unknown(reason: "role_AXWindow"), captured: nil, focused: external, frontmostPID: 100, decision: .refuse),
            .init(expectation: "missing live focus refuses", assessment: .editable(role: "AXTextArea"), captured: external, focused: nil, frontmostPID: 100, decision: .refuse),
            .init(expectation: "capture without element refuses fallback", assessment: .notEditable(role: "AXButton"), captured: missingElement, focused: external, frontmostPID: 100, decision: .refuse),
            .init(expectation: "self frontmost refuses", assessment: .editable(role: "AXTextArea"), captured: external, focused: external, frontmostPID: 999, decision: .refuse),
            .init(expectation: "self focused refuses", assessment: .editable(role: "AXTextArea"), captured: own, focused: own, frontmostPID: 999, decision: .refuse),
            .init(expectation: "another FluidVoice process refuses", assessment: .editable(role: "AXTextArea"), captured: ownOtherProcess, focused: ownOtherProcess, frontmostPID: 300, decision: .refuse),
            .init(expectation: "changed PID refuses", assessment: .editable(role: "AXTextArea"), captured: external, focused: otherApp, frontmostPID: 200, decision: .refuse),
            .init(expectation: "changed bundle refuses", assessment: .notEditable(role: "AXButton"), captured: external, focused: changedBundle, frontmostPID: 100, decision: .refuse),
            .init(expectation: "AX and frontmost PID mismatch refuses", assessment: .notEditable(role: "AXButton"), captured: external, focused: external, frontmostPID: 200, decision: .refuse),
            .init(expectation: "missing frontmost refuses", assessment: .editable(role: "AXTextArea"), captured: external, focused: external, frontmostPID: nil, decision: .refuse),
            .init(expectation: "secure capture refuses", assessment: .editable(role: "AXTextArea"), captured: secureCapture, focused: external, frontmostPID: 100, decision: .refuse),
            .init(expectation: "secure live focus refuses", assessment: .secure(role: "AXTextField"), captured: external, focused: external, frontmostPID: 100, decision: .refuse),
            .init(expectation: "unavailable assessment refuses", assessment: .unavailable(reason: "no_focused_element"), captured: external, focused: external, frontmostPID: 100, decision: .refuse),
            .init(expectation: "static content still refuses", assessment: .notEditable(role: "AXStaticText"), captured: external, focused: external, frontmostPID: 100, decision: .refuse),
        ]
        for test in cases {
            let sut = test.assessment.deliveryDecision(capturedTarget: test.captured, focusedTarget: test.focused, frontmostPID: test.frontmostPID, ownPID: 999)
            XCTAssertEqual(sut, test.decision, test.expectation)
        }
    }
}
