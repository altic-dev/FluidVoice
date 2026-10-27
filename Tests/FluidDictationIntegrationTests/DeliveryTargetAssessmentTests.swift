@testable import FluidVoice_Debug
import XCTest

final class DeliveryTargetAssessmentTests: XCTestCase {
    func testTextRolesAreEditable() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField"] {
            XCTAssertEqual(DeliveryTargetAssessment.classify(role: role, valueSettable: false), .editable(role: role))
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
}
