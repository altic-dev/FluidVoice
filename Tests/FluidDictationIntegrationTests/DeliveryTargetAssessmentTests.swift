@testable import FluidVoice_Debug
import XCTest

@MainActor
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
            .init(expectation: "unknown role preserves selected mode", assessment: .unknown(reason: "role_AXWebArea"), captured: external, focused: external, frontmostPID: 100, decision: .insert),
            .init(expectation: "unreadable role preserves selected mode", assessment: .unknown(reason: "role_unreadable"), captured: external, focused: external, frontmostPID: 100, decision: .insert),
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

    func testButtonFallbackAppliesAcrossExternalAppsWithoutAnAllowlist() {
        let assessment = DeliveryTargetAssessment.classify(role: "AXButton", valueSettable: false)
        for bundleIdentifier in ["test.web-editor", "test.native-editor", "test.future-app"] {
            let captured = DeliveryTargetAssessment.Target(pid: 100, bundleIdentifier: bundleIdentifier, hasFocusedElement: true)
            XCTAssertEqual(
                assessment.deliveryDecision(capturedTarget: captured, focusedTarget: captured, frontmostPID: 100, ownPID: 999),
                .reliablePasteFallback,
                "A matching captured target receives the same fallback regardless of app identity"
            )
            let changed = DeliveryTargetAssessment.Target(pid: 200, bundleIdentifier: bundleIdentifier, hasFocusedElement: true)
            XCTAssertEqual(
                assessment.deliveryDecision(capturedTarget: captured, focusedTarget: changed, frontmostPID: 200, ownPID: 999),
                .refuse,
                "Cross-app fallback still rejects a changed destination"
            )
        }
    }

    func testOrdinaryDeliverySupportsUnbundledAppsAndNonActivatingLaunchers() {
        for bundle in [nil, "test.launcher"] as [String?] {
            let target = DeliveryTargetAssessment.Target(pid: 100, bundleIdentifier: bundle, hasFocusedElement: true)
            for frontmostPID: pid_t in [100, 200] {
                for assessment: DeliveryTargetAssessment in [.editable(role: "AXTextField"), .unknown(reason: "role_AXWindow")] {
                    XCTAssertEqual(assessment.deliveryDecision(capturedTarget: target, focusedTarget: target, frontmostPID: frontmostPID, ownPID: 999), .insert)
                }
                let button = DeliveryTargetAssessment.notEditable(role: "AXButton")
                XCTAssertEqual(button.deliveryDecision(capturedTarget: target, focusedTarget: target, frontmostPID: frontmostPID, ownPID: 999), bundle != nil && frontmostPID == 100 ? .reliablePasteFallback : .refuse)
            }
            let editable = DeliveryTargetAssessment.editable(role: "AXTextField")
            XCTAssertEqual(editable.deliveryDecision(capturedTarget: nil, focusedTarget: target, frontmostPID: 200, ownPID: 999), .refuse, "Launcher exception requires captured AX focus")
            let withoutElement = DeliveryTargetAssessment.Target(pid: 100, bundleIdentifier: bundle, hasFocusedElement: false)
            XCTAssertEqual(editable.deliveryDecision(capturedTarget: withoutElement, focusedTarget: target, frontmostPID: 200, ownPID: 999), .refuse)
            XCTAssertEqual(editable.deliveryDecision(capturedTarget: target, focusedTarget: target, frontmostPID: 999, ownPID: 999), .refuse)
        }
        let bundled = DeliveryTargetAssessment.Target(pid: 100, bundleIdentifier: "test.editor", hasFocusedElement: true)
        let unbundled = DeliveryTargetAssessment.Target(pid: 100, bundleIdentifier: nil, hasFocusedElement: true)
        let editable = DeliveryTargetAssessment.editable(role: "AXTextField")
        XCTAssertEqual(editable.deliveryDecision(capturedTarget: bundled, focusedTarget: unbundled, frontmostPID: 100, ownPID: 999), .refuse)
        XCTAssertEqual(editable.deliveryDecision(capturedTarget: unbundled, focusedTarget: bundled, frontmostPID: 100, ownPID: 999), .refuse)
    }

    func testDirectDeliveryPreservesModeAndDoesNotReplayRoleChanges() {
        let external = DeliveryTargetAssessment.Target(pid: 100, bundleIdentifier: "test.editor", hasFocusedElement: true)
        let unknownDecision = DeliveryTargetAssessment.classify(role: "AXWebArea", valueSettable: false)
            .deliveryDecision(capturedTarget: external, focusedTarget: external, frontmostPID: 100, ownPID: 999)
        let buttonDecision = DeliveryTargetAssessment.classify(role: "AXButton", valueSettable: false)
            .deliveryDecision(capturedTarget: external, focusedTarget: external, frontmostPID: 100, ownPID: 999)
        let unknown = self.simulateDirectDelivery([unknownDecision, unknownDecision, unknownDecision])
        XCTAssertEqual(unknown.chunks, 2)
        XCTAssertFalse(unknown.pastes)
        let buttonBeforeStart = self.simulateDirectDelivery([buttonDecision])
        XCTAssertEqual(buttonBeforeStart.chunks, 0)
        XCTAssertTrue(buttonBeforeStart.pastes)
        let roleChangedDuringTyping = self.simulateDirectDelivery([.insert, .insert, buttonDecision])
        XCTAssertEqual(roleChangedDuringTyping.chunks, 2)
        XCTAssertFalse(roleChangedDuringTyping.pastes)
    }

    func testUnsafePartialDeliveryNeverReplaysEvenAfterFocusRecovers() {
        let external = DeliveryTargetAssessment.Target(pid: 100, bundleIdentifier: "test.editor", hasFocusedElement: true)
        let other = DeliveryTargetAssessment.Target(pid: 200, bundleIdentifier: "test.other", hasFocusedElement: true)
        let own = DeliveryTargetAssessment.Target(pid: 999, bundleIdentifier: "com.FluidApp.app", hasFocusedElement: true)
        let changedBundle = DeliveryTargetAssessment.Target(pid: 100, bundleIdentifier: "test.changed", hasFocusedElement: true)
        let unsafeFocus: [(DeliveryTargetAssessment, DeliveryTargetAssessment.Target?, pid_t?)] = [
            (.secure(role: "AXTextField"), external, 100),
            (.unavailable(reason: "no_focused_element"), nil, 100),
            (.notEditable(role: "AXSlider"), external, 100),
            (.notEditable(role: "AXStaticText"), external, 100),
            (.editable(role: "AXTextField"), other, 200),
            (.editable(role: "AXTextField"), own, 999),
            (.editable(role: "AXTextField"), changedBundle, 100),
            (.editable(role: "AXTextField"), external, 999),
        ]
        for (assessment, focused, frontmostPID) in unsafeFocus {
            let decision = assessment.deliveryDecision(capturedTarget: external, focusedTarget: focused, frontmostPID: frontmostPID, ownPID: 999)
            let result = self.simulateDirectDelivery([.insert, .insert, decision, .insert])
            XCTAssertEqual(result.chunks, 1, assessment.logDescription)
            XCTAssertFalse(result.pastes, assessment.logDescription)
            XCTAssertFalse(result.canResume, assessment.logDescription)
        }
    }

    func testDirectStartRefusesUnsafeControlAndSecureRoles() {
        let external = DeliveryTargetAssessment.Target(pid: 100, bundleIdentifier: "test.editor", hasFocusedElement: true)
        for role in ["AXSlider", "AXStaticText", "AXSecureTextField"] {
            let decision = DeliveryTargetAssessment.classify(role: role, valueSettable: false)
                .deliveryDecision(capturedTarget: external, focusedTarget: external, frontmostPID: 100, ownPID: 999)
            let state = DeliveryTargetAssessment.DirectInsertionState()
            XCTAssertFalse(state.canStart(decision), role)
            let result = self.simulateDirectDelivery([decision])
            XCTAssertEqual(result.chunks, 0, role)
            XCTAssertFalse(result.pastes, role)
        }
    }

    func testAsyncFocusObservationKeepsMainActorResponsive() async {
        let releaseRead = DispatchSemaphore(value: 0)
        var heartbeatRan = false
        let observation = DeliveryTargetAssessment.FocusObservation(pid: 100, assessment: .editable(role: "AXTextField"))
        let sut = await DeliveryTargetAssessment.observeFocusedElementOffMain(
            on: DispatchQueue(label: "test.fluid.clipboard-focus"),
            readFocus: {
                XCTAssertFalse(Thread.isMainThread, "Clipboard AX reads must run off main")
                DispatchQueue.main.async { heartbeatRan = true; releaseRead.signal() }
                XCTAssertEqual(releaseRead.wait(timeout: .now() + 1), .success)
                return observation
            }
        )
        XCTAssertEqual(sut?.pid, 100)
        XCTAssertEqual(sut?.assessment, .editable(role: "AXTextField"))
        XCTAssertTrue(heartbeatRan)
    }

    func testSlowFocusReadDoesNotBlockMainActorAndRechecksCancellation() async {
        let releaseRead = DispatchSemaphore(value: 0)
        var isValid = true
        var heartbeatRan = false
        var insertionStarted = false
        let observation = DeliveryTargetAssessment.FocusObservation(pid: 100, assessment: .editable(role: "AXTextField"))
        let sut = await DirectInsertionExecutor.run(
            on: DispatchQueue(label: "test.fluid.slow-focus"),
            readFocus: {
                XCTAssertFalse(Thread.isMainThread, "Remote AX reads must stay off the main thread")
                DispatchQueue.main.async {
                    heartbeatRan = true
                    isValid = false
                    releaseRead.signal()
                }
                XCTAssertEqual(releaseRead.wait(timeout: .now() + 1), .success, "Main actor must remain responsive during the read")
                return observation
            },
            canStart: { _ in
                XCTAssertTrue(Thread.isMainThread, "Lifecycle checks remain on the main actor")
                insertionStarted = isValid
                return isValid
            },
            canContinue: { _ in isValid },
            insert: { _ in XCTFail("Cancelled delivery must not insert"); return false }
        )
        XCTAssertFalse(sut)
        XCTAssertTrue(heartbeatRan)
        XCTAssertFalse(insertionStarted, "Cancellation during the read must prevent insertion")
    }

    func testWorkerRefreshesFocusBetweenChunksAndLatchesRefusal() async {
        let assessments: [DeliveryTargetAssessment] = [
            .editable(role: "AXTextField"), .editable(role: "AXTextField"),
            .secure(role: "AXSecureTextField"), .editable(role: "AXTextField"),
        ]
        var reads = 0
        var state = DeliveryTargetAssessment.DirectInsertionState()
        let target = DeliveryTargetAssessment.Target(pid: 100, bundleIdentifier: "test.editor", hasFocusedElement: true)
        let decision: @MainActor (DeliveryTargetAssessment.FocusObservation?) -> DeliveryTargetAssessment.DeliveryDecision = {
            $0?.assessment.deliveryDecision(capturedTarget: target, focusedTarget: target, frontmostPID: 100, ownPID: 999) ?? .refuse
        }
        let sut = await DirectInsertionExecutor.run(
            on: DispatchQueue(label: "test.fluid.fresh-focus"),
            readFocus: {
                XCTAssertFalse(Thread.isMainThread)
                return DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        let assessment = assessments[reads]
                        reads += 1
                        return DeliveryTargetAssessment.FocusObservation(pid: 100, assessment: assessment)
                    }
                }
            },
            canStart: { state.canStart(decision($0)) },
            canContinue: { state.canContinue(decision($0)) },
            insert: { valid in
                XCTAssertTrue(valid(), "First chunk remains safe")
                XCTAssertFalse(valid(), "Secure focus stops the next chunk")
                XCTAssertFalse(valid(), "A later fallback cannot resume after focus recovers")
                return false
            }
        )
        XCTAssertFalse(sut)
        XCTAssertEqual(reads, 4, "Admission and every chunk or fallback need fresh focus")
        XCTAssertTrue(state.wasRefused, "Partial delivery must suppress clipboard replay")
    }

    func testCancellationDuringChunkFocusReadStopsFurtherInsertion() async {
        let releaseRead = DispatchSemaphore(value: 0)
        var reads = 0
        var isValid = true
        let observation = DeliveryTargetAssessment.FocusObservation(pid: 100, assessment: .editable(role: "AXTextField"))
        let sut = await DirectInsertionExecutor.run(
            on: DispatchQueue(label: "test.fluid.chunk-cancellation"),
            readFocus: {
                XCTAssertFalse(Thread.isMainThread)
                let read = DispatchQueue.main.sync { MainActor.assumeIsolated { reads += 1; return reads } }
                if read == 2 {
                    DispatchQueue.main.async { isValid = false; releaseRead.signal() }
                    XCTAssertEqual(releaseRead.wait(timeout: .now() + 1), .success)
                }
                return observation
            },
            canStart: { _ in isValid },
            canContinue: { _ in isValid },
            insert: { valid in
                XCTAssertFalse(valid(), "Cancellation during a remote read must prevent the next chunk")
                return false
            }
        )
        XCTAssertFalse(sut)
        XCTAssertEqual(reads, 2)
        XCTAssertFalse(isValid)
    }

    private func simulateDirectDelivery(
        _ decisions: [DeliveryTargetAssessment.DeliveryDecision]
    ) -> (chunks: Int, pastes: Bool, canResume: Bool) {
        var state = DeliveryTargetAssessment.DirectInsertionState()
        var chunks = 0
        var completed = false
        if state.canStart(decisions[0]) {
            completed = true
            for decision in decisions.dropFirst() {
                guard state.canContinue(decision) else {
                    completed = false
                    break
                }
                chunks += 1
            }
        }
        let pastes = !completed && !state.wasRefused && decisions.last != .refuse
        return (chunks, pastes, state.canContinue(.insert))
    }
}
