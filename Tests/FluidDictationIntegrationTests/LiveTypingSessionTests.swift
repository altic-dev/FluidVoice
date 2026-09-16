import CoreGraphics
@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Pure-logic coverage for the experimental Live Typing ownership session.
///
/// These tests never touch Accessibility, a window server or the network: they
/// assert the safety rules the feature depends on, which is the only part of
/// Live Typing that can be verified without a live target application.
final class LiveTypingSessionTests: XCTestCase {
    private func session(
        anchor: Int = 0,
        value: String = "",
        level: LiveTypingLevel = .full
    ) -> LiveTypingSession {
        LiveTypingSession(targetPID: 4242, anchor: anchor, initialValue: value, level: level)
    }

    // MARK: - Level 1

    func testFullLevelWritesThenReplacesTheOwnedRange() {
        var session = self.session()
        XCTAssertEqual(
            session.partial("Je pense que", currentValue: ""),
            .write(range: NSRange(location: 0, length: 0), text: "Je pense que")
        )
        session.noteWrite("Je pense que")
        XCTAssertEqual(session.ownedRange, NSRange(location: 0, length: 12))
        XCTAssertTrue(session.contextIsIntact("Je pense que"))

        XCTAssertEqual(
            session.partial("Je pense que demain", currentValue: "Je pense que"),
            .write(range: NSRange(location: 0, length: 12), text: "Je pense que demain")
        )
    }

    func testUnchangedPartialIsANoOp() {
        var session = self.session()
        session.noteWrite("Bonjour")
        XCTAssertEqual(session.partial("Bonjour", currentValue: "Bonjour"), .none)
    }

    // MARK: - Safety

    func testEditingBeforeTheOwnedRangeAbortsTheSession() {
        var session = self.session(anchor: 5, value: "Hello world")
        session.noteWrite(" big")
        XCTAssertEqual(
            session.partial(" big day", currentValue: "Heyo big world"),
            .abort(.valueChangedExternally)
        )
    }

    func testTypingAfterTheOwnedTextAbortsTheSession() {
        var session = self.session(anchor: 5, value: "Hello world")
        session.noteWrite(" big")
        XCTAssertEqual(
            session.partial(" big day", currentValue: "Hello bigX world"),
            .abort(.valueChangedExternally)
        )
    }

    func testTrailingTextIsPreservedWhileStreaming() {
        var session = self.session(anchor: 5, value: "Hello world")
        session.noteWrite(" beautiful")
        // The " world" tail is still exactly where the session opened.
        XCTAssertTrue(session.contextIsIntact("Hello beautiful world"))
        XCTAssertFalse(session.contextIsIntact("Hello beautifulthere world"))
    }

    func testRangeOutsideTheFieldIsNeverOwned() {
        var session = self.session(anchor: 100, value: "short")
        // The anchor is clamped into the field, so the range can never escape it.
        XCTAssertEqual(session.anchor, 5)
        session.noteWrite("!")
        XCTAssertTrue(session.contextIsIntact("short!"))
    }

    // MARK: - Level 2

    func testCommittedChunksOnlyAppendAndNeverRewrite() {
        var session = self.session(anchor: 0, value: "", level: .committedChunks)
        XCTAssertEqual(
            session.partial("Je pense que demain", currentValue: ""),
            .write(range: NSRange(location: 0, length: 0), text: "Je pense que")
        )
        session.noteWrite("Je pense que")

        // A revision that diverges from what is already written must not rewrite
        // the committed prefix; the session stops instead.
        XCTAssertEqual(
            session.partial("Je pense demain matin", currentValue: "Je pense que"),
            .abort(.verificationFailed)
        )
    }

    func testCommittedChunksGrowMonotonically() {
        var session = self.session(anchor: 0, value: "", level: .committedChunks)
        session.noteWrite("Je pense")
        XCTAssertEqual(
            session.partial("Je pense que demain", currentValue: "Je pense"),
            .write(range: NSRange(location: 0, length: 8), text: "Je pense que")
        )
    }

    func testSingleWordPartialIsNotCommitted() {
        var session = self.session(anchor: 0, value: "", level: .committedChunks)
        XCTAssertEqual(session.partial("Bonjour", currentValue: ""), .none)
    }

    // MARK: - Finalisation

    func testFinalFallsBackWhenNothingWasWritten() {
        var session = self.session()
        XCTAssertEqual(session.final("Bonjour", currentValue: ""), .fallbackToDelivery)
    }

    func testFinalIsANoOpWhenTheFieldAlreadyMatches() {
        var session = self.session()
        session.noteWrite("Bonjour")
        XCTAssertEqual(session.final("Bonjour", currentValue: "Bonjour"), .nothingToDo)
    }

    func testFinalReplacesARevisedTranscript() {
        var session = self.session()
        session.noteWrite("Je pense que")
        XCTAssertEqual(
            session.final("Je pense que demain", currentValue: "Je pense que"),
            .replace(range: NSRange(location: 0, length: 12), text: "Je pense que demain")
        )
    }

    func testFinalAbortsWhenOwnershipWasLost() {
        var session = self.session()
        session.noteWrite("Je pense que")
        XCTAssertEqual(
            session.final("Je pense que demain", currentValue: "L'utilisateur a tapé autre chose"),
            .abort(.valueChangedExternally)
        )
    }

    /// A session that already wrote must still reconcile even after it
    /// downgraded, otherwise the final paste would duplicate the text.
    func testFinalStillReconcilesAfterADowngradeToFinalOnly() {
        var session = self.session()
        session.noteWrite("Bonjour")
        session.downgrade(to: .finalOnly)
        XCTAssertEqual(
            session.final("Bonjour", currentValue: "Bonjour"),
            .nothingToDo
        )
        // But no new partial is ever written at that level.
        XCTAssertEqual(session.partial("Bonjour tout le monde", currentValue: "Bonjour"), .none)
    }

    // MARK: - Abort tombstone

    /// Once a session has written text and then stopped, the field still holds
    /// that text: the final delivery must keep being suppressed instead of
    /// pasting the transcript a second time.
    func testAbortAfterAWriteLeavesATombstone() {
        var session = self.session()
        session.noteWrite("Je pense que")
        session.markAborted()
        XCTAssertTrue(session.hasWritten)
        XCTAssertTrue(session.abortedAfterWrite)
        // The tombstone survives further bookkeeping, so a later partial can
        // never start a fresh session over the same field.
        session.noteObservedValue("Je pense que demain")
        XCTAssertTrue(session.abortedAfterWrite)
    }

    /// A session that never wrote anything is simply over: the normal paste
    /// still has to run, so no tombstone is left behind.
    func testAbortWithoutAWriteLeavesNoTombstone() {
        var session = self.session()
        session.markAborted()
        XCTAssertFalse(session.abortedAfterWrite)
        XCTAssertEqual(session.final("Bonjour", currentValue: ""), .fallbackToDelivery)
    }

    func testFreshSessionHasNoTombstone() {
        XCTAssertFalse(self.session().abortedAfterWrite)
    }

    // MARK: - Secure fields

    /// An unreadable subrole is not proof that a field is safe, so it must be
    /// treated exactly like a secure one.
    func testUnknownSubroleIsTreatedAsSecure() {
        XCTAssertTrue(LiveTypingAXTarget.isSecureSubrole(nil))
        XCTAssertTrue(LiveTypingAXTarget.isSecureSubrole(""))
        XCTAssertTrue(LiveTypingAXTarget.isSecureSubrole("AXSecureTextField"))
        XCTAssertTrue(LiveTypingAXTarget.isSecureSubrole("AXSecureTextArea"))
        XCTAssertTrue(LiveTypingAXTarget.isSecureSubrole("AXSecureTextFieldSubrole"))
    }

    func testOrdinarySubrolesAreNotSecure() {
        XCTAssertFalse(LiveTypingAXTarget.isSecureSubrole("AXTextField"))
        XCTAssertFalse(LiveTypingAXTarget.isSecureSubrole("AXTextArea"))
        XCTAssertFalse(LiveTypingAXTarget.isSecureSubrole("AXSearchField"))
    }

    /// A nil subrole is reported as secure by the probe, so the predicted level
    /// can never be Level 1.
    func testCapabilitiesWithAnUnreadableSubroleStayFinalOnly() {
        let unknown = LiveTypingCapabilities(
            role: "AXTextField",
            subrole: nil,
            canReadValue: true,
            canReadSelection: true,
            valueIsSettable: true,
            selectedTextIsSettable: true,
            isSecure: LiveTypingAXTarget.isSecureSubrole(nil)
        )
        XCTAssertEqual(unknown.predictedLevel, .finalOnly)
    }

    // MARK: - Levels

    func testDowngradeOnlyMovesDownwards() {
        var session = self.session(level: .full)
        session.downgrade(to: .committedChunks)
        XCTAssertEqual(session.level, .committedChunks)
        session.downgrade(to: .full)
        XCTAssertEqual(session.level, .committedChunks, "a session never upgrades mid-flight")
        session.downgrade(to: .finalOnly)
        XCTAssertEqual(session.level, .finalOnly)
    }

    func testLevelsAreOrderedForTheAutomaticDowngrade() {
        XCTAssertLessThan(LiveTypingLevel.full, .committedChunks)
        XCTAssertLessThan(LiveTypingLevel.committedChunks, .finalOnly)
        XCTAssertEqual(LiveTypingLevel.full.rawValue, 1)
        XCTAssertEqual(LiveTypingLevel.finalOnly.rawValue, 3)
    }

    func testFinalOnlyNeverWritesAPartial() {
        var session = self.session(level: .finalOnly)
        XCTAssertEqual(session.partial("Bonjour", currentValue: ""), .none)
        XCTAssertFalse(session.hasWritten)
    }

    // MARK: - Helpers

    func testOwnedRangeIsMeasuredInUTF16Units() {
        var session = self.session(anchor: 2, value: "ab😀")
        XCTAssertEqual(session.anchor, 2)
        session.noteWrite("XY")
        // Two ASCII characters, whatever the surrounding emoji costs.
        XCTAssertEqual(session.ownedRange, NSRange(location: 2, length: 2))
        XCTAssertTrue(session.contextIsIntact("abXY😀"))
    }

    func testStablePrefixIgnoresCaseAndPunctuation() {
        XCTAssertEqual(
            LiveTypingSession.stablePrefix(previous: "je pense que", current: "Je pense que demain"),
            "Je pense que"
        )
        XCTAssertEqual(LiveTypingSession.stablePrefix(previous: "bonjour", current: "Bonsoir"), "")
        XCTAssertEqual(LiveTypingSession.stablePrefix(previous: "", current: "Bonjour"), "")
    }

    func testCaretIsExpectedAtTheEndOfTheOwnedText() {
        var session = self.session()
        session.noteWrite("Bonjour")
        XCTAssertTrue(session.caretIsAtOwnedEnd(CFRange(location: 7, length: 0)))
        XCTAssertFalse(session.caretIsAtOwnedEnd(CFRange(location: 2, length: 0)))
        XCTAssertFalse(session.caretIsAtOwnedEnd(nil))
    }

    func testObservedValueDoesNotFakeOwnership() {
        var session = self.session()
        session.noteObservedValue("Bonjour")
        XCTAssertFalse(session.hasWritten)
        XCTAssertEqual(session.final("Bonjour", currentValue: "Bonjour"), .fallbackToDelivery)
    }

    // MARK: - Accessibilty capability probe

    private func capabilities(
        value: Bool = true,
        selection: Bool = true,
        valueSettable: Bool = true,
        selectionSettable: Bool = false,
        secure: Bool = false
    ) -> LiveTypingCapabilities {
        LiveTypingCapabilities(
            role: "AXTextArea",
            subrole: secure ? "AXSecureTextField" : "AXStandardWindow",
            canReadValue: value,
            canReadSelection: selection,
            valueIsSettable: valueSettable,
            selectedTextIsSettable: selectionSettable,
            isSecure: secure
        )
    }

    func testCapabilitiesPredictLevelOneWhenTheValueIsSettable() {
        XCTAssertEqual(self.capabilities().predictedLevel, .full)
    }

    /// A settable selection is enough for committed chunk streaming.
    func testCapabilitiesPredictLevelTwoWhenOnlyTheSelectionIsSettable() {
        XCTAssertEqual(
            self.capabilities(valueSettable: false, selectionSettable: true).predictedLevel,
            .committedChunks
        )
    }

    func testCapabilitiesFallBackToFinalOnlyWhenNothingIsUsable() {
        XCTAssertEqual(self.capabilities(value: false).predictedLevel, .finalOnly)
        XCTAssertEqual(self.capabilities(selection: false).predictedLevel, .finalOnly)
        XCTAssertEqual(
            self.capabilities(valueSettable: false, selectionSettable: false).predictedLevel,
            .finalOnly
        )
    }

    /// A secure field is never streamed into, whatever else it exposes.
    func testSecureFieldsAreAlwaysFinalOnly() {
        XCTAssertEqual(self.capabilities(secure: true).predictedLevel, .finalOnly)
    }

    func testCapabilitySummaryNamesTheResolvedLevel() {
        XCTAssertTrue(self.capabilities().summary.contains("Level 1"))
        XCTAssertTrue(self.capabilities(secure: true).summary.contains("Level 3"))
    }
}
