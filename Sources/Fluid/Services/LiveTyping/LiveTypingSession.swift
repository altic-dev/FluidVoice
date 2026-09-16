//
//  LiveTypingSession.swift
//  Fluid
//
//  Ownership bookkeeping for the experimental Live Typing path.
//

import CoreGraphics
import Foundation

/// How aggressively Live Typing is allowed to write into the target field.
///
/// The controller starts at the highest level the target can support and
/// downgrades automatically - never upgrades mid-session - so a failure can only
/// ever fall back to the behaviour the app already had.
nonisolated enum LiveTypingLevel: Int, Codable, Equatable, Comparable {
    /// Read the field, own a range, rewrite the partial as it is revised.
    case full = 1
    /// Only append the stabilised prefix; never rewrite what was already written.
    case committedChunks = 2
    /// Never touch the field while speaking. The existing final paste runs.
    case finalOnly = 3

    static func < (lhs: LiveTypingLevel, rhs: LiveTypingLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Why a session stopped rewriting. Every case is a *safe* stop: the session has
/// either written nothing, or it refuses to touch a field it no longer owns.
nonisolated enum LiveTypingAbortReason: String, Equatable {
    case targetChanged
    case valueChangedExternally
    case verificationFailed
    case writeFailed
}

/// What the controller must do for one partial or final transcript.
nonisolated enum LiveTypingAction: Equatable {
    case none
    /// Replace exactly this range with this text. The range is always the range
    /// FluidVoice previously wrote, never "the last N characters".
    case write(range: NSRange, text: String)
    case abort(LiveTypingAbortReason)
}

/// What to do once the final transcript is known.
nonisolated enum LiveTypingFinalPlan: Equatable {
    /// The field already contains exactly the final text: do not insert again.
    case nothingToDo
    /// Replace the owned range with the final transcript.
    case replace(range: NSRange, text: String)
    /// Nothing was ever written (or the level is final-only): run the normal
    /// delivery path exactly as before.
    case fallbackToDelivery
    /// Ownership was lost. The caller must not paste on top; it should keep the
    /// final text on the pasteboard instead of risking a duplicate.
    case abort(LiveTypingAbortReason)
}

/// One live-typing session.
///
/// Deliberately a value type with no Accessibility or AppKit dependency: every
/// safety rule of the brief is expressed here and can be tested without a live
/// application.
///
/// Invariants:
/// - `ownedRange` is always `anchor ..< anchor + ownedText.length`;
/// - FluidVoice only ever writes to `ownedRange`;
/// - it never writes until it has verified that the field still contains exactly
///   `ownedText` at that range;
/// - any doubt aborts instead of guessing.
nonisolated struct LiveTypingSession: Equatable {
    let sessionID: UUID
    /// The process FluidVoice started writing into. A different PID means a
    /// different field, so the session is over.
    let targetPID: pid_t
    /// Caret location where FluidVoice started writing, in UTF-16 units.
    let anchor: Int
    /// Text that sat before the caret when the session opened. It must never
    /// change; if it does, the user edited the field and the session is over.
    private let prefixText: String
    /// Text that sat after the caret when the session opened. It must never
    /// change either, which is what stops FluidVoice from writing into a field
    /// the user has typed into.
    private let trailingText: String
    /// The exact text FluidVoice wrote and still owns.
    private(set) var ownedText: String
    /// The last field value FluidVoice observed.
    private(set) var lastKnownValue: String
    private(set) var level: LiveTypingLevel
    /// True once at least one write reached the field.
    private(set) var hasWritten: Bool

    init(
        sessionID: UUID = UUID(),
        targetPID: pid_t,
        anchor: Int,
        initialValue: String,
        level: LiveTypingLevel
    ) {
        let text = initialValue as NSString
        let clampedAnchor = max(0, min(anchor, text.length))
        self.sessionID = sessionID
        self.targetPID = targetPID
        self.anchor = clampedAnchor
        self.prefixText = text.substring(to: clampedAnchor)
        self.trailingText = text.substring(from: clampedAnchor)
        self.ownedText = ""
        self.lastKnownValue = initialValue
        self.level = level
        self.hasWritten = false
    }

    /// The exact range FluidVoice owns, in UTF-16 units.
    var ownedRange: NSRange {
        NSRange(location: self.anchor, length: (self.ownedText as NSString).length)
    }

    /// True when the field still contains exactly what FluidVoice wrote, at the
    /// range it wrote it. This is the ownership proof the safety rule demands.
    func owns(_ value: String) -> Bool {
        let text = value as NSString
        let range = self.ownedRange
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= text.length else {
            return false
        }
        return text.substring(with: range) == self.ownedText
    }

    /// The strongest ownership proof available: the text before the caret, the
    /// text inside the owned range and the text after it must all still be
    /// exactly what FluidVoice last saw. A change anywhere aborts the session -
    /// FluidVoice never guesses what the user meant.
    func contextIsIntact(_ value: String) -> Bool {
        let text = value as NSString
        guard text.length >= self.anchor + (self.ownedText as NSString).length else { return false }
        guard text.substring(to: self.anchor) == self.prefixText else { return false }
        guard text.substring(with: self.ownedRange) == self.ownedText else { return false }
        guard text.substring(from: NSMaxRange(self.ownedRange)) == self.trailingText else { return false }
        return true
    }

    /// The caret is expected to sit just after the owned text while streaming.
    func caretIsAtOwnedEnd(_ selection: CFRange?) -> Bool {
        guard let selection else { return false }
        return selection.location == NSMaxRange(self.ownedRange)
    }

    /// What to do for a revised partial.
    mutating func partial(_ text: String, currentValue: String) -> LiveTypingAction {
        switch self.level {
        case .finalOnly:
            return .none

        case .full:
            guard self.contextIsIntact(currentValue) else { return .abort(.valueChangedExternally) }
            guard text != self.ownedText else { return .none }
            return .write(range: self.ownedRange, text: text)

        case .committedChunks:
            guard self.contextIsIntact(currentValue) else { return .abort(.valueChangedExternally) }
            // Commit everything but the last word: the tail is still provisional,
            // and this level is not allowed to rewrite it.
            let words = text.split(separator: " ").map(String.init)
            guard words.count > 1 else { return .none }
            let committed = words.dropLast().joined(separator: " ")
            guard committed.count > self.ownedText.count, committed.hasPrefix(self.ownedText) else {
                return committed == self.ownedText ? .none : .abort(.verificationFailed)
            }
            return .write(range: self.ownedRange, text: committed)
        }
    }

    /// Records that a write of `text` reached the field.
    mutating func noteWrite(_ text: String) {
        self.ownedText = text
        self.hasWritten = true
    }

    /// Records a field value FluidVoice observed without writing to it.
    mutating func noteObservedValue(_ value: String) {
        self.lastKnownValue = value
    }

    /// Level 2 to 3 never loses text: the session simply stops rewriting and the
    /// final delivery takes over.
    mutating func downgrade(to newLevel: LiveTypingLevel) {
        if newLevel > self.level {
            self.level = newLevel
        }
    }

    /// What to do with the final transcript.
    mutating func final(_ transcript: String, currentValue: String) -> LiveTypingFinalPlan {
        // The level only gates *new* writes. Once something was written the field
        // holds our text whatever the level is now, so it still has to be
        // reconciled - falling back to the paste path here would duplicate it.
        guard self.hasWritten else {
            return .fallbackToDelivery
        }
        guard self.contextIsIntact(currentValue) else {
            return .abort(.valueChangedExternally)
        }
        if self.ownedText == transcript {
            return .nothingToDo
        }
        return .replace(range: self.ownedRange, text: transcript)
    }

    /// Longest word prefix common to two transcripts, ignoring case and
    /// punctuation. Mirrors the streaming diff so the two never disagree.
    static func stablePrefix(previous: String, current: String) -> String {
        let previousWords = previous.split(separator: " ").map(String.init)
        let currentWords = current.split(separator: " ").map(String.init)
        guard !currentWords.isEmpty else { return "" }

        var matchCount = 0
        for index in 0..<min(previousWords.count, currentWords.count) {
            let lhs = previousWords[index].lowercased().trimmingCharacters(in: .punctuationCharacters)
            let rhs = currentWords[index].lowercased().trimmingCharacters(in: .punctuationCharacters)
            guard !lhs.isEmpty, lhs == rhs else { break }
            matchCount = index + 1
        }
        guard matchCount > 0 else { return "" }
        return currentWords[0..<matchCount].joined(separator: " ")
    }
}
