import AppKit
import ApplicationServices
import Foundation

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
    // Explicitly nonisolated: on macOS 15.4+ the synthesized main-actor deinit can abort until the OS runtime has the fix (swiftlang/swift#88036).
    nonisolated deinit {}

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
        let learningRecording: DictionaryLearningRecording?
        var lastValue: String
        var insertedRange: NSRange
        var pendingCorrection: PendingCorrection?
    }

    private static let maximumFieldLength = 100_000
    private static let verificationAttempts = 20
    private static let verificationDelayNanoseconds: UInt64 = 50_000_000
    nonisolated static func observationDuration(hasVoiceSpellings: Bool) -> Duration {
        // Keep observing through confirmation and the edit debounce. Ordinary dictations stay short.
        hasVoiceSpellings ? DictionaryVoiceSpellingLearner.confirmationWindow + .seconds(5) : .seconds(30)
    }

    private static let completionSignalDelayNanoseconds: UInt64 = 1_000_000_000
    private static let inactivityFallbackNanoseconds: UInt64 = 3_000_000_000

    private var observer: AXObserver?
    private var session: ObservationSession?
    private var verificationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var evidencePreparationTask: Task<Void, Never>?
    private var suggestionGeneration = UUID()

    private init() {}

    func beginObservingInsertion(
        _ insertedText: String, targetPID: pid_t?, learningRecording: DictionaryLearningRecording? = nil
    ) {
        self.cancel()
        guard SettingsStore.shared.automaticDictionaryLearningEnabled || DictionaryMatcherExperiment.collectNegatives,
              !insertedText.isEmpty
        else {
            return
        }

        self.verificationTask = Task { @MainActor [weak self] in
            for _ in 0..<Self.verificationAttempts {
                // Give the paste time to land before probing, and keep the synchronous
                // Accessibility round trips off the main thread so they never delay
                // the event tap that delivers the paste itself.
                try? await Task.sleep(nanoseconds: Self.verificationDelayNanoseconds)
                guard !Task.isCancelled, self != nil else { return }
                let seed = await Self.captureAnchoredInsertionOffMain(
                    insertedText: insertedText,
                    targetPID: targetPID
                )
                guard !Task.isCancelled, let self else { return }
                if let seed {
                    self.installObserver(for: seed, learningRecording: DictionaryMatcherExperiment.sharedFeaturesEnabled ? learningRecording : nil)
                    return
                }
            }
        }
    }

    func cancel() {
        self.suggestionGeneration = UUID()
        self.evidencePreparationTask?.cancel()
        self.evidencePreparationTask = nil
        self.stopObservation()
        DictionaryCorrectionOverlayController.shared.hide()
    }

    func handleObservedValueChange() {
        guard var session = self.session,
              let currentValue = Self.stringValue(of: session.element),
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

        // Reject on the edit event, before the debounce can race the confirmation deadline.
        if isInside, let recording = session.learningRecording {
            DictionaryVoiceSpellingLearner.shared.cancel(recordingID: recording.id)
        }

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
              let selection = Self.selectedRange(of: session.element)
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
              let focus = Self.focusedElementAndPID(),
              focus.pid != session.pid || !CFEqual(focus.element, session.element)
        else {
            return
        }
        self.scheduleCandidateEvaluation(
            for: pending.id,
            after: Self.completionSignalDelayNanoseconds
        )
    }

    private nonisolated static let accessibilityProbeQueue = DispatchQueue(
        label: "com.fluidvoice.dictionary-correction.ax-probe",
        qos: .userInitiated
    )

    private nonisolated static func captureAnchoredInsertionOffMain(
        insertedText: String,
        targetPID: pid_t?
    ) async -> InsertionSeed? {
        await withCheckedContinuation { continuation in
            self.accessibilityProbeQueue.async {
                continuation.resume(
                    returning: self.captureAnchoredInsertion(insertedText: insertedText, targetPID: targetPID)
                )
            }
        }
    }

    private nonisolated static func captureAnchoredInsertion(
        insertedText: String,
        targetPID: pid_t?
    ) -> InsertionSeed? {
        guard let focus = focusedElementAndPID(),
              targetPID == nil || focus.pid == targetPID,
              !Self.isSecureTextInput(focus.element),
              let value = stringValue(of: focus.element),
              (value as NSString).length <= Self.maximumFieldLength,
              let selectedRange = Self.selectedRange(of: focus.element),
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

    private func installObserver(for seed: InsertionSeed, learningRecording: DictionaryLearningRecording?) {
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
            learningRecording: learningRecording,
            lastValue: seed.expectedValue,
            insertedRange: seed.insertedRange,
            pendingCorrection: nil
        )
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(createdObserver), .commonModes)

        if let learningRecording {
            DictionaryVoiceSpellingLearner.shared.propose(learningRecording.alignment.voiceSpellings, recordingID: learningRecording.id)
        }
        let duration = Self.observationDuration(hasVoiceSpellings: learningRecording?.alignment.voiceSpellings.isEmpty == false)
        self.timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
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
        if let candidate {
            DictionaryVoiceSpellingLearner.shared.reject(editedText: candidate.heardText)
        }
        var context: DictionaryLearningCorrectionContext?
        if DictionaryMatcherExperiment.sharedFeaturesEnabled, let recording = self.session?.learningRecording, let range = candidate?.sourceUTF16Range {
            let before = pending.beforeValue as NSString
            let insertion = pending.insertedRange
            if insertion.location >= 0, insertion.location <= before.length,
               insertion.length >= 0, insertion.length <= before.length - insertion.location
            {
                context = DictionaryLearningCorrectionContext(
                    recording: recording, deliveredTextBeforeEdit: before.substring(with: insertion), selectedUTF16Range: range
                )
            }
        }
        self.stopObservation()

        if let candidate, let context, DictionaryMatcherExperiment.collectNegatives,
           !SettingsStore.shared.shouldShowOnboarding, !AppServices.shared.asr.isRunning,
           !DictionaryCorrectionOverlayController.shared.isPresented,
           let negative = DictionaryNegativeEvidenceResolver.resolve(context: context, heard: candidate.heardText, corrected: candidate.correctedText)
        {
            var prepared = candidate
            prepared.negativeCorrection = negative
            DictionaryCorrectionOverlayController.shared.show(candidate: prepared) { _ in }
            return
        }

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

        let generation = self.suggestionGeneration
        let pronunciationGeneration = DictionaryMatcherExperiment.generation
        self.evidencePreparationTask = Task { @MainActor [weak self, context] in
            let observedText = candidate.heardText
            let evidence = await Task.detached(priority: .utility) {
                guard DictionaryMatcherExperiment.sharedFeaturesEnabled, pronunciationGeneration == DictionaryMatcherExperiment.generation,
                      let context else { return DictionaryLearningAudioEvidence?.none }
                return try? DictionaryLearningAlignmentResolver.resolve(
                    recording: context.recording,
                    deliveredTextBeforeEdit: context.deliveredTextBeforeEdit,
                    selectedUTF16Range: context.selectedUTF16Range,
                    observedText: observedText
                )
            }.value
            guard !Task.isCancelled, let self, self.suggestionGeneration == generation,
                  SettingsStore.shared.automaticDictionaryLearningEnabled,
                  !SettingsStore.shared.shouldShowOnboarding,
                  !self.isAlreadySaved(candidate), !AppServices.shared.asr.isRunning,
                  !DictionaryCorrectionOverlayController.shared.isPresented
            else { return }
            var prepared = candidate
            prepared.audioEvidence = DictionaryMatcherExperiment.sharedFeaturesEnabled && pronunciationGeneration == DictionaryMatcherExperiment.generation ? evidence : nil
            self.evidencePreparationTask = nil
            AutomaticDictionarySuggestionPolicy.shared.markShown(prepared)
            DictionaryCorrectionOverlayController.shared.show(candidate: prepared) { outcome in
                AutomaticDictionarySuggestionPolicy.shared.record(outcome, for: prepared)
            }
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

    private nonisolated static func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private nonisolated static func isSecureTextInput(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value)
        guard result == .success, let subrole = value as? String else { return false }
        return subrole == (kAXSecureTextFieldSubrole as String) || subrole.localizedCaseInsensitiveContains("secure")
    }

    private nonisolated static func selectedRange(of element: AXUIElement) -> NSRange? {
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

    private nonisolated static func focusedElementAndPID() -> (element: AXUIElement, pid: pid_t)? {
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
        if let recording = self.session?.learningRecording {
            DictionaryVoiceSpellingLearner.shared.cancel(recordingID: recording.id)
        }
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
