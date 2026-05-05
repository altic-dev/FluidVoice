import AppKit
import ApplicationServices
import Foundation

final class AutoLearnDictionaryService {
    static let shared = AutoLearnDictionaryService()

    private init() {}

    private let monitoringTimeoutSeconds: TimeInterval = 30
    private let correctionProcessingDebounceSeconds: TimeInterval = 1.25
    private let suggestionThreshold = 2
    private let maxSegmentTokenCount = 3
    private let maxFullDiffTokenCount = 500
    private let scopedDiffContextCharacterCount = 300

    private var insertedText: String = ""
    private var baselineText: String = ""
    private var lastKnownText: String = ""
    private var recordedSessionObservationCounts: [String: Int] = [:]
    private var axObserver: AXObserver?
    private var workspaceObserver: NSObjectProtocol?
    private var timeoutTimer: DispatchSourceTimer?
    private var correctionProcessingTimer: DispatchSourceTimer?
    private var pollingTimer: DispatchSourceTimer?
    private var monitoredElement: AXUIElement?
    private var monitoredPID: pid_t?
    private var isActive = false

    func captureFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?

        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        ) == .success,
        let focusedElement,
        CFGetTypeID(focusedElement) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return unsafeBitCast(focusedElement, to: AXUIElement.self)
    }

    func pid(for element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else {
            return nil
        }
        return pid
    }

    func beginMonitoring(pastedText: String, element: AXUIElement) {
        guard SettingsStore.shared.autoLearnCustomDictionaryEnabled else {
            self.log("Monitoring skipped: auto-learn disabled.")
            return
        }
        self.startMonitoring(pastedText: pastedText, element: element)
    }

    func stopMonitoring() {
        self.isActive = false

        self.timeoutTimer?.cancel()
        self.timeoutTimer = nil

        self.correctionProcessingTimer?.cancel()
        self.correctionProcessingTimer = nil

        self.pollingTimer?.cancel()
        self.pollingTimer = nil
        self.monitoredElement = nil
        self.monitoredPID = nil

        if let observer = self.axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            self.axObserver = nil
        }

        if let observer = self.workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.workspaceObserver = nil
        }
    }

    private func startMonitoring(pastedText: String, element: AXUIElement) {
        self.finalize()
        self.insertedText = pastedText
        self.recordedSessionObservationCounts = [:]
        self.monitoredElement = element
        self.monitoredPID = self.pid(for: element)

        // Capture the full field value as baseline so that both baselineText
        // and lastKnownText (updated via kAXValueChanged) cover the same scope.
        // Without this, dictating into an existing non-empty editor would diff
        // the partial transcript against the entire field and produce junk.
        var fieldValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &fieldValue) == .success,
           let fullText = fieldValue as? String {
            self.baselineText = fullText
            self.lastKnownText = fullText
        } else {
            self.log("AXText_Unreadable: using inserted text as baseline.")
            self.baselineText = pastedText
            self.lastKnownText = pastedText
        }
        self.isActive = true

        self.setupValueChangeObserver(for: element)
        self.setupAppSwitchObserver()
        self.startTimeoutTimer()
    }

    private func setupValueChangeObserver(for element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else {
            self.setupPollingFallback(for: element)
            return
        }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, changedElement, _, refcon in
            guard let refcon else { return }
            let service = Unmanaged<AutoLearnDictionaryService>.fromOpaque(refcon).takeUnretainedValue()
            guard service.isActive else { return }

            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(changedElement, kAXValueAttribute as CFString, &value) == .success,
               let text = value as? String {
                service.updateLastKnownText(text)
            }
        }

        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else {
            self.setupPollingFallback(for: element)
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if AXObserverAddNotification(observer, element, kAXValueChangedNotification as CFString, refcon) == .success {
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            self.axObserver = observer
            self.setupPollingFallback(for: element)
        } else {
            // Notification registration failed (e.g., unsupported control).
            // Fall back to a lightweight polling loop to track edits.
            self.setupPollingFallback(for: element)
        }
    }

    private func setupPollingFallback(for element: AXUIElement) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self, self.isActive else { return }
            if let text = self.currentText(from: element) {
                self.updateLastKnownText(text)
            }
        }
        timer.resume()
        self.pollingTimer = timer
    }

    private func updateLastKnownText(_ text: String) {
        guard self.lastKnownText != text else { return }
        self.lastKnownText = text
        self.scheduleCorrectionProcessing()
    }

    private func scheduleCorrectionProcessing() {
        guard self.isActive, self.baselineText != self.lastKnownText else { return }

        self.correctionProcessingTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + self.correctionProcessingDebounceSeconds)
        timer.setEventHandler { [weak self] in
            guard let self, self.isActive else { return }
            self.correctionProcessingTimer = nil
            self.processCurrentCorrections()
        }
        timer.resume()
        self.correctionProcessingTimer = timer
    }

    private func setupAppSwitchObserver() {
        self.workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, self.isActive else { return }
            if let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               !self.shouldFinalizeForActivatedApplication(pid: activatedApp.processIdentifier)
            {
                return
            }
            self.finalize()
        }
    }

    private func shouldFinalizeForActivatedApplication(pid activatedPID: pid_t?) -> Bool {
        guard let activatedPID, let monitoredPID = self.monitoredPID else {
            return true
        }
        return activatedPID != monitoredPID
    }

    private func startTimeoutTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + self.monitoringTimeoutSeconds)
        timer.setEventHandler { [weak self] in
            guard let self, self.isActive else { return }
            self.finalize()
        }
        timer.resume()
        self.timeoutTimer = timer
    }

    private func finalize() {
        guard self.isActive else { return }
        if let monitoredElement = self.monitoredElement,
           let currentText = self.currentText(from: monitoredElement) {
            self.lastKnownText = currentText
        }
        self.processCurrentCorrections()
        self.stopMonitoring()
        self.insertedText = ""
        self.baselineText = ""
        self.lastKnownText = ""
        self.recordedSessionObservationCounts = [:]
    }

    private func currentText(from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func correctionCandidates(
        baseline: String,
        currentText: String,
        insertedText: String
    ) -> [CorrectionDiffEngine.Candidate] {
        let baselineTokenCount = self.diffTokenCount(baseline)
        let currentTokenCount = self.diffTokenCount(currentText)
        if baselineTokenCount <= self.maxFullDiffTokenCount,
           currentTokenCount <= self.maxFullDiffTokenCount {
            return CorrectionDiffEngine.findCorrectionCandidates(
                original: baseline,
                edited: currentText,
                maxSegmentTokenCount: self.maxSegmentTokenCount
            )
        }

        self.log(
            "DiffSkipped_OverTokenLimit: baselineTokens=\(baselineTokenCount), currentTokens=\(currentTokenCount); attempting scoped diff."
        )

        guard let scopedText = self.scopedDiffText(
            baseline: baseline,
            currentText: currentText,
            insertedText: insertedText
        ) else {
            return []
        }

        let scopedBaselineTokenCount = self.diffTokenCount(scopedText.baseline)
        let scopedCurrentTokenCount = self.diffTokenCount(scopedText.current)
        guard scopedBaselineTokenCount <= self.maxFullDiffTokenCount,
              scopedCurrentTokenCount <= self.maxFullDiffTokenCount else {
            self.log(
                "DiffSkipped_ScopedWindowOverTokenLimit: baselineTokens=\(scopedBaselineTokenCount), currentTokens=\(scopedCurrentTokenCount)."
            )
            return []
        }

        return CorrectionDiffEngine.findCorrectionCandidates(
            original: scopedText.baseline,
            edited: scopedText.current,
            maxSegmentTokenCount: self.maxSegmentTokenCount
        )
    }

    private func scopedDiffText(
        baseline: String,
        currentText: String,
        insertedText: String
    ) -> (baseline: String, current: String)? {
        let inserted = insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inserted.isEmpty else {
            self.log("DiffSkipped_EmptyInsertedText")
            return nil
        }

        let insertedRangeResult = self.uniqueRange(of: inserted, in: baseline)
        guard case let .found(insertedRange) = insertedRangeResult else {
            switch insertedRangeResult {
            case .ambiguous:
                self.log("DiffSkipped_AmbiguousOccurrence")
            case .notFound:
                self.log("DiffSkipped_InsertedTextNotFound")
            case .found:
                break
            }
            return nil
        }

        let baselineWindowRange = self.expandedRange(
            in: baseline,
            around: insertedRange,
            contextCharacters: self.scopedDiffContextCharacterCount
        )
        let prefixAnchor = String(baseline[baselineWindowRange.lowerBound..<insertedRange.lowerBound])
        let suffixAnchor = String(baseline[insertedRange.upperBound..<baselineWindowRange.upperBound])

        guard let currentWindowRange = self.currentWindowRange(
            in: currentText,
            prefixAnchor: prefixAnchor,
            suffixAnchor: suffixAnchor
        ) else {
            return nil
        }

        return (
            baseline: String(baseline[baselineWindowRange]),
            current: String(currentText[currentWindowRange])
        )
    }

    private enum UniqueRangeResult {
        case found(Range<String.Index>)
        case notFound
        case ambiguous
    }

    private func uniqueRange(of needle: String, in haystack: String) -> UniqueRangeResult {
        self.uniqueRange(of: needle, in: haystack, range: haystack.startIndex..<haystack.endIndex)
    }

    private func uniqueRange(
        of needle: String,
        in haystack: String,
        range searchRange: Range<String.Index>
    ) -> UniqueRangeResult {
        guard let firstRange = haystack.range(of: needle, range: searchRange) else {
            return .notFound
        }

        if haystack.range(of: needle, range: firstRange.upperBound..<searchRange.upperBound) != nil {
            return .ambiguous
        }

        return .found(firstRange)
    }

    private func expandedRange(
        in text: String,
        around range: Range<String.Index>,
        contextCharacters: Int
    ) -> Range<String.Index> {
        let lowerDistance = min(contextCharacters, text.distance(from: text.startIndex, to: range.lowerBound))
        let upperDistance = min(contextCharacters, text.distance(from: range.upperBound, to: text.endIndex))
        let lowerBound = text.index(range.lowerBound, offsetBy: -lowerDistance)
        let upperBound = text.index(range.upperBound, offsetBy: upperDistance)
        return lowerBound..<upperBound
    }

    private func currentWindowRange(
        in currentText: String,
        prefixAnchor: String,
        suffixAnchor: String
    ) -> Range<String.Index>? {
        let startIndex: String.Index
        let suffixSearchStart: String.Index
        if prefixAnchor.isEmpty {
            startIndex = currentText.startIndex
            suffixSearchStart = currentText.startIndex
        } else {
            let prefixResult = self.uniqueRange(of: prefixAnchor, in: currentText)
            guard case let .found(prefixRange) = prefixResult else {
                switch prefixResult {
                case .ambiguous:
                    self.log("DiffSkipped_AmbiguousPrefixAnchor")
                case .notFound:
                    self.log("DiffSkipped_PrefixAnchorNotFound")
                case .found:
                    break
                }
                return nil
            }
            startIndex = prefixRange.lowerBound
            suffixSearchStart = prefixRange.upperBound
        }

        let endIndex: String.Index
        if suffixAnchor.isEmpty {
            endIndex = currentText.endIndex
        } else {
            let searchRange = suffixSearchStart..<currentText.endIndex
            let suffixResult = self.uniqueRange(of: suffixAnchor, in: currentText, range: searchRange)
            guard case let .found(relativeSuffixRange) = suffixResult else {
                switch suffixResult {
                case .ambiguous:
                    self.log("DiffSkipped_AmbiguousSuffixAnchor")
                case .notFound:
                    self.log("DiffSkipped_SuffixAnchorNotFound")
                case .found:
                    break
                }
                return nil
            }
            endIndex = relativeSuffixRange.upperBound
        }

        guard startIndex <= endIndex else {
            self.log("DiffSkipped_InvalidScopedWindow")
            return nil
        }
        return startIndex..<endIndex
    }

    private func diffTokenCount(_ text: String) -> Int {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
    }

    private func log(_ message: String) {
        DebugLogger.shared.debug(message, source: "AutoLearnDictionary")
    }

    private func processCurrentCorrections() {
        guard self.isActive else { return }
        guard SettingsStore.shared.autoLearnCustomDictionaryEnabled else { return }

        let baseline = self.baselineText
        let currentText = self.lastKnownText
        let insertedText = self.insertedText

        guard baseline != currentText else { return }

        let corrections = self.correctionCandidates(
            baseline: baseline,
            currentText: currentText,
            insertedText: insertedText
        )

        guard !corrections.isEmpty else { return }

        var observationCounts: [String: (correction: CorrectionDiffEngine.Candidate, count: Int)] = [:]

        for correction in corrections where
            self.isCorrectionFromInsertedText(correction, insertedText: insertedText) &&
            self.shouldTrack(correction, editedText: currentText) {
            let observationKey = self.sessionObservationKey(
                original: correction.original,
                replacement: correction.replacement
            )
            var observation = observationCounts[observationKey] ?? (correction: correction, count: 0)
            observation.count += 1
            observationCounts[observationKey] = observation
        }

        for (observationKey, observation) in observationCounts {
            let alreadyRecordedCount = self.recordedSessionObservationCounts[observationKey, default: 0]
            guard observation.count > alreadyRecordedCount else { continue }

            for _ in alreadyRecordedCount..<observation.count {
                self.recordObservation(
                    original: observation.correction.original,
                    replacement: observation.correction.replacement
                )
            }
            self.recordedSessionObservationCounts[observationKey] = observation.count
        }
    }

    private func sessionObservationKey(original: String, replacement: String) -> String {
        "\(self.triggerPhrase(original))\u{1F}\(replacement.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private func shouldTrack(_ candidate: CorrectionDiffEngine.Candidate, editedText: String) -> Bool {
        let originalText = self.triggerPhrase(candidate.original)
        let originalKey = self.normalizePhrase(candidate.original)
        let replacement = candidate.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacementKey = self.normalizePhrase(replacement)
        let signal = self.suggestionSignal(
            original: originalText,
            replacement: replacement
        )
        let isSameKeyCorrection = originalKey == replacementKey

        guard !originalText.isEmpty, !originalKey.isEmpty, !replacement.isEmpty, !replacementKey.isEmpty else { return false }
        guard !isSameKeyCorrection || signal != nil else { return false }
        guard originalText.count <= 64, replacement.count <= 64 else { return false }
        guard isSameKeyCorrection || self.looksLikeARealCorrection(original: originalKey, replacement: replacementKey) else { return false }
        guard !self.mappingAlreadyExists(original: originalText, replacement: replacement) else { return false }

        return true
    }

    private func mappingAlreadyExists(original: String, replacement: String) -> Bool {
        SettingsStore.shared.customDictionaryEntries.contains { entry in
            entry.replacement.caseInsensitiveCompare(replacement) == .orderedSame &&
                entry.triggers.contains(original)
        }
    }

    private func recordObservation(original: String, replacement: String) {
        let normalizedOriginal = self.triggerPhrase(original)
        let normalizedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedOriginal.isEmpty, !normalizedReplacement.isEmpty else { return }

        var suggestions = SettingsStore.shared.autoLearnCustomDictionarySuggestions
        let now = Date()

        if let index = suggestions.firstIndex(where: {
            self.triggerPhrase($0.originalText) == normalizedOriginal &&
                $0.replacement.caseInsensitiveCompare(normalizedReplacement) == .orderedSame
        }) {
            let previousOccurrences = suggestions[index].occurrences
            suggestions[index].occurrences += 1
            suggestions[index].lastObservedAt = now
            if suggestions[index].status == .dismissed {
                let dismissedAt = suggestions[index].dismissedAtOccurrenceCount ?? previousOccurrences
                suggestions[index].dismissedAtOccurrenceCount = dismissedAt

                if suggestions[index].occurrences - dismissedAt >= self.displayThreshold(forReplacement: normalizedReplacement) {
                    suggestions[index].status = .pending
                    suggestions[index].dismissedAtOccurrenceCount = nil
                }
            }
        } else {
            suggestions.append(
                SettingsStore.AutoLearnSuggestion(
                    originalText: normalizedOriginal,
                    replacement: normalizedReplacement,
                    occurrences: 1,
                    lastObservedAt: now,
                    status: .pending
                )
            )
        }

        suggestions.sort { lhs, rhs in
            if lhs.status != rhs.status {
                return lhs.status == .pending
            }
            if lhs.occurrences != rhs.occurrences {
                return lhs.occurrences > rhs.occurrences
            }
            return lhs.lastObservedAt > rhs.lastObservedAt
        }

        SettingsStore.shared.autoLearnCustomDictionarySuggestions = suggestions
    }

    private func looksLikeARealCorrection(original: String, replacement: String) -> Bool {
        let distance = self.levenshteinDistance(original, replacement)
        let maxLength = max(original.count, replacement.count)
        guard maxLength > 0 else { return false }

        // Ratio-based threshold: allow higher edit distances for longer
        // (multi-word) phrases. Single-token swaps use a tighter ratio.
        let isMultiWord = original.contains(" ") || replacement.contains(" ")
        let maxRatio: Double = isMultiWord ? 0.65 : 0.50
        let ratio = Double(distance) / Double(maxLength)
        return ratio <= maxRatio
    }

    private func isCorrectionFromInsertedText(
        _ candidate: CorrectionDiffEngine.Candidate,
        insertedText: String
    ) -> Bool {
        // Use token-sequence containment to avoid learning edits outside the
        // most recent insertion without adding fragile editor-specific ranges.
        // If the same phrase appears elsewhere in the field, the review gate
        // still protects users from accepting an unwanted replacement.
        let insertedTokens = self.learningTokens(insertedText)
        let originalTokens = self.learningTokens(candidate.original)
        guard !insertedTokens.isEmpty, !originalTokens.isEmpty else { return false }
        guard originalTokens.count <= insertedTokens.count else { return false }

        for startIndex in 0...(insertedTokens.count - originalTokens.count) {
            let endIndex = startIndex + originalTokens.count
            if Array(insertedTokens[startIndex..<endIndex]) == originalTokens {
                return true
            }
        }

        return false
    }

    private func learningTokens(_ text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    func displayThreshold(for suggestion: SettingsStore.AutoLearnSuggestion) -> Int {
        self.displayThreshold(forReplacement: suggestion.replacement)
    }

    func displayThreshold(forReplacement replacement: String) -> Int {
        self.isHighSignalReplacement(replacement)
            ? 1
            : self.minimumSuggestionOccurrences
    }

    private enum SuggestionSignal {
        case ordinary
        case high
    }

    private func suggestionSignal(original: String, replacement: String) -> SuggestionSignal? {
        guard !original.isEmpty, !replacement.isEmpty else { return nil }
        guard original != replacement else { return nil }
        guard self.normalizePhrase(original) == self.normalizePhrase(replacement) else { return nil }

        if self.isHighSignalReplacement(replacement) {
            return .high
        }

        return original.caseInsensitiveCompare(replacement) == .orderedSame ? .ordinary : nil
    }

    func isHighSignalReplacement(_ replacement: String) -> Bool {
        let replacementScalars = replacement.unicodeScalars
        let uppercaseCount = replacementScalars.filter { CharacterSet.uppercaseLetters.contains($0) }.count
        return uppercaseCount > 1 ||
            replacement.dropFirst().contains(where: { $0.isUppercase }) ||
            replacement.rangeOfCharacter(from: .decimalDigits) != nil ||
            replacement.rangeOfCharacter(from: CharacterSet(charactersIn: "-_/.'&+")) != nil
    }

    private func triggerPhrase(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizePhrase(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)
        guard !lhsChars.isEmpty else { return rhsChars.count }
        guard !rhsChars.isEmpty else { return lhsChars.count }

        var previous = Array(0...rhsChars.count)
        for (lhsIndex, lhsChar) in lhsChars.enumerated() {
            var current = [lhsIndex + 1]
            current.reserveCapacity(rhsChars.count + 1)

            for (rhsIndex, rhsChar) in rhsChars.enumerated() {
                let insertion = current[rhsIndex] + 1
                let deletion = previous[rhsIndex + 1] + 1
                let substitution = previous[rhsIndex] + (lhsChar == rhsChar ? 0 : 1)
                current.append(min(insertion, deletion, substitution))
            }

            previous = current
        }

        return previous[rhsChars.count]
    }

    var minimumSuggestionOccurrences: Int {
        self.suggestionThreshold
    }
}

#if DEBUG
extension AutoLearnDictionaryService {
    func shouldTrackForTesting(original: String, replacement: String) -> Bool {
        self.shouldTrack(
            CorrectionDiffEngine.Candidate(original: original, replacement: replacement),
            editedText: replacement
        )
    }

    func recordObservationForTesting(original: String, replacement: String) {
        self.recordObservation(original: original, replacement: replacement)
    }

    func recordCorrectionsForTesting(insertedText: String, baselineText: String, currentText: String) {
        let corrections = self.correctionCandidates(
            baseline: baselineText,
            currentText: currentText,
            insertedText: insertedText
        )

        for correction in corrections
            where self.isCorrectionFromInsertedText(correction, insertedText: insertedText) &&
            self.shouldTrack(correction, editedText: currentText)
        {
            self.recordObservation(original: correction.original, replacement: correction.replacement)
        }
    }

    func recordCorrectionsDuringSessionForTesting(
        insertedText: String,
        baselineText: String,
        currentText: String,
        processingPasses: Int
    ) {
        self.stopMonitoring()
        self.insertedText = insertedText
        self.baselineText = baselineText
        self.lastKnownText = currentText
        self.recordedSessionObservationCounts = [:]
        self.isActive = true

        defer {
            self.stopMonitoring()
            self.insertedText = ""
            self.baselineText = ""
            self.lastKnownText = ""
            self.recordedSessionObservationCounts = [:]
        }

        for _ in 0..<processingPasses {
            self.processCurrentCorrections()
        }
    }

    func beginSyntheticMonitoringForTesting(
        insertedText: String,
        baselineText: String,
        monitoredPID: pid_t?
    ) {
        self.finalize()
        self.insertedText = insertedText
        self.baselineText = baselineText
        self.lastKnownText = baselineText
        self.recordedSessionObservationCounts = [:]
        self.monitoredElement = nil
        self.monitoredPID = monitoredPID
        self.isActive = true
    }

    func updateSyntheticCurrentTextForTesting(_ text: String) {
        guard self.isActive else { return }
        self.lastKnownText = text
    }

    func handleActivatedApplicationForTesting(pid: pid_t?) {
        guard self.isActive else { return }
        if self.shouldFinalizeForActivatedApplication(pid: pid) {
            self.finalize()
        }
    }

    func finalizeForTesting() {
        self.finalize()
    }
}
#endif
