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
    var automaticCaptureActive = false
    var audioLevels: AnyPublisher<CGFloat, Never> = Empty().eraseToAnyPublisher()
    var pronunciationNotice: String?
    var pronunciationIncomplete = false

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var wordFocused: Bool
    @State private var showingRecordingTips = false
    @State private var hasViewedTips = false
    @State private var showingCapturedSpellings = false
    @State private var playgroundBusy = false
    @State private var confirmingRedo = false
    @State private var confirmingWordChange = false
    @State private var pendingWord = ""

    var body: some View {
        VStack(spacing: self.theme.metrics.spacing.lg) {
            HStack {
                if self.step != .spelling, self.step != .saved {
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
    }

    private var spelling: some View {
        VStack(spacing: self.theme.metrics.spacing.lg) {
            DictionaryLearningRing(progress: 0, active: false, symbol: "waveform")
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
            Group {
                if self.step == .review {
                    self.manualAlternative.hidden().accessibilityHidden(true)
                } else {
                    self.manualAlternative
                }
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
            Text(self.step == .review ? (self.pronunciationIncomplete ? "Your spellings are ready" : "Your word is ready") : "Let’s hear your word")
                .font(self.theme.typography.body)
                .foregroundStyle(self.theme.palette.accent)
            Text("“\(self.word)”")
                .font(self.theme.typography.title)
                .fixedSize(horizontal: false, vertical: true)
            DictionaryLearningRing(
                progress: Double(min(self.count, 3)) / 3,
                active: self.recording && !self.starting,
                symbol: self.processing ? "ellipsis" : (self.count >= 3 ? "checkmark" : "waveform"),
                diameter: 264,
                count: self.count,
                processing: self.processing,
                audioLevels: self.audioLevels
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(DictionaryLearningEncouragement.messages(for: self.count)[0])
            .accessibilityValue(self.processing ? "Processing recording" : (self.recording ? "Listening" : ""))
            .accessibilityHidden(false)
            self.captureControls
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, self.theme.metrics.spacing.lg)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var learningTitle: String {
        if self.step == .review { return self.alreadyCorrect ? "It already sounds right" : "Ready to save" }
        if self.starting { return "Getting ready…" }
        if self.processing { return "Learning your voice…" }
        if self.recording { return self.count < 1 ? "Listening…" : "Say it again" }
        if self.count >= 3 { return "Ready to add" }
        return self.count < 1 ? "Let’s hear your word" : "Keep going—you’re nearly there"
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
                self.instruction(3, title: "Wait for the next prompt", detail: "Speak again when you see “Listening…”.")
                Divider()
                Label("Choose a quiet place and keep a comfortable distance from your microphone.", systemImage: "ear")
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            if self.count >= 1, !self.capturedSpellings.isEmpty {
                DisclosureGroup("Captured spellings · \(self.capturedSpellings.count)", isExpanded: self.$showingCapturedSpellings) {
                    self.capturedVariations.padding(.top, self.theme.metrics.spacing.sm)
                }
                .font(self.theme.typography.body)
                .tint(self.theme.palette.accent)
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
            self.stableInstruction("Say only “\(self.word)” once, then wait.", review: "Ready to add “\(self.word)”")
                .font(self.theme.typography.title)
                .foregroundStyle(self.theme.palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            self.stableInstruction("We’ll stop automatically and let you know when to speak again.", review: "Add it now, or record another example.")
                .font(self.theme.typography.body)
                .foregroundStyle(self.theme.palette.secondaryText)
            if let pronunciationNotice {
                Text(pronunciationNotice)
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            ZStack(alignment: .top) {
                if self.step == .review {
                    self.captureRecordActions.hidden().accessibilityHidden(true)
                    self.reviewActions
                } else {
                    self.reviewActions.hidden().accessibilityHidden(true)
                    self.captureRecordActions
                }
            }
        }
    }

    private func stableInstruction(_ recording: String, review: String) -> some View {
        ZStack {
            Text(recording).hidden().accessibilityHidden(true)
            Text(review).hidden().accessibilityHidden(true)
            Text(self.step == .review ? review : recording)
        }
    }

    private var captureRecordActions: some View {
        VStack(spacing: self.theme.metrics.spacing.md) {
            Button(action: self.onRecord) {
                ZStack {
                    Text("Stop recording").hidden()
                    Text(DictionaryCaptureAction.title(active: self.captureActive, failed: self.error != nil, count: self.count))
                }
            }
            .buttonStyle(FluidRecordInvitationStyle(inviting: !self.captureActive && self.count < 1, recording: self.captureActive))
            .disabled(self.processing || self.starting)
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
        self.automaticCaptureActive || self.recording || self.processing || self.starting
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
                Text("Add “\(self.word)” to dictionary").hidden().accessibilityHidden(true)
                Text(self.busy ? "Saving…" : (self.pronunciationIncomplete ? "Save spelling corrections" : "Add “\(self.word)” to dictionary"))
            }
        }
        .buttonStyle(FluidRecordInvitationStyle(inviting: self.step == .review && !self.busy, recording: false, fillsWidth: true))
        .disabled(self.busy)
        if self.count < CustomDictionaryTrainingMerge.maxSamples {
            VStack(spacing: self.theme.metrics.spacing.sm) {
                Button("Record more", action: self.onRecord)
                    .buttonStyle(FluidRecordInvitationStyle(inviting: false, recording: false, prominent: false, fillsWidth: true))
                    .disabled(self.busy)
                Text(self.pronunciationIncomplete ? "Needed to finish pronunciation learning" : "Optional · Recommended for tricky words")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .frame(maxWidth: 190)
                    .fixedSize(horizontal: false, vertical: true)
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
        return (self.variants + [self.heard]).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0.lowercased()).inserted
        }
    }

    @ViewBuilder private var capturedVariations: some View {
        if !self.capturedSpellings.isEmpty {
            VStack(spacing: self.theme.metrics.spacing.sm) {
                Text("Spellings linked to “\(self.word)”")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                FlowLayout(spacing: 6) {
                    ForEach(self.capturedSpellings, id: \.self) { variant in
                        Text(variant)
                            .font(self.theme.typography.caption)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(self.theme.palette.accent.opacity(0.08), in: Capsule())
                    }
                }
            }
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

enum DictionaryLearningEncouragement {
    static func messages(for count: Int) -> [String] {
        switch count {
        case ...0: ["Ready when you are"]
        case 1: ["Nice! 2 more to go"]
        case 2: ["One more—you’ve got this"]
        default: ["Got it! Ready to add"]
        }
    }
}

/// Bounded ambient motion redraws only the artwork; text stays stable and hidden rings stop updating.
private struct DictionaryLearningRing: View {
    let progress: Double
    let active: Bool
    let symbol: String
    var diameter: CGFloat = 176
    var count: Int? = nil
    var processing = false
    var audioLevels: AnyPublisher<CGFloat, Never> = Empty().eraseToAnyPublisher()
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase

    // Match the preview blue explicitly, independent of the selected app accent or appearance.
    private let learningBlue = Color(red: 10 / 255, green: 132 / 255, blue: 1)

    @State private var isVisible = false
    @State private var voiceEnergy = 0.0
    @State private var listening = 0.0
    @State private var pulse = 0.0
    @State private var highlightsProgress = false
    @State private var completionBloom = 1.0

    private var animates: Bool {
        self.isVisible && !self.reduceMotion && self.scenePhase == .active &&
            (self.active || (self.count != nil && self.progress < 1))
    }

    var body: some View {
        ZStack {
            if !self.reduceTransparency {
                Circle()
                    .fill(RadialGradient(
                        colors: [self.learningBlue.opacity(0.04 + self.progress * 0.14), .clear],
                        center: .center,
                        startRadius: 10,
                        endRadius: self.diameter / 2
                    ))
            }
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !self.animates)) { context in
                let phase = self.reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 14) / 14 * .pi * 2
                DictionaryRingArtwork(
                    phase: phase,
                    progress: self.progress,
                    energy: self.reduceMotion ? 0 : self.voiceEnergy,
                    glow: max(self.listening, self.pulse, self.progress >= 1 ? 0.5 : 0),
                    accent: self.learningBlue,
                    rest: self.theme.palette.secondaryText,
                    additive: !self.reduceTransparency
                )
            }
            .animation(self.reduceMotion ? nil : .easeInOut(duration: 0.65), value: self.progress)
            .animation(self.reduceMotion ? nil : .easeOut(duration: 0.12), value: self.voiceEnergy)
            if let count, count >= 3, !self.reduceMotion {
                DictionaryCompletionBloom(progress: self.completionBloom, color: self.learningBlue)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
            if let count {
                ZStack {
                    Text(DictionaryLearningEncouragement.messages(for: count)[0])
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.highlightsProgress ? self.learningBlue : self.theme.palette.primaryText)
                        .animation(self.reduceMotion ? nil : .easeInOut(duration: 0.9), value: self.highlightsProgress)
                        .multilineTextAlignment(.center)
                        .frame(height: 60)
                    HStack(spacing: 8) {
                        ForEach(0..<3) { index in
                            Circle()
                                .fill(index < count ? self.learningBlue : self.theme.palette.secondaryText.opacity(0.2))
                                .frame(width: 8, height: 8)
                        }
                    }
                    .offset(y: 44)
                    ZStack {
                        if self.processing { ProgressView().controlSize(.small) }
                    }
                    .frame(height: 20)
                    .offset(y: 66)
                }
                .frame(width: self.diameter * 0.57, height: self.diameter)
                .transaction { $0.animation = nil }
            } else {
                Image(systemName: self.symbol)
                    .font(.system(size: 27, weight: .light))
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
        }
        .frame(width: self.diameter, height: self.diameter)
        .animation(self.reduceMotion ? nil : .easeInOut(duration: 0.4), value: self.progress)
        .transaction { if self.reduceMotion { $0.animation = nil } }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .onAppear { self.isVisible = true; self.listening = self.active ? 1 : 0 }
        .onDisappear { self.isVisible = false; self.voiceEnergy = 0 }
        .task(id: (self.count ?? 0) >= 3) {
            guard (self.count ?? 0) >= 3, !self.reduceMotion else {
                self.completionBloom = 1
                return
            }
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { self.completionBloom = 0 }
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
            withAnimation(.easeOut(duration: 1.1)) { self.completionBloom = 1 }
        }
        .task(id: self.count) {
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { self.highlightsProgress = false }
            guard let count = self.count, count > 0 else { return }
            if !self.reduceMotion {
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            self.highlightsProgress = true
        }
        .onChange(of: self.active) { _, active in
            if !active { self.voiceEnergy = 0 }
            withAnimation(self.reduceMotion ? nil : .easeInOut(duration: 0.5)) { self.listening = active ? 1 : 0 }
        }
        .onChange(of: self.count) { old, new in
            // A captured word flashes the ring, then settles into the new progress.
            guard let old, let new, new > old, !self.reduceMotion else { return }
            self.pulse = 1
            withAnimation(.easeOut(duration: 1.4)) { self.pulse = 0 }
        }
        .onChange(of: self.scenePhase) { _, phase in
            if phase != .active { self.voiceEnergy = 0 }
        }
        .onReceive(self.audioLevels.throttle(for: .milliseconds(50), scheduler: RunLoop.main, latest: true)) { level in
            guard self.active, self.isVisible, self.scenePhase == .active, !self.reduceMotion else { return }
            let target = DictionaryRingResponse.energy(for: level)
            self.voiceEnergy += (target - self.voiceEnergy) * (target > self.voiceEnergy ? 0.75 : 0.35)
        }
    }
}

/// A single contained release of light at the third capture, with no change to layout or hit targets.
private struct DictionaryCompletionBloom: View, Animatable {
    var progress: Double
    let color: Color

    var animatableData: Double {
        get { self.progress }
        set { self.progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let phase = min(1, max(0, self.progress))
            guard phase < 1 else { return }
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) * (0.27 + phase * 0.19)
            let opacity = sin(phase * .pi)
            context.stroke(
                Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(self.color.opacity(opacity * 0.5)),
                lineWidth: 2 * (1 - phase) + 0.5
            )
            for index in 0..<16 {
                let angle = Double(index) / 16 * .pi * 2
                let length = 3 + (1 - phase) * 7
                var ray = Path()
                ray.move(to: CGPoint(x: centre.x + cos(angle) * (radius - length), y: centre.y + sin(angle) * (radius - length)))
                ray.addLine(to: CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius))
                context.stroke(ray, with: .color(self.color.opacity(opacity * 0.8)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
    }
}

enum DictionaryRingResponse {
    static func energy(for level: CGFloat) -> Double {
        guard level.isFinite else { return 0 }
        return sqrt(Double(min(1, max(0, level))))
    }
}

/// Three translucent sheets fan wide and pinch loosely; lines inside a sheet never cross, so the ring reads as silk, not rope.
private struct DictionaryRingArtwork: View, Animatable {
    let phase: Double
    var progress: Double
    var energy: Double
    var glow: Double
    let accent: Color
    let rest: Color
    let additive: Bool

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(self.progress, AnimatablePair(self.energy, self.glow)) }
        set {
            self.progress = newValue.first
            self.energy = newValue.second.first
            self.glow = newValue.second.second
        }
    }

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let lit = min(1, max(0, self.glow) * 0.7 + self.energy * 0.5)
            let shading = GraphicsContext.Shading.conicGradient(
                Gradient(stops: self.stops),
                center: CGPoint(x: rect.midX, y: rect.midY),
                angle: .degrees(-90)
            )
            let paths = (0..<DictionaryRibbon.sheets).flatMap { sheet in
                (0..<7).map { line in
                    DictionaryRibbon(phase: self.phase, strand: Double(line - 3) * 4 / 3, energy: self.energy, sheet: sheet).path(in: rect)
                }
            }
            if self.additive { context.blendMode = .plusLighter }
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 5 + lit * 5))
                layer.opacity = 0.3 + lit * 0.35
                for path in paths {
                    layer.stroke(path, with: shading, lineWidth: 1.6 + lit * 0.8)
                }
            }
            context.opacity = 0.5 + lit * 0.3
            for path in paths {
                context.stroke(path, with: shading, lineWidth: 0.7 + lit * 0.25)
            }
        }
    }

    /// The learned arc fades into the resting color instead of ending on a hard edge.
    private var stops: [Gradient.Stop] {
        let learned = self.accent
        let resting = self.rest.opacity(0.55)
        guard self.progress > 0.001 else { return [.init(color: resting, location: 0), .init(color: resting, location: 1)] }
        guard self.progress < 0.999 else { return [.init(color: learned, location: 0), .init(color: learned, location: 1)] }
        let fade = 0.1
        let start = max(0, self.progress - fade / 2)
        let end = min(1, max(start, self.progress + fade / 2))
        let seam = max(end, 1 - fade)
        return [
            .init(color: learned, location: 0),
            .init(color: learned, location: start),
            .init(color: resting, location: end),
            .init(color: resting, location: seam),
            .init(color: learned, location: 1),
        ]
    }
}

struct DictionaryRibbon: Shape {
    static let sheets = 3

    let phase: Double
    let strand: Double
    let energy: Double
    var sheet = 0

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) * 0.34
        let offset = Double(self.sheet) * 2.1
        let lobes = Double([3, 2, 4][self.sheet % 3])
        let drift = self.sheet.isMultiple(of: 2) ? self.phase : -self.phase
        let spread = self.strand / 4
        return Path { path in
            for sample in 0...180 {
                let angle = Double(sample) / 180 * .pi * 2
                let center = 1 + sin(angle * 3 + offset + self.phase) * 0.05 + sin(angle * 2 + offset * 0.6 - self.phase) * 0.03 + self.energy * 0.02
                // The sheet twists through a loose pinch, then opens into a wide veil; speech opens it further.
                let width = cos(angle * lobes + offset + drift) * (0.11 + self.energy * 0.05) + 0.018
                let distance = radius * (center + spread * width)
                let point = CGPoint(
                    x: rect.midX + CGFloat(cos(angle)) * distance,
                    y: rect.midY + CGFloat(sin(angle)) * distance
                )
                if sample == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        }
    }
}

/// Uses normal shortcut dictation, accepting output only for a capture begun in this editor.
struct DictionaryWordPlayground: View {
    let word: String
    let onPracticeMore: () -> Void
    @Binding var busy: Bool
    @EnvironmentObject private var appServices: AppServices
    @Environment(\.theme) private var theme
    @FocusState private var editorFocused: Bool
    @State private var test = DictionaryShortcutTestState()
    @AppStorage("DictionaryPronunciationDebugCapture") private var debugCapture = false

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
                Text("We didn’t catch “\(self.word)”. Try again, or add more examples.")
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.secondaryText)
                Button("Record more examples", action: self.onPracticeMore)
                    .fluidGlassAction()
                    .disabled(self.busy)
            case .empty:
                Text("No words came through. Try your shortcut again.")
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.secondaryText)
            case .none:
                EmptyView()
            }
            if DictionaryPronunciationExperiment.enabled {
                Toggle("Save dictionary debug audio locally", isOn: self.$debugCapture)
                    .font(self.theme.typography.caption)
                    .help("Saves audio, embeddings, cuts and scores locally. Switch off to stop collection. Keeps at most 50 debug reports / 200 MB.")
            }
        }
        .task(id: self.word) {
            self.test = DictionaryShortcutTestState()
            self.editorFocused = true
            self.busy = false
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
