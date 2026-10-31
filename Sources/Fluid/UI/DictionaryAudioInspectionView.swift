import AVFoundation
import Combine
import SwiftUI

@MainActor
final class DictionaryInspectionPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playing: String?
    @Published private(set) var error: String?
    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func stop() {
        self.generation = UUID()
        self.task?.cancel()
        self.task = nil
        self.player?.stop()
        self.player = nil
        self.playing = nil
    }

    func play(_ audio: DictionaryAudioInspection, cut: DictionaryAudioCut?, id: String) {
        let wasPlaying = self.playing == id
        self.stop()
        guard !wasPlaying else { return }
        let generation = self.generation
        self.error = nil
        self.playing = id
        self.task = Task { [weak self] in
            do {
                let data = try await DictionaryAudioInspector.shared.wav(audio, cut: cut)
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                self.player = player
                guard player.play() else { throw DictionaryMatchPlaygroundError.unavailable("Couldn't play this audio.") }
            } catch {
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                self.stop()
                self.error = error.localizedDescription
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard self?.player === player else { return }
            self?.stop()
        }
    }
}

struct DictionaryAudioInspectionView: View {
    let report: DictionaryMatchReport
    let recordingBusy: Bool
    var loadReference: @Sendable (UUID) async throws -> DictionaryAudioInspection = { try await PronunciationDictionaryStore.shared.inspection(for: $0) }
    var onRecordMore: (() -> Void)? = nil
    @Environment(\.theme) private var theme
    @AppStorage("DictionaryPronunciationDebugCapture") private var retainTrainingAudio = false
    @StateObject private var playback = DictionaryInspectionPlayback()
    @State private var references: [Int: DictionaryAudioInspection] = [:]
    @State private var referenceCuts: [Int: DictionaryAudioCut] = [:]
    @State private var editedReferences: Set<Int> = []
    @State private var testCut = DictionaryAudioCut(start: 0, end: 0.08)
    @State private var adjustedScores: [Float?] = []
    @State private var loadingReferences = false
    @State private var comparing = false
    @State private var loadErrors: Set<Int> = []

    private var enrollments: [PronunciationEnrollmentCapture] {
        self.report.profiles.first { $0.label.caseInsensitiveCompare(self.report.targetWord) == .orderedSame }?.enrollments ?? []
    }

    private var comparisonID: String {
        "\(self.testCut):" + self.editedReferences.sorted().map { "\($0):\(String(describing: self.referenceCuts[$0]))" }.joined(separator: ";")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            Text("This cut compared with every training recording")
                .font(self.theme.typography.bodyStrong)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                ForEach(self.enrollments.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recording \(index + 1)").font(self.theme.typography.caption)
                        Text(self.comparing ? "…" : self.scoreText(index))
                            .font(self.theme.typography.bodyStrong).monospacedDigit()
                            .foregroundStyle(self.theme.palette.accent)
                    }
                }
            }
            if let audio = self.report.inspection {
                DictionaryAudioCutView(
                    title: "Your test recording",
                    audio: audio,
                    cut: self.$testCut,
                    initialCut: self.initialTestCut,
                    playback: self.playback,
                    playbackID: "test"
                )
            }
            Divider()
            Text("Your training recordings").font(self.theme.typography.bodyStrong)
            if let onRecordMore = self.onRecordMore {
                Button("Record new examples") {
                    self.playback.stop()
                    onRecordMore()
                }.fluidGlassAction()
            }
            Text("Play each original or the exact section used for its saved embedding.")
                .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(self.enrollments.indices, id: \.self) { index in
                self.referenceRow(index)
                if index < self.enrollments.count - 1 { Divider() }
            }
            Text("A higher similarity score does not mean a cleaner recording. Extra context can raise it. Listen to the cuts before changing how matching works.")
                .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("These cuts update all scores above, without changing saved examples or your match level. Scores reuse existing encoder frames in 80 ms steps.")
                .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if !self.comparing, !self.adjustedScores.isEmpty, self.adjustedScores.allSatisfy({ $0 == nil }) {
                Text("Choose a non-empty cut within one encoder chunk (up to 14.88 seconds).")
                    .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
            }
            HStack {
                Text("Keep audio with new training examples").font(self.theme.typography.bodySmall)
                Spacer(minLength: self.theme.metrics.spacing.md)
                Toggle("Keep audio with new training examples", isOn: self.$retainTrainingAudio)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Text("Stored locally with up to 10 examples per word, up to 15 seconds each. Turning this off affects future examples.")
                .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let error = self.playback.error {
                Text(error).font(self.theme.typography.caption).foregroundStyle(.red)
            }
        }
        .disabled(self.recordingBusy)
        .task(id: self.report.recordingID) {
            self.testCut = self.initialTestCut
            self.loadingReferences = true
            for index in self.enrollments.indices {
                guard !Task.isCancelled else { return }
                guard let id = self.enrollments[index].inspectionID else { continue }
                do {
                    let audio = try await self.loadReference(id)
                    guard !Task.isCancelled else { return }
                    self.references[index] = audio
                    self.referenceCuts[index] = .init(start: audio.selectedStart, end: min(audio.duration, audio.selectedEnd))
                } catch {
                    guard !Task.isCancelled else { return }
                    self.loadErrors.insert(index)
                }
            }
            self.loadingReferences = false
        }
        .task(id: self.comparisonID) {
            self.playback.stop()
            self.adjustedScores = []
            self.comparing = true
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard let test = self.report.inspection else { self.comparing = false; return }
            let scores = await DictionaryAudioInspector.shared.scores(
                test: test,
                testCut: self.testCut,
                references: self.enrollments.indices.map { self.references[$0] },
                referenceCuts: self.enrollments.indices.map { self.editedReferences.contains($0) ? self.referenceCuts[$0] : nil },
                storedVectors: self.enrollments.map(\.values)
            )
            guard !Task.isCancelled else { return }
            self.adjustedScores = scores
            self.comparing = false
        }
        .onChange(of: self.recordingBusy) { _, busy in if busy { self.playback.stop() } }
        .onDisappear { self.playback.stop() }
    }

    private func scoreText(_ index: Int) -> String {
        guard self.adjustedScores.indices.contains(index), let score = self.adjustedScores[index] else { return "—" }
        return String(format: "%.3f", score)
    }

    private func referenceRow(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            HStack {
                Text("Recording \(index + 1)").font(self.theme.typography.bodyStrong)
                Spacer()
                Text(self.comparing ? "…" : self.scoreText(index)).monospacedDigit()
                    .font(self.theme.typography.bodyStrong).foregroundStyle(self.theme.palette.accent)
            }
            if let audio = self.references[index] {
                Text(String(format: "Full %.2f s · trained section %.2f–%.2f s", audio.duration, audio.selectedStart, audio.selectedEnd))
                    .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                FluidGlassControlGroup {
                    HStack(spacing: self.theme.metrics.spacing.sm) {
                        Button(self.playback.playing == "original-\(index)" ? "Stop" : "Play original") {
                            self.playback.play(audio, cut: nil, id: "original-\(index)")
                        }.fluidGlassAction()
                        Button(self.playback.playing == "trained-\(index)" ? "Stop" : self.editedReferences.contains(index) ? "Play edited cut" : "Play trained cut") {
                            let cut = self.editedReferences.contains(index) ? self.referenceCuts[index] : DictionaryAudioCut(start: audio.selectedStart, end: audio.selectedEnd)
                            self.playback.play(audio, cut: cut, id: "trained-\(index)")
                        }.fluidGlassAction()
                    }
                }
                DisclosureGroup("Inspect this training cut") {
                    DictionaryAudioCutView(
                        title: "Training recording \(index + 1)",
                        audio: audio,
                        cut: Binding(
                            get: { self.referenceCuts[index] ?? .init(start: audio.selectedStart, end: min(audio.duration, audio.selectedEnd)) },
                            set: {
                                self.referenceCuts[index] = $0
                                if $0 == DictionaryAudioCut(start: audio.selectedStart, end: min(audio.duration, audio.selectedEnd)) {
                                    self.editedReferences.remove(index)
                                } else { self.editedReferences.insert(index) }
                            }
                        ),
                        initialCut: .init(start: audio.selectedStart, end: min(audio.duration, audio.selectedEnd)),
                        playback: self.playback,
                        playbackID: "reference-\(index)"
                    )
                    .padding(.top, self.theme.metrics.spacing.sm)
                }
                .disclosureGroupStyle(FluidDisclosureGroupStyle())
            } else {
                Text(self.loadingReferences && self.enrollments[index].inspectionID != nil ? "Loading audio…" : self.loadErrors.contains(index)
                    ? "Saved audio couldn't be loaded. Its stored embedding is still compared."
                    : "Audio wasn't saved for this older example. Record a new example to hear it; its stored embedding is still compared.")
                    .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var initialTestCut: DictionaryAudioCut {
        let duration = self.report.inspection?.duration ?? self.report.duration
        let sample = self.report.targetSamples.max { ($0.score ?? -.infinity) < ($1.score ?? -.infinity) }
        return .init(start: min(max(0, duration - 0.08), sample?.start ?? 0), end: min(duration, sample?.end ?? duration))
    }
}

private struct DictionaryAudioCutView: View {
    let title: String
    let audio: DictionaryAudioInspection
    @Binding var cut: DictionaryAudioCut
    let initialCut: DictionaryAudioCut
    @ObservedObject var playback: DictionaryInspectionPlayback
    let playbackID: String
    @Environment(\.theme) private var theme
    @State private var peaks: [Float] = []
    @State private var metrics: DictionaryAudioCutMetrics?

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            HStack {
                Text(self.title).font(self.theme.typography.bodyStrong)
                Spacer()
                Text(String(format: "%.2f s", self.audio.duration)).font(self.theme.typography.caption).monospacedDigit()
            }
            Canvas { context, size in
                let duration = max(0.08, self.audio.duration)
                let lower = min(1, max(0, self.cut.start / duration)) * size.width
                let upper = min(1, max(0, self.cut.end / duration)) * size.width
                context.fill(Path(CGRect(x: lower, y: 0, width: max(0, upper - lower), height: size.height)), with: .color(self.theme.palette.accent.opacity(0.15)))
                let peak = max(0.01, self.peaks.max() ?? 0.01)
                for (index, value) in self.peaks.enumerated() {
                    let x = CGFloat(index) / CGFloat(max(1, self.peaks.count)) * size.width
                    let height = max(1, CGFloat(value / peak) * (size.height - 8))
                    context.fill(Path(CGRect(x: x, y: (size.height - height) / 2, width: max(1, size.width / 256 - 1), height: height)), with: .color(self.theme.palette.accent))
                }
            }
            .frame(height: 64)
            .accessibilityLabel("Waveform, selected \(String(format: "%.2f", self.cut.start)) to \(String(format: "%.2f", self.cut.end)) seconds")
            self.boundarySlider("Start", value: Binding(get: { self.cut.start }, set: { self.cut.start = min($0, max(0, self.cut.end - 0.08)) }))
            self.boundarySlider("End", value: Binding(get: { self.cut.end }, set: { self.cut.end = max($0, self.cut.start + 0.08) }))
            FluidGlassControlGroup {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    Button(self.playback.playing == self.playbackID + "full" ? "Stop" : "Play full") {
                        self.playback.play(self.audio, cut: nil, id: self.playbackID + "full")
                    }.fluidGlassAction()
                    Button(self.playback.playing == self.playbackID + "cut" ? "Stop" : "Play cut") {
                        self.playback.play(self.audio, cut: self.cut, id: self.playbackID + "cut")
                    }.fluidGlassAction()
                    Button("Reset") { self.cut = self.initialCut }.fluidGlassAction()
                }
            }
            if let metrics = self.metrics {
                Text(String(format: "Quiet in cut: %.2f s at start · %.2f s at end", metrics.leadingQuiet, metrics.trailingQuiet))
                    .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText).fixedSize(horizontal: false, vertical: true)
                Button("Try quiet-edge trim") {
                    if let suggested = metrics.suggested { self.cut = suggested }
                }
                .fluidGlassAction()
                .disabled(metrics.suggested == nil || metrics.suggested == self.cut)
            }
            Text("Quiet means below −45 dBFS; faint speech can also be quiet. No noise removal is applied.")
                .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText).fixedSize(horizontal: false, vertical: true)
            if self.audio.paddedDuration > self.audio.duration + 0.001 {
                Text(String(format: "Model input added %.2f s of trailing padding. Playback uses captured audio only.", self.audio.paddedDuration - self.audio.duration))
                    .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            let heard = self.audio.words.filter { $0.start < self.cut.end && $0.end > self.cut.start }.map(\.text).joined(separator: " ")
            Text("Recognizer heard: \(heard.isEmpty ? "No timestamped words" : heard)")
                .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
        .task {
            let values = await DictionaryAudioInspector.shared.waveform(self.audio)
            guard !Task.isCancelled else { return }
            self.peaks = values
        }
        .task(id: "\(self.cut)") {
            self.metrics = nil
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            let metrics = await DictionaryAudioInspector.shared.metrics(self.audio, cut: self.cut)
            guard !Task.isCancelled else { return }
            self.metrics = metrics
        }
    }

    private func boundarySlider(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            Text(title).frame(width: 34, alignment: .leading)
            Slider(value: value, in: 0...max(0.08, self.audio.duration), step: 0.08)
                .accessibilityLabel("\(self.title) \(title.lowercased())")
            Text(String(format: "%.2f s", value.wrappedValue)).monospacedDigit().frame(width: 56, alignment: .trailing)
        }
        .font(self.theme.typography.caption)
    }
}
