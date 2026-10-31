import AppKit
import Combine
import Foundation

@MainActor
final class AutomaticDictionaryTrainingSession: ObservableObject {
    enum Screen: Equatable {
        case choice
        case training
        case success
    }

    enum CapturePhase: Equatable {
        case idle
        case starting
        case recording
        case processing
    }

    let candidate: AutomaticDictionaryCorrectionCandidate

    @Published private(set) var screen: Screen = .choice
    @Published private(set) var capturePhase: CapturePhase = .idle
    @Published private(set) var variants: [String]
    @Published private(set) var sampleCount = 0
    @Published private(set) var lastOutput = ""
    @Published private(set) var lastOutputIsCovered = false
    @Published private(set) var consecutiveCoveredCaptures = 0
    @Published private(set) var statusMessage = ""
    @Published private(set) var hasError = false
    @Published private(set) var successTitle = "Added to Dictionary"
    @Published private(set) var isAutomaticCaptureEnabled = false

    var onInteraction: (() -> Void)?
    var onSuccess: (() -> Void)?

    private let asr: ASRService
    private let audioLearning: DictionaryAudioLearningService
    private var stopRequestedDuringStart = false
    private var didStartAudioCapture = false
    private var discardCurrentCapture = false
    private var isCancelled = false
    private var stopTask: Task<Void, Never>?
    private var trainingGeneration: String?
    private var activeCaptureToken: Int?
    private var pronunciationSettingsObserver: AnyCancellable?

    private var trainingRunIsCurrent: Bool {
        DictionaryMatcherExperiment.sharedFeaturesEnabled && self.trainingGeneration == DictionaryMatcherExperiment.generation
    }

    init(
        candidate: AutomaticDictionaryCorrectionCandidate,
        asr: ASRService,
        audioLearning: DictionaryAudioLearningService = .shared
    ) {
        self.candidate = candidate
        self.asr = asr
        self.audioLearning = audioLearning

        let replacement = CustomDictionaryTrainingMerge.normalizedReplacement(candidate.correctedText)
        let savedVariants = SettingsStore.shared.customDictionaryEntries
            .filter { $0.replacement.caseInsensitiveCompare(replacement) == .orderedSame }
            .flatMap(\.triggers)
        self.variants = CustomDictionaryTrainingMerge.normalizedTriggers(
            from: savedVariants + [candidate.heardText],
            intendedReplacement: replacement
        )
        // Observe the generation too: SwiftUI may coalesce a rapid OFF then ON.
        self.pronunciationSettingsObserver = NotificationCenter.default.publisher(for: DictionaryMatcherExperiment.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.trainingGeneration != nil, !self.trainingRunIsCurrent else { return }
                    self.disablePronunciationTraining()
                }
            }
    }

    var intendedText: String {
        CustomDictionaryTrainingMerge.normalizedReplacement(self.candidate.correctedText)
    }

    var readinessProgress: Int {
        guard self.lastOutputIsCovered else { return 0 }
        return min(self.consecutiveCoveredCaptures, CustomDictionaryTrainingMerge.readyCoveredCount)
    }

    var isReady: Bool {
        self.readinessProgress >= CustomDictionaryTrainingMerge.readyCoveredCount
    }

    var finalOutputText: String {
        guard !self.lastOutput.isEmpty else { return "Record to check" }
        return self.lastOutputIsCovered ? self.intendedText : self.lastOutput
    }

    var canSave: Bool {
        DictionaryMatcherExperiment.sharedFeaturesEnabled && self.isReady && !self.variants.isEmpty && self.capturePhase == .idle
    }

    var canUseRecordButton: Bool {
        guard DictionaryMatcherExperiment.sharedFeaturesEnabled else { return false }
        if self.isAutomaticCaptureEnabled {
            return true
        }
        switch self.capturePhase {
        case .starting, .recording, .processing:
            return false
        case .idle:
            return !self.asr.isRunning && (
                self.sampleCount < CustomDictionaryTrainingMerge.maxSamples || !self.isReady
            )
        }
    }

    var recordButtonIsStop: Bool {
        self.isAutomaticCaptureEnabled || self.capturePhase == .starting || self.capturePhase == .recording
    }

    var recordButtonTitle: String {
        if self.isAutomaticCaptureEnabled {
            return "Stop"
        }
        switch self.capturePhase {
        case .starting:
            return self.stopRequestedDuringStart ? "Stopping..." : "Stop"
        case .recording:
            return "Stop"
        case .processing:
            return "Checking..."
        case .idle:
            return self.sampleCount >= CustomDictionaryTrainingMerge.maxSamples && !self.isReady
                ? "Try Again"
                : "Start"
        }
    }

    func beginTraining() {
        guard DictionaryMatcherExperiment.sharedFeaturesEnabled, !self.isCancelled, self.screen == .choice else { return }
        self.onInteraction?()
        self.screen = .training
        self.statusMessage = ""
        self.hasError = false
        let generation = DictionaryMatcherExperiment.generation
        Task {
            guard DictionaryMatcherExperiment.sharedFeaturesEnabled, generation == DictionaryMatcherExperiment.generation, !self.isCancelled else { return }
            await DictionaryTrainingEndpointMonitor.shared.prepare()
        }
    }

    func returnToChoice() {
        guard self.screen == .training, self.capturePhase == .idle else { return }
        self.onInteraction?()
        self.isAutomaticCaptureEnabled = false
        self.screen = .choice
    }

    func toggleCapture() {
        guard DictionaryMatcherExperiment.sharedFeaturesEnabled else {
            self.disablePronunciationTraining()
            return
        }
        self.onInteraction?()
        if self.isAutomaticCaptureEnabled {
            self.isAutomaticCaptureEnabled = false
            switch self.capturePhase {
            case .starting, .recording:
                Task { await self.stopCapture() }
            case .idle, .processing:
                break
            }
        } else if self.capturePhase == .idle {
            if self.sampleCount >= CustomDictionaryTrainingMerge.maxSamples, !self.isReady {
                self.resetVerificationAttempts()
            }
            self.trainingGeneration = DictionaryMatcherExperiment.generation
            self.isAutomaticCaptureEnabled = true
            Task { await self.startCapture() }
        }
    }

    func addOnlyCorrection() {
        guard !self.isCancelled, self.capturePhase == .idle else { return }
        self.persist(triggers: [self.candidate.heardText])
    }

    func confirmWrongMatch() {
        guard DictionaryMatcherExperiment.collectNegatives, !self.isCancelled, self.capturePhase == .idle,
              let correction = self.candidate.negativeCorrection else { return }
        self.onInteraction?()
        self.capturePhase = .processing
        self.statusMessage = "Saving wrong match…"
        let pronunciationGeneration = DictionaryMatcherExperiment.generation
        Task { @MainActor in
            defer { self.capturePhase = .idle }
            guard DictionaryMatcherExperiment.collectNegatives, pronunciationGeneration == DictionaryMatcherExperiment.generation else { return }
            let store = DictionaryNegativeExampleStore.shared
            let revision = await store.revision()
            let evidence = correction.evidence
            func entryIsCurrent() -> Bool {
                SettingsStore.shared.customDictionaryEntries.contains { $0.id == evidence.entryID && $0.replacement == evidence.label }
            }
            do {
                let profiles = await PronunciationDictionaryStore.shared.profiles(modelKey: evidence.modelKey)
                guard !self.isCancelled, DictionaryMatcherExperiment.collectNegatives,
                      pronunciationGeneration == DictionaryMatcherExperiment.generation, entryIsCurrent(),
                      correction.expiresAt > Date(), profiles.contains(where: {
                          $0.dictionaryEntryID == evidence.entryID && DictionaryNegativeEvidenceResolver.profileKey($0) + ":shared-features-v1" == evidence.profileKey
                      }) else { throw PronunciationDictionaryStoreError.staleEvidence }
                try await store.save(correction, expectedRevision: revision)
                let latest = await PronunciationDictionaryStore.shared.profiles(modelKey: evidence.modelKey)
                let latestRevision = await store.revision()
                guard !self.isCancelled, DictionaryMatcherExperiment.collectNegatives,
                      pronunciationGeneration == DictionaryMatcherExperiment.generation, entryIsCurrent(),
                      latestRevision == revision,
                      latest.contains(where: { $0.dictionaryEntryID == evidence.entryID && DictionaryNegativeEvidenceResolver.profileKey($0) + ":shared-features-v1" == evidence.profileKey })
                else {
                    try await store.remove(id: evidence.id)
                    throw PronunciationDictionaryStoreError.staleEvidence
                }
                self.completeSave(title: "Wrong Match Saved")
            } catch {
                guard !self.isCancelled else { return }
                self.hasError = true
                self.statusMessage = "Couldn’t save this example. It may have expired or the word changed."
            }
        }
    }

    func addTrainedReplacement() {
        guard self.canSave, !self.isCancelled else { return }
        self.isAutomaticCaptureEnabled = false
        self.capturePhase = .processing
        let variants = self.variants
        let pronunciationGeneration = DictionaryMatcherExperiment.generation
        Task { @MainActor in
            guard DictionaryMatcherExperiment.sharedFeaturesEnabled, pronunciationGeneration == DictionaryMatcherExperiment.generation else {
                self.capturePhase = .idle
                return
            }
            let filtered = await VoiceTrainingAliasFilter.filter(variants)
            self.capturePhase = .idle
            guard DictionaryMatcherExperiment.sharedFeaturesEnabled,
                  pronunciationGeneration == DictionaryMatcherExperiment.generation, !self.isCancelled else { return }
            guard !filtered.accepted.isEmpty else {
                self.hasError = true
                self.statusMessage = filtered.rejectionMessage
                return
            }
            self.persist(triggers: filtered.accepted)
        }
    }

    func removeVariant(_ variant: String) {
        guard self.capturePhase == .idle else { return }
        self.onInteraction?()
        self.variants.removeAll { $0.caseInsensitiveCompare(variant) == .orderedSame }
        self.refreshCoverageAfterVariantRemoval()
    }

    func cancel() {
        self.isCancelled = true
        self.trainingGeneration = nil
        self.discardCurrentCapture = true
        self.isAutomaticCaptureEnabled = false
        DictionaryTrainingEndpointMonitor.shared.stop()
        switch self.capturePhase {
        case .starting:
            self.stopRequestedDuringStart = true
            Task { await self.asr.cancelPendingPronunciationTrainingStart() }
        case .recording:
            self.stopTask?.cancel()
            self.stopTask = Task { await self.finishCapture() }
        case .idle, .processing:
            break
        }
    }

    func disablePronunciationTraining() {
        self.trainingGeneration = nil
        self.discardCurrentCapture = true
        self.isAutomaticCaptureEnabled = false
        DictionaryTrainingEndpointMonitor.shared.stop()
        if self.capturePhase == .starting {
            self.stopRequestedDuringStart = true
            Task { await self.asr.cancelPendingPronunciationTrainingStart() }
        } else if self.capturePhase == .recording {
            self.stopTask?.cancel()
            self.stopTask = Task { await self.finishCapture() }
        }
        if self.screen == .training { self.screen = .choice }
    }

    private func startCapture() async {
        guard self.trainingRunIsCurrent, !self.isCancelled, self.isAutomaticCaptureEnabled,
              self.capturePhase == .idle,
              !self.asr.isRunning,
              self.sampleCount < CustomDictionaryTrainingMerge.maxSamples
        else {
            self.isAutomaticCaptureEnabled = false
            return
        }

        let generation = self.trainingGeneration
        self.activeCaptureToken = nil
        self.stopRequestedDuringStart = false
        self.didStartAudioCapture = false
        self.discardCurrentCapture = false
        self.capturePhase = .starting
        self.hasError = false
        self.statusMessage = "Starting..."

        await self.asr.start(forDictionaryTraining: true) { [weak self] in
            guard let self else { return }
            self.activeCaptureToken = self.asr.dictionaryCaptureToken
            self.didStartAudioCapture = true
            self.capturePhase = .recording
            if self.stopRequestedDuringStart || self.isCancelled || !self.trainingRunIsCurrent || self.trainingGeneration != generation {
                self.statusMessage = "Stopping..."
                self.stopTask?.cancel()
                self.stopTask = Task { await self.finishCapture() }
            } else {
                self.statusMessage = "Listening..."
            }
        }
        guard self.didStartAudioCapture, self.asr.isRunning, self.asr.dictionaryCaptureToken == self.activeCaptureToken else {
            self.capturePhase = .idle
            self.stopRequestedDuringStart = false
            self.isAutomaticCaptureEnabled = false
            guard !self.didStartAudioCapture else { return }
            guard !self.isCancelled, self.trainingRunIsCurrent else { return }
            self.hasError = true
            self.statusMessage = "Couldn't start recording. Check microphone access and try again."
            return
        }

        if self.stopRequestedDuringStart || self.isCancelled || !self.trainingRunIsCurrent || self.trainingGeneration != generation {
            await self.finishCapture()
            return
        }

        if self.capturePhase == .starting {
            self.capturePhase = .recording
            self.statusMessage = "Listening..."
        }
        DictionaryTrainingEndpointMonitor.shared.start(asr: self.asr) { [weak self] in
            self?.handleAutomaticSpeechEnd()
        }
    }

    private func stopCapture() async {
        DictionaryTrainingEndpointMonitor.shared.stop()
        switch self.capturePhase {
        case .starting:
            self.stopRequestedDuringStart = true
            self.statusMessage = "Stopping..."
        case .recording:
            await self.finishCapture()
        case .idle, .processing:
            break
        }
    }

    private func handleAutomaticSpeechEnd() {
        guard self.trainingRunIsCurrent, !self.isCancelled, self.isAutomaticCaptureEnabled,
              self.capturePhase == .starting || self.capturePhase == .recording
        else {
            return
        }
        self.statusMessage = "Stopping..."
        self.stopTask?.cancel()
        self.stopTask = Task { await self.stopCapture() }
    }

    private func finishCapture() async {
        guard self.capturePhase == .recording || self.capturePhase == .starting else { return }
        DictionaryTrainingEndpointMonitor.shared.stop()
        self.capturePhase = .processing
        self.stopRequestedDuringStart = false
        self.hasError = false
        self.statusMessage = "Checking..."

        // A settings change may already have stopped this capture. Never stop normal dictation.
        guard let captureToken = self.activeCaptureToken, self.asr.dictionaryCaptureToken == captureToken else {
            self.capturePhase = .idle
            self.isAutomaticCaptureEnabled = false
            self.discardCurrentCapture = false
            return
        }
        let generation = self.trainingGeneration
        let transcript = await self.asr.stop(forDictionaryTraining: true)
        self.activeCaptureToken = nil
        let shouldDiscard = self.discardCurrentCapture || self.isCancelled || !self.trainingRunIsCurrent || self.trainingGeneration != generation
        if shouldDiscard { self.isAutomaticCaptureEnabled = false }
        self.capturePhase = .idle
        self.discardCurrentCapture = false
        guard !shouldDiscard else { return }
        self.addTrainingVariant(from: transcript)
        await self.continueAutomaticCaptureIfNeeded()
    }

    private func continueAutomaticCaptureIfNeeded() async {
        guard self.trainingRunIsCurrent, !self.isCancelled, self.isAutomaticCaptureEnabled,
              !self.isReady,
              self.sampleCount < CustomDictionaryTrainingMerge.maxSamples
        else {
            self.isAutomaticCaptureEnabled = false
            return
        }

        await Task.yield()
        await self.startCapture()
    }

    private func resetVerificationAttempts() {
        self.sampleCount = 0
        self.lastOutput = ""
        self.lastOutputIsCovered = false
        self.consecutiveCoveredCaptures = 0
        self.statusMessage = ""
        self.hasError = false
    }

    private func addTrainingVariant(from transcript: String) {
        guard let detected = CustomDictionaryTrainingMerge.normalizedTrigger(transcript) else {
            self.lastOutput = ""
            self.lastOutputIsCovered = false
            self.consecutiveCoveredCaptures = 0
            self.hasError = true
            self.statusMessage = "Nothing heard. Try again."
            return
        }

        self.lastOutput = detected
        self.sampleCount = min(self.sampleCount + 1, CustomDictionaryTrainingMerge.maxSamples)

        let matchesReplacement = detected.caseInsensitiveCompare(self.intendedText) == .orderedSame
        let isCaptured = self.variants.contains { $0.caseInsensitiveCompare(detected) == .orderedSame }
        if matchesReplacement || isCaptured {
            self.lastOutputIsCovered = true
            self.consecutiveCoveredCaptures += 1
            self.hasError = false
            self.statusMessage = self.isReady ? "Ready to add." : "Understood. Try again."
            return
        }

        guard self.variants.count < CustomDictionaryTrainingMerge.maxSamples else {
            self.lastOutputIsCovered = false
            self.consecutiveCoveredCaptures = 0
            self.hasError = false
            self.statusMessage = "Maximum samples reached."
            return
        }

        self.variants.append(detected)
        self.lastOutputIsCovered = false
        self.consecutiveCoveredCaptures = 0
        self.hasError = false
        self.statusMessage = "New pronunciation captured."
    }

    private func refreshCoverageAfterVariantRemoval() {
        guard !self.lastOutput.isEmpty else { return }
        let matchesReplacement = self.lastOutput.caseInsensitiveCompare(self.intendedText) == .orderedSame
        let isCaptured = self.variants.contains { $0.caseInsensitiveCompare(self.lastOutput) == .orderedSame }
        self.lastOutputIsCovered = matchesReplacement || isCaptured
        if !self.lastOutputIsCovered {
            self.consecutiveCoveredCaptures = 0
        }
    }

    private func persist(triggers: [String]) {
        guard !self.isCancelled else { return }
        self.onInteraction?()
        let currentEntries = SettingsStore.shared.customDictionaryEntries
        let updatedExisting = currentEntries.contains {
            $0.replacement.caseInsensitiveCompare(self.intendedText) == .orderedSame
        }
        let mergedEntries = CustomDictionaryTrainingMerge.mergedEntries(
            current: currentEntries,
            replacement: self.intendedText,
            triggers: triggers
        )
        if DictionaryMatcherExperiment.sharedFeaturesEnabled, let evidence = self.candidate.audioEvidence, let entry = mergedEntries.first(where: {
            $0.replacement.caseInsensitiveCompare(self.intendedText) == .orderedSame
        }) {
            // Scheduled work runs after this synchronous text save returns.
            self.audioLearning.learn(
                entry: entry, evidenceID: self.candidate.id, evidence: evidence
            )
        }
        guard mergedEntries != currentEntries else {
            self.hasError = true
            self.statusMessage = "These spellings are already covered. No new spelling corrections were saved."
            return
        }

        SettingsStore.shared.customDictionaryEntries = mergedEntries
        ASRService.invalidateDictionaryCache()
        NotificationCenter.default.post(name: .parakeetVocabularyDidChange, object: nil)
        self.completeSave(title: updatedExisting ? "Dictionary Updated" : "Added to Dictionary")
    }

    private func completeSave(title: String) {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        self.successTitle = title
        self.screen = .success
        self.hasError = false
        self.statusMessage = ""
        self.onSuccess?()
    }
}
