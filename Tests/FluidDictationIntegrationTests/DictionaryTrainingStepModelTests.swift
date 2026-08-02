@testable import FluidVoice_Debug
import XCTest

final class DictionaryTrainingStepModelTests: XCTestCase {
    /// Pinned to the production constant so a threshold change fails these tests.
    private var readyCoveredCount: Int {
        CustomDictionaryTrainingMerge.readyCoveredCount
    }

    private func derived(
        word: String = "FluidVoice",
        consecutiveCoveredCaptures: Int = 0,
        pronunciationEnrollmentCount: Int = 0,
        lastTrainingOutput: String = "",
        lastTrainingOutputIsCovered: Bool = false,
        trainingVariantsIsEmpty: Bool = true,
        activePronunciationMatching: Bool = false,
        hasReachedVerify: Bool = false
    ) -> DictionaryTrainingStep {
        let snapshot = DictionaryTrainingSnapshot(
            normalizedWord: word,
            consecutiveCoveredCaptures: consecutiveCoveredCaptures,
            pronunciationEnrollmentCount: pronunciationEnrollmentCount,
            lastTrainingOutput: lastTrainingOutput,
            lastTrainingOutputIsCovered: lastTrainingOutputIsCovered,
            trainingVariantsIsEmpty: trainingVariantsIsEmpty,
            activePronunciationMatching: activePronunciationMatching
        )
        return DictionaryTrainingStepModel.derivedStep(
            snapshot,
            readyCoveredCount: self.readyCoveredCount,
            hasReachedVerify: hasReachedVerify
        )
    }

    // MARK: - derivedStep

    func testEmptyWordDerivesWordStep() {
        // Caller pre-trims, so only "" counts as empty.
        XCTAssertEqual(self.derived(word: ""), .word)
    }

    func testNonEmptyWordWithNoProgressDerivesRecordStep() {
        XCTAssertEqual(self.derived(word: "FluidVoice"), .record)
    }

    func testReadyAfterThreeConsecutiveCoveredCapturesDerivesVerifyStep() {
        let step = self.derived(
            consecutiveCoveredCaptures: 3,
            lastTrainingOutput: "FluidVoice",
            lastTrainingOutputIsCovered: true,
            trainingVariantsIsEmpty: false
        )
        XCTAssertEqual(step, .verify)
    }

    func testAlmostReadyStaysOnRecordStep() {
        let step = self.derived(
            consecutiveCoveredCaptures: 2,
            lastTrainingOutput: "FluidVoice",
            lastTrainingOutputIsCovered: true,
            trainingVariantsIsEmpty: false
        )
        XCTAssertEqual(step, .record)
    }

    func testAlreadyCorrectWithoutReplacementDerivesVerifyStep() {
        let step = self.derived(
            consecutiveCoveredCaptures: 3,
            lastTrainingOutput: "FluidVoice",
            lastTrainingOutputIsCovered: true,
            trainingVariantsIsEmpty: true
        )
        XCTAssertEqual(step, .verify)
    }

    func testPronunciationMatchingBranchUsesEnrollmentCountNotConsecutiveCaptures() {
        // Consecutive captures is 0 (irrelevant in this branch); enrollment count drives readiness.
        let notReady = self.derived(
            consecutiveCoveredCaptures: 0,
            pronunciationEnrollmentCount: 2,
            trainingVariantsIsEmpty: false,
            activePronunciationMatching: true
        )
        XCTAssertEqual(notReady, .record)

        let ready = self.derived(
            consecutiveCoveredCaptures: 0,
            pronunciationEnrollmentCount: 3,
            trainingVariantsIsEmpty: false,
            activePronunciationMatching: true
        )
        XCTAssertEqual(ready, .verify)
    }

    func testVerifyLockSurvivesPostReadyMissedCapture() {
        // A miss after being ready: the latch must not snap back to .record.
        let step = self.derived(
            consecutiveCoveredCaptures: 0,
            lastTrainingOutput: "FluidVoice",
            lastTrainingOutputIsCovered: false,
            trainingVariantsIsEmpty: false,
            hasReachedVerify: true
        )
        XCTAssertEqual(step, .verify)
    }

    func testPreloadedVariantsStateDerivesRecordStepNotVerify() {
        let step = self.derived(
            consecutiveCoveredCaptures: 0,
            lastTrainingOutput: "",
            lastTrainingOutputIsCovered: false,
            trainingVariantsIsEmpty: false
        )
        XCTAssertEqual(step, .record)
    }

    func testEmptyWordGuardOutranksVerifyLatch() {
        // The empty-word guard must outrank the latch — the word-edit reset depends on it.
        XCTAssertEqual(self.derived(word: "", hasReachedVerify: true), .word)
    }

    func testCoveredCapturesAreCaseInsensitiveAgainstWord() {
        let step = self.derived(
            word: "FluidVoice",
            consecutiveCoveredCaptures: 3,
            lastTrainingOutput: "fluidvoice",
            lastTrainingOutputIsCovered: true,
            trainingVariantsIsEmpty: true
        )
        XCTAssertEqual(step, .verify)
    }

    // MARK: - finalOutputIsReady / alreadyCorrectWithoutReplacement

    private func finalReady(
        word: String = "FluidVoice",
        consecutiveCoveredCaptures: Int = 0,
        pronunciationEnrollmentCount: Int = 0,
        lastTrainingOutput: String = "",
        lastTrainingOutputIsCovered: Bool = false,
        trainingVariantsIsEmpty: Bool = true,
        activePronunciationMatching: Bool = false
    ) -> Bool {
        DictionaryTrainingStepModel.finalOutputIsReady(
            DictionaryTrainingSnapshot(
                normalizedWord: word,
                consecutiveCoveredCaptures: consecutiveCoveredCaptures,
                pronunciationEnrollmentCount: pronunciationEnrollmentCount,
                lastTrainingOutput: lastTrainingOutput,
                lastTrainingOutputIsCovered: lastTrainingOutputIsCovered,
                trainingVariantsIsEmpty: trainingVariantsIsEmpty,
                activePronunciationMatching: activePronunciationMatching
            ),
            readyCoveredCount: self.readyCoveredCount
        )
    }

    private func alreadyCorrect(
        word: String = "FluidVoice",
        consecutiveCoveredCaptures: Int = 0,
        pronunciationEnrollmentCount: Int = 0,
        lastTrainingOutput: String = "",
        lastTrainingOutputIsCovered: Bool = false,
        trainingVariantsIsEmpty: Bool = true,
        activePronunciationMatching: Bool = false
    ) -> Bool {
        DictionaryTrainingStepModel.alreadyCorrectWithoutReplacement(
            DictionaryTrainingSnapshot(
                normalizedWord: word,
                consecutiveCoveredCaptures: consecutiveCoveredCaptures,
                pronunciationEnrollmentCount: pronunciationEnrollmentCount,
                lastTrainingOutput: lastTrainingOutput,
                lastTrainingOutputIsCovered: lastTrainingOutputIsCovered,
                trainingVariantsIsEmpty: trainingVariantsIsEmpty,
                activePronunciationMatching: activePronunciationMatching
            ),
            readyCoveredCount: self.readyCoveredCount
        )
    }

    func testAlreadyCorrectRequiresNoCapturedVariants() {
        // Variants remain, so there is something to save: ready, not already-correct.
        XCTAssertFalse(self.alreadyCorrect(
            consecutiveCoveredCaptures: 3,
            lastTrainingOutput: "FluidVoice",
            lastTrainingOutputIsCovered: true,
            trainingVariantsIsEmpty: false
        ))
        XCTAssertTrue(self.finalReady(
            consecutiveCoveredCaptures: 3,
            lastTrainingOutput: "FluidVoice",
            lastTrainingOutputIsCovered: true,
            trainingVariantsIsEmpty: false
        ))
    }

    func testAlreadyCorrectImpliesFinalOutputNotReady() {
        // Nothing to save means not ready — this is what keeps Save disabled.
        let args = (3, "FluidVoice", true, true)
        XCTAssertTrue(self.alreadyCorrect(
            consecutiveCoveredCaptures: args.0,
            lastTrainingOutput: args.1,
            lastTrainingOutputIsCovered: args.2,
            trainingVariantsIsEmpty: args.3
        ))
        XCTAssertFalse(self.finalReady(
            consecutiveCoveredCaptures: args.0,
            lastTrainingOutput: args.1,
            lastTrainingOutputIsCovered: args.2,
            trainingVariantsIsEmpty: args.3
        ))
    }

    func testFinalReadyForCoveredNonMatchingOutput() {
        // Covered but output != word: a real replacement to save.
        XCTAssertTrue(self.finalReady(
            consecutiveCoveredCaptures: 3,
            lastTrainingOutput: "fluid voice",
            lastTrainingOutputIsCovered: true,
            trainingVariantsIsEmpty: false
        ))
        XCTAssertFalse(self.alreadyCorrect(
            consecutiveCoveredCaptures: 3,
            lastTrainingOutput: "fluid voice",
            lastTrainingOutputIsCovered: true,
            trainingVariantsIsEmpty: false
        ))
    }

    func testPronunciationEnrollmentBoundary() {
        XCTAssertFalse(self.finalReady(
            pronunciationEnrollmentCount: self.readyCoveredCount - 1,
            trainingVariantsIsEmpty: false,
            activePronunciationMatching: true
        ))
        XCTAssertTrue(self.finalReady(
            pronunciationEnrollmentCount: self.readyCoveredCount,
            trainingVariantsIsEmpty: false,
            activePronunciationMatching: true
        ))
    }

    func testPronunciationAlreadyCorrectWithEnoughEnrollments() {
        // Nothing to save and the output already matches: already-correct, not ready.
        XCTAssertTrue(self.alreadyCorrect(
            pronunciationEnrollmentCount: self.readyCoveredCount,
            lastTrainingOutput: "FluidVoice",
            trainingVariantsIsEmpty: true,
            activePronunciationMatching: true
        ))
        XCTAssertFalse(self.finalReady(
            pronunciationEnrollmentCount: self.readyCoveredCount,
            lastTrainingOutput: "FluidVoice",
            trainingVariantsIsEmpty: true,
            activePronunciationMatching: true
        ))
    }

    // MARK: - resolveExpandedStep

    func testRecordingLockOverridesManualOverrideAndDerivedStep() {
        let resolved = DictionaryTrainingStepModel.resolveExpandedStep(
            derived: .verify,
            manualOverride: .word,
            isRecordingLocked: true,
            isWordFieldFocused: false
        )
        XCTAssertEqual(resolved, .record)
    }

    func testWordFieldFocusPinsWordStepEvenWithManualOverrideElsewhere() {
        let resolved = DictionaryTrainingStepModel.resolveExpandedStep(
            derived: .record,
            manualOverride: .verify,
            isRecordingLocked: false,
            isWordFieldFocused: true
        )
        XCTAssertEqual(resolved, .word)
    }

    func testManualOverrideWinsOverDerivedStepWhenNoLockOrFocus() {
        let resolved = DictionaryTrainingStepModel.resolveExpandedStep(
            derived: .record,
            manualOverride: .verify,
            isRecordingLocked: false,
            isWordFieldFocused: false
        )
        XCTAssertEqual(resolved, .verify)
    }

    func testFallsBackToDerivedStepWithNoOverrideLockOrFocus() {
        let resolved = DictionaryTrainingStepModel.resolveExpandedStep(
            derived: .record,
            manualOverride: nil,
            isRecordingLocked: false,
            isWordFieldFocused: false
        )
        XCTAssertEqual(resolved, .record)
    }

    func testRecordingLockWinsEvenWithWordFieldFocused() {
        // Recording lock is priority 1, above word-field focus (priority 2).
        let resolved = DictionaryTrainingStepModel.resolveExpandedStep(
            derived: .word,
            manualOverride: nil,
            isRecordingLocked: true,
            isWordFieldFocused: true
        )
        XCTAssertEqual(resolved, .record)
    }

    // MARK: - isStepInteractive

    func testVerifyHeaderIsNotTappableBeforeAnythingIsRecorded() {
        // Opening Verify here would strand the user with Add Replacement disabled.
        XCTAssertFalse(DictionaryTrainingStepModel.isStepInteractive(
            .verify,
            derived: .record,
            isRecordingLocked: false,
            wordIsEmpty: false
        ))
    }

    func testVerifyHeaderIsTappableOnceDerivedStepReachesVerify() {
        XCTAssertTrue(DictionaryTrainingStepModel.isStepInteractive(
            .verify,
            derived: .verify,
            isRecordingLocked: false,
            wordIsEmpty: false
        ))
    }

    func testRecordAndVerifyHeadersAreLockedWhileWordIsEmpty() {
        for step in [DictionaryTrainingStep.record, .verify] {
            XCTAssertFalse(DictionaryTrainingStepModel.isStepInteractive(
                step,
                derived: .word,
                isRecordingLocked: false,
                wordIsEmpty: true
            ))
        }
        XCTAssertTrue(DictionaryTrainingStepModel.isStepInteractive(
            .word,
            derived: .word,
            isRecordingLocked: false,
            wordIsEmpty: true
        ))
    }

    func testRecordingLockLeavesOnlyRecordTappable() {
        XCTAssertTrue(DictionaryTrainingStepModel.isStepInteractive(
            .record,
            derived: .verify,
            isRecordingLocked: true,
            wordIsEmpty: false
        ))
        for step in [DictionaryTrainingStep.word, .verify] {
            XCTAssertFalse(DictionaryTrainingStepModel.isStepInteractive(
                step,
                derived: .verify,
                isRecordingLocked: true,
                wordIsEmpty: false
            ))
        }
    }

    // MARK: - Latched post-ready-miss progress

    /// Mirrors `CustomDictionaryView.trainingReadinessProgress` so the test sees the
    /// same progress the view would show.
    private func readinessProgress(
        consecutiveCoveredCaptures: Int,
        lastTrainingOutputIsCovered: Bool,
        pronunciationEnrollmentCount: Int = 0,
        activePronunciationMatching: Bool = false,
        trainingVariantsIsEmpty: Bool = true,
        lastTrainingOutput: String = "FluidVoice",
        normalizedWord: String = "FluidVoice"
    ) -> Int {
        let snapshot = DictionaryTrainingSnapshot(
            normalizedWord: normalizedWord,
            consecutiveCoveredCaptures: consecutiveCoveredCaptures,
            pronunciationEnrollmentCount: pronunciationEnrollmentCount,
            lastTrainingOutput: lastTrainingOutput,
            lastTrainingOutputIsCovered: lastTrainingOutputIsCovered,
            trainingVariantsIsEmpty: trainingVariantsIsEmpty,
            activePronunciationMatching: activePronunciationMatching
        )
        let total = self.readyCoveredCount
        if DictionaryTrainingStepModel.alreadyCorrectWithoutReplacement(snapshot, readyCoveredCount: total) {
            return total
        }
        let covered = DictionaryTrainingStepModel.isOutputCovered(
            lastTrainingOutputIsCovered: snapshot.lastTrainingOutputIsCovered,
            pronunciationEnrollmentCount: snapshot.pronunciationEnrollmentCount,
            activePronunciationMatching: snapshot.activePronunciationMatching
        )
        return covered ? min(snapshot.consecutiveCoveredCaptures, total) : 0
    }

    func testLatchedPostReadyMissKeepsVerifyExpandedButReadsZeroProgress() {
        // The latch holds .verify while coverage resets; the ring must show real progress.
        let total = self.readyCoveredCount
        let snapshot = DictionaryTrainingSnapshot(
            normalizedWord: "FluidVoice",
            consecutiveCoveredCaptures: 0,
            pronunciationEnrollmentCount: 0,
            lastTrainingOutput: "fluid voice",
            lastTrainingOutputIsCovered: false,
            trainingVariantsIsEmpty: false,
            activePronunciationMatching: false
        )

        let step = DictionaryTrainingStepModel.derivedStep(
            snapshot,
            readyCoveredCount: total,
            hasReachedVerify: true
        )
        XCTAssertEqual(step, .verify)

        let resolved = DictionaryTrainingStepModel.resolveExpandedStep(
            derived: step,
            manualOverride: nil,
            isRecordingLocked: false,
            isWordFieldFocused: false
        )
        XCTAssertEqual(resolved, .verify)

        let progress = self.readinessProgress(
            consecutiveCoveredCaptures: snapshot.consecutiveCoveredCaptures,
            lastTrainingOutputIsCovered: snapshot.lastTrainingOutputIsCovered,
            trainingVariantsIsEmpty: snapshot.trainingVariantsIsEmpty,
            lastTrainingOutput: snapshot.lastTrainingOutput
        )
        XCTAssertEqual(progress, 0, "latched post-ready-miss must read zero progress")

        // Verify stays tappable through the miss so Try Again remains reachable.
        XCTAssertTrue(DictionaryTrainingStepModel.isStepInteractive(
            .verify,
            derived: step,
            isRecordingLocked: false,
            wordIsEmpty: false
        ))
    }
}
