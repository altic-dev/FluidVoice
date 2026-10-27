import Combine
import SwiftUI

enum DictionaryWordWizardStep: Equatable {
    case spelling, recording, review, saved, manual

    var position: Int {
        switch self {
        case .spelling: 1
        case .recording, .manual: 2
        case .review, .saved: 3
        }
    }
}

/// One task at a time. Recording and persistence remain with the existing dictionary services.
struct DictionaryWordWizard: View {
    @Binding var word: String
    let step: DictionaryWordWizardStep
    let count: Int
    let heard: String
    let variants: [String]
    let busy: Bool
    let recording: Bool
    let processing: Bool
    let starting: Bool
    let error: String?
    let voiceSupported: Bool
    let alreadyCorrect: Bool
    let savedWord: String
    let onContinue: () -> Void
    let onRecord: () -> Void
    let onSave: () -> Void
    let onBack: () -> Void
    let onNewWord: () -> Void
    let onManual: () -> Void
    let onPracticeMore: () -> Void
    var onRedo: () -> Void = {}
    var wordFocusRequest = 0
    var automaticCaptureActive = false
    var waiting = false
    var canSave = true
    var onPauseRecording: (() -> Void)?
    var onAddSpelling: ((String) -> String?)?
    var onRemoveSpelling: ((String) -> Void)?
    var audioLevels: AnyPublisher<CGFloat, Never> = Empty().eraseToAnyPublisher()
    var pronunciationNotice: String?
    var pronunciationIncomplete = false
    /// What each try transcribed, oldest first.
    var attempts: [String] = []

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var wordFocused: Bool
    @State private var showingRecordingTips = false
    @State private var hasViewedTips = false
    @State private var showingAddSpelling = false
    @State private var newSpelling = ""
    @State private var spellingError: String?
    @State private var playgroundBusy = false
    @State private var confirmingRedo = false
    @State private var confirmingWordChange = false
    @State private var pendingWord = ""

    var body: some View {
        VStack(spacing: self.theme.metrics.spacing.lg) {
            HStack {
                if self.step == .recording, self.captureActive, let onPauseRecording {
                    Button("Pause learning", action: onPauseRecording)
                        .fluidGlassAction(quiet: true)
                        .keyboardShortcut(.cancelAction)
                        .disabled(self.processing || self.starting)
                        .help("Pause automatic recording to review or edit spellings (Esc)")
                } else if self.step != .spelling, self.step != .saved {
                    Button(action: self.onBack) { Label("Change word", systemImage: "chevron.left") }
                        .fluidGlassAction()
                        .disabled(self.busy)
                }
                Spacer()
                if self.step == .recording || self.step == .review {
                    self.guidanceButton
                }
            }
            .frame(minHeight: 32)
            .overlay {
                Text(self.step == .saved ? "Word saved" : "Step \(self.step.position) of 3")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .allowsHitTesting(false)
            }
            FluidGlassControlGroup {
                VStack(spacing: self.theme.metrics.spacing.lg) {
                    switch self.step {
                    case .spelling: self.spelling
                    case .recording, .review: self.capture
                    case .saved: self.saved
                    case .manual: EmptyView()
                    }
                }
                .frame(maxWidth: self.step == .recording || self.step == .review ? .infinity : 420)
                .frame(maxWidth: .infinity)
                .padding(.vertical, self.theme.metrics.spacing.sm)
            }
        }
        .alert("Discard these recordings and try again?", isPresented: self.$confirmingRedo) {
            Button("Cancel", role: .cancel) {}
            Button("Redo recordings", role: .destructive, action: self.onRedo)
        } message: {
            Text("Your word stays the same. Previously saved dictionary entries are unchanged.")
        }
        .alert("Change the word and discard these recordings?", isPresented: self.$confirmingWordChange) {
            Button("Cancel", role: .cancel) {}
            Button("Change word", role: .destructive) { self.word = self.pendingWord }
        }
        .task(id: self.step) { self.wordFocused = self.step == .spelling }
        .task(id: self.wordFocusRequest) {
            guard self.wordFocusRequest != 0 else { return }
            self.wordFocused = false
            await Task.yield()
            guard !Task.isCancelled else { return }
            self.wordFocused = self.step == .spelling
        }
    }

    private var spelling: some View {
        VStack(spacing: self.theme.metrics.spacing.lg) {
            DictionaryVoiceWave(active: false, height: 96)
            Text("Which word does FluidVoice keep getting wrong?")
                .font(self.theme.typography.sectionTitle)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            TextField("For example, FluidVoice", text: Binding(get: { self.word }, set: { value in
                if self.count >= 1, value != self.word {
                    self.pendingWord = value
                    self.confirmingWordChange = true
                } else { self.word = value }
            }))
            .textFieldStyle(.plain)
            .padding(14)
            .background(self.theme.palette.contentBackground, in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.md))
            .overlay {
                RoundedRectangle(cornerRadius: self.theme.metrics.corners.md)
                    .stroke(self.wordFocused ? self.theme.palette.accent.opacity(0.7) : self.theme.palette.cardBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .font(self.theme.typography.body)
            .focused(self.$wordFocused)
            .dictionaryDictationInput(focused: self.wordFocused)
            .accessibilityLabel("Word to learn")
            .onSubmit { if !self.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.onContinue() } }
            self.primary("Continue", action: self.onContinue)
                .disabled(self.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var capture: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            HStack(alignment: .top, spacing: self.theme.metrics.spacing.lg) {
                self.captureStage.frame(minWidth: 264, maxWidth: .infinity)
                if self.showingRecordingTips {
                    self.guidanceCard
                        .frame(width: 240, alignment: .leading)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            self.captureError
            if self.count >= 1 || !self.capturedSpellings.isEmpty {
                self.capturedVariations
            }
            if self.step != .review {
                self.manualAlternative
            }
        }
    }

    private var manualAlternative: some View {
        HStack(spacing: self.theme.metrics.spacing.md) {
            Text("Prefer typing?")
                .font(self.theme.typography.body)
                .foregroundStyle(self.theme.palette.secondaryText)
            self.manualButton.disabled(self.busy)
        }
        .frame(maxWidth: .infinity)
    }

    private var captureStage: some View {
        VStack(spacing: self.theme.metrics.spacing.lg) {
            Text(self.step == .review ? (self.pronunciationIncomplete ? "Your spellings are ready" : "Your word is ready") : (self.voiceSupported ? "Learn your pronunciation" : "Learn the spelling of"))
                .font(self.theme.typography.body)
                .foregroundStyle(self.theme.palette.accent)
            Text("“\(self.word)”")
                .font(self.theme.typography.title)
                .fixedSize(horizontal: false, vertical: true)
            DictionaryVoiceWave(
                active: self.isListening,
                height: self.step == .review ? 100 : 150,
                audioLevels: self.audioLevels
            )
            DictionaryCaptureSlots(word: self.word, attempts: self.attempts, pendingStatus: self.pendingSlotStatus)
            self.captureControls
                .padding(.top, self.theme.metrics.spacing.sm)
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, self.theme.metrics.spacing.lg)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    /// Shown in the next empty slot while a try is in progress.
    private var pendingSlotStatus: String? {
        guard self.step == .recording else { return nil }
        if self.isListening { return "Listening…" }
        if self.processing && !self.starting { return "Checking…" }
        if self.starting || self.waiting { return "Getting ready…" }
        return nil
    }

    private var isListening: Bool {
        self.step == .recording && self.recording && !self.starting && !self.processing && !self.waiting
    }

    private var captureInstruction: String {
        if self.waiting { return "Get ready to say it again" }
        if self.starting { return "Wait for recording to start" }
        if self.processing { return "Checking what we heard" }
        if self.isListening { return "Say “\(self.word)” now" }
        return "Say only the word, then pause."
    }

    private var guidanceButton: some View {
        Button {
            withAnimation(self.reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                self.showingRecordingTips.toggle()
                self.hasViewedTips = true
            }
        } label: {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Image(systemName: "lightbulb")
                Text("Tips")
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(self.showingRecordingTips ? 180 : 0))
                    .accessibilityHidden(true)
            }
        }
        .fluidGlassAction(prominent: !self.hasViewedTips || self.showingRecordingTips, tone: self.theme.palette.accent)
        .accessibilityValue(self.showingRecordingTips ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows or hides guidance beside the learning area")
    }

    private var guidanceCard: some View {
        self.captureGuidance
            .padding(self.theme.metrics.spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(self.theme.palette.contentBackground, in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg))
            .overlay {
                RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg)
                    .stroke(self.theme.palette.cardBorder.opacity(0.6), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }

    private var captureGuidance: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xxl) {
            Text(self.step == .review ? "Your word, your way" : "For best results")
                .font(self.theme.typography.title)
            if self.step == .review {
                Text(self.alreadyCorrect ? "FluidVoice recognised your word in each recording." : "Your recordings are ready. Save this word to use it in future dictations.")
                    .font(self.theme.typography.statement)
                    .foregroundStyle(self.theme.palette.secondaryText)
                Divider()
                Text("Want to add another example?")
                    .font(self.theme.typography.sectionTitle)
                Text("You can record more before saving. Keep saying the word in your normal voice.")
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.secondaryText)
            } else {
                self.instruction(1, title: "Say only the word", detail: "Use your normal voice. No sentence needed.")
                self.instruction(2, title: "Wait when you finish", detail: "Recording stops automatically.")
                self.instruction(3, title: "Wait for the next recording", detail: "Speak again when “Recording” appears.")
                Divider()
                Label("Choose a quiet place and keep a comfortable distance from your microphone.", systemImage: "ear")
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, self.theme.metrics.spacing.lg)
        .accessibilityElement(children: .contain)
    }

    private func instruction(_ number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) {
            Text("\(number)")
                .font(self.theme.typography.bodyStrong)
                .foregroundStyle(self.theme.palette.accent)
                .frame(width: 28, height: 28)
                .background(self.theme.palette.accent.opacity(0.1), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                Text(title).font(self.theme.typography.sectionTitle)
                Text(detail).font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
        }
    }

    @ViewBuilder private var captureError: some View {
        if let error {
            Text(error)
                .font(self.theme.typography.body)
                .foregroundStyle(self.theme.palette.warning)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .accessibilityLabel("Recording issue: \(error)")
        }
    }

    private var captureControls: some View {
        VStack(spacing: self.theme.metrics.spacing.lg) {
            if self.step == .review {
                if self.pronunciationIncomplete, let pronunciationNotice {
                    Text(pronunciationNotice)
                        .font(self.theme.typography.body)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                self.reviewActions
            } else {
                ZStack {
                    Text("Say only the word, then pause.").hidden().accessibilityHidden(true)
                    Text(self.captureInstruction)
                }
                .font(self.theme.typography.title)
                .foregroundStyle(self.theme.palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                Text("Recording stops automatically.")
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.secondaryText)
                self.captureRecordActions
            }
        }
    }

    private var captureRecordActions: some View {
        VStack(spacing: self.theme.metrics.spacing.md) {
            Group {
                if self.captureActive {
                    Color.clear
                } else {
                    Button {
                        guard !self.busy, !self.captureActive else { return }
                        self.onRecord()
                    } label: {
                        Label(DictionaryCaptureAction.title(failed: self.error != nil, count: self.count), systemImage: "mic.fill")
                    }
                    .buttonStyle(FluidRecordInvitationStyle(inviting: self.count < 1, recording: false))
                    .disabled(self.busy)
                }
            }
            .frame(minHeight: FluidButtonSize.large.controlHeight)
            self.redoButton
                .hidden()
                .accessibilityHidden(true)
                .overlay {
                    if self.count >= 1, !self.captureActive {
                        self.redoButton
                    }
                }
        }
    }

    private var captureActive: Bool {
        self.automaticCaptureActive || self.recording || self.processing || self.starting || self.waiting
    }

    private var redoButton: some View {
        Button("Redo recordings") { self.confirmingRedo = true }
            .fluidGlassAction()
            .disabled(self.busy)
    }

    private var manualButton: some View {
        Button(action: self.onManual) {
            Label("Add manually", systemImage: "keyboard")
        }
        .fluidGlassAction()
    }

    private var reviewActions: some View {
        DictionaryReviewActionLayout(spacing: self.theme.metrics.spacing.lg) {
            self.reviewButtons
        }
    }

    @ViewBuilder private var reviewButtons: some View {
        Button("Redo recordings") { self.confirmingRedo = true }
            .buttonStyle(FluidRecordInvitationStyle(inviting: false, recording: false, prominent: false, fillsWidth: true))
            .disabled(self.busy)
        Button(action: self.onSave) {
            ZStack {
                Text(self.pronunciationIncomplete ? "Save spelling corrections" : "Add to dictionary").hidden().accessibilityHidden(true)
                Text(self.busy ? "Saving…" : (self.pronunciationIncomplete ? "Save spelling corrections" : "Add to dictionary"))
            }
        }
        .buttonStyle(FluidRecordInvitationStyle(inviting: self.step == .review && !self.busy, recording: false, fillsWidth: true))
        .disabled(self.busy || !self.canSave)
        if self.count < CustomDictionaryTrainingMerge.maxSamples {
            VStack(spacing: self.theme.metrics.spacing.sm) {
                Button("Record more", action: self.onRecord)
                    .buttonStyle(FluidRecordInvitationStyle(inviting: false, recording: false, prominent: false, fillsWidth: true))
                    .disabled(self.busy)
                if self.pronunciationIncomplete {
                    Text("Finish pronunciation learning")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .frame(maxWidth: 190)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var saved: some View {
        VStack(spacing: self.theme.metrics.spacing.lg) {
            DictionaryWordPlayground(word: self.savedWord, onPracticeMore: self.onPracticeMore, busy: self.$playgroundBusy)
            Button("Add another word", action: self.onNewWord)
                .fluidGlassAction()
                .disabled(self.playgroundBusy)
        }
    }

    private var capturedSpellings: [String] {
        var seen = Set<String>()
        return self.variants.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0.lowercased()).inserted
        }
    }

    private var capturedVariations: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            HStack {
                Text("Spelling corrections")
                    .font(self.theme.typography.bodyStrong)
                Spacer()
                if self.onAddSpelling != nil {
                    Button {
                        self.newSpelling = ""
                        self.spellingError = nil
                        self.showingAddSpelling = true
                    } label: {
                        Label("Add spelling", systemImage: "plus")
                    }
                    .fluidGlassAction(quiet: true)
                    .disabled(self.busy || self.captureActive || self.capturedSpellings.count >= CustomDictionaryTrainingMerge.maxSamples)
                    .help("Pause learning to edit spelling corrections")
                    .popover(isPresented: self.$showingAddSpelling) { self.addSpellingPopover }
                }
            }
            if self.capturedSpellings.isEmpty {
                Text(self.heard.caseInsensitiveCompare(self.word) == .orderedSame ? "“\(self.word)” was recognised correctly." : "No spelling corrections yet.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(self.capturedSpellings, id: \.self) { variant in
                        HStack(spacing: 4) {
                            Text(variant).font(self.theme.typography.bodySmall)
                            if let onRemoveSpelling {
                                Button { onRemoveSpelling(variant) } label: {
                                    Image(systemName: "xmark").font(self.theme.typography.caption)
                                }
                                .fluidGlassAction(circular: true, quiet: true)
                                .disabled(self.busy || self.captureActive)
                                .accessibilityLabel("Remove spelling \(variant)")
                                .help("Remove this spelling correction; keep the voice examples")
                            }
                        }
                        .padding(.leading, 10)
                        .padding(.trailing, self.onRemoveSpelling == nil ? 10 : 0)
                        .padding(.vertical, self.onRemoveSpelling == nil ? 6 : 0)
                        .background(self.theme.palette.accent.opacity(0.08), in: Capsule())
                    }
                }
            }
        }
        .padding(self.theme.metrics.spacing.md)
        .onChange(of: self.captureActive || self.busy) { _, active in
            if active { self.showingAddSpelling = false }
        }
    }

    private var addSpellingPopover: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            Text("Add a spelling correction").font(self.theme.typography.sectionTitle)
            TextField("What FluidVoice types instead", text: self.$newSpelling)
                .textFieldStyle(.roundedBorder)
                .onSubmit { self.addSpelling() }
            if let spellingError {
                Text(spellingError)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.warning)
            }
            HStack {
                Button("Cancel") { self.showingAddSpelling = false }.fluidGlassAction()
                Spacer()
                Button("Add") { self.addSpelling() }
                    .fluidGlassAction(prominent: true)
                    .disabled(self.newSpelling.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.busy || self.captureActive)
            }
        }
        .padding(self.theme.metrics.spacing.lg)
        .frame(width: 320)
    }

    private func addSpelling() {
        guard !self.busy, !self.captureActive, let onAddSpelling else { return }
        if let error = onAddSpelling(self.newSpelling) {
            self.spellingError = error
        } else {
            self.showingAddSpelling = false
        }
    }

    private func heading(_ title: String, detail: String) -> some View {
        VStack(spacing: self.theme.metrics.spacing.sm) {
            Text(title).font(self.theme.typography.sectionTitle)
            Text(detail).font(self.theme.typography.bodySmall).foregroundStyle(self.theme.palette.secondaryText)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
        }
        .fluidGlassAction(prominent: true, tone: self.theme.palette.accent)
    }
}

/// Equal columns keep Add to dictionary on the ring's centre line despite unequal button labels.
/// Stack the same controls when their natural widths cannot fit without clipping.
private struct DictionaryReviewActionLayout: Layout {
    let spacing: CGFloat

    private func measurements(_ subviews: Subviews) -> (width: CGFloat, height: CGFloat) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return (sizes.map(\.width).max() ?? 0, sizes.map(\.height).max() ?? 0)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let cell = self.measurements(subviews)
        let rowWidth = cell.width * CGFloat(subviews.count) + self.spacing * CGFloat(max(0, subviews.count - 1))
        if rowWidth <= proposal.width ?? .infinity {
            return CGSize(width: rowWidth, height: cell.height)
        }
        let height = subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(.unspecified).height }
            + self.spacing * CGFloat(max(0, subviews.count - 1))
        return CGSize(width: cell.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cell = self.measurements(subviews)
        let rowWidth = cell.width * CGFloat(subviews.count) + self.spacing * CGFloat(max(0, subviews.count - 1))
        let horizontal = rowWidth <= proposal.width ?? .infinity
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            let x = horizontal
                ? bounds.midX - rowWidth / 2 + cell.width / 2 + CGFloat(index) * (cell.width + self.spacing)
                : bounds.midX
            subview.place(at: CGPoint(x: x, y: y), anchor: .top, proposal: ProposedViewSize(width: cell.width, height: nil))
            if !horizontal { y += subview.sizeThatFits(.unspecified).height + self.spacing }
        }
    }
}

/// A glowing ribbon drawn by a Metal shader. It drifts slowly at rest and swells with the voice.
/// Reduce Motion freezes it; Reduce Transparency swaps the glow for a plain line.
private struct DictionaryVoiceWave: View {
    let active: Bool
    var height: CGFloat = 140
    var audioLevels: AnyPublisher<CGFloat, Never> = Empty().eraseToAnyPublisher()
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var voiceEnergy = 0.0
    @State private var motion = DictionaryWaveMotion()

    private var animates: Bool {
        self.active && self.isVisible && self.scenePhase == .active && !self.reduceMotion
    }

    private var respondsToAudio: Bool {
        self.active && self.animates
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !self.animates)) { timeline in
            let frame = self.motion.advance(
                to: timeline.date,
                targetEnergy: self.respondsToAudio ? self.voiceEnergy : 0,
                speed: self.active ? 1.1 : 0.45,
                animating: self.animates
            )
            if self.reduceTransparency {
                DictionaryWaveShape(phase: frame.phase, amplitude: 0.45 + CGFloat(frame.energy) * 0.4, frequency: 1)
                    .stroke(self.theme.palette.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            } else {
                Rectangle()
                    .fill(.white)
                    .visualEffect { content, proxy in
                        content.colorEffect(ShaderLibrary.dictionaryVoiceWave(
                            .float2(proxy.size),
                            .float(Float(frame.phase)),
                            .float(Float(frame.energy)),
                            .float(self.colorScheme == .dark ? 1 : 0)
                        ))
                    }
            }
        }
        .frame(maxWidth: 620)
        .frame(height: self.height)
        .opacity(self.active ? 1 : 0.85)
        .animation(self.reduceMotion ? nil : .smooth(duration: 0.3), value: self.active)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .onAppear { self.isVisible = true }
        .onDisappear { self.isVisible = false; self.voiceEnergy = 0 }
        .onChange(of: self.active) { _, active in
            if !active { self.voiceEnergy = 0 }
        }
        .onChange(of: self.scenePhase) { _, phase in
            if phase != .active { self.voiceEnergy = 0 }
        }
        .onChange(of: self.reduceMotion) { _, reduced in
            if reduced { self.voiceEnergy = 0 }
        }
        .onReceive(self.audioLevels.throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)) { level in
            guard self.respondsToAudio else { return }
            self.voiceEnergy = DictionaryGlowResponse.energy(for: level)
        }
    }
}

/// Per-frame phase and eased energy, so speed changes and level jumps never make the ribbon jump.
private final class DictionaryWaveMotion {
    private var lastDate: Date?
    private var phase = 0.0
    private var energy = 0.0
    private static let noiseGate = 0.35

    func advance(to date: Date, targetEnergy: Double, speed: Double, animating: Bool) -> (phase: Double, energy: Double) {
        let elapsed = self.lastDate.map { min(max(date.timeIntervalSince($0), 0), 0.1) } ?? 0
        self.lastDate = animating ? date : nil
        guard animating else {
            self.energy = 0
            return (self.phase, 0)
        }
        self.phase = (self.phase + elapsed * speed).truncatingRemainder(dividingBy: 2 * .pi * 100)
        // Room noise stays below the gate; speech eases in and out slowly so the glow never flickers.
        let gated = max(0, (targetEnergy - Self.noiseGate) / (1 - Self.noiseGate))
        let rate = gated > self.energy ? 3.0 : 1.2
        self.energy += (gated - self.energy) * min(1, elapsed * rate)
        return (self.phase, self.energy)
    }
}

/// One sine line that tapers to nothing at both ends.
private struct DictionaryWaveShape: Shape {
    var phase: Double
    var amplitude: CGFloat
    let frequency: CGFloat

    var animatableData: CGFloat {
        get { self.amplitude }
        set { self.amplitude = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0 else { return path }
        let step: CGFloat = 3
        var x: CGFloat = 0
        while x <= rect.width {
            let t = x / rect.width
            let envelope = sin(.pi * t)
            let y = rect.midY + rect.height / 2 * self.amplitude * envelope * sin(2 * .pi * self.frequency * t + CGFloat(self.phase))
            if x == 0 { path.move(to: CGPoint(x: rect.minX + x, y: y)) } else { path.addLine(to: CGPoint(x: rect.minX + x, y: y)) }
            x += step
        }
        return path
    }
}

/// Three tries, each showing what FluidVoice heard. Past three, the latest tries stay visible.
private struct DictionaryCaptureSlots: View {
    let word: String
    let attempts: [String]
    let pendingStatus: String?
    @Environment(\.theme) private var theme

    private var firstVisible: Int {
        let shown = self.attempts.count + (self.pendingStatus == nil ? 0 : 1)
        return max(0, shown - 3)
    }

    var body: some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            ForEach(0..<3, id: \.self) { offset in
                self.slot(self.firstVisible + offset)
            }
        }
        .frame(maxWidth: 440)
    }

    private func slot(_ index: Int) -> some View {
        let heard = self.attempts.indices.contains(index) ? self.attempts[index] : nil
        let matches = heard.map { $0.caseInsensitiveCompare(self.word.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame } ?? false
        let pending = heard == nil && index == self.attempts.count ? self.pendingStatus : nil
        return VStack(spacing: 2) {
            Text("Try \(index + 1)")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
            HStack(spacing: 4) {
                if matches {
                    Image(systemName: "checkmark").accessibilityHidden(true)
                } else if pending == "Listening…" {
                    Circle().fill(Color(nsColor: .systemRed)).frame(width: 7, height: 7).accessibilityHidden(true)
                }
                Text(heard ?? pending ?? "—")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(heard == nil ? self.theme.typography.body : self.theme.typography.bodyStrong)
            .foregroundStyle(matches ? self.theme.palette.accent : (heard == nil ? self.theme.palette.tertiaryText : self.theme.palette.primaryText))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(
            matches ? self.theme.palette.accent.opacity(0.1) : self.theme.palette.contentBackground,
            in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.md)
        )
        .overlay {
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md)
                .stroke(matches || pending != nil ? self.theme.palette.accent.opacity(0.5) : self.theme.palette.cardBorder, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Try \(index + 1)")
        .accessibilityValue(heard.map { matches ? "Heard correctly: \($0)" : "Heard: \($0)" } ?? pending ?? "Not recorded yet")
    }
}

enum DictionaryGlowResponse {
    static func energy(for level: CGFloat) -> Double {
        guard level.isFinite else { return 0 }
        return sqrt(Double(min(1, max(0, level))))
    }
}

/// Uses normal shortcut dictation, accepting output only for a capture begun in this editor.
struct DictionaryWordPlayground: View {
    let word: String
    let onPracticeMore: (() -> Void)?
    @Binding var busy: Bool
    @EnvironmentObject private var appServices: AppServices
    @Environment(\.theme) private var theme
    @FocusState private var editorFocused: Bool
    @State private var test = DictionaryShortcutTestState()

    private var shortcut: String {
        let value = SettingsStore.shared.primaryDictationShortcutDisplayString
        return value.isEmpty ? "your dictation shortcut" : value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            Text("Test “\(self.word)”")
                .font(self.theme.typography.title)
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { self.test.text }, set: { self.test.edit($0) }))
                    .font(self.theme.typography.body)
                    .scrollContentBackground(.hidden)
                    .focused(self.$editorFocused)
                    .padding(10)
                    .accessibilityLabel("Dictionary test text")
                if self.test.text.isEmpty {
                    Text(self.test.phase == .recording ? "Listening…" : (self.test.phase == .processing ? "Checking…" : "Use \(self.shortcut) and say something with “\(self.word)”."))
                        .font(self.theme.typography.body)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .padding(15)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 150)
            .background(self.theme.palette.contentBackground, in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.md))
            .overlay {
                RoundedRectangle(cornerRadius: self.theme.metrics.corners.md)
                    .stroke(self.editorFocused ? self.theme.palette.accent.opacity(0.5) : self.theme.palette.cardBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            switch self.test.result {
            case .recognized:
                Text("“\(self.word)” recognized" + (self.test.successes > 1 ? " · \(self.test.successes) times" : ""))
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(self.theme.palette.accent)
            case .missed:
                Text("We didn’t catch “\(self.word)”. Try your shortcut again.")
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.secondaryText)
                if let onPracticeMore {
                    Button("Record more examples", action: onPracticeMore)
                        .fluidGlassAction()
                        .disabled(self.busy)
                }
            case .empty:
                Text("No words came through. Try your shortcut again.")
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.secondaryText)
            case .none:
                EmptyView()
            }
        }
        .task(id: self.word) {
            self.test = DictionaryShortcutTestState()
            self.busy = false
            self.editorFocused = false
            await Task.yield()
            guard !Task.isCancelled else { return }
            self.editorFocused = true
        }
        .onReceive(self.appServices.asr.$isRunning.dropFirst()) { running in
            if running {
                self.test.begin(editorFocused: self.editorFocused, appActive: NSApp.isActive, dictionaryCapture: self.appServices.asr.isDictionaryTrainingCaptureActive)
            } else {
                self.test.stopped()
            }
            self.busy = self.test.phase != .idle
        }
        .onReceive(self.appServices.asr.dictionaryTestAudioPublisher) { samples in
            self.test.receiveAudio(samples)
        }
        .onReceive(self.appServices.asr.$finalText.dropFirst()) { text in
            // Start clears shared output; only the final, nonempty value belongs to a test result.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self.test.receive(text, word: self.word)
            self.busy = self.test.phase != .idle
        }
        .onReceive(self.appServices.asr.$showError.dropFirst()) { failed in
            if failed, let attempt = self.test.attemptID {
                self.test.expire(attempt)
                self.busy = false
            }
        }
        .task(id: self.test.phase == .processing ? self.test.attemptID : nil) {
            guard self.test.phase == .processing, let attempt = self.test.attemptID else { return }
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            self.test.expire(attempt)
            self.busy = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            self.test.cancel()
            self.busy = false
        }
        .onDisappear {
            self.test.cancel()
            self.busy = false
        }
    }
}
