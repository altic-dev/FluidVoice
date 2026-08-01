//
//  PracticeView.swift
//  Voix
//
//  Record a practice speech, then show what was said and how it was delivered.
//

import Charts
import SwiftUI

struct PracticeView: View {
    @ObservedObject private var service = PracticeSessionService.shared
    @ObservedObject private var store = PracticeSessionStore.shared
    @ObservedObject private var asr = AppServices.shared.asr
    @Environment(\.theme) private var theme

    @State private var showPastSessions = false
    @State private var copiedLabel: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                self.header
                self.recorderCard

                if let session = service.currentSession {
                    if !session.metrics.quality.isReliable {
                        self.qualityWarningCard(session.metrics.quality)
                    }
                    self.metricsRow(session.metrics)
                    self.contourCard(session.metrics)
                    self.transcriptCard(session)
                    self.feedbackCard(session)
                }

                if !self.store.sessions.isEmpty {
                    self.pastSessionsCard
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 32)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(self.theme.palette.contentBackground)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(self.theme.palette.accent.gradient)

            Text("Practice")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Record a speech, get feedback on what you said and how you said it")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Recorder

    private var recorderCard: some View {
        ThemedCard {
            VStack(spacing: 16) {
                if self.service.isRecording {
                    // Recomputes on its own schedule instead of driving a Timer and
                    // republishing the whole service every tick.
                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        Text(self.elapsedText)
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                } else if let session = service.currentSession {
                    Text(session.formattedDuration)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                self.recordButton

                if let status = service.phase.statusLabel {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(status)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if case let .failed(message) = service.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(self.theme.palette.warning)
                        .multilineTextAlignment(.center)
                }

                if self.service.isRecording, !self.asr.partialTranscription.isEmpty {
                    ScrollView {
                        Text(self.asr.partialTranscription)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 120)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var recordButton: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    if self.service.isRecording {
                        await self.service.stopPractice()
                    } else {
                        await self.service.startPractice()
                    }
                }
            } label: {
                Label(
                    self.service.isRecording ? "Stop" : "Record",
                    systemImage: self.service.isRecording ? "stop.fill" : "record.circle"
                )
                .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(self.service.isRecording ? .red : self.theme.palette.accent)
            .disabled(self.service.phase.isBusy)

            if self.service.currentSession != nil, !self.service.phase.isBusy {
                Button("New session") {
                    self.service.reset()
                }
                .controlSize(.large)
            }
        }
    }

    private var elapsedText: String {
        guard let startedAt = service.recordingStartedAt else { return "0:00" }
        let total = Int(Date().timeIntervalSince(startedAt))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Quality

    /// Shown instead of letting the cards below speak for themselves. The numbers are
    /// still rendered — seeing them is how you learn what a bad recording looks like —
    /// but they are labelled as untrustworthy rather than presented as measurements.
    private func qualityWarningCard(_ quality: DeliveryMetrics.SignalQuality) -> some View {
        ThemedCard(style: .prominent) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Delivery could not be measured reliably", systemImage: "waveform.badge.exclamationmark")
                    .font(.headline)
                    .foregroundStyle(self.theme.palette.warning)

                if let warning = quality.warning {
                    Text(warning.prefix(1).uppercased() + warning.dropFirst() + ".")
                        .font(.callout)
                }

                Text("The numbers below were still computed, but they describe the recording rather than your delivery — treat them as unreliable and record again. The coach was told to skip delivery feedback for this session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(String(format: "Signal-to-noise %.0f dB · speech level %.0f dBFS", quality.signalToNoiseDb, quality.speechLevelDb))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Metrics

    private func metricsRow(_ metrics: DeliveryMetrics) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
            spacing: 12
        ) {
            self.metricCard(
                "Speaking rate",
                value: "\(Int(metrics.wordsPerMinute.rounded()))",
                unit: "WPM",
                detail: Self.paceNote(metrics.wordsPerMinute)
            )
            self.metricCard(
                "Articulation",
                value: "\(Int(metrics.articulationRate.rounded()))",
                unit: "WPM",
                detail: "excluding pauses"
            )
            self.metricCard(
                "Pauses",
                value: "\(metrics.pauseCount)",
                unit: metrics.pauseCount == 1 ? "pause" : "pauses",
                detail: String(format: "longest %.1fs", metrics.longestPauseSeconds)
            )
            self.metricCard(
                "Fillers",
                value: String(format: "%.1f", metrics.fillersPerMinute),
                unit: "per min",
                detail: "\(metrics.totalFillers) total"
            )
            self.metricCard(
                "Pitch variety",
                value: "\(Int(metrics.pitchStdDevHz.rounded()))",
                unit: "Hz sd",
                detail: String(format: "mean %.0f Hz", metrics.meanPitchHz)
            )
            self.metricCard(
                "Volume variety",
                value: String(format: "%.1f", metrics.levelStdDevDb),
                unit: "dB sd",
                detail: String(format: "range %.0f dB", metrics.dynamicRangeDb)
            )
        }
    }

    private func metricCard(_ title: String, value: String, unit: String, detail: String) -> some View {
        ThemedCard(style: .subtle, padding: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Must stay in step with the pace norm in `PracticeSessionService.coachPrompt`.
    /// These drifted once already — the card called 101 WPM "conversational range"
    /// while the coach called the same number slow — and a card disagreeing with the
    /// feedback beside it undermines both.
    private static func paceNote(_ wpm: Double) -> String {
        switch wpm {
        case ..<100: "below the 100–130 range"
        case ...130: "in the 100–130 range"
        default: "above the 100–130 range"
        }
    }

    // MARK: - Contours

    private struct ContourPoint: Identifiable {
        let id = UUID()
        let time: Double
        let value: Double
        /// Index of the contiguous voiced run this point belongs to. Charting each
        /// run as its own series breaks the line across unvoiced gaps instead of
        /// drawing a straight segment through silence that was never spoken.
        let segment: Int
    }

    private func contourCard(_ metrics: DeliveryMetrics) -> some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Delivery over time")
                    .font(.headline)

                if metrics.pitchContour.isEmpty, metrics.energyContour.isEmpty {
                    Text("No contour data for this session.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    self.pitchChart(metrics)
                    self.energyChart(metrics)

                    Label(
                        "Shaded bands are pauses of 0.5s or longer.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pitchChart(_ metrics: DeliveryMetrics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pitch (Hz)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Chart {
                ForEach(self.pauseBands(metrics), id: \.start) { band in
                    RectangleMark(
                        xStart: .value("Start", band.start),
                        xEnd: .value("End", band.end)
                    )
                    .foregroundStyle(self.theme.palette.warning.opacity(0.12))
                }

                ForEach(self.voicedPoints(metrics)) { point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("Pitch", point.value),
                        series: .value("Run", point.segment)
                    )
                    .foregroundStyle(self.theme.palette.accent)
                    .interpolationMethod(.monotone)
                }
            }
            .chartXAxisLabel("seconds", alignment: .trailing)
            .frame(height: 130)
        }
    }

    private func energyChart(_ metrics: DeliveryMetrics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Volume (dBFS)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Chart {
                ForEach(self.energyPoints(metrics)) { point in
                    AreaMark(
                        x: .value("Time", point.time),
                        y: .value("Level", point.value)
                    )
                    .foregroundStyle(self.theme.palette.accent.opacity(0.25))
                }
            }
            .chartXAxisLabel("seconds", alignment: .trailing)
            .frame(height: 90)
        }
    }

    private func voicedPoints(_ metrics: DeliveryMetrics) -> [ContourPoint] {
        let interval = metrics.contourIntervalSeconds
        var points: [ContourPoint] = []
        var segment = 0
        var previousWasVoiced = false

        for (index, hz) in metrics.pitchContour.enumerated() {
            guard hz > 0 else {
                previousWasVoiced = false
                continue
            }
            if !previousWasVoiced { segment += 1 }
            previousWasVoiced = true
            points.append(
                ContourPoint(time: Double(index) * interval, value: hz, segment: segment)
            )
        }
        return points
    }

    private func energyPoints(_ metrics: DeliveryMetrics) -> [ContourPoint] {
        let interval = metrics.contourIntervalSeconds
        // Digital silence lands at -200 dBFS and would flatten the whole plot.
        let floor = -60.0
        return metrics.energyContour.enumerated().map { index, level in
            ContourPoint(time: Double(index) * interval, value: max(level, floor), segment: 0)
        }
    }

    private func pauseBands(_ metrics: DeliveryMetrics) -> [(start: Double, end: Double)] {
        metrics.pauses.map { ($0.startSeconds, $0.startSeconds + $0.durationSeconds) }
    }

    // MARK: - Transcript and feedback

    private func transcriptCard(_ session: PracticeSession) -> some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Transcript")
                        .font(.headline)
                    Spacer()
                    self.copyButton(label: "Transcript", text: session.transcript)
                }

                if session.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Nothing was transcribed for this session.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text(session.transcript)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func feedbackCard(_ session: PracticeSession) -> some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Coaching")
                        .font(.headline)
                    Spacer()
                    if !session.model.isEmpty {
                        Text(session.model)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if !session.feedback.isEmpty {
                        self.copyButton(label: "Feedback", text: session.feedback)
                    }
                }

                if let error = session.coachingError {
                    // The session is still saved; only the coaching leg failed.
                    Label(
                        "Coaching unavailable: \(error)",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(self.theme.palette.warning)

                    Text("The transcript and delivery metrics above were still saved. Configure an AI provider in AI Enhancement to get written feedback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // ponytail: Text's markdown init renders inline styling but not
                    // headings or lists. Good enough for v1; swap for a real markdown
                    // view if the coach's structure starts mattering visually.
                    Text(LocalizedStringKey(session.feedback))
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func copyButton(label: String, text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self.copiedLabel = label
            Task {
                try? await Task.sleep(for: .seconds(2))
                if self.copiedLabel == label { self.copiedLabel = nil }
            }
        } label: {
            Label(
                self.copiedLabel == label ? "Copied" : "Copy",
                systemImage: self.copiedLabel == label ? "checkmark" : "doc.on.doc"
            )
            .font(.caption)
        }
        .buttonStyle(.borderless)
    }

    // MARK: - History

    private var pastSessionsCard: some View {
        ThemedCard {
            DisclosureGroup(isExpanded: self.$showPastSessions) {
                VStack(spacing: 0) {
                    ForEach(self.store.sessions) { session in
                        Divider().opacity(0.4)
                        self.pastSessionRow(session)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Past sessions (\(self.store.sessions.count))")
                    .font(.headline)
            }
        }
    }

    private func pastSessionRow(_ session: PracticeSession) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.previewText.isEmpty ? "(no transcript)" : session.previewText)
                    .font(.callout)
                    .lineLimit(2)

                Text(
                    "\(session.relativeTimeString) · \(session.formattedDuration) · "
                        + "\(Int(session.metrics.wordsPerMinute.rounded())) WPM · "
                        + "\(session.metrics.pauseCount) pauses · "
                        + String(format: "%.1f fillers/min", session.metrics.fillersPerMinute)
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                self.store.delete(id: session.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

#Preview {
    PracticeView()
        .frame(width: 820, height: 700)
        .environment(\.theme, AppTheme.dark)
}
