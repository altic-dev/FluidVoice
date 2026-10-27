import AppKit
import SwiftUI

// Generated from Upstream/BottomOverlayView.swift. Visual declarations below are verbatim.
// Only inputs are frozen, and production action/anchor controllers are not included.
struct BottomOverlayView: View {
    let smart: Bool
    var chipScale: Double = 1
    var chipHighlighted = false
    var demonstrationMenu = AnyView(EmptyView())
    var demonstrationPointer = AnyView(EmptyView())
    private let settings = SettingsStore()
    private let contentState = FrozenOverlayState()
    private let appServices = FrozenAppServices()
    private let displayedAppIcon: NSImage? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var onboardingHighlight = false
    @State private var isHoveringActionsChip = false
    private let isHoveringPromptChip = false
    private let showsOnboardingHint = false
    private let isAppPromptOverrideActive = false
    private let isPromptSelectableMode = true
    private let shouldReservePreviewArea = true
    private let shouldSuppressPreviewDuringRelease = false
    private let shouldShowTextDeliveryFailure = false
    private let shouldShowAIProcessingFailure = false
    private let shouldShowProcessingPreview = false
    private let shouldShowProcessingStatus = false
    private let hasTranscription = false
    private let frozenDynamicPreviewHeight: CGFloat? = nil
    private let borderAnimationStartedAt: Date? = nil
    private let showsSpokenSendIndicator = false
    private let spokenSendIndicatorSize: CGFloat = 15
    private let modeColor = Color.white.opacity(0.85)
    private let modeLabel = "Dictate"
    private let processingPreviewText = ""
    private let transcriptionPreviewText = ""
    private var layout: LayoutConstants { .get(for: settings.overlaySize) }
    private var promptSelectorIconName: String? { smart ? "sparkles" : "bolt.fill" }
    private var promptSelectorDisplayLabel: String { smart ? "Smart" : "Basic" }
    private var promptSelectorBuiltInLabel: String? { promptSelectorDisplayLabel }
    // Wrappers supply only demonstration animation; the label itself is copied unchanged.
    private var promptSelectorView: some View {
        promptSelectorTrigger.scaleEffect(chipScale)
            .background(RoundedRectangle(cornerRadius: promptSelectorCornerRadius).fill(.white.opacity(chipHighlighted ? 0.10 : 0)))
            .overlay(alignment: .topTrailing) {
                demonstrationMenu.fixedSize()
                    .alignmentGuide(.top) { $0[.bottom] + max(0, layout.vPadding * 0.05) }
            }
            .overlay { demonstrationPointer }
    }
    private var actionsSelectorView: some View { actionsSelectorTrigger }
    // Unreachable branches in the frozen, medium, silence state.
    private var settingsChip: some View { EmptyView() }
    private var textDeliveryFailureView: some View { EmptyView() }
    private var aiProcessingFailureView: some View { EmptyView() }
    private func scrollablePreviewText(_ text: String) -> some View { EmptyView() }
    private func dynamicPreviewText(_ text: String) -> some View { EmptyView() }
    struct LayoutConstants {
        let hPadding: CGFloat
        let vPadding: CGFloat
        let waveformWidth: CGFloat
        let waveformHeight: CGFloat
        let iconSize: CGFloat
        let transFontSize: CGFloat
        let modeFontSize: CGFloat
        let cornerRadius: CGFloat
        let barCount: Int
        let barWidth: CGFloat
        let barSpacing: CGFloat
        let minBarHeight: CGFloat
        let maxBarHeight: CGFloat
        let containerWidth: CGFloat
        let overlayWidth: CGFloat
        let overlayHeight: CGFloat
        let previewBoxHeight: CGFloat
        let usesFixedCanvas: Bool
        let showsTopControls: Bool
        let showsPreview: Bool
        let showsModeLabel: Bool

        static func get(for size: SettingsStore.OverlaySize) -> LayoutConstants {
            switch size {
            case .pill:
                return LayoutConstants(
                    hPadding: 12,
                    vPadding: 8,
                    waveformWidth: 46,
                    waveformHeight: 30,
                    iconSize: 18,
                    transFontSize: 10,
                    modeFontSize: 9,
                    cornerRadius: 23,
                    barCount: 8,
                    barWidth: 3.0,
                    barSpacing: 2.5,
                    minBarHeight: 4,
                    maxBarHeight: 28,
                    containerWidth: 100,
                    overlayWidth: 100,
                    overlayHeight: 46,
                    previewBoxHeight: 0,
                    usesFixedCanvas: false,
                    showsTopControls: false,
                    showsPreview: false,
                    showsModeLabel: false
                )
            case .small:
                return LayoutConstants(
                    hPadding: 10,
                    vPadding: 6,
                    waveformWidth: 90,
                    waveformHeight: 20,
                    iconSize: 16,
                    transFontSize: 11,
                    modeFontSize: 10,
                    cornerRadius: 14,
                    barCount: 7,
                    barWidth: 3.0,
                    barSpacing: 3.5,
                    minBarHeight: 5,
                    maxBarHeight: 16,
                    containerWidth: 200,
                    overlayWidth: 300,
                    overlayHeight: 124,
                    previewBoxHeight: 0,
                    usesFixedCanvas: false,
                    showsTopControls: false,
                    showsPreview: true,
                    showsModeLabel: true
                )
            case .medium:
                return LayoutConstants(
                    hPadding: 18,
                    vPadding: 12,
                    waveformWidth: 130,
                    waveformHeight: 32,
                    iconSize: 20,
                    transFontSize: 13,
                    modeFontSize: 12,
                    cornerRadius: 18,
                    barCount: 8,
                    barWidth: 3.5,
                    barSpacing: 4.5,
                    minBarHeight: 6,
                    maxBarHeight: 28,
                    containerWidth: 340,
                    overlayWidth: 380,
                    overlayHeight: 156,
                    previewBoxHeight: 0,
                    usesFixedCanvas: false,
                    showsTopControls: true,
                    showsPreview: true,
                    showsModeLabel: true
                )
            case .large:
                return LayoutConstants(
                    hPadding: 18,
                    vPadding: 12,
                    waveformWidth: 180,
                    waveformHeight: 48,
                    iconSize: 26,
                    transFontSize: 15,
                    modeFontSize: 14,
                    cornerRadius: 24,
                    barCount: 11,
                    barWidth: 5.0,
                    barSpacing: 6.0,
                    minBarHeight: 8,
                    maxBarHeight: 44,
                    containerWidth: 600,
                    overlayWidth: 600,
                    overlayHeight: 288,
                    previewBoxHeight: 92,
                    usesFixedCanvas: true,
                    showsTopControls: true,
                    showsPreview: true,
                    showsModeLabel: true
                )
            }
        }
    }

    private var isCompactControls: Bool {
        self.settings.overlaySize == .medium
    }

    private var waveformHorizontalOffset: CGFloat {
        self.settings.overlaySize == .medium ? -28 : 0
    }

    private var isPillSize: Bool {
        self.settings.overlaySize == .pill
    }

    private var promptSelectorFontSize: CGFloat {
        if self.isCompactControls { return 10 }
        return max(self.layout.modeFontSize - 1, 9)
    }

    private var promptSelectorLabelFontSize: CGFloat {
        max(self.promptSelectorFontSize - 1, 8)
    }

    private var promptSelectorVerticalPadding: CGFloat {
        4
    }

    private var promptSelectorCornerRadius: CGFloat {
        max(self.layout.cornerRadius * 0.42, 8)
    }

    private var previewMaxHeight: CGFloat {
        self.layout.usesFixedCanvas ? self.layout.previewBoxHeight : self.layout.transFontSize * 4.2
    }

    private var overlayFrameHeight: CGFloat? {
        guard self.layout.usesFixedCanvas else { return nil }
        return self.shouldReservePreviewArea ? self.layout.overlayHeight : nil
    }

    private var previewMaxWidth: CGFloat {
        if self.layout.usesFixedCanvas {
            return self.layout.waveformWidth * 2.2
        }

        return max(self.layout.waveformWidth * 2.2, self.layout.containerWidth - self.layout.hPadding * 2)
    }

    private var dynamicPreviewBaseMinHeight: CGFloat {
        guard self.shouldReservePreviewArea else { return 0 }
        let verticalPadding = self.settings.overlaySize == .small
            ? max(2, self.transcriptionVerticalPadding - 1)
            : self.transcriptionVerticalPadding
        return self.estimatedPreviewLineHeight + verticalPadding * 2
    }

    private var effectiveDynamicPreviewLockedHeight: CGFloat? {
        guard self.contentState.isBottomOverlayReleaseTransitioning else { return nil }
        guard let frozenDynamicPreviewHeight else { return nil }
        return max(frozenDynamicPreviewHeight, self.dynamicPreviewBaseMinHeight)
    }

    private var effectiveDynamicPreviewMinHeight: CGFloat {
        self.effectiveDynamicPreviewLockedHeight ?? self.dynamicPreviewBaseMinHeight
    }

    private var estimatedPreviewLineHeight: CGFloat {
        max(self.layout.transFontSize * 1.25, self.layout.transFontSize + 2)
    }

    private var transcriptionVerticalPadding: CGFloat {
        max(4, self.layout.vPadding / 2)
    }

    private var overlayBorderLineWidth: CGFloat {
        self.settings.overlaySize == .large ? 0.8 : 1
    }

    private var overlayBorderTopOpacity: Double {
        switch self.settings.overlaySize {
        case .pill: return 0.22 // a touch crisper so the smaller pill reads clearly
        case .large: return 0.10
        default: return 0.15
        }
    }

    private var overlayBorderBottomOpacity: Double {
        switch self.settings.overlaySize {
        case .pill: return 0.10
        case .large: return 0.05
        default: return 0.08
        }
    }

    private var targetAppIconView: some View {
        let appIcon = self.displayedAppIcon
        let showModelLoading = self.layout.showsModeLabel && !self.appServices.asr.isAsrReady &&
            (self.appServices.asr.isLoadingModel || self.appServices.asr.isDownloadingModel)
        return VStack(spacing: 2) {
            if showModelLoading {
                ProgressView()
                    .controlSize(.mini)
            }
            if let appIcon = appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: self.layout.iconSize, height: self.layout.iconSize)
                    .clipShape(RoundedRectangle(cornerRadius: self.layout.iconSize / 4))
            } else if !self.layout.showsModeLabel {
                Circle()
                    .fill(self.modeColor.opacity(0.9))
                    .frame(width: max(self.layout.iconSize * 0.45, 7), height: max(self.layout.iconSize * 0.45, 7))
            }
        }
        .frame(width: self.layout.iconSize, height: self.layout.iconSize)
        .opacity((appIcon != nil || showModelLoading || !self.layout.showsModeLabel) ? 1 : 0)
    }

    private var leadingAppContextView: some View {
        HStack(spacing: self.isPillSize ? 4 : 8) {
            if self.showsSpokenSendIndicator {
                SpokenSendIndicatorView(
                    state: self.contentState.spokenSendIndicatorState,
                    color: self.modeColor,
                    size: self.isPillSize ? 14 : self.spokenSendIndicatorSize
                )
                .id(self.contentState.spokenSendCountdownID)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }

            self.targetAppIconView
        }
        .animation(
            self.reduceMotion ? nil : .easeOut(duration: 0.14),
            value: self.contentState.spokenSendIndicatorState
        )
    }

    private var promptSelectorTrigger: some View {
        HStack(spacing: 5) {
            if let promptSelectorIconName = self.promptSelectorIconName {
                Image(systemName: promptSelectorIconName)
                    .font(.fluidSystem(size: max(self.promptSelectorFontSize - 1, 9), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }
            Text(self.promptSelectorDisplayLabel)
                .font(.fluidSystem(size: self.promptSelectorFontSize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(
                    maxWidth: self.promptSelectorBuiltInLabel == nil ? 72 : nil,
                    alignment: .leading
                )
            if self.isAppPromptOverrideActive {
                Text("App")
                    .font(.fluidSystem(size: max(self.promptSelectorFontSize - 2, 8), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.15))
                    )
            }
            Image(systemName: "chevron.down")
                .font(.fluidSystem(size: max(self.promptSelectorFontSize - 1, 8), weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, self.promptSelectorVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: self.promptSelectorCornerRadius, style: .continuous)
                .fill(
                    self.isHoveringPromptChip && self.isPromptSelectableMode && !self.contentState.isProcessing
                        ? Color.white.opacity(0.10)
                        : Color.clear
                )
        )
        .overlay(alignment: .top) {
            if self.isHoveringPromptChip, !self.showsOnboardingHint, self.isPromptSelectableMode, !self.contentState.isProcessing {
                Text("Select dictation mode")
                    .font(.fluidSystem(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.94))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
                    .fixedSize()
                    .offset(y: -30)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Select dictation mode")
        .overlay {
            if self.showsOnboardingHint {
                RoundedRectangle(cornerRadius: self.promptSelectorCornerRadius)
                    .stroke(FluidOnboardingLandingColors.blue, lineWidth: 1.5)
                    .padding(-3)
                    .opacity(self.reduceMotion || self.onboardingHighlight ? 1 : 0.2)
                    .allowsHitTesting(false)
            }
        }
        .task(id: self.showsOnboardingHint) {
            guard self.showsOnboardingHint else {
                self.onboardingHighlight = false
                return
            }
            withAnimation(self.reduceMotion ? nil : .easeOut(duration: 0.45)) {
                self.onboardingHighlight = true
            }
        }
    }

    private var actionsSelectorTrigger: some View {
        let actionsDisabled = self.contentState.isProcessing
        return HStack(spacing: 0) {
            Image(systemName: "ellipsis")
                .font(.fluidSystem(size: 16, weight: .bold))
                .foregroundStyle(.white.opacity(actionsDisabled ? 0.3 : 0.78))
        }
        .frame(width: 32, height: 32)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(self.isHoveringActionsChip && !actionsDisabled ? Color.white.opacity(0.1) : Color.clear)
        )
        .overlay(alignment: .top) {
            if self.isHoveringActionsChip, !actionsDisabled {
                Text("Actions")
                    .font(.fluidSystem(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.94))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
                    .fixedSize()
                    .offset(y: -30)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Actions")
    }

    private func chipBackground(isHovered: Bool, disabled: Bool) -> some View {
        let fillColor: Color
        if disabled {
            fillColor = Color.black.opacity(0.95)
        } else if isHovered {
            fillColor = Color(red: 0.13, green: 0.13, blue: 0.16)
        } else {
            fillColor = Color.black
        }

        let topStrokeOpacity: Double = disabled ? 0.10 : (isHovered ? 0.36 : 0.14)
        let bottomStrokeOpacity: Double = disabled ? 0.06 : (isHovered ? 0.22 : 0.08)
        let hoverShadowColor: Color = (isHovered && !disabled) ? Color.white.opacity(0.16) : .clear

        return RoundedRectangle(cornerRadius: self.promptSelectorCornerRadius)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: self.promptSelectorCornerRadius)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(topStrokeOpacity),
                                Color.white.opacity(bottomStrokeOpacity),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: hoverShadowColor, radius: 6, x: 0, y: 1)
    }

    var body: some View {
        VStack(spacing: max(4, self.layout.vPadding / 2)) {
            if self.layout.showsTopControls, !self.isCompactControls {
                HStack {
                    Spacer(minLength: 4)
                    self.settingsChip
                }
                .padding(.horizontal, self.layout.hPadding)
            }

            VStack(spacing: self.layout.vPadding / 2) {
                if self.shouldReservePreviewArea {
                    if self.layout.usesFixedCanvas {
                        // Transcription text area (fixed-height in large mode)
                        Group {
                            if self.shouldSuppressPreviewDuringRelease {
                                Color.clear
                            } else if self.shouldShowTextDeliveryFailure {
                                self.textDeliveryFailureView
                            } else if self.shouldShowAIProcessingFailure {
                                self.aiProcessingFailureView
                            } else if self.shouldShowProcessingPreview {
                                self.scrollablePreviewText(self.processingPreviewText)
                            } else if self.shouldShowProcessingStatus {
                                // Temporarily hidden; the waveform sweep carries processing state.
                                // ShimmerText(
                                //     text: self.processingStatusText,
                                //     color: self.modeColor,
                                //     font: .fluidSystem(size: self.layout.transFontSize, weight: .medium)
                                // )
                                // .id(self.processingStatusCycleID)
                                // .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                Color.clear
                            } else if self.contentState.isProcessing {
                                Color.clear
                            } else if self.hasTranscription {
                                let previewText = self.transcriptionPreviewText
                                if !previewText.isEmpty {
                                    ScrollViewReader { proxy in
                                        ScrollView(.vertical, showsIndicators: false) {
                                            Text(previewText)
                                                .font(.fluidSystem(size: self.layout.transFontSize, weight: .medium))
                                                .foregroundStyle(.white.opacity(0.9))
                                                .multilineTextAlignment(.leading)
                                                .lineLimit(nil)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Color.clear.frame(height: 1).id("bottom")
                                        }
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                        .clipped()
                                        .onAppear {
                                            DispatchQueue.main.async {
                                                proxy.scrollTo("bottom", anchor: .bottom)
                                            }
                                        }
                                        .onChange(of: previewText) { _, _ in
                                            DispatchQueue.main.async {
                                                proxy.scrollTo("bottom", anchor: .bottom)
                                            }
                                        }
                                    }
                                }
                            } else {
                                Color.clear
                            }
                        }
                        .padding(.vertical, self.transcriptionVerticalPadding)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: self.previewMaxHeight,
                            maxHeight: self.previewMaxHeight,
                            alignment: .topLeading
                        )
                    } else {
                        // Original dynamic preview behavior for small/medium
                        Group {
                            if self.shouldSuppressPreviewDuringRelease {
                                Color.clear
                            } else if self.shouldShowTextDeliveryFailure {
                                self.textDeliveryFailureView
                            } else if self.shouldShowAIProcessingFailure {
                                self.aiProcessingFailureView
                            } else if self.shouldShowProcessingPreview {
                                self.dynamicPreviewText(self.processingPreviewText)
                            } else if self.hasTranscription && !self.contentState.isProcessing {
                                let previewText = self.transcriptionPreviewText
                                if !previewText.isEmpty {
                                    if self.settings.overlaySize == .small {
                                        Text(previewText)
                                            .font(.fluidSystem(size: self.layout.transFontSize, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.9))
                                            .multilineTextAlignment(.leading)
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.vertical, max(2, self.transcriptionVerticalPadding - 1))
                                    } else {
                                        Text(previewText)
                                            .font(.fluidSystem(size: self.layout.transFontSize, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.9))
                                            .multilineTextAlignment(.leading)
                                            .lineLimit(Int(self.previewMaxHeight / max(self.estimatedPreviewLineHeight, 1)))
                                            .truncationMode(.head)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(width: self.previewMaxWidth, alignment: .leading)
                                            .padding(.vertical, self.transcriptionVerticalPadding)
                                    }
                                }
                            } else if self.shouldShowProcessingStatus {
                                // Temporarily hidden; the waveform sweep carries processing state.
                                // ShimmerText(
                                //     text: self.processingStatusText,
                                //     color: self.modeColor,
                                //     font: .fluidSystem(size: self.layout.transFontSize, weight: .medium)
                                // )
                                // .id(self.processingStatusCycleID)
                                Color.clear
                            } else if self.contentState.isProcessing {
                                Color.clear
                            } else {
                                Color.clear
                            }
                        }
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .preference(key: DynamicPreviewHeightPreferenceKey.self, value: proxy.size.height)
                            }
                        )
                        .frame(
                            maxWidth: self.previewMaxWidth,
                            minHeight: self.effectiveDynamicPreviewMinHeight,
                            maxHeight: self.effectiveDynamicPreviewLockedHeight
                        )
                    }
                }

                // Waveform + Mode label row
                HStack(spacing: self.isPillSize ? 4 : self.layout.hPadding / 1.5) {
                    if !self.layout.showsTopControls {
                        self.leadingAppContextView
                    }

                    // Waveform visualization
                    BottomWaveformView(
                        color: self.modeColor,
                        layout: self.layout,
                        visibleBarCount: self.isPillSize && self.showsSpokenSendIndicator ? 6 : nil
                    )
                    .frame(
                        width: self.isPillSize && self.showsSpokenSendIndicator
                            ? 32
                            : self.layout.waveformWidth,
                        height: self.layout.waveformHeight
                    )

                    // Compact overlays still need a visible mode because they have no selector.
                    if self.layout.showsModeLabel, !self.layout.showsTopControls {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(self.modeLabel)
                                .font(.fluidSystem(size: self.layout.modeFontSize, weight: .semibold))
                                .foregroundStyle(self.modeColor)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)

                            if !self.appServices.asr.isAsrReady &&
                                (self.appServices.asr.isLoadingModel || self.appServices.asr.isDownloadingModel)
                                && self.settings.overlaySize != .small
                            {
                                Text("Loading model…")
                                    .font(.fluidSystem(size: max(self.layout.modeFontSize - 2, 9), weight: .medium))
                                    .foregroundStyle(.orange.opacity(0.85))
                                    .lineLimit(1)
                            }
                        }
                        .animation(
                            self.reduceMotion ? nil : .easeOut(duration: 0.14),
                            value: self.contentState.spokenSendIndicatorState
                        )
                    }
                }
                .offset(x: self.waveformHorizontalOffset)
                .frame(maxWidth: .infinity, alignment: .center)
                .overlay(alignment: .leading) {
                    if self.layout.showsTopControls {
                        self.leadingAppContextView
                    }
                }
                .overlay(alignment: .trailing) {
                    if self.layout.showsTopControls {
                        HStack(spacing: 8) {
                            self.promptSelectorView
                            self.actionsSelectorView
                        }
                    }
                }
            }
            .padding(.horizontal, self.layout.hPadding)
            .padding(.vertical, self.layout.vPadding)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(
                ZStack {
                    // Solid pitch black background, with a soft drop shadow so the pill lifts
                    // off whatever is behind it (pill size only; outer padding reserves room).
                    RoundedRectangle(cornerRadius: self.layout.cornerRadius)
                        .fill(Color.black)
                        .shadow(
                            color: Color.black.opacity(self.isPillSize ? 0.32 : 0),
                            radius: self.isPillSize ? PillShadowMetrics.radius : 0,
                            x: 0,
                            y: self.isPillSize ? PillShadowMetrics.yOffset : 0
                        )

                    if self.isPillSize {
                        // Glossy border: a bright highlight that slowly rotates around the edge.
                        // Paused under reduce-motion to avoid continuous redraws on low-resource Macs.
                        if self.reduceMotion || !self.contentState.isBottomOverlayPresented {
                            RoundedRectangle(cornerRadius: self.layout.cornerRadius)
                                .strokeBorder(
                                    AngularGradient(
                                        gradient: Gradient(stops: [
                                            .init(color: .white.opacity(0.06), location: 0.00),
                                            .init(color: .white.opacity(0.55), location: 0.13),
                                            .init(color: .white.opacity(0.10), location: 0.30),
                                            .init(color: .white.opacity(0.03), location: 0.55),
                                            .init(color: .white.opacity(0.22), location: 0.80),
                                            .init(color: .white.opacity(0.06), location: 1.00),
                                        ]),
                                        center: .center,
                                        angle: .degrees(0)
                                    ),
                                    lineWidth: 1.2
                                )
                        } else {
                            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                                let seconds = max(
                                    0,
                                    timeline.date.timeIntervalSince(self.borderAnimationStartedAt ?? timeline.date)
                                )
                                let angle = (seconds.truncatingRemainder(dividingBy: 6.0) / 6.0) * 360.0
                                RoundedRectangle(cornerRadius: self.layout.cornerRadius)
                                    .strokeBorder(
                                        AngularGradient(
                                            gradient: Gradient(stops: [
                                                .init(color: .white.opacity(0.06), location: 0.00),
                                                .init(color: .white.opacity(0.55), location: 0.13),
                                                .init(color: .white.opacity(0.10), location: 0.30),
                                                .init(color: .white.opacity(0.03), location: 0.55),
                                                .init(color: .white.opacity(0.22), location: 0.80),
                                                .init(color: .white.opacity(0.06), location: 1.00),
                                            ]),
                                            center: .center,
                                            angle: .degrees(angle)
                                        ),
                                        lineWidth: 1.2
                                    )
                            }
                        }
                    } else {
                        // Inner border
                        RoundedRectangle(cornerRadius: self.layout.cornerRadius)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(self.overlayBorderTopOpacity),
                                        Color.white.opacity(self.overlayBorderBottomOpacity),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: self.overlayBorderLineWidth
                            )
                    }
                }
            )
            .frame(maxWidth: .infinity, alignment: .top)
            .transaction { transaction in
                if self.shouldSuppressPreviewDuringRelease {
                    transaction.animation = nil
                }
            }
        }
        .frame(
            width: self.layout.usesFixedCanvas ? self.layout.overlayWidth : self.layout.containerWidth,
            height: self.overlayFrameHeight,
            alignment: .top
        )
        // Reserve space around the pill so its drop shadow isn't clipped by the (content-sized) window.
        .padding(self.isPillSize ? 26 : 0)
    }
}
