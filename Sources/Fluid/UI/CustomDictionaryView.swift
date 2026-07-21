//
//  CustomDictionaryView.swift
//  fluid
//
//  Custom dictionary for correcting commonly misheard words.
//  Created: 2025-12-21
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CustomDictionaryView: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appServices: AppServices

    @State private var entries: [SettingsStore.CustomDictionaryEntry] = SettingsStore.shared.customDictionaryEntries
    @State private var boostTerms: [ParakeetVocabularyStore.VocabularyConfig.Term] = []
    @State private var editingEntry: SettingsStore.CustomDictionaryEntry?

    @State private var boostStatusMessage = "Add custom words for better Parakeet recognition."
    @State private var boostHasError = false
    @State private var automaticDictionaryLearningEnabled = SettingsStore.shared.automaticDictionaryLearningEnabled
    @State private var vocabBoostingEnabled: Bool = SettingsStore.shared.vocabularyBoostingEnabled
    @State private var isCustomWordsPresented = false
    @State private var isBoostWordEditorPresented = false
    @State private var editingBoostTermIndex: Int?
    @State private var boostTermText = ""
    @State private var boostTermStrength: BoostStrengthPreset = .balanced

    @State private var trainingReplacement = ""
    @State private var trainingVariants: [String] = []
    @State private var pronunciationMatchingEnabled = SettingsStore.shared.pronunciationMatchingEnabled
    @State private var trainingPronunciationEnrollments: [PronunciationEnrollmentCapture] = []
    @State private var trainingSampleCount = 0
    @State private var lastTrainingOutput = ""
    @State private var lastTrainingOutputIsCovered = false
    @State private var consecutiveCoveredCaptures = 0
    @State private var trainingStatusMessage = "Type the correct text."
    @State private var trainingHasError = false
    @State private var isTrainingActive = false
    @State private var isTrainingStarting = false
    @State private var isTrainingRecording = false
    @State private var trainingStopRequestedDuringStart = false
    @State private var isTrainingProcessing = false
    @State private var isAutomaticTrainingEnabled = false
    @State private var isTrainedReplacementButtonHovered = false
    @State private var isTrainedReplacementGlowExpanded = false
    @State private var replacementConfirmation: ReplacementConfirmation?
    @State private var composerMode: DictionaryComposerMode = .train
    @State private var manualTriggerDraft = ""
    @State private var manualReplacement = ""
    @State private var isYourDictionaryPresented = false
    @State private var isPunctuationDictionaryPresented = false
    @State private var punctuationAutoConvertEnabled = SettingsStore.shared.autoConvertPunctuationEnabled
    @State private var punctuationPrefix = SettingsStore.shared.punctuationDictionaryPrefix
    @State private var punctuationRules = SettingsStore.shared.punctuationDictionaryRules
    @State private var isPunctuationInfoExpanded = false
    @State private var isPunctuationRuleEditorPresented = false
    @State private var editingPunctuationRuleID: UUID?
    @State private var punctuationAliasesText = ""
    @State private var punctuationSymbolText = ""
    private var normalizedTrainingReplacement: String {
        self.trainingReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var activePronunciationMatching: Bool {
        self.pronunciationMatchingEnabled && SettingsStore.shared.selectedSpeechModel.supportsPronunciationMatching
    }

    private var pronunciationMatchingBinding: Binding<Bool> {
        Binding(
            get: { self.activePronunciationMatching },
            set: { self.pronunciationMatchingEnabled = $0 }
        )
    }

    private var trainingTargetReference: String {
        DictionaryTrainingCopy.target(for: self.normalizedTrainingReplacement)
    }

    private var composerModeDetail: String {
        DictionaryTrainingCopy.composerDetail(mode: self.composerMode, target: self.trainingTargetReference)
    }

    private var canUseTrainingRecorderButton: Bool {
        if self.isAutomaticTrainingEnabled {
            return true
        }
        guard !self.trainingStopRequestedDuringStart, !self.isTrainingProcessing else { return false }
        return self.isTrainingRecording || self.canRecordTrainingSample || self.canRetryTrainingAfterMaximum
    }

    private var trainingRecorderIsStop: Bool {
        self.isAutomaticTrainingEnabled || self.isTrainingRecording || self.isTrainingStarting
    }

    private var trainingRecorderButtonTitle: String {
        if self.trainingRecorderIsStop {
            return "Stop"
        }
        return self.canRetryTrainingAfterMaximum ? "Try Again" : "Start"
    }

    private var trainingFinalOutputIsReady: Bool {
        if self.activePronunciationMatching {
            return !self.trainingAlreadyCorrectWithoutReplacement &&
                self.trainingPronunciationEnrollments.count >= CustomDictionaryTrainingMerge.readyCoveredCount
        }
        return !self.trainingAlreadyCorrectWithoutReplacement &&
            self.trainingOutputIsCovered &&
            self.consecutiveCoveredCaptures >= CustomDictionaryTrainingMerge.readyCoveredCount
    }

    private var trainingAlreadyCorrectWithoutReplacement: Bool {
        if self.activePronunciationMatching {
            return self.trainingVariants.isEmpty &&
                !self.lastTrainingOutput.isEmpty &&
                self.lastTrainingOutput.caseInsensitiveCompare(self.normalizedTrainingReplacement) == .orderedSame &&
                self.trainingPronunciationEnrollments.count >= CustomDictionaryTrainingMerge.readyCoveredCount
        }
        return self.trainingVariants.isEmpty &&
            self.trainingOutputIsCovered &&
            !self.lastTrainingOutput.isEmpty &&
            self.lastTrainingOutput.caseInsensitiveCompare(self.normalizedTrainingReplacement) == .orderedSame &&
            self.consecutiveCoveredCaptures >= CustomDictionaryTrainingMerge.readyCoveredCount
    }

    private var trainingReadinessProgress: Int {
        if self.activePronunciationMatching {
            return min(self.trainingPronunciationEnrollments.count, CustomDictionaryTrainingMerge.readyCoveredCount)
        }
        guard !self.trainingAlreadyCorrectWithoutReplacement else {
            return CustomDictionaryTrainingMerge.readyCoveredCount
        }
        guard self.trainingOutputIsCovered else { return 0 }
        return min(self.consecutiveCoveredCaptures, CustomDictionaryTrainingMerge.readyCoveredCount)
    }

    private var trainingOutputIsCovered: Bool {
        if self.activePronunciationMatching {
            return !self.trainingPronunciationEnrollments.isEmpty
        }
        return self.lastTrainingOutputIsCovered
    }

    private var trainingFinalOutputText: String {
        guard !self.lastTrainingOutput.isEmpty else { return "Record to check" }
        return self.trainingOutputIsCovered ? self.normalizedTrainingReplacement : self.lastTrainingOutput
    }

    private var canRecordTrainingSample: Bool {
        !self.normalizedTrainingReplacement.isEmpty &&
            !self.isTrainingProcessing &&
            !self.asr.isRunning &&
            self.trainingSampleCount < CustomDictionaryTrainingMerge.maxSamples
    }

    private var canRetryTrainingAfterMaximum: Bool {
        !self.normalizedTrainingReplacement.isEmpty &&
            !self.trainingFinalOutputIsReady &&
            !self.trainingAlreadyCorrectWithoutReplacement &&
            !self.isTrainingRecording &&
            !self.isTrainingProcessing &&
            !self.asr.isRunning &&
            self.trainingSampleCount >= CustomDictionaryTrainingMerge.maxSamples
    }

    private var canAddTrainedReplacement: Bool {
        !self.normalizedTrainingReplacement.isEmpty &&
            (!self.trainingVariants.isEmpty || !self.trainingPronunciationEnrollments.isEmpty) &&
            !self.isTrainingRecording &&
            !self.isTrainingProcessing &&
            self.trainingFinalOutputIsReady
    }

    private var shouldPulseTrainedReplacementButton: Bool {
        self.shouldEmphasizeTrainedReplacementButton &&
            !self.isTrainedReplacementButtonHovered &&
            !self.reduceMotion
    }

    private var manualTriggers: [String] {
        CustomDictionaryManualEntry.normalizedDraftTriggers(self.manualTriggerDraft)
    }

    private var manualDuplicateTriggers: [String] {
        self.manualTriggers.filter { self.allExistingTriggers().contains($0) }
    }

    private var canAddManualReplacement: Bool {
        !self.manualTriggers.isEmpty &&
            !self.manualReplacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            self.manualDuplicateTriggers.isEmpty
    }

    private var punctuationEditorTitle: String {
        self.editingPunctuationRuleID == nil ? "Add Rule" : "Edit Rule"
    }

    private var normalizedPunctuationAliases: [String] {
        SettingsStore.PunctuationDictionaryRule.normalizedAliases(
            self.punctuationAliasesText.components(separatedBy: .newlines)
        )
    }

    private var normalizedPunctuationSymbol: String? {
        SettingsStore.PunctuationDictionaryRule.normalizedSymbol(self.punctuationSymbolText)
    }

    private var canSavePunctuationRule: Bool {
        !self.normalizedPunctuationAliases.isEmpty && self.normalizedPunctuationSymbol != nil
    }

    private var punctuationPreviewPrefix: String {
        SettingsStore.normalizedPunctuationDictionaryPrefix(self.punctuationPrefix) ?? SettingsStore.defaultPunctuationDictionaryPrefix
    }

    private var boostEditorTitle: String {
        self.editingBoostTermIndex == nil ? "Add Word" : "Edit Word"
    }

    private var normalizedBoostTermText: String {
        self.boostTermText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isBoostTermDuplicate: Bool {
        self.existingBoostTerms(excludingIndex: self.editingBoostTermIndex)
            .contains(self.normalizedBoostTermText.lowercased())
    }

    private var canSaveBoostTerm: Bool {
        !self.normalizedBoostTermText.isEmpty && !self.isBoostTermDuplicate
    }

    private enum DictionaryHeaderControlLayout {
        static let controlsWidth: CGFloat = 194
        static let toggleColumnWidth: CGFloat = 54
        static let actionButtonWidth: CGFloat = 128
        static let actionButtonLabelWidth: CGFloat = 104
        static let controlHeight: CGFloat = 36
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
                self.pageHeader

                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xxl) {
                    self.trainReplacementSection
                    self.yourDictionarySection
                    self.punctuationDictionarySection
                    self.aiPostProcessingSection
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(self.theme.metrics.spacing.xl)
        }
        .dismissTextFocusOnBackgroundTap()
        .overlay {
            if let confirmation = self.replacementConfirmation {
                ReplacementConfirmationToast(confirmation: confirmation)
                    .padding(self.theme.metrics.spacing.xl)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .sheet(item: self.$editingEntry) { entry in
            EditDictionaryEntrySheet(
                entry: entry,
                existingTriggers: self.allExistingTriggers(excluding: entry.id)
            ) { updatedEntry in
                if let index = self.entries.firstIndex(where: { $0.id == updatedEntry.id }) {
                    self.entries[index] = updatedEntry
                    self.saveEntries()
                    Task {
                        if PronunciationProfileEditPolicy.shouldDiscardProfile(
                            previousReplacement: entry.replacement,
                            updatedReplacement: updatedEntry.replacement
                        ) {
                            try? await PronunciationDictionaryStore.shared.delete(dictionaryEntryID: updatedEntry.id)
                        } else {
                            try? await PronunciationDictionaryStore.shared.updateLabel(
                                dictionaryEntryID: updatedEntry.id,
                                label: updatedEntry.replacement
                            )
                        }
                    }
                }
            }
        }
        .onAppear {
            self.entries = SettingsStore.shared.customDictionaryEntries
            self.loadBoostTerms()
            self.automaticDictionaryLearningEnabled = SettingsStore.shared.automaticDictionaryLearningEnabled
            self.pronunciationMatchingEnabled = SettingsStore.shared.pronunciationMatchingEnabled
            if !SettingsStore.shared.selectedSpeechModel.supportsPronunciationMatching {
                self.pronunciationMatchingEnabled = false
                SettingsStore.shared.pronunciationMatchingEnabled = false
            }
            self.punctuationAutoConvertEnabled = SettingsStore.shared.autoConvertPunctuationEnabled
        }
        .onReceive(NotificationCenter.default.publisher(for: .parakeetVocabularyDidChange)) { _ in
            self.entries = SettingsStore.shared.customDictionaryEntries
        }
        .onDisappear {
            self.isAutomaticTrainingEnabled = false
            DictionaryTrainingEndpointMonitor.shared.stop()
            guard self.isTrainingRecording else { return }
            Task { @MainActor in
                await self.stopTrainingSample()
            }
        }
    }

    // MARK: - Page Header

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
            self.settingsIconTile(systemName: "text.book.closed.fill")

            VStack(alignment: .leading, spacing: 2) {
                Text("Custom Dictionary")
                    .font(self.theme.typography.title)
                Text("Correct recurring mistakes and teach the voice engine the words you use.")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }

            Spacer(minLength: self.theme.metrics.spacing.md)

            HStack(spacing: self.theme.metrics.spacing.sm) {
                self.automaticLearningToggle

                Button(action: self.importDictionary) {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .fluidButton(.compact, size: .compact)

                Button(action: self.exportDictionary) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .fluidButton(.compact, size: .compact)
            }
        }
    }

    private var automaticLearningToggle: some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Auto-learn words")
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.theme.palette.primaryText)
                    .lineLimit(1)

                Text("Show notifications")
                    .font(self.theme.typography.captionSmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .lineLimit(1)
            }

            Toggle("Auto-learn words while typing", isOn: self.$automaticDictionaryLearningEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(self.theme.palette.accent)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(
                            self.automaticDictionaryLearningEnabled
                                ? self.theme.palette.accent.opacity(0.42)
                                : self.theme.palette.cardBorder.opacity(0.3),
                            lineWidth: 1
                        )
                )
        )
        .onChange(of: self.automaticDictionaryLearningEnabled) { _, newValue in
            SettingsStore.shared.automaticDictionaryLearningEnabled = newValue
            if !newValue {
                AutomaticDictionaryCorrectionTracker.shared.cancel()
            }
        }
        .help("Notice corrections to recent dictation and show Train by Voice suggestions.")
    }

    private func settingsIconTile(systemName: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.82))
                .overlay(
                    LinearGradient(
                        colors: [.white.opacity(0.1), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.accent.opacity(0.35), lineWidth: 1)
                )

            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(self.theme.palette.accent)
        }
        .frame(width: 34, height: 34)
    }

    // MARK: - Teach Words

    private var trainReplacementSection: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
                HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
                    self.settingsIconTile(systemName: "mic.fill")

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Teach Words")
                            .font(self.theme.typography.sectionTitle)
                        Text("Show FluidVoice the right spelling, by voice or by typing.")
                            .font(self.theme.typography.caption)
                            .foregroundStyle(self.theme.palette.secondaryText)
                    }
                }

                self.dictionaryComposerModePicker

                Group {
                    switch self.composerMode {
                    case .train:
                        self.trainReplacementComposer
                    case .manual:
                        self.manualReplacementComposer
                    }
                }
                .frame(minHeight: 315, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dictionaryComposerModePicker: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            self.dictionaryComposerModeSegmented

            Text(self.composerModeDetail)
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dictionaryComposerModeSegmented: some View {
        HStack(spacing: 2) {
            ForEach(DictionaryComposerMode.allCases) { mode in
                DictionaryComposerModeTab(
                    mode: mode,
                    isSelected: self.composerMode == mode,
                    isDisabled: self.isTrainingRecording || self.isTrainingProcessing
                ) {
                    self.selectComposerMode(mode)
                }
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private var trainReplacementComposer: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            TextField("Type the correct text, e.g. FluidVoice", text: self.$trainingReplacement)
                .dictionaryInputChrome()
                .disabled(self.isTrainingRecording || self.isTrainingProcessing)
                .onChange(of: self.trainingReplacement) { oldValue, newValue in
                    self.handleTrainingReplacementChange(oldValue: oldValue, newValue: newValue)
                }

            self.voiceMatchingSettingsRow

            self.trainingRecorderPanel

            self.trainingFinalOutputPanel

            if !self.trainingVariants.isEmpty {
                self.trainingHeardSection
            }

            self.trainingFooter

            Spacer(minLength: 0)

            Button {
                Task { await self.addTrainedReplacement() }
            } label: {
                Label(
                    self.trainedReplacementButtonTitle,
                    systemImage: self.shouldEmphasizeTrainedReplacementButton
                        ? "sparkles"
                        : (self.trainingAlreadyCorrectWithoutReplacement ? "checkmark" : "plus")
                )
                .frame(maxWidth: .infinity)
                .frame(height: 38)
            }
            .fluidButton(self.shouldEmphasizeTrainedReplacementButton ? .accent : .compact, size: .small)
            .disabled(!self.canAddTrainedReplacement)
            .opacity(self.canAddTrainedReplacement ? 1 : 0.62)
            .overlay(self.trainedReplacementButtonReadyOutline)
            .shadow(
                color: self.shouldEmphasizeTrainedReplacementButton
                    ? self.theme.palette.accent.opacity(self.isTrainedReplacementGlowExpanded ? 0.34 : 0.14)
                    : .clear,
                radius: self.shouldEmphasizeTrainedReplacementButton
                    ? (self.isTrainedReplacementGlowExpanded ? 18 : 8)
                    : 0,
                x: 0,
                y: 4
            )
            .onHover { self.isTrainedReplacementButtonHovered = $0 }
            .onAppear { self.updateTrainedReplacementGlow() }
            .onChange(of: self.shouldPulseTrainedReplacementButton) { _, _ in
                self.updateTrainedReplacementGlow()
            }
        }
        .task {
            await DictionaryTrainingEndpointMonitor.shared.prepare()
        }
    }

    private var trainedReplacementButtonReadyOutline: some View {
        RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
            .stroke(
                self.shouldEmphasizeTrainedReplacementButton ? self.theme.palette.success.opacity(0.72) : .clear,
                lineWidth: 1.5
            )
            .padding(-3)
            .allowsHitTesting(false)
    }

    private var manualReplacementComposer: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) {
                    self.manualTriggerField
                    self.manualReplacementField
                }

                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                    self.manualTriggerField
                    self.manualReplacementField
                }
            }

            if !self.manualDuplicateTriggers.isEmpty {
                Label("Already used: \(self.manualDuplicateTriggers.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.warning)
            }

            if !self.manualTriggers.isEmpty || !self.manualReplacement.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(self.manualTriggers, id: \.self) { trigger in
                        DictionaryPreviewChip(text: trigger)
                    }

                    Image(systemName: "arrow.right")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.tertiaryText)

                    Text(self.manualReplacement.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(self.theme.typography.captionStrong)
                        .foregroundStyle(self.theme.palette.accent)
                }
            }

            Spacer(minLength: 0)

            Button {
                self.addManualReplacementIfValid()
            } label: {
                Label("Add Replacement", systemImage: "plus")
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
            }
            .fluidButton(.accent, size: .small)
            .disabled(!self.canAddManualReplacement)
            .opacity(self.canAddManualReplacement ? 1 : 0.45)
        }
    }

    private var manualTriggerField: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            Text("When FluidVoice hears")
                .font(self.theme.typography.captionStrong)

            TextField("fluid voice, fluid boys", text: self.$manualTriggerDraft)
                .dictionaryInputChrome()
                .onSubmit { self.addManualReplacementIfValid() }

            Text("Separate different versions with commas. Enter only commas to replace comma punctuation.")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        }
    }

    private var manualReplacementField: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            Text("Change it to")
                .font(self.theme.typography.captionStrong)
            TextField("FluidVoice", text: self.$manualReplacement)
                .dictionaryInputChrome()
                .onSubmit { self.addManualReplacementIfValid() }
            Text("This is what appears in your transcription.")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        }
    }

    private var voiceMatchingSettingsRow: some View {
        VoiceMatchingSettingsRow(
            isEnabled: self.pronunciationMatchingBinding,
            isDisabled: self.isTrainingRecording || self.isTrainingProcessing,
            isAdvancedAvailable: SettingsStore.shared.selectedSpeechModel.supportsPronunciationMatching,
            onChange: self.handlePronunciationMatchingChange(enabled:)
        )
    }

    private var trainingRecorderPanel: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            Text("Teach FluidVoice your pronunciation")
                .font(self.theme.typography.bodySmallStrong)

            if self.trainingAlreadyCorrectWithoutReplacement {
                Label("\(self.trainingTargetReference) is already recognized correctly.", systemImage: "checkmark.circle.fill")
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.theme.palette.accent)
            } else if self.trainingFinalOutputIsReady {
                Label(
                    self.activePronunciationMatching
                        ? "Voice profile for \(self.trainingTargetReference) captured 3 times."
                        : "FluidVoice recognized \(self.trainingTargetReference) 3 times in a row.",
                    systemImage: "checkmark.circle.fill"
                )
                .font(self.theme.typography.captionStrong)
                .foregroundStyle(self.theme.palette.accent)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    self.trainingInstruction(
                        number: 1,
                        text: "Type the correct word you want to teach in the box above."
                    )
                    self.trainingInstruction(
                        number: 2,
                        text: "Press Start once."
                    )
                    self.trainingInstruction(
                        number: 3,
                        text: "Say \(self.trainingTargetReference) naturally, then pause. FluidVoice records and listens again automatically."
                    )
                    self.trainingInstruction(
                        number: 4,
                        text: self.activePronunciationMatching
                            ? "Repeat 3 times to teach FluidVoice how your voice sounds."
                            : "Keep repeating it until the circle reaches 3/3."
                    )
                }
            }

            HStack(spacing: self.theme.metrics.spacing.md) {
                DictionaryTrainingReadinessRing(
                    progress: self.trainingReadinessProgress,
                    total: CustomDictionaryTrainingMerge.readyCoveredCount,
                    isReady: self.trainingFinalOutputIsReady || self.trainingAlreadyCorrectWithoutReplacement
                )

                Text(self.trainingReadinessCaption)
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(
                        self.trainingFinalOutputIsReady
                            ? self.theme.palette.accent
                            : self.theme.palette.secondaryText
                    )
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                Button {
                    Task { await self.toggleAutomaticTraining() }
                } label: {
                    Label(
                        self.trainingRecorderButtonTitle,
                        systemImage: self.trainingRecorderIsStop ? "stop.fill" : "mic.fill"
                    )
                }
                .fluidButton(self.trainingRecorderIsStop ? .destructive : .accent, size: .small)
                .disabled(!self.canUseTrainingRecorderButton)
                .opacity(self.canUseTrainingRecorderButton ? 1 : 0.45)
            }
        }
        .padding(self.theme.metrics.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(
                            self.trainingFinalOutputIsReady
                                ? self.theme.palette.accent.opacity(0.26)
                                : self.theme.palette.cardBorder.opacity(0.25),
                            lineWidth: 1
                        )
                )
        )
    }

    private var trainingReadinessCaption: String {
        DictionaryTrainingCopy.readinessCaption(
            target: self.trainingTargetReference,
            isAlreadyCorrect: self.trainingAlreadyCorrectWithoutReplacement,
            isReady: self.trainingFinalOutputIsReady,
            usesVoiceMatching: self.activePronunciationMatching
        )
    }

    private var trainingHeardSection: some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            Text("Captured")
                .font(self.theme.typography.captionStrong)
                .foregroundStyle(self.theme.palette.secondaryText)

            HStack(spacing: 6) {
                ForEach(Array(self.trainingVariants.prefix(5).enumerated()), id: \.element) { index, variant in
                    TrainingVariantChip(number: index + 1, variant: variant) {
                        self.removeTrainingVariant(variant)
                    }
                }

                if self.trainingVariants.count > 5 {
                    Text("+\(self.trainingVariants.count - 5)")
                        .font(self.theme.typography.captionStrong)
                        .foregroundStyle(self.theme.palette.tertiaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(self.theme.palette.cardBackground.opacity(0.65))
                        )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, self.theme.metrics.spacing.md)
        .padding(.vertical, self.theme.metrics.spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private var trainingFinalOutputPanel: some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Final output")
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.theme.palette.secondaryText)

                Text(self.trainingFinalOutputText)
                    .font(self.theme.typography.bodySmallStrong)
                    .foregroundStyle(self.lastTrainingOutput.isEmpty ? self.theme.palette.tertiaryText : self.theme.palette.primaryText)
                    .lineLimit(1)

                if !self.lastTrainingOutput.isEmpty, self.lastTrainingOutput.caseInsensitiveCompare(self.trainingFinalOutputText) != .orderedSame {
                    Text("Heard: \(self.lastTrainingOutput)")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.tertiaryText)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, self.theme.metrics.spacing.md)
        .padding(.vertical, self.theme.metrics.spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.42))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(
                            self.trainingFinalOutputIsReady ? self.theme.palette.success.opacity(0.28) : self.theme.palette.cardBorder.opacity(0.22),
                            lineWidth: 1
                        )
                )
        )
    }

    @ViewBuilder
    private var trainingFooter: some View {
        if self.trainingHasError || self.isTrainingActive || !self.trainingVariants.isEmpty {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                if self.trainingHasError {
                    Label(self.trainingStatusMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.warning)
                }

                if self.isTrainingActive || !self.trainingVariants.isEmpty || !self.normalizedTrainingReplacement.isEmpty {
                    Spacer()

                    Button("Clear") {
                        self.resetTraining()
                    }
                    .fluidButton(.compact, size: .compact)
                    .disabled(self.isTrainingRecording || self.isTrainingProcessing)
                    .opacity(self.isTrainingRecording || self.isTrainingProcessing ? 0.45 : 1)
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Your Dictionary

    private var yourDictionarySection: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
                self.settingsIconTile(systemName: "book.closed.fill")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Your Dictionary")
                            .font(self.theme.typography.sectionTitle)
                        if !self.entries.isEmpty {
                            Text("(\(self.entries.count))")
                                .font(self.theme.typography.captionSmall)
                                .foregroundStyle(self.theme.palette.tertiaryText)
                        }
                    }
                    Text("Words and phrases FluidVoice will correct automatically.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                self.yourDictionaryControls
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var yourDictionaryControls: some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
            Button {
                self.presentYourDictionary()
            } label: {
                Label("Modify", systemImage: "slider.horizontal.3")
                    .frame(width: Self.DictionaryHeaderControlLayout.actionButtonLabelWidth)
            }
            .frame(width: Self.DictionaryHeaderControlLayout.actionButtonWidth)
            .fluidButton(.compact, size: .medium)
            .help("Modify dictionary replacements")
            .popover(isPresented: self.$isYourDictionaryPresented, arrowEdge: .top) {
                self.yourDictionaryPopover
            }

            Color.clear
                .frame(width: Self.DictionaryHeaderControlLayout.toggleColumnWidth)
                .accessibilityHidden(true)
        }
        .frame(width: Self.DictionaryHeaderControlLayout.controlsWidth, height: Self.DictionaryHeaderControlLayout.controlHeight, alignment: .leading)
    }

    private var punctuationDictionarySection: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
                self.settingsIconTile(systemName: "textformat")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Punctuation Dictionary")
                            .font(self.theme.typography.sectionTitle)
                        if !self.punctuationRules.isEmpty {
                            Text("(\(self.punctuationRules.count))")
                                .font(self.theme.typography.captionSmall)
                                .foregroundStyle(self.theme.palette.tertiaryText)
                        }
                    }
                    Text("Say a start word first, then a punctuation name, to type punctuation symbols.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                self.punctuationDictionaryControls
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var punctuationDictionaryControls: some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
            Button {
                self.presentPunctuationDictionary()
            } label: {
                Label("Modify", systemImage: "slider.horizontal.3")
                    .frame(width: Self.DictionaryHeaderControlLayout.actionButtonLabelWidth)
            }
            .frame(width: Self.DictionaryHeaderControlLayout.actionButtonWidth)
            .fluidButton(.compact, size: .medium)
            .disabled(!self.punctuationAutoConvertEnabled)
            .opacity(self.punctuationAutoConvertEnabled ? 1 : 0.45)
            .help(self.punctuationAutoConvertEnabled ? "Modify punctuation rules" : "Turn on Punctuation Dictionary to modify rules.")
            .popover(isPresented: self.$isPunctuationDictionaryPresented, arrowEdge: .top) {
                self.punctuationDictionaryPopover
            }

            self.punctuationDictionaryToggle
        }
        .frame(width: Self.DictionaryHeaderControlLayout.controlsWidth, height: Self.DictionaryHeaderControlLayout.controlHeight, alignment: .leading)
    }

    private var punctuationDictionaryToggle: some View {
        Toggle("Punctuation Dictionary", isOn: self.$punctuationAutoConvertEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
            .onChange(of: self.punctuationAutoConvertEnabled) { _, newValue in
                SettingsStore.shared.autoConvertPunctuationEnabled = newValue
            }
            .frame(width: Self.DictionaryHeaderControlLayout.toggleColumnWidth, alignment: .trailing)
            .help("Turn Punctuation Dictionary on or off.")
    }

    private var entriesListView: some View {
        VStack(spacing: self.theme.metrics.spacing.sm) {
            ForEach(self.entries) { entry in
                DictionaryEntryRow(
                    entry: entry,
                    onEdit: {
                        self.closeYourDictionary()
                        self.editingEntry = entry
                    },
                    onDelete: { self.deleteEntry(entry) }
                )
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var yourDictionaryPopover: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your Dictionary")
                        .font(self.theme.typography.sectionTitle)

                    Text("FluidVoice automatically corrects these words and phrases.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }

                Spacer()

                Button {
                    self.closeYourDictionary()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(SquareIconButtonStyle())
                .help("Close")
            }

            self.yourDictionaryHelpNote

            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saved Replacements")
                        .font(self.theme.typography.captionStrong)
                    Text("These run automatically after dictation.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }

                if self.entries.isEmpty {
                    self.dictionaryEmptyState(
                        title: "No replacements yet",
                        detail: "Use Teach Words above to create your first one."
                    )
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        self.entriesListView
                    }
                    .frame(maxHeight: 235)
                }
            }
        }
        .padding(self.theme.metrics.spacing.lg)
        .frame(width: 640, alignment: .leading)
    }

    private var yourDictionaryHelpNote: some View {
        Label {
            Text("Use the Teach Words area above to add dictionary entries by voice or manually.")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        } icon: {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(self.theme.palette.accent)
        }
        .padding(self.theme.metrics.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
                )
        )
    }

    // MARK: - Custom Words

    private var aiPostProcessingSection: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
                self.settingsIconTile(systemName: "character.book.closed")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Custom Words")
                            .font(self.theme.typography.sectionTitle)
                        if !self.boostTerms.isEmpty {
                            Text("(\(self.boostTerms.count))")
                                .font(self.theme.typography.captionSmall)
                                .foregroundStyle(self.theme.palette.tertiaryText)
                        }
                    }
                    Text("Help the Parakeet voice engine recognize names, products, and uncommon terms.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                self.customWordsControls
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var customWordsControls: some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
            Button {
                self.presentCustomWords()
            } label: {
                Label("Modify", systemImage: "slider.horizontal.3")
                    .frame(width: Self.DictionaryHeaderControlLayout.actionButtonLabelWidth)
            }
            .frame(width: Self.DictionaryHeaderControlLayout.actionButtonWidth)
            .fluidButton(.compact, size: .medium)
            .disabled(!self.vocabBoostingEnabled)
            .opacity(self.vocabBoostingEnabled ? 1 : 0.45)
            .help(self.vocabBoostingEnabled ? "Modify custom words" : "Turn on Boosting to modify custom words.")
            .popover(isPresented: self.$isCustomWordsPresented, arrowEdge: .top) {
                self.customWordsPopover
            }

            self.customWordsBoostingToggle
        }
        .frame(width: Self.DictionaryHeaderControlLayout.controlsWidth, height: Self.DictionaryHeaderControlLayout.controlHeight, alignment: .leading)
    }

    private var customWordsBoostingToggle: some View {
        Toggle("Custom Words Boosting", isOn: self.$vocabBoostingEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
            .onChange(of: self.vocabBoostingEnabled) { _, newValue in
                SettingsStore.shared.vocabularyBoostingEnabled = newValue
            }
            .frame(width: Self.DictionaryHeaderControlLayout.toggleColumnWidth, alignment: .trailing)
            .help("Improve recognition of your custom words when using Parakeet.")
    }

    private var customWordsPopover: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom Words")
                        .font(self.theme.typography.sectionTitle)

                    Text("Add names, products, and uncommon terms for Parakeet to recognize.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }

                Spacer()

                Button {
                    self.closeCustomWords()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(SquareIconButtonStyle())
                .help("Close")
            }

            if self.isBoostWordEditorPresented {
                self.boostWordEditor
            } else {
                HStack {
                    Button {
                        self.startAddingBoostTerm()
                    } label: {
                        Label("Add Word", systemImage: "plus")
                    }
                    .fluidButton(.accent, size: .small)

                    Spacer()
                }
            }

            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saved Words")
                        .font(self.theme.typography.captionStrong)
                    Text("These words get extra recognition help while Boosting is enabled.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }

                if self.boostTerms.isEmpty {
                    self.dictionaryEmptyState(
                        title: "No custom words yet",
                        detail: "Add a name or term that needs a little extra recognition help."
                    )
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: self.theme.metrics.spacing.sm) {
                            ForEach(Array(self.boostTerms.enumerated()), id: \.offset) { index, term in
                                BoostTermRow(
                                    term: term,
                                    onEdit: {
                                        self.editBoostTerm(at: index)
                                    },
                                    onDelete: {
                                        self.deleteBoostTerm(at: index)
                                    }
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 235)
                }
            }

            if self.boostHasError {
                Label(self.boostStatusMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.warning)
            }
        }
        .padding(self.theme.metrics.spacing.lg)
        .frame(width: 640, alignment: .leading)
        .onDisappear {
            self.dismissBoostTermEditor()
        }
    }

    private var boostWordEditor: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            Text(self.boostEditorTitle)
                .font(self.theme.typography.captionStrong)

            VStack(alignment: .leading, spacing: 6) {
                Text("Word or Phrase")
                    .font(self.theme.typography.captionStrong)
                TextField("FluidVoice", text: self.$boostTermText)
                    .font(self.theme.typography.bodySmall)
                    .dictionaryInputChrome()
                    .onSubmit { self.saveBoostTermIfValid() }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Word Priority")
                    .font(self.theme.typography.captionStrong)
                Picker("Word Priority", selection: self.$boostTermStrength) {
                    ForEach(BoostStrengthPreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                Text(self.boostTermStrength.hint)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }

            if self.isBoostTermDuplicate {
                Text("This word already exists.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.warning)
            }

            HStack {
                Spacer()

                Button("Clear") {
                    self.clearBoostTermFields()
                }
                .fluidButton(.compact, size: .compact)

                Spacer()

                Button("Cancel") {
                    self.dismissBoostTermEditor()
                }
                .fluidButton(.compact, size: .compact)

                Button("Save Word") {
                    self.saveBoostTermIfValid()
                }
                .fluidButton(.accent, size: .small)
                .disabled(!self.canSaveBoostTerm)
                .opacity(self.canSaveBoostTerm ? 1 : 0.45)
            }
        }
        .padding(self.theme.metrics.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private var punctuationDictionaryPopover: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Punctuation Dictionary")
                            .font(self.theme.typography.sectionTitle)

                        Button {
                            withAnimation(self.reduceMotion ? nil : .easeOut(duration: 0.14)) {
                                self.isPunctuationInfoExpanded.toggle()
                            }
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(SquareIconButtonStyle())
                        .help("About punctuation rules")
                        .accessibilityLabel("About punctuation rules")
                    }

                    Text("Say the start word first, then the punctuation name you want to type.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }

                Spacer()

                Button {
                    self.closePunctuationDictionary()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(SquareIconButtonStyle())
                .help("Close")
            }

            if self.isPunctuationInfoExpanded {
                self.punctuationDictionaryInfoPanel
            }

            HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Start Word")
                        .font(self.theme.typography.captionStrong)
                    Text("Say this first so normal words do not change.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    TextField("literal", text: self.$punctuationPrefix)
                        .dictionaryInputChrome()
                        .onSubmit { self.savePunctuationDictionaryPrefix() }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Try Saying")
                        .font(self.theme.typography.captionStrong)
                    Text("Examples of what FluidVoice will type.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    self.punctuationTrySayingPreview
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            if self.isPunctuationRuleEditorPresented {
                self.punctuationRuleEditor
            } else {
                HStack {
                    Button {
                        self.startAddingPunctuationRule()
                    } label: {
                        Label("Add Rule", systemImage: "plus")
                    }
                    .fluidButton(.accent, size: .small)

                    Spacer()
                }
            }

            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saved Rules")
                        .font(self.theme.typography.captionStrong)
                    Text("After the start word, these spoken versions type the punctuation symbol.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }

                if self.punctuationRules.isEmpty {
                    self.dictionaryEmptyState(
                        title: "No punctuation rules",
                        detail: "Add what you say and what FluidVoice should type."
                    )
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: self.theme.metrics.spacing.sm) {
                            ForEach(self.punctuationRules) { rule in
                                PunctuationDictionaryRuleRow(
                                    rule: rule,
                                    onEdit: { self.editPunctuationRule(rule) },
                                    onDelete: { self.deletePunctuationRule(rule) }
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 235)
                }
            }

            HStack {
                Spacer()
                Button("Reset Defaults") {
                    self.resetPunctuationDictionary()
                }
                .fluidButton(.compact, size: .compact)
            }
        }
        .padding(self.theme.metrics.spacing.lg)
        .frame(width: 640, alignment: .leading)
        .onDisappear {
            self.savePunctuationDictionaryPrefix()
        }
    }

    private var punctuationDictionaryInfoPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Say the start word first, then say the punctuation name.")
            Text("When you say \"\(self.punctuationPreviewPrefix) comma\", it types \",\".")
            Text("When you say \"\(self.punctuationPreviewPrefix) question mark\", it types \"?\".")
            Text("For each rule, add one spoken version per line. Then choose what FluidVoice types.")
        }
        .font(self.theme.typography.caption)
        .foregroundStyle(self.theme.palette.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
        .padding(self.theme.metrics.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private var punctuationTrySayingPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            self.punctuationExampleText(
                spoken: "\(self.punctuationPreviewPrefix) comma",
                typed: ","
            )
            self.punctuationExampleText(
                spoken: "\(self.punctuationPreviewPrefix) question mark",
                typed: "?"
            )
        }
        .font(self.theme.typography.caption)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, self.theme.metrics.spacing.md)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private func punctuationExampleText(spoken: String, typed: String) -> Text {
        Text("When you say ")
            .foregroundStyle(self.theme.palette.secondaryText) +
            Text("\"\(spoken)\"")
            .foregroundStyle(self.theme.palette.accent) +
            Text(", it types ")
            .foregroundStyle(self.theme.palette.secondaryText) +
            Text("\"\(typed)\"")
            .foregroundStyle(self.theme.palette.accent)
    }

    private var punctuationRuleEditor: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            Text(self.punctuationEditorTitle)
                .font(self.theme.typography.captionStrong)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) {
                    self.punctuationAliasesEditor
                    self.punctuationSymbolEditor
                }

                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                    self.punctuationAliasesEditor
                    self.punctuationSymbolEditor
                }
            }

            HStack {
                Spacer()

                Button("Clear") {
                    self.clearPunctuationRuleFields()
                }
                .fluidButton(.compact, size: .compact)

                Spacer()

                Button("Cancel") {
                    self.dismissPunctuationRuleEditor()
                }
                .fluidButton(.compact, size: .compact)

                Button("Save Rule") {
                    self.savePunctuationRuleIfValid()
                }
                .fluidButton(.accent, size: .small)
                .disabled(!self.canSavePunctuationRule)
                .opacity(self.canSavePunctuationRule ? 1 : 0.45)
            }
        }
        .padding(self.theme.metrics.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private var punctuationAliasesEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What You Say")
                .font(self.theme.typography.captionStrong)
            Text("One way per line, like comma or full stop.")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
            TextEditor(text: self.$punctuationAliasesText)
                .font(self.theme.typography.bodySmall)
                .frame(minHeight: 64, maxHeight: 86)
                .scrollContentBackground(.hidden)
                .dictionaryInputChrome(minHeight: 64)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var punctuationSymbolEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What It Types")
                .font(self.theme.typography.captionStrong)
            TextField(",", text: self.$punctuationSymbolText)
                .font(self.theme.typography.bodySmallStrong)
                .dictionaryInputChrome()
                .frame(width: 92)
            Text("One punctuation symbol, like , or ?.")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        }
    }

    private func dictionaryEmptyState(
        title: String,
        detail: String,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            Image(systemName: "plus.circle")
                .font(.title3)
                .foregroundStyle(self.theme.palette.tertiaryText)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(self.theme.typography.bodySmallStrong)
                Text(detail)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }

            if let action {
                Spacer()

                Button("Add", action: action)
                    .fluidButton(.compact, size: .compact)
            }
        }
        .padding(self.theme.metrics.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
                )
        )
    }

    // MARK: - Actions

    private func saveEntries() {
        SettingsStore.shared.customDictionaryEntries = self.entries
        // Invalidate cached regex patterns so changes take effect immediately
        ASRService.invalidateDictionaryCache()
        NotificationCenter.default.post(name: .parakeetVocabularyDidChange, object: nil)
    }

    private func updateTrainedReplacementGlow() {
        guard self.shouldPulseTrainedReplacementButton else {
            withAnimation(.easeOut(duration: 0.16)) {
                self.isTrainedReplacementGlowExpanded = false
            }
            return
        }

        self.isTrainedReplacementGlowExpanded = false
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            self.isTrainedReplacementGlowExpanded = true
        }
    }

    private func addReplacementEntry(_ entry: SettingsStore.CustomDictionaryEntry) {
        self.entries.insert(entry, at: 0)
        self.saveEntries()
        self.showReplacementConfirmation(
            title: "Replacement added",
            detail: "It is at the top of the list."
        )
    }

    private func selectComposerMode(_ mode: DictionaryComposerMode) {
        guard !self.isTrainingRecording, !self.isTrainingProcessing else { return }
        self.composerMode = mode
    }

    private func addManualReplacementIfValid() {
        guard self.canAddManualReplacement else { return }
        let entry = SettingsStore.CustomDictionaryEntry(
            triggers: self.manualTriggers,
            replacement: self.manualReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        self.addReplacementEntry(entry)
        self.manualTriggerDraft = ""
        self.manualReplacement = ""
    }

    private func presentYourDictionary() {
        self.entries = SettingsStore.shared.customDictionaryEntries
        self.isYourDictionaryPresented = true
    }

    private func closeYourDictionary() {
        self.isYourDictionaryPresented = false
    }

    private func presentPunctuationDictionary() {
        self.punctuationPrefix = SettingsStore.shared.punctuationDictionaryPrefix
        self.punctuationRules = SettingsStore.shared.punctuationDictionaryRules
        self.isPunctuationInfoExpanded = false
        self.dismissPunctuationRuleEditor()
        self.isPunctuationDictionaryPresented = true
    }

    private func closePunctuationDictionary() {
        self.savePunctuationDictionaryPrefix()
        self.isPunctuationInfoExpanded = false
        self.isPunctuationDictionaryPresented = false
    }

    private func savePunctuationDictionaryPrefix() {
        SettingsStore.shared.punctuationDictionaryPrefix = self.punctuationPrefix
        self.punctuationPrefix = SettingsStore.shared.punctuationDictionaryPrefix
    }

    private func savePunctuationRules() {
        SettingsStore.shared.punctuationDictionaryRules = self.punctuationRules
        self.punctuationRules = SettingsStore.shared.punctuationDictionaryRules
    }

    private func startAddingPunctuationRule() {
        self.editingPunctuationRuleID = nil
        self.clearPunctuationRuleFields()
        self.isPunctuationRuleEditorPresented = true
    }

    private func savePunctuationRuleIfValid() {
        guard self.canSavePunctuationRule, let symbol = self.normalizedPunctuationSymbol else { return }
        self.savePunctuationDictionaryPrefix()
        let rule = SettingsStore.PunctuationDictionaryRule(
            id: self.editingPunctuationRuleID ?? UUID(),
            aliases: self.normalizedPunctuationAliases,
            symbol: symbol
        )

        if let editingID = self.editingPunctuationRuleID,
           let index = self.punctuationRules.firstIndex(where: { $0.id == editingID })
        {
            self.punctuationRules[index] = rule
        } else {
            self.punctuationRules.insert(rule, at: 0)
        }

        self.savePunctuationRules()
        self.dismissPunctuationRuleEditor()
    }

    private func editPunctuationRule(_ rule: SettingsStore.PunctuationDictionaryRule) {
        self.editingPunctuationRuleID = rule.id
        self.punctuationAliasesText = rule.aliases.joined(separator: "\n")
        self.punctuationSymbolText = rule.symbol
        self.isPunctuationRuleEditorPresented = true
    }

    private func deletePunctuationRule(_ rule: SettingsStore.PunctuationDictionaryRule) {
        self.punctuationRules.removeAll { $0.id == rule.id }
        if self.editingPunctuationRuleID == rule.id {
            self.dismissPunctuationRuleEditor()
        }
        self.savePunctuationRules()
    }

    private func resetPunctuationDictionary() {
        self.punctuationPrefix = SettingsStore.defaultPunctuationDictionaryPrefix
        self.punctuationRules = SettingsStore.defaultPunctuationDictionaryRules
        self.dismissPunctuationRuleEditor()
        self.savePunctuationDictionaryPrefix()
        self.savePunctuationRules()
    }

    private func clearPunctuationRuleFields() {
        self.punctuationAliasesText = ""
        self.punctuationSymbolText = ""
    }

    private func dismissPunctuationRuleEditor() {
        self.editingPunctuationRuleID = nil
        self.clearPunctuationRuleFields()
        self.isPunctuationRuleEditorPresented = false
    }

    private func presentCustomWords() {
        self.loadBoostTerms()
        self.dismissBoostTermEditor()
        self.isCustomWordsPresented = true
    }

    private func closeCustomWords() {
        self.dismissBoostTermEditor()
        self.isCustomWordsPresented = false
    }

    private func startAddingBoostTerm() {
        self.editingBoostTermIndex = nil
        self.clearBoostTermFields()
        self.isBoostWordEditorPresented = true
    }

    private func editBoostTerm(at index: Int) {
        guard self.boostTerms.indices.contains(index) else { return }
        let term = self.boostTerms[index]
        self.editingBoostTermIndex = index
        self.boostTermText = term.text
        self.boostTermStrength = BoostStrengthPreset.nearest(for: term.weight ?? BoostStrengthPreset.balanced.weight)
        self.isBoostWordEditorPresented = true
    }

    private func saveBoostTermIfValid() {
        guard self.canSaveBoostTerm else { return }
        let updatedTerm = ParakeetVocabularyStore.VocabularyConfig.Term(
            text: self.normalizedBoostTermText,
            weight: self.boostTermStrength.weight,
            aliases: []
        )

        if let index = self.editingBoostTermIndex,
           self.boostTerms.indices.contains(index)
        {
            self.boostTerms[index] = ParakeetVocabularyStore.VocabularyConfig.Term(
                text: updatedTerm.text,
                weight: updatedTerm.weight,
                aliases: self.boostTerms[index].aliases
            )
        } else {
            self.boostTerms.append(updatedTerm)
        }

        self.saveBoostTerms()
        self.dismissBoostTermEditor()
    }

    private func clearBoostTermFields() {
        self.boostTermText = ""
        self.boostTermStrength = .balanced
    }

    private func dismissBoostTermEditor() {
        self.editingBoostTermIndex = nil
        self.clearBoostTermFields()
        self.isBoostWordEditorPresented = false
    }

    private func toggleAutomaticTraining() async {
        if self.isAutomaticTrainingEnabled {
            self.isAutomaticTrainingEnabled = false
            if self.isTrainingRecording {
                await self.stopTrainingSample()
            }
            return
        }

        if self.canRetryTrainingAfterMaximum {
            self.resetTrainingVerificationAttempts()
        }
        guard self.canRecordTrainingSample else { return }
        self.isAutomaticTrainingEnabled = true
        await self.startTrainingSample()
    }

    private func startTrainingSample() async {
        guard self.isAutomaticTrainingEnabled, self.canRecordTrainingSample else {
            self.isAutomaticTrainingEnabled = false
            return
        }
        self.isTrainingActive = true
        self.trainingHasError = false
        self.trainingStatusMessage = ""
        self.trainingStopRequestedDuringStart = false
        self.isTrainingStarting = true
        self.isTrainingRecording = true

        await self.asr.start(forDictionaryTraining: true)
        self.isTrainingStarting = false
        if !self.asr.isRunning {
            self.isTrainingRecording = false
            self.trainingStopRequestedDuringStart = false
            self.isAutomaticTrainingEnabled = false
            self.trainingHasError = true
            self.trainingStatusMessage = "Couldn't start recording. Check microphone access and try again."
            return
        }

        if self.trainingStopRequestedDuringStart {
            await self.finishTrainingSampleStop()
            return
        }
        DictionaryTrainingEndpointMonitor.shared.start(asr: self.asr) {
            self.handleAutomaticTrainingSpeechEnd()
        }
    }

    private func stopTrainingSample() async {
        DictionaryTrainingEndpointMonitor.shared.stop()
        guard self.isTrainingRecording else { return }
        guard !self.trainingStopRequestedDuringStart else { return }

        guard !self.isTrainingStarting, self.asr.isRunning else {
            self.trainingStopRequestedDuringStart = true
            self.trainingHasError = false
            self.trainingStatusMessage = "Stopping..."
            return
        }

        await self.finishTrainingSampleStop()
    }

    private func handleAutomaticTrainingSpeechEnd() {
        guard self.isAutomaticTrainingEnabled, self.isTrainingRecording else { return }
        Task { await self.stopTrainingSample() }
    }

    private func finishTrainingSampleStop() async {
        guard self.isTrainingRecording else { return }
        DictionaryTrainingEndpointMonitor.shared.stop()
        self.isTrainingRecording = false
        self.isTrainingStarting = false
        self.trainingStopRequestedDuringStart = false
        self.isTrainingProcessing = true
        self.trainingHasError = false
        self.trainingStatusMessage = ""

        let transcript = await self.asr.stop(forDictionaryTraining: true)
        self.isTrainingProcessing = false
        if self.activePronunciationMatching,
           CustomDictionaryTrainingMerge.normalizedTrigger(transcript) != nil,
           let enrollment = self.asr.lastDictionaryTrainingResult?.pronunciationEnrollment
        {
            self.trainingPronunciationEnrollments.append(enrollment)
        }
        self.addTrainingVariant(from: transcript)
        await self.continueAutomaticTrainingIfNeeded()
    }

    private func continueAutomaticTrainingIfNeeded() async {
        guard self.isAutomaticTrainingEnabled,
              !self.trainingFinalOutputIsReady,
              !self.trainingAlreadyCorrectWithoutReplacement,
              self.trainingSampleCount < CustomDictionaryTrainingMerge.maxSamples
        else {
            self.isAutomaticTrainingEnabled = false
            return
        }

        await Task.yield()
        await self.startTrainingSample()
    }

    private func resetTrainingVerificationAttempts() {
        self.trainingSampleCount = 0
        self.lastTrainingOutput = ""
        self.lastTrainingOutputIsCovered = false
        self.consecutiveCoveredCaptures = 0
        self.trainingStatusMessage = ""
        self.trainingHasError = false
    }

    private func addTrainingVariant(from transcript: String) {
        if self.activePronunciationMatching,
           self.asr.lastDictionaryTrainingResult?.pronunciationEnrollment == nil
        {
            self.trainingHasError = true
            self.trainingStatusMessage = "Couldn't capture a voice profile. Try again with one clear word."
            return
        }
        guard let detected = CustomDictionaryTrainingMerge.normalizedTrigger(transcript) else {
            self.lastTrainingOutput = ""
            self.lastTrainingOutputIsCovered = false
            self.consecutiveCoveredCaptures = 0
            self.trainingHasError = true
            self.trainingStatusMessage = "Nothing heard. Try again."
            return
        }

        self.lastTrainingOutput = detected
        self.trainingSampleCount = min(self.trainingSampleCount + 1, CustomDictionaryTrainingMerge.maxSamples)

        if detected.caseInsensitiveCompare(self.normalizedTrainingReplacement) == .orderedSame {
            self.lastTrainingOutputIsCovered = true
            self.consecutiveCoveredCaptures += 1
            self.trainingHasError = false
            if self.consecutiveCoveredCaptures >= CustomDictionaryTrainingMerge.readyCoveredCount {
                self.trainingStatusMessage = self.trainingVariants.isEmpty
                    ? "Looks good already. No replacement needed."
                    : "Looks ready. Add this replacement when you're ready."
            } else {
                self.trainingStatusMessage = "Covered. Try a couple more."
            }
            return
        }

        let wasAlreadyCaptured = self.trainingVariants.contains { $0.caseInsensitiveCompare(detected) == .orderedSame }
        let wasAlreadySaved = self.savedDictionaryCovers(detected)

        if wasAlreadyCaptured || wasAlreadySaved {
            self.lastTrainingOutputIsCovered = true
            self.consecutiveCoveredCaptures += 1
            self.trainingHasError = false
            if self.consecutiveCoveredCaptures >= CustomDictionaryTrainingMerge.readyCoveredCount {
                self.trainingStatusMessage = "Looks ready. Add this replacement when you're ready."
            } else if wasAlreadySaved {
                self.trainingStatusMessage = "Covered by your dictionary."
            } else {
                self.trainingStatusMessage = "Already captured. Try a couple more."
            }
            return
        }

        guard self.trainingVariants.count < CustomDictionaryTrainingMerge.maxSamples else {
            self.lastTrainingOutputIsCovered = false
            self.consecutiveCoveredCaptures = 0
            self.trainingHasError = false
            self.trainingStatusMessage = "Max samples reached. Add it or clear one."
            return
        }

        self.trainingVariants.append(detected)
        self.lastTrainingOutputIsCovered = false
        self.consecutiveCoveredCaptures = 0
        self.trainingHasError = false
        if self.trainingSampleCount >= CustomDictionaryTrainingMerge.maxSamples || self.trainingVariants.count >= CustomDictionaryTrainingMerge.maxSamples {
            self.trainingStatusMessage = "Max samples reached. Add it or clear one."
        } else {
            self.trainingStatusMessage = "New pronunciation captured. Add replacement to cover it."
        }
    }

    private func addTrainedReplacement() async {
        guard self.canAddTrainedReplacement else { return }
        self.isTrainingProcessing = true
        let replacementText = self.normalizedTrainingReplacement
        let updatesExisting = self.entries.contains {
            $0.replacement.caseInsensitiveCompare(replacementText) == .orderedSame
        }
        self.entries = CustomDictionaryTrainingMerge.mergedEntries(
            current: self.entries,
            replacement: replacementText,
            triggers: self.trainingVariants
        )
        let entry = self.entries.first {
            $0.replacement.caseInsensitiveCompare(replacementText) == .orderedSame
        }
        let enrollments = self.trainingPronunciationEnrollments
        if self.activePronunciationMatching, let entry, let modelKey = enrollments.first?.modelKey {
            do {
                try await PronunciationDictionaryStore.shared.upsert(
                    dictionaryEntryID: entry.id,
                    label: replacementText,
                    modelKey: modelKey,
                    enrollments: enrollments
                )
            } catch {
                self.isTrainingProcessing = false
                self.trainingHasError = true
                self.trainingStatusMessage = "Couldn't save the voice profile. Try again."
                DebugLogger.shared.error(
                    "Failed to save pronunciation profile: \(error.localizedDescription)",
                    source: "PronunciationMatching"
                )
                return
            }
        }
        self.saveEntries()
        self.resetTraining()
        self.showReplacementConfirmation(
            title: updatesExisting ? "Replacement updated" : "Recorded",
            detail: updatesExisting ? "Your variants are ready." : "Replacement added at the top."
        )
    }

    private func removeTrainingVariant(_ variant: String) {
        self.trainingVariants.removeAll { $0 == variant }
        self.refreshLastTrainingCoverage()
    }

    private func refreshLastTrainingCoverage() {
        guard !self.lastTrainingOutput.isEmpty else {
            self.lastTrainingOutputIsCovered = false
            self.consecutiveCoveredCaptures = 0
            return
        }

        let matchesReplacement = self.lastTrainingOutput.caseInsensitiveCompare(self.normalizedTrainingReplacement) == .orderedSame
        let isStillCaptured = self.trainingVariants.contains {
            $0.caseInsensitiveCompare(self.lastTrainingOutput) == .orderedSame
        }

        if matchesReplacement || isStillCaptured || self.savedDictionaryCovers(self.lastTrainingOutput) {
            self.lastTrainingOutputIsCovered = true
        } else {
            self.lastTrainingOutputIsCovered = false
            self.consecutiveCoveredCaptures = 0
        }
    }

    private func resetTraining(statusMessage: String = "Type the correct text.") {
        self.isAutomaticTrainingEnabled = false
        DictionaryTrainingEndpointMonitor.shared.stop()
        self.trainingReplacement = ""
        self.trainingVariants = []
        self.trainingPronunciationEnrollments = []
        self.trainingSampleCount = 0
        self.lastTrainingOutput = ""
        self.lastTrainingOutputIsCovered = false
        self.consecutiveCoveredCaptures = 0
        self.trainingStatusMessage = statusMessage
        self.trainingHasError = false
        self.isTrainingActive = false
        self.isTrainingStarting = false
        self.isTrainingRecording = false
        self.trainingStopRequestedDuringStart = false
        self.isTrainingProcessing = false
    }

    private func handleTrainingReplacementChange(oldValue: String, newValue: String) {
        let oldKey = CustomDictionaryTrainingMerge.normalizedReplacement(oldValue).lowercased()
        let newKey = CustomDictionaryTrainingMerge.normalizedReplacement(newValue).lowercased()
        guard oldKey != newKey else { return }

        self.trainingVariants = self.existingTrainingVariants(for: newValue)
        self.trainingPronunciationEnrollments = []
        self.trainingSampleCount = 0
        self.lastTrainingOutput = ""
        self.lastTrainingOutputIsCovered = false
        self.consecutiveCoveredCaptures = 0
        self.isTrainingActive = false
        if newKey.isEmpty {
            self.trainingStatusMessage = "Type the correct text."
        } else if self.trainingVariants.isEmpty {
            self.trainingStatusMessage = ""
        } else {
            self.trainingStatusMessage = "Loaded \(self.trainingVariants.count) saved \(self.trainingVariants.count == 1 ? "capture" : "captures")."
        }
        self.trainingHasError = false
    }

    private func existingTrainingVariants(for replacement: String) -> [String] {
        let replacementText = CustomDictionaryTrainingMerge.normalizedReplacement(replacement)
        guard !replacementText.isEmpty else { return [] }

        let triggers = self.entries
            .filter { $0.replacement.caseInsensitiveCompare(replacementText) == .orderedSame }
            .flatMap(\.triggers)

        return CustomDictionaryTrainingMerge.normalizedTriggers(
            from: triggers,
            intendedReplacement: replacementText
        )
    }

    private func savedDictionaryCovers(_ trigger: String) -> Bool {
        guard let triggerKey = CustomDictionaryTrainingMerge.normalizedTrigger(trigger),
              !self.normalizedTrainingReplacement.isEmpty
        else {
            return false
        }

        return self.entries.contains { entry in
            entry.replacement.caseInsensitiveCompare(self.normalizedTrainingReplacement) == .orderedSame &&
                entry.triggers.contains { savedTrigger in
                    guard let savedKey = CustomDictionaryTrainingMerge.normalizedTrigger(savedTrigger) else { return false }
                    return savedKey == triggerKey
                }
        }
    }

    private func showReplacementConfirmation(title: String, detail: String) {
        let confirmation = ReplacementConfirmation(title: title, detail: detail)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)

        withAnimation(self.reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.78)) {
            self.replacementConfirmation = confirmation
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_650_000_000)
            guard self.replacementConfirmation?.id == confirmation.id else { return }
            withAnimation(self.reduceMotion ? nil : .easeOut(duration: 0.16)) {
                self.replacementConfirmation = nil
            }
        }
    }

    private func loadBoostTerms() {
        do {
            self.boostTerms = try ParakeetVocabularyStore.shared.loadUserBoostTerms()
            self.boostStatusMessage = "Loaded \(self.boostTerms.count) custom words."
            self.boostHasError = false
        } catch {
            self.boostTerms = []
            self.boostStatusMessage = "Couldn't load custom words: \(error.localizedDescription)"
            self.boostHasError = true
        }
    }

    private func saveBoostTerms() {
        do {
            try ParakeetVocabularyStore.shared.saveUserBoostTerms(self.boostTerms)
            self.boostStatusMessage = "Saved \(self.boostTerms.count) custom words."
            self.boostHasError = false
        } catch {
            self.boostStatusMessage = "Couldn't save custom words: \(error.localizedDescription)"
            self.boostHasError = true
        }
    }

    private func exportDictionary() {
        do {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = DictionaryTransferService.shared.suggestedFilename()

            guard panel.runModal() == .OK, let url = panel.url else { return }

            let document = try DictionaryTransferService.shared.makeExportDocument()
            let data = try DictionaryTransferService.shared.encode(document)
            try data.write(to: url, options: .atomic)

            self.presentInfoAlert(
                title: "Dictionary Exported",
                message: "Saved \(document.replacements.count) replacement rules and \(document.customWords.count) custom words."
            )
        } catch {
            self.presentErrorAlert(title: "Dictionary Export Failed", message: error.localizedDescription)
        }
    }

    private func importDictionary() {
        do {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.json]

            guard panel.runModal() == .OK, let url = panel.url else { return }

            let data = try Data(contentsOf: url)
            let document = try DictionaryTransferService.shared.decode(data)
            guard let mode = self.confirmDictionaryImport(document) else { return }

            let summary = try DictionaryTransferService.shared.restore(document, mode: mode)
            self.entries = SettingsStore.shared.customDictionaryEntries
            self.loadBoostTerms()

            self.presentInfoAlert(
                title: "Dictionary Imported",
                message: "Now using \(summary.replacementCount) replacement rules and \(summary.customWordCount) custom words."
            )
        } catch {
            self.presentErrorAlert(title: "Dictionary Import Failed", message: error.localizedDescription)
        }
    }

    private func confirmDictionaryImport(_ document: DictionaryTransferDocument) -> DictionaryTransferImportMode? {
        let confirm = NSAlert()
        confirm.messageText = "Import this dictionary?"
        confirm.informativeText = """
        Found \(document.replacements.count) replacement rules and \(document.customWords.count) custom words.

        Merge adds them to your current dictionary. Replace clears the current dictionary first.
        """
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Merge")
        confirm.addButton(withTitle: "Replace")
        confirm.addButton(withTitle: "Cancel")

        switch confirm.runModal() {
        case .alertFirstButtonReturn:
            return .merge
        case .alertSecondButtonReturn:
            return .replace
        default:
            return nil
        }
    }

    private func presentInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func presentErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }

    private func deleteBoostTerm(at index: Int) {
        guard self.boostTerms.indices.contains(index) else { return }
        self.boostTerms.remove(at: index)
        if self.editingBoostTermIndex == index {
            self.dismissBoostTermEditor()
        } else if let editingIndex = self.editingBoostTermIndex, index < editingIndex {
            self.editingBoostTermIndex = editingIndex - 1
        }
        self.saveBoostTerms()
    }

    private func deleteEntry(_ entry: SettingsStore.CustomDictionaryEntry) {
        self.entries.removeAll { $0.id == entry.id }
        self.saveEntries()
        Task {
            try? await PronunciationDictionaryStore.shared.delete(dictionaryEntryID: entry.id)
        }
    }

    /// Returns all existing trigger words for duplicate detection
    private func allExistingTriggers(excluding entryId: UUID? = nil) -> Set<String> {
        var triggers = Set<String>()
        for entry in self.entries where entry.id != entryId {
            for trigger in entry.triggers {
                triggers.insert(trigger.lowercased())
            }
        }
        return triggers
    }

    private func existingBoostTerms(excludingIndex: Int? = nil) -> Set<String> {
        var terms: Set<String> = []
        for (index, term) in self.boostTerms.enumerated() where index != excludingIndex {
            terms.insert(term.text.lowercased())
        }
        return terms
    }
}

private extension CustomDictionaryView {
    var asr: ASRService { self.appServices.asr }

    var trainedReplacementButtonTitle: String {
        self.trainingAlreadyCorrectWithoutReplacement ? "Nothing to Save" : "Add Replacement"
    }

    var shouldEmphasizeTrainedReplacementButton: Bool {
        self.trainingFinalOutputIsReady && self.canAddTrainedReplacement
    }

    func trainingInstruction(number: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(self.theme.typography.captionStrong)
                .foregroundStyle(self.theme.palette.accent)
                .frame(width: 16, alignment: .center)

            Text(text)
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        }
    }

    func handlePronunciationMatchingChange(enabled: Bool) {
        SettingsStore.shared.pronunciationMatchingEnabled = enabled
        self.isAutomaticTrainingEnabled = false
        DictionaryTrainingEndpointMonitor.shared.stop()
        self.trainingVariants = self.existingTrainingVariants(for: self.trainingReplacement)
        self.trainingPronunciationEnrollments = []
        self.resetTrainingVerificationAttempts()
        self.trainingStatusMessage = self.normalizedTrainingReplacement.isEmpty
            ? "Type the correct text."
            : ""
    }
}

private struct VoiceMatchingSettingsRow: View {
    @Binding var isEnabled: Bool

    let isDisabled: Bool
    let isAdvancedAvailable: Bool
    let onChange: (Bool) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredMethod: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                self.methodButton(title: "Basic", systemImage: "checkmark", enabledValue: false)
                self.methodButton(title: "Advanced", systemImage: "waveform", enabledValue: true, isResearchPreview: true)
            }

            if self.isEnabled {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "flask.fill")
                        .foregroundStyle(self.theme.palette.accent)
                    Text("Research Preview: Compares how your voice sounds instead of only the words FluidVoice hears. Results may vary.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 2)
            } else if !self.isAdvancedAvailable {
                Text("Advanced voice matching requires Parakeet TDT on Apple Silicon.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .padding(.horizontal, 2)
            }
        }
        .padding(self.theme.metrics.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.42))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.24), lineWidth: 1)
                )
        )
    }

    private func methodButton(
        title: String,
        systemImage: String,
        enabledValue: Bool,
        isResearchPreview: Bool = false
    ) -> some View {
        let isSelected = self.isEnabled == enabledValue
        let isHovered = self.hoveredMethod == enabledValue
        return Button {
            guard !isSelected else { return }
            self.isEnabled = enabledValue
            self.onChange(enabledValue)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                Text(title)
                if isResearchPreview {
                    Text("Research Preview")
                        .font(self.theme.typography.captionSmall)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.86) : self.theme.palette.accent)
                }
            }
            .font(self.theme.typography.captionStrong)
            .foregroundStyle(isSelected ? Color.white : self.theme.palette.primaryText)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        isSelected
                            ? self.theme.palette.accent
                            : (isHovered
                                ? self.theme.palette.accent.opacity(0.1)
                                : self.theme.palette.cardBackground.opacity(0.5))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(
                                isSelected || isHovered
                                    ? self.theme.palette.accent
                                    : self.theme.palette.primaryText.opacity(0.22),
                                lineWidth: isSelected || isHovered ? 1.25 : 1
                            )
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(self.isDisabled || (enabledValue && !self.isAdvancedAvailable))
        .opacity(self.isDisabled || (enabledValue && !self.isAdvancedAvailable) ? 0.55 : 1)
        .onHover { hovering in
            let update = { self.hoveredMethod = hovering ? enabledValue : nil }
            if self.reduceMotion {
                update()
            } else {
                withAnimation(.easeOut(duration: 0.14), update)
            }
        }
    }
}

private struct DictionaryInputChrome: ViewModifier {
    let minHeight: CGFloat

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focused(self.$isFocused)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: self.minHeight)
            .background(self.background)
            .contentShape(RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous))
            .shadow(
                color: self.isFocused ? self.theme.palette.accent.opacity(0.16) : .clear,
                radius: 7
            )
            .onHover { hovering in
                if self.reduceMotion {
                    self.isHovered = hovering
                } else {
                    withAnimation(.easeOut(duration: 0.14)) {
                        self.isHovered = hovering
                    }
                }
            }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
            .fill(
                self.isFocused
                    ? self.theme.palette.accent.opacity(0.08)
                    : self.theme.palette.primaryText.opacity(self.isHovered ? 0.075 : 0.055)
            )
            .overlay(
                RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
                    .stroke(
                        self.isFocused
                            ? self.theme.palette.accent
                            : self.theme.palette.primaryText.opacity(self.isHovered ? 0.38 : 0.26),
                        lineWidth: self.isFocused ? 1.5 : 1
                    )
            )
    }
}

private extension View {
    func dictionaryInputChrome(minHeight: CGFloat = 34) -> some View {
        self.modifier(DictionaryInputChrome(minHeight: minHeight))
    }

    func dismissTextFocusOnBackgroundTap() -> some View {
        self.background(DictionaryFocusDismissMonitor())
    }
}

private struct DictionaryFocusDismissMonitor: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        FocusDismissView()
    }

    func updateNSView(_: NSView, context _: Context) {}

    private final class FocusDismissView: NSView {
        private var eventMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            self.removeEventMonitor()
            guard self.window != nil else { return }

            self.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let contentView = self.window?.contentView
                let location = contentView?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
                let hitView = contentView?.hitTest(location)
                if !self.isTextInput(hitView) {
                    self.window?.makeFirstResponder(nil)
                }
                return event
            }
        }

        deinit {
            self.removeEventMonitor()
        }

        private func isTextInput(_ view: NSView?) -> Bool {
            var candidate = view
            while let current = candidate {
                if current is NSTextField || current is NSTextView {
                    return true
                }
                candidate = current.superview
            }
            return false
        }

        private func removeEventMonitor() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

private enum DictionaryTrainingCopy {
    static func target(for normalizedTarget: String) -> String {
        normalizedTarget.isEmpty ? "the word" : "“\(normalizedTarget)”"
    }

    static func composerDetail(mode: DictionaryComposerMode, target: String) -> String {
        mode == .train && target != "the word" ? "Teach \(target) by speaking it." : mode.detail
    }

    static func readinessCaption(
        target: String,
        isAlreadyCorrect: Bool,
        isReady: Bool,
        usesVoiceMatching: Bool
    ) -> String {
        if isAlreadyCorrect {
            return "No replacement is needed for \(target)."
        }
        if isReady {
            return usesVoiceMatching
                ? "Ready. FluidVoice learned how \(target) sounds in your voice."
                : "Ready. FluidVoice got \(target) right 3 times in a row."
        }
        return usesVoiceMatching
            ? "Say \(target) 3 times to unlock Add Replacement."
            : "Keep trying until FluidVoice gets \(target) right 3 times in a row."
    }
}

private enum DictionaryComposerMode: CaseIterable, Identifiable {
    case train
    case manual

    var id: Self { self }

    var title: String {
        switch self {
        case .train:
            return "Train by Voice"
        case .manual:
            return "Add Manually"
        }
    }

    var systemImage: String {
        switch self {
        case .train:
            return "mic.fill"
        case .manual:
            return "keyboard"
        }
    }

    var detail: String {
        switch self {
        case .train:
            return "Teach a word by speaking it."
        case .manual:
            return "Type the misheard text and the spelling you want."
        }
    }
}

private struct DictionaryComposerModeTab: View {
    let mode: DictionaryComposerMode
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Image(systemName: self.mode.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(self.mode.title)
                    .font(self.theme.typography.bodySmallStrong)
            }
            .foregroundStyle(self.foreground)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 30)
            .padding(.horizontal, self.theme.metrics.spacing.md)
            .background(self.background)
            .contentShape(RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(self.isDisabled)
        .opacity(self.isDisabled ? 0.55 : 1)
        .onHover { hovering in
            guard !self.reduceMotion else {
                self.isHovered = hovering
                return
            }
            withAnimation(.easeOut(duration: 0.14)) {
                self.isHovered = hovering
            }
        }
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
    }

    private var foreground: Color {
        self.isSelected ? Color.white : self.theme.palette.primaryText
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
            .fill(
                self.isSelected
                    ? self.theme.palette.accent
                    : (self.isHovered
                        ? self.theme.palette.accent.opacity(0.1)
                        : self.theme.palette.cardBackground.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
                    .stroke(
                        self.isSelected || self.isHovered
                            ? self.theme.palette.accent
                            : self.theme.palette.primaryText.opacity(0.22),
                        lineWidth: self.isSelected || self.isHovered ? 1.25 : 1
                    )
            )
    }
}

enum CustomDictionaryManualEntry {
    static func normalizedTrigger(_ text: String) -> String? {
        let trigger = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trigger.isEmpty ? nil : trigger
    }

    static func normalizedTriggers(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var triggers: [String] = []
        triggers.reserveCapacity(values.count)

        for value in values {
            guard let trigger = self.normalizedTrigger(value), !seen.contains(trigger) else { continue }
            seen.insert(trigger)
            triggers.append(trigger)
        }

        return triggers
    }

    static func normalizedDraftTriggers(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.allSatisfy({ $0 == "," || $0.isWhitespace }) {
            return self.normalizedTriggers([trimmed])
        }

        return self.normalizedTriggers(trimmed.split(separator: ",").map(String.init))
    }
}

enum PronunciationProfileEditPolicy {
    static func shouldDiscardProfile(previousReplacement: String, updatedReplacement: String) -> Bool {
        previousReplacement.caseInsensitiveCompare(updatedReplacement) != .orderedSame
    }
}

enum CustomDictionaryTrainingMerge {
    static let recommendedSamples = 5
    static let maxSamples = 20
    static let readyCoveredCount = 3

    private static let edgePunctuation = CharacterSet(charactersIn: ".,!?;:\"'“”‘’")

    static func normalizedReplacement(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedTrigger(_ value: String) -> String? {
        let edgeCharacters = CharacterSet.whitespacesAndNewlines.union(self.edgePunctuation)
        let trimmed = value.trimmingCharacters(in: edgeCharacters).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedTriggers(from values: [String], intendedReplacement: String) -> [String] {
        let replacement = self.normalizedReplacement(intendedReplacement)
        var seen: Set<String> = []
        var result: [String] = []
        result.reserveCapacity(values.count)

        for value in values {
            guard let trigger = self.normalizedTrigger(value),
                  trigger.caseInsensitiveCompare(replacement) != .orderedSame,
                  !seen.contains(trigger)
            else {
                continue
            }
            seen.insert(trigger)
            result.append(trigger)
            if result.count >= self.maxSamples {
                break
            }
        }

        return result
    }

    static func mergedEntries(
        current entries: [SettingsStore.CustomDictionaryEntry],
        replacement: String,
        triggers: [String]
    ) -> [SettingsStore.CustomDictionaryEntry] {
        let replacementText = self.normalizedReplacement(replacement)
        let incomingTriggers = self.normalizedTriggers(from: triggers, intendedReplacement: replacementText)
        guard !replacementText.isEmpty, !incomingTriggers.isEmpty else { return entries }

        let matchingIndex = entries.firstIndex {
            $0.replacement.caseInsensitiveCompare(replacementText) == .orderedSame
        }
        let replacementID = matchingIndex.map { entries[$0].id }
        let storedReplacementText = matchingIndex.map { entries[$0].replacement } ?? replacementText
        let matchingEntries = entries.filter {
            $0.replacement.caseInsensitiveCompare(storedReplacementText) == .orderedSame
        }
        let existingTriggers = matchingEntries.flatMap(\.triggers)
        let combinedTriggers = self.normalizedTriggers(
            from: existingTriggers + incomingTriggers,
            intendedReplacement: storedReplacementText
        )
        let triggerKeys = Set(combinedTriggers)

        let mergedEntry = replacementID.map {
            SettingsStore.CustomDictionaryEntry(
                id: $0,
                triggers: combinedTriggers,
                replacement: storedReplacementText
            )
        } ?? SettingsStore.CustomDictionaryEntry(
            triggers: combinedTriggers,
            replacement: storedReplacementText
        )

        var didInsertMergedEntry = false
        var updatedEntries: [SettingsStore.CustomDictionaryEntry] = []
        updatedEntries.reserveCapacity(entries.count + (matchingIndex == nil ? 1 : 0))

        for entry in entries {
            if entry.replacement.caseInsensitiveCompare(storedReplacementText) == .orderedSame {
                if !didInsertMergedEntry {
                    updatedEntries.append(mergedEntry)
                    didInsertMergedEntry = true
                }
                continue
            }

            let remainingTriggers = entry.triggers.filter { trigger in
                guard let key = self.normalizedTrigger(trigger) else { return false }
                return !triggerKeys.contains(key)
            }
            guard !remainingTriggers.isEmpty else { continue }
            updatedEntries.append(
                SettingsStore.CustomDictionaryEntry(
                    id: entry.id,
                    triggers: remainingTriggers,
                    replacement: entry.replacement
                )
            )
        }

        if !didInsertMergedEntry {
            updatedEntries.insert(mergedEntry, at: 0)
        }

        return updatedEntries
    }
}

private struct ReplacementConfirmation: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
}

private struct ReplacementConfirmationToast: View {
    let confirmation: ReplacementConfirmation

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: self.theme.metrics.spacing.sm) {
            ZStack {
                Circle()
                    .fill(self.theme.palette.accent.opacity(0.14))
                    .frame(width: 58, height: 58)

                Circle()
                    .stroke(self.theme.palette.accent.opacity(0.24), lineWidth: 1)
                    .frame(width: 58, height: 58)

                Image(systemName: "checkmark")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(self.theme.palette.accent)
            }

            VStack(spacing: 3) {
                Text(self.confirmation.title)
                    .font(self.theme.typography.sectionTitle)
                    .foregroundStyle(self.theme.palette.primaryText)
                Text(self.confirmation.detail)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(minWidth: 220)
        .padding(.horizontal, self.theme.metrics.spacing.xl)
        .padding(.vertical, self.theme.metrics.spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
                .fill(self.theme.palette.cardBackground.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
                        .stroke(self.theme.palette.accent.opacity(0.3), lineWidth: 1)
                )
                .shadow(
                    color: self.theme.palette.accent.opacity(0.24),
                    radius: 24,
                    x: 0,
                    y: 10
                )
                .shadow(
                    color: Color.black.opacity(0.16),
                    radius: 18,
                    x: 0,
                    y: 8
                )
        )
        .accessibilityElement(children: .combine)
    }
}

private struct DictionaryTrainingReadinessRing: View {
    let progress: Int
    let total: Int
    let isReady: Bool

    @Environment(\.theme) private var theme

    private var fraction: Double {
        guard self.total > 0 else { return 0 }
        return min(max(Double(self.progress) / Double(self.total), 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(self.theme.palette.cardBorder.opacity(0.62), lineWidth: 8)

            Circle()
                .trim(from: 0, to: self.fraction)
                .stroke(
                    self.theme.palette.accent,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: 1) {
                Text("\(self.progress)/\(self.total)")
                    .font(self.theme.typography.sectionTitle)
                    .foregroundStyle(self.isReady ? self.theme.palette.accent : self.theme.palette.primaryText)
                    .monospacedDigit()

                Text(self.isReady ? "Ready" : "correct")
                    .font(self.theme.typography.captionSmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
        }
        .frame(width: 92, height: 92)
        .shadow(color: self.isReady ? self.theme.palette.accent.opacity(0.2) : .clear, radius: 10)
        .animation(.easeOut(duration: 0.24), value: self.progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Training progress")
        .accessibilityValue("\(self.progress) of \(self.total) correct")
    }
}

private struct TrainingVariantChip: View {
    let number: Int
    let variant: String
    let onDelete: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Text("\(self.number)")
                .font(self.theme.typography.captionSmall)
                .foregroundStyle(self.theme.palette.accent)
                .frame(minWidth: 11)

            Text(self.variant)
                .font(self.theme.typography.caption)
                .lineLimit(1)
                .truncationMode(.tail)

            Button(action: self.onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(self.theme.palette.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("Remove \(self.variant)")
        }
        .frame(maxWidth: 165)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(self.theme.palette.cardBackground.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.35), lineWidth: 1)
                )
        )
    }
}

private struct DictionaryPreviewChip: View {
    let text: String

    @Environment(\.theme) private var theme

    var body: some View {
        Text(self.text)
            .font(self.theme.typography.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(self.theme.palette.cardBackground.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(self.theme.palette.cardBorder.opacity(0.35), lineWidth: 1)
                    )
            )
    }
}

private enum BoostStrengthPreset: String, CaseIterable, Identifiable {
    case mild = "Mild"
    case balanced = "Balanced"
    case strong = "Strong"

    var id: String { self.rawValue }

    var weight: Float {
        switch self {
        case .mild: return 5.0
        case .balanced: return 10.0
        case .strong: return 13.0
        }
    }

    var hint: String {
        switch self {
        case .mild: return "Very light nudge with minimal impact."
        case .balanced: return "Best default for most names and product terms."
        case .strong: return "Use when this word should win more often in noisy audio."
        }
    }

    var badgeColor: Color {
        switch self {
        case .mild: return .blue
        case .balanced: return Color.fluidGreen
        case .strong: return .orange
        }
    }

    static func nearest(for weight: Float) -> Self {
        if weight < 8.5 { return .mild }
        if weight > 11.5 { return .strong }
        return .balanced
    }
}

// MARK: - Boost Term Row

struct BoostTermRow: View {
    let term: ParakeetVocabularyStore.VocabularyConfig.Term
    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            Text(self.term.text)
                .font(self.theme.typography.bodySmallStrong)

            Spacer()

            if let weight = self.term.weight {
                let strength = BoostStrengthPreset.nearest(for: weight)
                Text(strength.rawValue)
                    .font(self.theme.typography.bodySmallStrong)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(strength.badgeColor.opacity(0.25)))
                    .foregroundStyle(strength.badgeColor)
            }

            HStack(spacing: 2) {
                Button {
                    self.onEdit()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(SquareIconButtonStyle())
                .help("Configure \(self.term.text)")

                Button(role: .destructive) {
                    self.onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(SquareIconButtonStyle(foreground: .red, borderColor: .red))
                .help("Delete \(self.term.text)")
            }
        }
        .padding(.horizontal, self.theme.metrics.spacing.md)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.52))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.28), lineWidth: 1)
                )
        )
    }
}

// MARK: - Dictionary Entry Row

struct DictionaryEntryRow: View {
    let entry: SettingsStore.CustomDictionaryEntry
    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.sm) {
            FlowLayout(spacing: 4) {
                ForEach(self.entry.triggers, id: \.self) { trigger in
                    Text(trigger)
                        .font(self.theme.typography.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.tertiaryText)

            Text(self.entry.replacement)
                .font(self.theme.typography.bodySmallStrong)
                .foregroundStyle(self.theme.palette.accent)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                Button {
                    self.onEdit()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(SquareIconButtonStyle())
                .help("Configure replacement")

                Button(role: .destructive) {
                    self.onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(SquareIconButtonStyle(foreground: .red, borderColor: .red))
                .help("Delete replacement")
            }
        }
        .padding(.horizontal, self.theme.metrics.spacing.md)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.52))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.28), lineWidth: 1)
                )
        )
    }
}

private struct PunctuationDictionaryRuleRow: View {
    let rule: SettingsStore.PunctuationDictionaryRule
    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.sm) {
            Text(self.rule.aliases.joined(separator: ", "))
                .font(self.theme.typography.captionStrong)
                .foregroundStyle(self.theme.palette.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.tertiaryText)

            Text(self.rule.symbol)
                .font(self.theme.typography.bodySmallStrong)
                .foregroundStyle(self.theme.palette.accent)
                .frame(width: 60, alignment: .leading)
                .lineLimit(1)

            HStack(spacing: 2) {
                Button {
                    self.onEdit()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(SquareIconButtonStyle())
                .help("Edit punctuation rule")

                Button(role: .destructive) {
                    self.onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(SquareIconButtonStyle(foreground: .red, borderColor: .red))
                .help("Delete punctuation rule")
            }
        }
        .padding(.horizontal, self.theme.metrics.spacing.md)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.52))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.28), lineWidth: 1)
                )
        )
    }
}

// MARK: - Add Entry Sheet

struct AddDictionaryEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let existingTriggers: Set<String>
    let onSave: (SettingsStore.CustomDictionaryEntry) -> Void

    @State private var triggersText = ""
    @State private var replacement = ""

    private var duplicateTriggers: [String] {
        self.parseTriggers().filter { self.existingTriggers.contains($0) }
    }

    private var canSave: Bool {
        !self.parseTriggers().isEmpty &&
            !self.replacement.trimmingCharacters(in: .whitespaces).isEmpty &&
            self.duplicateTriggers.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("Add Dictionary Entry")
                    .font(.headline)
                Spacer()
                Button("Cancel") { self.dismiss() }
                    .buttonStyle(.bordered)
            }

            Divider()

            // Triggers input
            VStack(alignment: .leading, spacing: 6) {
                Text("Misheard Words (triggers)")
                    .font(.subheadline.weight(.medium))
                Text("Add one version per line. Commas can be saved too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: self.$triggersText)
                    .font(.body)
                    .frame(minHeight: 54, maxHeight: 76)
                    .scrollContentBackground(.hidden)
                    .dictionaryInputChrome(minHeight: 54)

                // Duplicate warning
                if !self.duplicateTriggers.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Duplicate triggers: \(self.duplicateTriggers.joined(separator: ", "))")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                }
            }

            // Replacement input
            VStack(alignment: .leading, spacing: 6) {
                Text("Correct Spelling (replacement)")
                    .font(.subheadline.weight(.medium))
                Text("This is what will appear in the final transcription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("FluidVoice", text: self.$replacement)
                    .dictionaryInputChrome()
                    .onSubmit { self.saveIfValid() }
            }

            Spacer()

            // Preview
            if !self.triggersText.isEmpty && !self.replacement.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preview")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    FlowLayout(spacing: 6) {
                        ForEach(self.parseTriggers(), id: \.self) { trigger in
                            Text(trigger)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 4).fill(
                                        self.duplicateTriggers.contains(trigger)
                                            ? AnyShapeStyle(Color.orange.opacity(0.3))
                                            : AnyShapeStyle(.quaternary)
                                    )
                                )
                        }

                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        Text(self.replacement)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(self.theme.palette.accent)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(self.theme.palette.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(self.theme.palette.cardBorder.opacity(0.5), lineWidth: 1)
                        )
                )
            }

            // Save button
            HStack {
                Spacer()
                Button("Add Replacement") { self.saveIfValid() }
                    .buttonStyle(.borderedProminent)
                    .tint(self.theme.palette.accent)
                    .disabled(!self.canSave)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(20)
        .frame(minWidth: 400, idealWidth: 450, maxWidth: 500)
        .frame(minHeight: 350, idealHeight: 400, maxHeight: 450)
        .dismissTextFocusOnBackgroundTap()
    }

    private func parseTriggers() -> [String] {
        CustomDictionaryManualEntry.normalizedTriggers(
            self.triggersText.components(separatedBy: .newlines)
        )
    }

    private func saveIfValid() {
        guard self.canSave else { return }

        let entry = SettingsStore.CustomDictionaryEntry(
            triggers: self.parseTriggers(),
            replacement: self.replacement.trimmingCharacters(in: .whitespaces)
        )
        self.onSave(entry)
        self.dismiss()
    }
}

// MARK: - Edit Entry Sheet

struct EditDictionaryEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let entry: SettingsStore.CustomDictionaryEntry
    let existingTriggers: Set<String>
    let onSave: (SettingsStore.CustomDictionaryEntry) -> Void

    @State private var triggersText = ""
    @State private var replacement = ""

    private var duplicateTriggers: [String] {
        self.parseTriggers().filter { self.existingTriggers.contains($0) }
    }

    private var canSave: Bool {
        !self.parseTriggers().isEmpty &&
            !self.replacement.trimmingCharacters(in: .whitespaces).isEmpty &&
            self.duplicateTriggers.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("Edit Dictionary Entry")
                    .font(.headline)
                Spacer()
                Button("Cancel") { self.dismiss() }
                    .buttonStyle(.bordered)
            }

            Divider()

            // Triggers input
            VStack(alignment: .leading, spacing: 6) {
                Text("Misheard Words (triggers)")
                    .font(.subheadline.weight(.medium))
                Text("Add one version per line. Commas can be saved too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: self.$triggersText)
                    .font(.body)
                    .frame(minHeight: 54, maxHeight: 76)
                    .scrollContentBackground(.hidden)
                    .dictionaryInputChrome(minHeight: 54)

                // Duplicate warning
                if !self.duplicateTriggers.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Duplicate triggers: \(self.duplicateTriggers.joined(separator: ", "))")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                }
            }

            // Replacement input
            VStack(alignment: .leading, spacing: 6) {
                Text("Correct Spelling (replacement)")
                    .font(.subheadline.weight(.medium))
                Text("This is what will appear in the final transcription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("FluidVoice", text: self.$replacement)
                    .dictionaryInputChrome()
                    .onSubmit { self.saveIfValid() }
            }

            Spacer()

            // Preview
            if !self.triggersText.isEmpty && !self.replacement.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preview")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    FlowLayout(spacing: 6) {
                        ForEach(self.parseTriggers(), id: \.self) { trigger in
                            Text(trigger)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 4).fill(
                                        self.duplicateTriggers.contains(trigger)
                                            ? AnyShapeStyle(Color.orange.opacity(0.3))
                                            : AnyShapeStyle(.quaternary)
                                    )
                                )
                        }

                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        Text(self.replacement)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(self.theme.palette.accent)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(self.theme.palette.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(self.theme.palette.cardBorder.opacity(0.5), lineWidth: 1)
                        )
                )
            }

            // Save button
            HStack {
                Spacer()
                Button("Save Changes") { self.saveIfValid() }
                    .buttonStyle(.borderedProminent)
                    .tint(self.theme.palette.accent)
                    .disabled(!self.canSave)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(20)
        .frame(minWidth: 400, idealWidth: 450, maxWidth: 500)
        .frame(minHeight: 320, idealHeight: 380, maxHeight: 420)
        .dismissTextFocusOnBackgroundTap()
        .onAppear {
            self.triggersText = self.entry.triggers.joined(separator: "\n")
            self.replacement = self.entry.replacement
        }
    }

    private func parseTriggers() -> [String] {
        CustomDictionaryManualEntry.normalizedTriggers(
            self.triggersText.components(separatedBy: .newlines)
        )
    }

    private func saveIfValid() {
        guard self.canSave else { return }

        let updatedEntry = SettingsStore.CustomDictionaryEntry(
            id: self.entry.id,
            triggers: self.parseTriggers(),
            replacement: self.replacement.trimmingCharacters(in: .whitespaces)
        )
        self.onSave(updatedEntry)
        self.dismiss()
    }
}
