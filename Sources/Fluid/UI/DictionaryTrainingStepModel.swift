import Foundation

/// The three always-visible steps of the "Train by Voice" accordion composer.
enum DictionaryTrainingStep: Int, CaseIterable, Equatable {
    case word
    case record
    case verify
}

/// Immutable snapshot of the primitive training state the step model derives from.
struct DictionaryTrainingSnapshot: Equatable {
    let normalizedWord: String
    let consecutiveCoveredCaptures: Int
    let pronunciationEnrollmentCount: Int
    let lastTrainingOutput: String
    let lastTrainingOutputIsCovered: Bool
    let trainingVariantsIsEmpty: Bool
    let activePronunciationMatching: Bool
}

enum DictionaryTrainingStepModel {
    static func isOutputCovered(
        lastTrainingOutputIsCovered: Bool,
        pronunciationEnrollmentCount: Int,
        activePronunciationMatching: Bool
    ) -> Bool {
        if activePronunciationMatching {
            return pronunciationEnrollmentCount > 0
        }
        return lastTrainingOutputIsCovered
    }

    static func alreadyCorrectWithoutReplacement(
        _ snapshot: DictionaryTrainingSnapshot,
        readyCoveredCount: Int
    ) -> Bool {
        if snapshot.activePronunciationMatching {
            return snapshot.trainingVariantsIsEmpty &&
                !snapshot.lastTrainingOutput.isEmpty &&
                snapshot.lastTrainingOutput.caseInsensitiveCompare(snapshot.normalizedWord) == .orderedSame &&
                snapshot.pronunciationEnrollmentCount >= readyCoveredCount
        }

        let outputIsCovered = self.isOutputCovered(
            lastTrainingOutputIsCovered: snapshot.lastTrainingOutputIsCovered,
            pronunciationEnrollmentCount: snapshot.pronunciationEnrollmentCount,
            activePronunciationMatching: snapshot.activePronunciationMatching
        )
        return snapshot.trainingVariantsIsEmpty &&
            outputIsCovered &&
            !snapshot.lastTrainingOutput.isEmpty &&
            snapshot.lastTrainingOutput.caseInsensitiveCompare(snapshot.normalizedWord) == .orderedSame &&
            snapshot.consecutiveCoveredCaptures >= readyCoveredCount
    }

    static func finalOutputIsReady(
        _ snapshot: DictionaryTrainingSnapshot,
        readyCoveredCount: Int
    ) -> Bool {
        let alreadyCorrect = self.alreadyCorrectWithoutReplacement(
            snapshot,
            readyCoveredCount: readyCoveredCount
        )

        if snapshot.activePronunciationMatching {
            return !alreadyCorrect && snapshot.pronunciationEnrollmentCount >= readyCoveredCount
        }

        let outputIsCovered = self.isOutputCovered(
            lastTrainingOutputIsCovered: snapshot.lastTrainingOutputIsCovered,
            pronunciationEnrollmentCount: snapshot.pronunciationEnrollmentCount,
            activePronunciationMatching: snapshot.activePronunciationMatching
        )
        return !alreadyCorrect && outputIsCovered && snapshot.consecutiveCoveredCaptures >= readyCoveredCount
    }

    /// Derives the step from primitive state: `.word` when empty, `.verify` when ready,
    /// already-correct, or latched (a post-ready miss must not snap back), else `.record`.
    static func derivedStep(
        _ snapshot: DictionaryTrainingSnapshot,
        readyCoveredCount: Int,
        hasReachedVerify: Bool
    ) -> DictionaryTrainingStep {
        guard !snapshot.normalizedWord.isEmpty else { return .word }

        let ready = self.finalOutputIsReady(
            snapshot,
            readyCoveredCount: readyCoveredCount
        )
        let alreadyCorrect = self.alreadyCorrectWithoutReplacement(
            snapshot,
            readyCoveredCount: readyCoveredCount
        )

        if ready || alreadyCorrect || hasReachedVerify {
            return .verify
        }
        return .record
    }

    /// Resolves the expanded step. Priority: recording lock, word-field focus, manual tap,
    /// then the derived step.
    static func resolveExpandedStep(
        derived: DictionaryTrainingStep,
        manualOverride: DictionaryTrainingStep?,
        isRecordingLocked: Bool,
        isWordFieldFocused: Bool
    ) -> DictionaryTrainingStep {
        if isRecordingLocked {
            return .record
        }
        if isWordFieldFocused {
            return .word
        }
        if let manualOverride {
            return manualOverride
        }
        return derived
    }

    /// Whether a header can be tapped. The lock pins `.record`; `.record`/`.verify` need a
    /// word; `.verify` waits for the derived step, or it opens with Save disabled.
    static func isStepInteractive(
        _ step: DictionaryTrainingStep,
        derived: DictionaryTrainingStep,
        isRecordingLocked: Bool,
        wordIsEmpty: Bool
    ) -> Bool {
        if isRecordingLocked { return step == .record }
        if step != .word, wordIsEmpty { return false }
        if step == .verify, derived != .verify { return false }
        return true
    }
}
