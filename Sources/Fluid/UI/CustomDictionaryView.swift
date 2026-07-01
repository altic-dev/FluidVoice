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

    private var asr: ASRService { self.appServices.asr }

    @State private var entries: [SettingsStore.CustomDictionaryEntry] = SettingsStore.shared.customDictionaryEntries
    @State private var boostTerms: [ParakeetVocabularyStore.VocabularyConfig.Term] = []
    @State private var editingEntry: SettingsStore.CustomDictionaryEntry?
    @State private var showAddBoostSheet = false
    @State private var editingBoostTerm: EditableBoostTerm?

    @State private var boostStatusMessage = "Add custom words for better Parakeet recognition."
    @State private var boostHasError = false
    @State private var vocabBoostingEnabled: Bool = SettingsStore.shared.vocabularyBoostingEnabled
    @State private var isBoostingInfoPresented = false

    @State private var trainingReplacement = ""
    @State private var trainingVariants: [String] = []
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
    @State private var replacementConfirmation: ReplacementConfirmation?
    @State private var composerMode: DictionaryComposerMode = .train
    @State private var manualTriggersText = ""
    @State private var manualReplacement = ""
    @State private var isDictionaryExpanded = false

    private var normalizedTrainingReplacement: String {
        self.trainingReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trainingProgressText: String {
        let count = self.trainingSampleCount
        return "\(count) \(count == 1 ? "sample" : "samples") · up to \(CustomDictionaryTrainingMerge.maxSamples)"
    }

    private var shouldShowTrainingStatus: Bool {
        self.trainingHasError || (
            !self.trainingStatusMessage.isEmpty &&
                self.trainingStatusMessage != "Type the correct text."
        )
    }

    private var canUseTrainingRecorderButton: Bool {
        guard !self.trainingStopRequestedDuringStart, !self.isTrainingProcessing else { return false }
        return self.isTrainingRecording || self.canRecordTrainingSample
    }

    private var trainingRecorderTitle: String {
        if self.trainingStopRequestedDuringStart {
            return "Stopping..."
        }
        if self.isTrainingProcessing {
            return "Working..."
        }
        if self.isTrainingStarting {
            return "Starting..."
        }
        if self.isTrainingRecording {
            return "Listening..."
        }
        if self.normalizedTrainingReplacement.isEmpty {
            return "Record sample"
        }
        return self.trainingVariants.isEmpty ? "Say it once" : "Say it again"
    }

    private var trainingRecorderDetail: String {
        self.normalizedTrainingReplacement.isEmpty
            ? "Type the correct text first."
            : "Keep trying until FluidVoice understands you 3 times in a row."
    }

    private var trainingRecorderStatusText: String {
        guard !self.lastTrainingOutput.isEmpty else { return "Record to check" }
        if self.trainingAlreadyCorrectWithoutReplacement {
            return "Already correct"
        }
        if self.trainingFinalOutputIsReady {
            return "Ready to add"
        }
        return "\(self.trainingReadinessProgress)/\(CustomDictionaryTrainingMerge.readyCoveredCount) understood"
    }

    private var trainingRecorderStatusColor: Color {
        self.trainingFinalOutputIsReady || self.trainingAlreadyCorrectWithoutReplacement
            ? self.theme.palette.success
            : self.theme.palette.secondaryText
    }

    private var trainingRecorderFillColor: Color {
        self.trainingFinalOutputIsReady || self.trainingAlreadyCorrectWithoutReplacement
            ? self.theme.palette.success
            : self.theme.palette.accent
    }

    private var trainingRecorderFillFraction: Double {
        guard !self.lastTrainingOutput.isEmpty else { return 0 }
        if self.trainingAlreadyCorrectWithoutReplacement {
            return 1
        }
        return Double(self.trainingReadinessProgress) / Double(CustomDictionaryTrainingMerge.readyCoveredCount)
    }

    private var trainingFinalOutputIsReady: Bool {
        !self.trainingAlreadyCorrectWithoutReplacement &&
            self.trainingOutputIsCovered &&
            self.consecutiveCoveredCaptures >= CustomDictionaryTrainingMerge.readyCoveredCount
    }

    private var trainingAlreadyCorrectWithoutReplacement: Bool {
        self.trainingVariants.isEmpty &&
            self.trainingOutputIsCovered &&
            !self.lastTrainingOutput.isEmpty &&
            self.lastTrainingOutput.caseInsensitiveCompare(self.normalizedTrainingReplacement) == .orderedSame &&
            self.consecutiveCoveredCaptures >= CustomDictionaryTrainingMerge.readyCoveredCount
    }

    private var trainingReadinessProgress: Int {
        guard !self.trainingAlreadyCorrectWithoutReplacement else {
            return CustomDictionaryTrainingMerge.readyCoveredCount
        }
        guard self.trainingOutputIsCovered else { return 0 }
        return min(self.consecutiveCoveredCaptures, CustomDictionaryTrainingMerge.readyCoveredCount)
    }

    private var trainingOutputIsCovered: Bool {
        self.lastTrainingOutputIsCovered
    }

    private var trainingFinalOutputText: String {
        guard !self.lastTrainingOutput.isEmpty else { return "Record to check" }
        return self.trainingOutputIsCovered ? self.normalizedTrainingReplacement : self.lastTrainingOutput
    }

    private var canStartTraining: Bool {
        !self.normalizedTrainingReplacement.isEmpty &&
            !self.isTrainingRecording &&
            !self.isTrainingProcessing
    }

    private var canRecordTrainingSample: Bool {
        !self.normalizedTrainingReplacement.isEmpty &&
            !self.isTrainingProcessing &&
            !self.asr.isRunning &&
            self.trainingSampleCount < CustomDictionaryTrainingMerge.maxSamples
    }

    private var canAddTrainedReplacement: Bool {
        !self.normalizedTrainingReplacement.isEmpty &&
            !self.trainingVariants.isEmpty &&
            !self.isTrainingRecording &&
            !self.isTrainingProcessing
    }

    private var trainedReplacementButtonTitle: String {
        self.trainingAlreadyCorrectWithoutReplacement ? "No Replacement Needed" : "Add Replacement"
    }

    private var shouldEmphasizeTrainedReplacementButton: Bool {
        self.trainingFinalOutputIsReady && self.canAddTrainedReplacement
    }

    private var manualTriggers: [String] {
        CustomDictionaryManualEntry.parseTriggers(self.manualTriggersText)
    }

    private var manualDuplicateTriggers: [String] {
        self.manualTriggers.filter { self.allExistingTriggers().contains($0) }
    }

    private var canAddManualReplacement: Bool {
        !self.manualTriggers.isEmpty &&
            !self.manualReplacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            self.manualDuplicateTriggers.isEmpty
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
                self.pageHeader

                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xxl) {
                    self.trainReplacementSection
                    self.yourDictionarySection
                    self.aiPostProcessingSection
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(self.theme.metrics.spacing.xl)
        }
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
                }
            }
        }
        .sheet(isPresented: self.$showAddBoostSheet) {
            AddBoostTermSheet(existingTerms: self.existingBoostTerms()) { newTerm in
                self.boostTerms.append(newTerm)
                self.saveBoostTerms()
            }
        }
        .sheet(item: self.$editingBoostTerm) { editable in
            EditBoostTermSheet(
                term: editable.term,
                existingTerms: self.existingBoostTerms(excludingIndex: editable.index)
            ) { updatedTerm in
                guard self.boostTerms.indices.contains(editable.index) else { return }
                self.boostTerms[editable.index] = updatedTerm
                self.saveBoostTerms()
            }
        }
        .onAppear {
            self.loadBoostTerms()
        }
        .onDisappear {
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

            Text(self.composerMode.detail)
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
                .textFieldStyle(.roundedBorder)
                .disabled(self.isTrainingRecording || self.isTrainingProcessing)
                .onChange(of: self.trainingReplacement) { oldValue, newValue in
                    self.handleTrainingReplacementChange(oldValue: oldValue, newValue: newValue)
                }

            self.trainingRecorderPanel

            self.trainingFinalOutputPanel

            if !self.trainingVariants.isEmpty {
                self.trainingHeardSection
            }

            self.trainingFooter

            Spacer(minLength: 0)

            Button {
                self.addTrainedReplacement()
            } label: {
                Label(self.trainedReplacementButtonTitle, systemImage: self.trainingAlreadyCorrectWithoutReplacement ? "checkmark" : "plus")
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
            }
            .fluidButton(.accent, size: .small)
            .disabled(!self.canAddTrainedReplacement)
            .opacity(self.canAddTrainedReplacement ? 1 : 0.45)
            .overlay(self.trainedReplacementButtonReadyOutline)
            .shadow(
                color: self.shouldEmphasizeTrainedReplacementButton ? self.theme.palette.success.opacity(0.18) : .clear,
                radius: self.shouldEmphasizeTrainedReplacementButton ? 14 : 0,
                x: 0,
                y: 5
            )
            .scaleEffect(self.shouldEmphasizeTrainedReplacementButton ? 1.006 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: self.shouldEmphasizeTrainedReplacementButton)
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
            TextField("fluid voice, fluid boys", text: self.$manualTriggersText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { self.addManualReplacementIfValid() }
            Text("Separate multiple versions with commas.")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        }
    }

    private var manualReplacementField: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            Text("Change it to")
                .font(self.theme.typography.captionStrong)
            TextField("FluidVoice", text: self.$manualReplacement)
                .textFieldStyle(.roundedBorder)
                .onSubmit { self.addManualReplacementIfValid() }
            Text("This is what appears in your transcription.")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        }
    }

    private var trainingRecorderPanel: some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.md) {
            VStack(alignment: .leading, spacing: 6) {
                Text(self.trainingRecorderTitle)
                    .font(self.theme.typography.bodySmallStrong)

                Text(self.trainingRecorderDetail)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .lineLimit(2)

                self.trainingRecorderProgressRow

                HStack(spacing: 7) {
                    Text(self.trainingRecorderStatusText)
                        .font(self.theme.typography.captionStrong)
                        .foregroundStyle(self.trainingRecorderStatusColor)
                        .lineLimit(1)

                    Text("· \(self.trainingProgressText) recorded")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.tertiaryText)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                Task {
                    if self.isTrainingRecording {
                        await self.stopTrainingSample()
                    } else {
                        await self.startTrainingSample()
                    }
                }
            } label: {
                Label(self.isTrainingRecording ? "Stop" : "Record", systemImage: self.isTrainingRecording ? "stop.fill" : "mic.fill")
            }
            .fluidButton(self.isTrainingRecording ? .destructive : .accent, size: .small)
            .disabled(!self.canUseTrainingRecorderButton)
            .opacity(self.canUseTrainingRecorderButton ? 1 : 0.45)
        }
        .padding(self.theme.metrics.spacing.md)
        .background(self.trainingRecorderBackground)
    }

    private var trainingRecorderBackground: some View {
        GeometryReader { proxy in
            let fillWidth = proxy.size.width * min(max(self.trainingRecorderFillFraction, 0), 1)

            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.theme.palette.contentBackground.opacity(0.5))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .fill(self.trainingRecorderFillColor.opacity(0.16))
                        .frame(width: fillWidth)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.trainingRecorderBorderColor, lineWidth: 1)
                )
                .animation(.easeOut(duration: 0.18), value: self.trainingRecorderFillFraction)
        }
        .allowsHitTesting(false)
    }

    private var trainingRecorderBorderColor: Color {
        self.trainingFinalOutputIsReady || self.trainingAlreadyCorrectWithoutReplacement
            ? self.theme.palette.success.opacity(0.28)
            : self.theme.palette.cardBorder.opacity(0.25)
    }

    private var trainingRecorderProgressBar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width * min(max(self.trainingRecorderFillFraction, 0), 1)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(self.theme.palette.cardBorder.opacity(0.35))

                Capsule(style: .continuous)
                    .fill(self.trainingRecorderFillColor)
                    .frame(width: width)
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.18), value: self.trainingRecorderFillFraction)
        .accessibilityHidden(true)
    }

    private var trainingRecorderProgressRow: some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            self.trainingRecorderProgressBar

            Text("\(self.trainingReadinessProgress)/\(CustomDictionaryTrainingMerge.readyCoveredCount)")
                .font(self.theme.typography.captionStrong)
                .foregroundStyle(self.trainingRecorderStatusColor)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
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
        if self.shouldShowTrainingStatus || self.isTrainingActive || !self.trainingVariants.isEmpty {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                if self.trainingHasError {
                    Label(self.trainingStatusMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.warning)
                } else if self.shouldShowTrainingStatus {
                    Text(self.trainingStatusMessage)
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
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
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
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

                    Spacer()

                    Button {
                        withAnimation(self.reduceMotion ? nil : .easeOut(duration: 0.16)) {
                            self.isDictionaryExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: self.isDictionaryExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(self.theme.palette.secondaryText)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
                                    .fill(self.theme.palette.contentBackground.opacity(0.45))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(self.isDictionaryExpanded ? "Collapse dictionary" : "Expand dictionary")
                    .accessibilityLabel(self.isDictionaryExpanded ? "Collapse dictionary" : "Expand dictionary")
                }

                if self.isDictionaryExpanded {
                    if self.entries.isEmpty {
                        self.dictionaryEmptyState(
                            title: "No replacements yet",
                            detail: "Use Train Replacement or Manual Add above to create your first one."
                        )
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        self.entriesListView
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var entriesListView: some View {
        VStack(spacing: self.theme.metrics.spacing.sm) {
            ForEach(self.entries) { entry in
                DictionaryEntryRow(
                    entry: entry,
                    onEdit: { self.editingEntry = entry },
                    onDelete: { self.deleteEntry(entry) }
                )
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Custom Words

    private var aiPostProcessingSection: some View {
        ThemedCard(style: .standard, hoverEffect: false) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
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

                    Spacer()

                    Toggle("Boosting", isOn: self.$vocabBoostingEnabled)
                        .font(self.theme.typography.captionStrong)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .help("Improve recognition of your custom words when using Parakeet.")
                        .onChange(of: self.vocabBoostingEnabled) { _, newValue in
                            SettingsStore.shared.vocabularyBoostingEnabled = newValue
                        }

                    Button {
                        self.isBoostingInfoPresented.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(SquareIconButtonStyle())
                    .help("About Vocabulary Boosting")
                    .popover(isPresented: self.$isBoostingInfoPresented, arrowEdge: .top) {
                        self.boostingInfoPopover
                    }

                    Button {
                        self.showAddBoostSheet = true
                    } label: {
                        Label("Add Word", systemImage: "plus")
                    }
                    .fluidButton(.accent, size: .small)
                }

                if self.boostTerms.isEmpty {
                    self.dictionaryEmptyState(
                        title: "No custom words yet",
                        detail: "Add a name or term that needs a little extra recognition help."
                    ) {
                        self.showAddBoostSheet = true
                    }
                } else {
                    VStack(spacing: self.theme.metrics.spacing.sm) {
                        ForEach(Array(self.boostTerms.enumerated()), id: \.offset) { index, term in
                            BoostTermRow(
                                term: term,
                                onEdit: {
                                    self.editingBoostTerm = EditableBoostTerm(index: index, term: term)
                                },
                                onDelete: {
                                    self.deleteBoostTerm(at: index)
                                }
                            )
                        }
                    }
                }

                if self.boostHasError {
                    Label(self.boostStatusMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.warning)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var boostingInfoPopover: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            HStack(spacing: 8) {
                Image(systemName: "testtube.2")
                    .foregroundStyle(self.theme.palette.accent)
                Text("Vocabulary Boosting · Alpha")
                    .font(self.theme.typography.bodySmallStrong)
            }

            Text("Vocabulary Boosting is an experimental feature that helps Parakeet recognize your custom words.")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)

            Text("It can add close to a second to transcription time.")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)

            Text("If recognition gets worse, the model behaves unexpectedly, or you notice other issues after enabling it, turn Boosting off.")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        }
        .padding(self.theme.metrics.spacing.lg)
        .frame(width: 310, alignment: .leading)
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
        self.manualTriggersText = ""
        self.manualReplacement = ""
    }

    private func beginTrainingReplacement() {
        guard self.canStartTraining else { return }
        self.isTrainingActive = true
        self.trainingHasError = false
        self.trainingStatusMessage = ""
    }

    private func startTrainingSample() async {
        guard self.canRecordTrainingSample else { return }
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
            self.trainingHasError = true
            self.trainingStatusMessage = "Couldn't start recording. Check microphone access and try again."
            return
        }

        if self.trainingStopRequestedDuringStart {
            await self.finishTrainingSampleStop()
        }
    }

    private func stopTrainingSample() async {
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

    private func finishTrainingSampleStop() async {
        guard self.isTrainingRecording else { return }
        self.isTrainingRecording = false
        self.isTrainingStarting = false
        self.trainingStopRequestedDuringStart = false
        self.isTrainingProcessing = true
        self.trainingHasError = false
        self.trainingStatusMessage = ""

        let transcript = await self.asr.stop(forDictionaryTraining: true)
        self.isTrainingProcessing = false
        self.addTrainingVariant(from: transcript)
    }

    private func addTrainingVariant(from transcript: String) {
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

    private func addTrainedReplacement() {
        guard self.canAddTrainedReplacement else { return }
        let replacementText = self.normalizedTrainingReplacement
        let updatesExisting = self.entries.contains {
            $0.replacement.caseInsensitiveCompare(replacementText) == .orderedSame
        }
        self.entries = CustomDictionaryTrainingMerge.mergedEntries(
            current: self.entries,
            replacement: replacementText,
            triggers: self.trainingVariants
        )
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
        self.trainingReplacement = ""
        self.trainingVariants = []
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
        self.saveBoostTerms()
    }

    private func deleteEntry(_ entry: SettingsStore.CustomDictionaryEntry) {
        self.entries.removeAll { $0.id == entry.id }
        self.saveEntries()
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

private struct EditableBoostTerm: Identifiable {
    let id = UUID()
    let index: Int
    let term: ParakeetVocabularyStore.VocabularyConfig.Term
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
            return "Say it a few times so FluidVoice can catch the versions it hears."
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
                    : (self.isHovered ? self.theme.palette.cardBackground.opacity(0.6) : Color.clear)
            )
    }
}

private enum CustomDictionaryManualEntry {
    static func parseTriggers(_ text: String) -> [String] {
        text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
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

// MARK: - Add Boost Term Sheet

struct AddBoostTermSheet: View {
    @Environment(\.dismiss) private var dismiss

    let existingTerms: Set<String>
    let onSave: (ParakeetVocabularyStore.VocabularyConfig.Term) -> Void

    @State private var termText = ""
    @State private var strength: BoostStrengthPreset = .balanced

    private var normalizedTerm: String {
        self.termText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDuplicate: Bool {
        self.existingTerms.contains(self.normalizedTerm.lowercased())
    }

    private var canSave: Bool {
        !self.normalizedTerm.isEmpty && !self.isDuplicate
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Add Custom Word")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Preferred Word or Phrase")
                        .font(.subheadline.weight(.medium))
                    TextField("FluidVoice", text: self.$termText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { self.saveIfValid() }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Word Priority")
                        .font(.subheadline.weight(.medium))
                    Picker("Word Priority", selection: self.$strength) {
                        ForEach(BoostStrengthPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(self.strength.hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if self.isDuplicate {
                    Text("This term already exists.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Button("Cancel") { self.dismiss() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Save") { self.saveIfValid() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!self.canSave)
                        .keyboardShortcut(.return, modifiers: [])
                }
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 460, maxWidth: 520)
        .frame(minHeight: 300, idealHeight: 340, maxHeight: 460)
        .onAppear {
            // Always start new entries at the recommended default.
            self.termText = ""
            self.strength = .balanced
        }
    }

    private func saveIfValid() {
        guard self.canSave else { return }
        self.onSave(
            ParakeetVocabularyStore.VocabularyConfig.Term(
                text: self.normalizedTerm,
                weight: self.strength.weight,
                aliases: []
            )
        )
        self.dismiss()
    }
}

// MARK: - Edit Boost Term Sheet

struct EditBoostTermSheet: View {
    @Environment(\.dismiss) private var dismiss

    let term: ParakeetVocabularyStore.VocabularyConfig.Term
    let existingTerms: Set<String>
    let onSave: (ParakeetVocabularyStore.VocabularyConfig.Term) -> Void

    @State private var termText = ""
    @State private var strength: BoostStrengthPreset = .balanced

    private var normalizedTerm: String {
        self.termText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDuplicate: Bool {
        self.existingTerms.contains(self.normalizedTerm.lowercased())
    }

    private var canSave: Bool {
        !self.normalizedTerm.isEmpty && !self.isDuplicate
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Edit Custom Word")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Preferred Word or Phrase")
                        .font(.subheadline.weight(.medium))
                    TextField("FluidVoice", text: self.$termText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { self.saveIfValid() }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Word Priority")
                        .font(.subheadline.weight(.medium))
                    Picker("Word Priority", selection: self.$strength) {
                        ForEach(BoostStrengthPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(self.strength.hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if self.isDuplicate {
                    Text("This term already exists.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Button("Cancel") { self.dismiss() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Save") { self.saveIfValid() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!self.canSave)
                        .keyboardShortcut(.return, modifiers: [])
                }
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 460, maxWidth: 520)
        .frame(minHeight: 300, idealHeight: 340, maxHeight: 460)
        .onAppear {
            self.termText = self.term.text
            self.strength = BoostStrengthPreset.nearest(for: self.term.weight ?? BoostStrengthPreset.balanced.weight)
        }
    }

    private func saveIfValid() {
        guard self.canSave else { return }
        self.onSave(
            ParakeetVocabularyStore.VocabularyConfig.Term(
                text: self.normalizedTerm,
                weight: self.strength.weight,
                aliases: self.term.aliases
            )
        )
        self.dismiss()
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
                Text("Enter words separated by commas. These are what the transcription might hear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("fluid voice, fluid boys", text: self.$triggersText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { self.saveIfValid() }

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
                    .textFieldStyle(.roundedBorder)
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
    }

    private func parseTriggers() -> [String] {
        self.triggersText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
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
                Text("Enter words separated by commas. These are what the transcription might hear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("fluid voice, fluid boys", text: self.$triggersText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { self.saveIfValid() }

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
                    .textFieldStyle(.roundedBorder)
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
        .onAppear {
            self.triggersText = self.entry.triggers.joined(separator: ", ")
            self.replacement = self.entry.replacement
        }
    }

    private func parseTriggers() -> [String] {
        self.triggersText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
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
