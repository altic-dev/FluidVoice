import SwiftUI

/// The current textbox attempt is primary; saved audio is an optional input below it.
struct DictionaryMatchDiagnosticsView: View {
    let word: String
    let recordingBusy: Bool
    let recording: DictionaryTestRecording?
    let onHistory: (UUID, String, URL) -> Void
    var onRecordMore: (() -> Void)? = nil
    @Environment(\.theme) private var theme
    @State private var profile: PronunciationDictionaryProfile?
    @State private var report: DictionaryMatchReport?
    @State private var threshold = 0.70
    @State private var savedThreshold = 0.70
    @State private var saving = false
    @State private var error: String?
    @State private var running = false
    @State private var historyExpanded = false
    @State private var inspectionExpanded = true
    @State private var history: [TranscriptionHistoryEntry] = []
    @State private var historyID: UUID?

    private var candidate: DictionaryMatchReport.Candidate? {
        self.report?.candidates.first { $0.word.caseInsensitiveCompare(self.word) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            if DictionaryMatcherExperiment.positiveEnabled || DictionaryMatcherExperiment.compareNegatives {
                Text("Experimental comparisons are enabled. Replay scores below show the original matcher; use live dictation to compare results. This cutoff controls fallback matching.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            HStack {
                Text(self.running ? "Checking this recording…" : "Pronunciation match")
                    .font(self.theme.typography.bodyStrong)
                Spacer()
                if self.running { ProgressView().controlSize(.small) }
            }
            if let report = self.report, report.inspection == nil || !self.inspectionExpanded {
                Text("Automatic search · before trimming")
                    .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                    ForEach(report.targetSamples) { sample in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Recording \(sample.sampleNumber ?? 1)")
                                .font(self.theme.typography.caption)
                                .foregroundStyle(self.theme.palette.secondaryText)
                            Text(sample.score.map { String(format: "%.3f", $0) } ?? "—")
                                .monospacedDigit()
                                .font(self.theme.typography.bodyStrong)
                                .foregroundStyle((sample.score ?? -.infinity) >= Float(self.threshold) ? self.theme.palette.accent : self.theme.palette.primaryText)
                        }
                    }
                }
            }
            Text(self.report?.inspection != nil && self.inspectionExpanded ? "Automatic search: \(self.status)" : self.status)
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 6) {
                HStack {
                    Text("Match level")
                    Spacer()
                    Text(String(format: "%.2f", self.threshold)).monospacedDigit()
                }
                .font(self.theme.typography.bodyStrong)
                Slider(value: self.$threshold, in: 0.4...0.95, step: 0.01) { editing in
                    if !editing { self.saveThreshold() }
                }
                .accessibilityLabel("Match level for \(self.word)")
                .disabled(self.profile == nil || self.saving || self.recordingBusy)
                HStack {
                    Text("More forgiving")
                    Spacer()
                    Text("More exact")
                }
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
            }
            Text(self.saving ? "Saving…" : "Applies to “\(self.word)” on your next dictation.")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
            if let error = self.error {
                Text(error).font(self.theme.typography.caption).foregroundStyle(.red)
            }
            if let report = self.report, report.inspection != nil {
                Divider()
                DisclosureGroup("Inspect audio cuts", isExpanded: self.$inspectionExpanded) {
                    if self.inspectionExpanded {
                        DictionaryAudioInspectionView(report: report, recordingBusy: self.recordingBusy, onRecordMore: self.onRecordMore)
                            .id(report.recordingID)
                            .padding(.top, self.theme.metrics.spacing.sm)
                    }
                }
            }
            Divider()
            DisclosureGroup("History", isExpanded: self.$historyExpanded) {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                    Text("Load an older recording into the textbox.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    FluidDropdownPicker(
                        "Recording",
                        selectedTitle: self.history.first(where: { $0.id == self.historyID }).map { "\($0.timestamp.formatted(date: .omitted, time: .shortened)) · \(String(($0.clipboardText ?? $0.rawText).prefix(60)))" } ?? "Choose a recording",
                        selection: self.$historyID
                    ) {
                        Text("Choose a recording").tag(UUID?.none)
                        ForEach(self.history) { entry in
                            Text("\(entry.timestamp.formatted(date: .omitted, time: .shortened)) · \(String((entry.clipboardText ?? entry.rawText).prefix(60)))")
                                .tag(Optional(entry.id))
                        }
                    }
                    .fluidDropdownStyle()
                    .disabled(self.recordingBusy)
                    if self.history.isEmpty {
                        Text("No saved audio yet.").font(self.theme.typography.caption)
                    }
                }
                .padding(.top, self.theme.metrics.spacing.sm)
            }
        }
        .task(id: self.word) {
            self.report = nil
            self.profile = nil
            let profiles = await PronunciationDictionaryStore.shared.allProfiles()
            guard !Task.isCancelled else { return }
            self.profile = profiles.first { $0.label.caseInsensitiveCompare(self.word) == .orderedSame }
            self.threshold = Double(self.profile.flatMap(DictionaryPronunciationDecision.overrideThreshold) ?? 0.70)
            self.savedThreshold = self.threshold
        }
        .task(id: "\(self.word):\(self.recording?.id.uuidString ?? "")") {
            self.report = nil
            self.error = nil
            self.running = false
            guard let recording = self.recording else { return }
            self.running = true
            do {
                let report: DictionaryMatchReport
                if !recording.samples.isEmpty {
                    report = try await DictionaryMatchPlayground.shared.analyze(
                        recordingID: recording.id, samples: recording.samples, savedTranscript: recording.text, target: self.word
                    )
                } else if let url = recording.audioURL {
                    report = try await DictionaryMatchPlayground.shared.analyze(
                        recordingID: recording.id, audioURL: url, savedTranscript: recording.text, target: self.word
                    )
                } else { throw DictionaryMatchPlaygroundError.unavailable("This recording has no audio.") }
                guard !Task.isCancelled else { return }
                self.report = report
                if self.profile?.matchThreshold == nil, let candidate = self.candidate {
                    self.threshold = Double(candidate.requiredScore)
                    self.savedThreshold = self.threshold
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            self.running = false
        }
        .onChange(of: self.historyExpanded) { _, expanded in
            if expanded { self.refreshHistory() }
        }
        .onChange(of: self.recording?.id) { _, _ in
            if self.historyExpanded { self.refreshHistory() }
        }
        .onChange(of: self.historyID) { _, id in
            guard !self.recordingBusy, let entry = self.history.first(where: { $0.id == id }),
                  let url = DictationAudioHistoryStore.shared.audioFileURL(for: entry)
            else { return }
            self.onHistory(entry.id, entry.clipboardText ?? entry.rawText, url)
        }
    }

    private var status: String {
        guard let candidate = self.candidate, let score = candidate.score else {
            return self.recordingBusy ? "Listening to your current test." : "Dictate in the textbox to see how closely it matches “\(self.word)”."
        }
        guard candidate.eligible else { return "Add more recordings for this word to enable matching." }
        if score < Float(self.threshold) { return "No recording clears your match level. Closest is \(String(format: "%.3f", Float(self.threshold) - score)) below." }
        if candidate.heard.isEmpty { return "Similar sound, but no clear word boundary was found." }
        if let competitor = candidate.competingScore, competitor > score - 0.05 { return "Similar, but too close to another saved word." }
        return "At least one recording clears your match level · “\(candidate.heard)”"
    }

    private func refreshHistory() {
        self.history = Array(TranscriptionHistoryStore.shared.entries.lazy.filter { $0.audio != nil }.prefix(50))
    }

    private func saveThreshold() {
        guard let profile = self.profile, !self.saving, self.threshold != self.savedThreshold else { return }
        let value = self.threshold
        self.saving = true
        Task {
            do {
                try await PronunciationDictionaryStore.shared.setMatchThreshold(Float(value), dictionaryEntryID: profile.dictionaryEntryID)
                self.savedThreshold = value
                self.error = nil
            } catch {
                self.threshold = self.savedThreshold
                self.error = "Couldn't save this match level. Try again."
            }
            self.saving = false
        }
    }
}
