import AppKit
import ApplicationServices
import Foundation

struct AutomaticDictionaryCorrectionCandidate: Equatable, Identifiable {
    let id = UUID()
    let heardText: String
    let correctedText: String
}

struct AutomaticDictionaryTextChange: Equatable {
    let oldRange: NSRange
    let newRange: NSRange
}

enum AutomaticDictionaryCorrectionDetector {
    private static let edgeCharacters = CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: ".,!?;:\"“”‘’()[]{}")
    )
    private static let boundaryCharacters = CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: ",!?;:\"“”()[]{}<>")
    )
    private static let maxCandidateLength = 40
    private static let maxCombinedLength = 70
    private static let maxWords = 3

    static func textChange(before: String, after: String) -> AutomaticDictionaryTextChange? {
        guard before != after else { return nil }

        let oldText = before as NSString
        let newText = after as NSString
        let sharedLength = min(oldText.length, newText.length)
        var prefixLength = 0

        while prefixLength < sharedLength,
              oldText.character(at: prefixLength) == newText.character(at: prefixLength)
        {
            prefixLength += 1
        }

        var suffixLength = 0
        let oldRemaining = oldText.length - prefixLength
        let newRemaining = newText.length - prefixLength
        while suffixLength < min(oldRemaining, newRemaining),
              oldText.character(at: oldText.length - suffixLength - 1) ==
              newText.character(at: newText.length - suffixLength - 1)
        {
            suffixLength += 1
        }

        return AutomaticDictionaryTextChange(
            oldRange: NSRange(
                location: prefixLength,
                length: oldText.length - prefixLength - suffixLength
            ),
            newRange: NSRange(
                location: prefixLength,
                length: newText.length - prefixLength - suffixLength
            )
        )
    }

    static func isChangeInsideInsertedRange(
        _ change: AutomaticDictionaryTextChange,
        insertedRange: NSRange,
        allowsInsertionAtEnd: Bool = false
    ) -> Bool {
        guard insertedRange.location != NSNotFound, insertedRange.length > 0 else { return false }
        let insertedEnd = NSMaxRange(insertedRange)

        if change.oldRange.length == 0 {
            return change.oldRange.location >= insertedRange.location &&
                (change.oldRange.location < insertedEnd ||
                    (allowsInsertionAtEnd && change.oldRange.location == insertedEnd))
        }

        return change.oldRange.location >= insertedRange.location &&
            NSMaxRange(change.oldRange) <= insertedEnd
    }

    static func candidate(
        before: String,
        after: String,
        insertedRange: NSRange,
        allowsInsertionAtEnd: Bool = false
    ) -> AutomaticDictionaryCorrectionCandidate? {
        guard let change = self.textChange(before: before, after: after),
              self.isChangeInsideInsertedRange(
                  change,
                  insertedRange: insertedRange,
                  allowsInsertionAtEnd: allowsInsertionAtEnd
              )
        else {
            return nil
        }

        let oldTokenRange = self.expandedTokenRange(in: before, around: change.oldRange)
        let newTokenRange = self.expandedTokenRange(in: after, around: change.newRange)
        guard oldTokenRange.location >= insertedRange.location,
              NSMaxRange(oldTokenRange) <= NSMaxRange(insertedRange)
        else {
            return nil
        }

        let heard = self.cleanedCandidate((before as NSString).substring(with: oldTokenRange))
        let corrected = self.cleanedCandidate((after as NSString).substring(with: newTokenRange))
        guard self.isValidCandidate(heard),
              self.isValidCandidate(corrected),
              self.isMeaningfulCorrection(heard: heard, corrected: corrected),
              heard != corrected,
              heard.count + corrected.count <= self.maxCombinedLength
        else {
            return nil
        }

        return AutomaticDictionaryCorrectionCandidate(
            heardText: heard,
            correctedText: corrected
        )
    }

    static func isWordContinuationAtInsertedRangeEnd(
        _ change: AutomaticDictionaryTextChange,
        after: String,
        insertedRange: NSRange
    ) -> Bool {
        guard change.oldRange.length == 0,
              change.oldRange.location == NSMaxRange(insertedRange),
              NSMaxRange(change.newRange) <= (after as NSString).length
        else { return false }
        let insertedText = (after as NSString).substring(with: change.newRange)
        return !insertedText.isEmpty && insertedText.unicodeScalars.allSatisfy {
            !self.boundaryCharacters.contains($0)
        }
    }

    static func correctedTokenRange(before: String, after: String) -> NSRange? {
        guard let change = self.textChange(before: before, after: after) else { return nil }
        return self.expandedTokenRange(in: after, around: change.newRange)
    }

    static func selectionTouchesCandidate(_ selection: NSRange, candidateRange: NSRange) -> Bool {
        guard selection.location != NSNotFound, candidateRange.location != NSNotFound else { return false }
        if selection.length == 0 {
            return selection.location >= candidateRange.location &&
                selection.location <= NSMaxRange(candidateRange)
        }
        return NSIntersectionRange(selection, candidateRange).length > 0
    }

    static func changeContinuesCandidate(
        _ change: AutomaticDictionaryTextChange,
        after: String,
        candidateRange: NSRange
    ) -> Bool {
        if change.oldRange.length > 0 {
            return NSIntersectionRange(change.oldRange, candidateRange).length > 0
        }

        guard change.oldRange.location >= candidateRange.location,
              change.oldRange.location <= NSMaxRange(candidateRange)
        else {
            return false
        }

        guard change.oldRange.location == NSMaxRange(candidateRange) else { return true }
        let text = after as NSString
        guard change.newRange.location != NSNotFound,
              NSMaxRange(change.newRange) <= text.length
        else {
            return false
        }
        let insertedText = text.substring(with: change.newRange)
        return insertedText.unicodeScalars.allSatisfy { !self.boundaryCharacters.contains($0) }
    }

    private static func expandedTokenRange(in text: String, around range: NSRange) -> NSRange {
        let nsText = text as NSString
        let safeLocation = max(0, min(range.location, nsText.length))
        let safeEnd = max(safeLocation, min(NSMaxRange(range), nsText.length))
        var start = safeLocation
        var end = safeEnd

        while start > 0, !self.isBoundary(nsText.character(at: start - 1)) {
            start -= 1
        }
        while end < nsText.length, !self.isBoundary(nsText.character(at: end)) {
            end += 1
        }

        return NSRange(location: start, length: end - start)
    }

    private static func isBoundary(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return false }
        return self.boundaryCharacters.contains(scalar)
    }

    private static func cleanedCandidate(_ value: String) -> String {
        value.trimmingCharacters(in: self.edgeCharacters)
    }

    private static func isValidCandidate(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= self.maxCandidateLength,
              value.rangeOfCharacter(from: .alphanumerics) != nil
        else {
            return false
        }

        let words = value.split(whereSeparator: { $0.isWhitespace })
        return !words.isEmpty && words.count <= self.maxWords
    }

    private static func isMeaningfulCorrection(heard: String, corrected: String) -> Bool {
        let heardCharacters = heard.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let correctedCharacters = corrected.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        guard heardCharacters.count >= 2,
              correctedCharacters.count >= 2,
              heardCharacters.contains(where: { CharacterSet.letters.contains($0) }),
              correctedCharacters.contains(where: { CharacterSet.letters.contains($0) })
        else {
            return false
        }

        let heardSemantic = String(String.UnicodeScalarView(heardCharacters))
        let correctedSemantic = String(String.UnicodeScalarView(correctedCharacters))
        return heardSemantic != correctedSemantic
    }
}

struct DictionarySuggestionPolicyConfig {
    var requiredOccurrences = 2
    var occurrenceWindow: TimeInterval = 7 * 24 * 60 * 60
    var dismissedPairCooldown: TimeInterval = 7 * 24 * 60 * 60
    var maximumSessionIgnores = 3
    var retentionDuration: TimeInterval = 30 * 24 * 60 * 60
    var maximumStoredPairs = 200
}

enum AutomaticDictionarySuggestionOutcome {
    case accepted
    case ignored
    case dismissed
    case timedOut
}

@MainActor
final class AutomaticDictionarySuggestionPolicy {
    static let shared = AutomaticDictionarySuggestionPolicy()

    private struct PairRecord: Codable {
        var heardText: String
        var correctedText: String
        var occurrences: [Date] = []
        var lastShownAt: Date?
        var dismissedUntil: Date?
        var isAccepted = false
    }

    private struct PersistedState: Codable {
        var records: [String: PairRecord] = [:]
    }

    private static let defaultsKey = "AutomaticDictionarySuggestionPolicyStateV1"

    private let defaults: UserDefaults
    private let configuration: DictionarySuggestionPolicyConfig
    private var state: PersistedState
    private var sessionIgnoreCount = 0

    init(
        defaults: UserDefaults = .standard,
        configuration: DictionarySuggestionPolicyConfig = .init()
    ) {
        self.defaults = defaults
        self.configuration = configuration
        if let data = defaults.data(forKey: Self.defaultsKey),
           let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        {
            self.state = state
        } else {
            self.state = PersistedState()
        }
    }

    func shouldShow(
        _ candidate: AutomaticDictionaryCorrectionCandidate,
        requiredOccurrences: Int? = nil,
        now: Date = Date()
    ) -> Bool {
        self.prune(now: now)
        let key = self.key(for: candidate)
        var record = self.state.records[key] ?? PairRecord(
            heardText: candidate.heardText,
            correctedText: candidate.correctedText
        )
        record.occurrences.removeAll { now.timeIntervalSince($0) > self.configuration.occurrenceWindow }
        record.occurrences.append(now)
        self.state.records[key] = record
        self.save()

        let correctedText = self.normalized(candidate.correctedText)
        let occurrenceCount = self.state.records.values
            .filter { self.normalized($0.correctedText) == correctedText }
            .flatMap(\.occurrences)
            .filter { now.timeIntervalSince($0) <= self.configuration.occurrenceWindow }
            .count
        guard !record.isAccepted,
              record.dismissedUntil.map({ $0 <= now }) ?? true,
              occurrenceCount >= (requiredOccurrences ?? self.configuration.requiredOccurrences),
              self.sessionIgnoreCount < self.configuration.maximumSessionIgnores
        else {
            return false
        }
        return true
    }

    func markShown(_ candidate: AutomaticDictionaryCorrectionCandidate, now: Date = Date()) {
        let key = self.key(for: candidate)
        guard var record = self.state.records[key] else { return }
        record.lastShownAt = now
        self.state.records[key] = record
        self.save()
    }

    func record(
        _ outcome: AutomaticDictionarySuggestionOutcome,
        for candidate: AutomaticDictionaryCorrectionCandidate,
        now: Date = Date()
    ) {
        let key = self.key(for: candidate)
        guard var record = self.state.records[key] else { return }
        switch outcome {
        case .accepted, .ignored:
            record.isAccepted = true
            record.dismissedUntil = nil
        case .dismissed, .timedOut:
            record.dismissedUntil = now.addingTimeInterval(self.configuration.dismissedPairCooldown)
            self.sessionIgnoreCount += 1
        }
        self.state.records[key] = record
        self.save()
    }

    private func key(for candidate: AutomaticDictionaryCorrectionCandidate) -> String {
        "\(self.normalized(candidate.heardText))\u{1F}\(self.normalized(candidate.correctedText))"
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private func prune(now: Date) {
        self.state.records = self.state.records.filter { _, record in
            let latestActivity = ([record.lastShownAt] + record.occurrences.map(Optional.some)).compactMap { $0 }.max()
            return record.isAccepted || latestActivity.map {
                now.timeIntervalSince($0) <= self.configuration.retentionDuration
            } ?? false
        }
        if self.state.records.count > self.configuration.maximumStoredPairs {
            let sortedKeys = self.state.records.keys.sorted {
                (self.state.records[$0]?.lastShownAt ?? .distantPast) >
                    (self.state.records[$1]?.lastShownAt ?? .distantPast)
            }
            let retainedKeys = Set(sortedKeys.prefix(self.configuration.maximumStoredPairs))
            self.state.records = self.state.records.filter { retainedKeys.contains($0.key) }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(self.state) else { return }
        self.defaults.set(data, forKey: Self.defaultsKey)
    }
}

@MainActor
final class AutomaticDictionaryCorrectionTracker {
    static let shared = AutomaticDictionaryCorrectionTracker()

    private struct InsertionSeed {
        let element: AXUIElement
        let pid: pid_t
        let expectedValue: String
        let insertedRange: NSRange
    }

    private struct PendingCorrection {
        let id = UUID()
        let beforeValue: String
        var afterValue: String
        let insertedRange: NSRange
        var correctedRange: NSRange?
    }

    private struct ObservationSession {
        let element: AXUIElement
        let applicationElement: AXUIElement
        let pid: pid_t
        let observesSelectionChanges: Bool
        let observesFocusChanges: Bool
        var lastValue: String
        var insertedRange: NSRange
        var pendingCorrection: PendingCorrection?
    }

    private static let maximumFieldLength = 100_000
    private static let verificationAttempts = 20
    private static let verificationDelayNanoseconds: UInt64 = 50_000_000
    private static let observationDurationNanoseconds: UInt64 = 30_000_000_000
    private static let completionSignalDelayNanoseconds: UInt64 = 1_000_000_000
    private static let inactivityFallbackNanoseconds: UInt64 = 3_000_000_000

    private var observer: AXObserver?
    private var session: ObservationSession?
    private var verificationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    private init() {}

    func beginObservingInsertion(_ insertedText: String, targetPID: pid_t?) {
        self.cancel()
        guard SettingsStore.shared.automaticDictionaryLearningEnabled,
              !insertedText.isEmpty
        else {
            return
        }

        self.verificationTask = Task { @MainActor [weak self] in
            for _ in 0..<Self.verificationAttempts {
                guard !Task.isCancelled, let self else { return }
                if let seed = self.captureAnchoredInsertion(
                    insertedText: insertedText,
                    targetPID: targetPID
                ) {
                    self.installObserver(for: seed)
                    return
                }
                try? await Task.sleep(nanoseconds: Self.verificationDelayNanoseconds)
            }
        }
    }

    func cancel() {
        self.verificationTask?.cancel()
        self.verificationTask = nil
        self.timeoutTask?.cancel()
        self.timeoutTask = nil
        self.debounceTask?.cancel()
        self.debounceTask = nil
        self.removeObserver()
        self.session = nil
        DictionaryCorrectionOverlayController.shared.hide()
    }

    func handleObservedValueChange() {
        guard var session = self.session,
              let currentValue = self.stringValue(of: session.element),
              currentValue != session.lastValue,
              (currentValue as NSString).length <= Self.maximumFieldLength,
              let change = AutomaticDictionaryCorrectionDetector.textChange(
                  before: session.lastValue,
                  after: currentValue
              )
        else {
            return
        }

        let allowsInsertionAtEnd = AutomaticDictionaryCorrectionDetector.isWordContinuationAtInsertedRangeEnd(
            change,
            after: currentValue,
            insertedRange: session.insertedRange
        )
        let isInside = AutomaticDictionaryCorrectionDetector.isChangeInsideInsertedRange(
            change,
            insertedRange: session.insertedRange,
            allowsInsertionAtEnd: allowsInsertionAtEnd
        )

        if var pending = session.pendingCorrection {
            let continuesCandidate = pending.correctedRange.map {
                AutomaticDictionaryCorrectionDetector.changeContinuesCandidate(
                    change,
                    after: currentValue,
                    candidateRange: $0
                )
            } ?? isInside

            if continuesCandidate {
                pending.afterValue = currentValue
                pending.correctedRange = AutomaticDictionaryCorrectionDetector.correctedTokenRange(
                    before: pending.beforeValue,
                    after: currentValue
                )
                session.pendingCorrection = pending
                session.insertedRange.length = max(
                    0,
                    session.insertedRange.length + change.newRange.length - change.oldRange.length
                )
                self.scheduleCandidateEvaluation(
                    for: pending.id,
                    after: Self.inactivityFallbackNanoseconds
                )
            } else {
                self.scheduleCandidateEvaluation(
                    for: pending.id,
                    after: Self.completionSignalDelayNanoseconds
                )
            }
        } else if isInside {
            let pending = PendingCorrection(
                beforeValue: session.lastValue,
                afterValue: currentValue,
                insertedRange: session.insertedRange,
                correctedRange: AutomaticDictionaryCorrectionDetector.correctedTokenRange(
                    before: session.lastValue,
                    after: currentValue
                )
            )
            session.pendingCorrection = pending
            session.insertedRange.length = max(
                0,
                session.insertedRange.length + change.newRange.length - change.oldRange.length
            )
            self.scheduleCandidateEvaluation(
                for: pending.id,
                after: Self.inactivityFallbackNanoseconds
            )
        } else if NSMaxRange(change.oldRange) <= session.insertedRange.location {
            session.insertedRange.location = max(
                0,
                session.insertedRange.location + change.newRange.length - change.oldRange.length
            )
        } else if change.oldRange.location < NSMaxRange(session.insertedRange) {
            self.cancel()
            return
        }

        session.lastValue = currentValue
        self.session = session
    }

    func handleObservedSelectionChange() {
        guard let session = self.session,
              let pending = session.pendingCorrection,
              let correctedRange = pending.correctedRange,
              let selection = self.selectedRange(of: session.element)
        else {
            return
        }

        let delay = AutomaticDictionaryCorrectionDetector.selectionTouchesCandidate(
            selection,
            candidateRange: correctedRange
        ) ? Self.inactivityFallbackNanoseconds : Self.completionSignalDelayNanoseconds
        self.scheduleCandidateEvaluation(for: pending.id, after: delay)
    }

    func handleObservedFocusChange() {
        guard let session = self.session,
              let pending = session.pendingCorrection,
              let focus = self.focusedElementAndPID(),
              focus.pid != session.pid || !CFEqual(focus.element, session.element)
        else {
            return
        }
        self.scheduleCandidateEvaluation(
            for: pending.id,
            after: Self.completionSignalDelayNanoseconds
        )
    }

    private func captureAnchoredInsertion(
        insertedText: String,
        targetPID: pid_t?
    ) -> InsertionSeed? {
        guard let focus = self.focusedElementAndPID(),
              targetPID == nil || focus.pid == targetPID,
              !self.isSecureTextInput(focus.element),
              let value = self.stringValue(of: focus.element),
              (value as NSString).length <= Self.maximumFieldLength,
              let selectedRange = self.selectedRange(of: focus.element),
              selectedRange.length == 0
        else {
            return nil
        }

        let insertedLength = (insertedText as NSString).length
        let start = selectedRange.location - insertedLength
        guard start >= 0 else { return nil }
        let insertedRange = NSRange(location: start, length: insertedLength)
        guard NSMaxRange(insertedRange) <= (value as NSString).length,
              (value as NSString).substring(with: insertedRange) == insertedText
        else {
            return nil
        }

        return InsertionSeed(
            element: focus.element,
            pid: focus.pid,
            expectedValue: value,
            insertedRange: insertedRange
        )
    }

    private func installObserver(for seed: InsertionSeed) {
        self.verificationTask = nil
        var createdObserver: AXObserver?
        let createResult = AXObserverCreate(seed.pid, automaticDictionaryAXObserverCallback, &createdObserver)
        guard createResult == .success, let createdObserver else { return }

        let context = Unmanaged.passUnretained(self).toOpaque()
        let addResult = AXObserverAddNotification(
            createdObserver,
            seed.element,
            kAXValueChangedNotification as CFString,
            context
        )
        guard addResult == .success else { return }

        let applicationElement = AXUIElementCreateApplication(seed.pid)
        let selectionResult = AXObserverAddNotification(
            createdObserver,
            seed.element,
            kAXSelectedTextChangedNotification as CFString,
            context
        )
        let focusResult = AXObserverAddNotification(
            createdObserver,
            applicationElement,
            kAXFocusedUIElementChangedNotification as CFString,
            context
        )

        self.observer = createdObserver
        self.session = ObservationSession(
            element: seed.element,
            applicationElement: applicationElement,
            pid: seed.pid,
            observesSelectionChanges: selectionResult == .success,
            observesFocusChanges: focusResult == .success,
            lastValue: seed.expectedValue,
            insertedRange: seed.insertedRange,
            pendingCorrection: nil
        )
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(createdObserver), .commonModes)

        self.timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.observationDurationNanoseconds)
            guard !Task.isCancelled else { return }
            self?.cancel()
        }
    }

    private func scheduleCandidateEvaluation(for pendingID: UUID?, after delay: UInt64) {
        guard let pendingID else { return }
        self.debounceTask?.cancel()
        self.debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled,
                  let self,
                  let pending = self.session?.pendingCorrection,
                  pending.id == pendingID
            else {
                return
            }
            self.evaluate(pending)
        }
    }

    private func evaluate(_ pending: PendingCorrection) {
        let candidate = AutomaticDictionaryCorrectionDetector.candidate(
            before: pending.beforeValue,
            after: pending.afterValue,
            insertedRange: pending.insertedRange,
            allowsInsertionAtEnd: true
        )
        self.stopObservation()

        guard let candidate,
              SettingsStore.shared.automaticDictionaryLearningEnabled,
              !SettingsStore.shared.shouldShowOnboarding,
              !self.isAlreadySaved(candidate),
              !AppServices.shared.asr.isRunning,
              !DictionaryCorrectionOverlayController.shared.isPresented,
              AutomaticDictionarySuggestionPolicy.shared.shouldShow(
                  candidate,
                  requiredOccurrences: SettingsStore.shared.automaticDictionarySuggestionFrequency.rawValue
              )
        else {
            return
        }

        AutomaticDictionarySuggestionPolicy.shared.markShown(candidate)
        DictionaryCorrectionOverlayController.shared.show(candidate: candidate) { outcome in
            AutomaticDictionarySuggestionPolicy.shared.record(outcome, for: candidate)
        }
    }

    private func isAlreadySaved(_ candidate: AutomaticDictionaryCorrectionCandidate) -> Bool {
        let trigger = candidate.heardText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return SettingsStore.shared.customDictionaryEntries.contains { entry in
            entry.triggers.contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == trigger
            }
        }
    }

    private func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private func isSecureTextInput(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value)
        guard result == .success, let subrole = value as? String else { return false }
        return subrole == (kAXSecureTextFieldSubrole as String) || subrole.localizedCaseInsensitiveContains("secure")
    }

    private func selectedRange(of element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range),
              range.location != kCFNotFound,
              range.location >= 0,
              range.length >= 0
        else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }

    private func focusedElementAndPID() -> (element: AXUIElement, pid: pid_t)? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard result == .success,
              let focusedElement,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID()
        else {
            return nil
        }

        let element = unsafeBitCast(focusedElement, to: AXUIElement.self)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid > 0 ? (element, pid) : nil
    }

    private func stopObservation() {
        self.verificationTask?.cancel()
        self.verificationTask = nil
        self.timeoutTask?.cancel()
        self.timeoutTask = nil
        self.debounceTask?.cancel()
        self.debounceTask = nil
        self.removeObserver()
        self.session = nil
    }

    private func removeObserver() {
        guard let observer = self.observer else { return }
        if let session = self.session {
            AXObserverRemoveNotification(observer, session.element, kAXValueChangedNotification as CFString)
            if session.observesSelectionChanges {
                AXObserverRemoveNotification(
                    observer,
                    session.element,
                    kAXSelectedTextChangedNotification as CFString
                )
            }
            if session.observesFocusChanges {
                AXObserverRemoveNotification(
                    observer,
                    session.applicationElement,
                    kAXFocusedUIElementChangedNotification as CFString
                )
            }
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
    }
}

private let automaticDictionaryAXObserverCallback: AXObserverCallback = { _, _, notification, context in
    guard let context else { return }

    let tracker = Unmanaged<AutomaticDictionaryCorrectionTracker>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in
        switch notification as String {
        case kAXValueChangedNotification as String:
            tracker.handleObservedValueChange()
        case kAXSelectedTextChangedNotification as String:
            // Web-backed editors may move the caret without emitting a value-change notification.
            tracker.handleObservedValueChange()
            tracker.handleObservedSelectionChange()
        case kAXFocusedUIElementChangedNotification as String:
            tracker.handleObservedFocusChange()
        default:
            break
        }
    }
}
