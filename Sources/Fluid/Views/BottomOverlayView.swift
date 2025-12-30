//
//  BottomOverlayView.swift
//  Fluid
//
//  Bottom overlay for transcription (alternative to notch overlay)
//

import AppKit
import Combine
import SwiftUI

// MARK: - Bottom Overlay Window Controller

@MainActor
final class BottomOverlayWindowController {
    static let shared = BottomOverlayWindowController()

    private var window: NSPanel?
    private var audioSubscription: AnyCancellable?

    private init() {
        NotificationCenter.default.addObserver(forName: NSNotification.Name("OverlayOffsetChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.positionWindow()
            }
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("OverlaySizeChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateSizeAndPosition()
            }
        }
    }

    func show(audioPublisher: AnyPublisher<CGFloat, Never>, mode: OverlayMode) {
        // Update mode in content state
        NotchContentState.shared.mode = mode
        NotchContentState.shared.updateTranscription("")
        NotchContentState.shared.bottomOverlayAudioLevel = 0

        // Subscribe to audio levels and route through NotchContentState
        self.audioSubscription?.cancel()
        self.audioSubscription = audioPublisher
            .receive(on: DispatchQueue.main)
            .sink { level in
                NotchContentState.shared.bottomOverlayAudioLevel = level
            }

        // Create window if needed
        if self.window == nil {
            self.createWindow()
        }

        // Position at bottom center of main screen
        self.positionWindow()

        // Show with animation
        self.window?.alphaValue = 0
        self.window?.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.window?.animator().alphaValue = 1
        }
    }

    func hide() {
        // Cancel audio subscription
        self.audioSubscription?.cancel()
        self.audioSubscription = nil

        // Reset state
        NotchContentState.shared.setProcessing(false)
        NotchContentState.shared.bottomOverlayAudioLevel = 0
        NotchContentState.shared.targetAppIcon = nil

        guard let window = window else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.window?.orderOut(nil)
        }
    }

    func setProcessing(_ processing: Bool) {
        NotchContentState.shared.setProcessing(processing)
    }

    /// Update window size based on current SwiftUI content and re-position
    private func updateSizeAndPosition() {
        guard let window = window, let hostingView = window.contentView as? NSHostingView<BottomOverlayView> else { return }

        // Re-calculate fitting size for the new layout constants
        let newSize = hostingView.fittingSize

        // Update window size
        window.setContentSize(newSize)
        hostingView.frame = NSRect(origin: .zero, size: newSize)

        // Re-position
        self.positionWindow()
    }

    private func createWindow() {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // SwiftUI handles shadow
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false

        let contentView = BottomOverlayView()
        let hostingView = NSHostingView(rootView: contentView)

        // Let SwiftUI determine the size
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)

        // Make hosting view fully transparent
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        panel.setContentSize(fittingSize)
        panel.contentView = hostingView

        self.window = panel
    }

    private func positionWindow() {
        // Safe check for window and screen availability
        guard let window = window else { return }

        // Use the screen that contains the window, or fallback to the main screen
        let screen = window.screen ?? NSScreen.main
        guard let screen = screen else { return }

        let fullFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let windowSize = window.frame.size

        // Horizontal centering
        let x = fullFrame.midX - windowSize.width / 2

        // Vertical positioning with safety clamping
        let offset = SettingsStore.shared.overlayBottomOffset

        // Calculate raw position
        var y = visibleFrame.minY + CGFloat(offset)

        // Safety Clamping:
        // 1. Min: Ensure it's at least visibleFrame.minY (not below the dock/visible area)
        // 2. Max: Ensure it doesn't cross the top of the visible frame minus its own height
        let minY = visibleFrame.minY + 10 // Small buffer from absolute bottom
        let maxY = visibleFrame.maxY - windowSize.height - 40 // Buffer from top

        y = max(min(y, maxY), minY)

        // Apply position using animator for smoother live transition if already visible
        if window.isVisible {
            window.animator().setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
}

// MARK: - Bottom Overlay SwiftUI View

struct BottomOverlayView: View {
    @ObservedObject private var contentState = NotchContentState.shared
    @ObservedObject private var settings = SettingsStore.shared

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

        static func get(for size: SettingsStore.OverlaySize) -> LayoutConstants {
            switch size {
            case .small:
                return LayoutConstants(
                    hPadding: 14,
                    vPadding: 8,
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
                    maxBarHeight: 16
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
                    barCount: 9,
                    barWidth: 3.5,
                    barSpacing: 4.5,
                    minBarHeight: 6,
                    maxBarHeight: 28
                )
            case .large:
                return LayoutConstants(
                    hPadding: 24,
                    vPadding: 18,
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
                    maxBarHeight: 44
                )
            }
        }
    }

    private var layout: LayoutConstants {
        LayoutConstants.get(for: self.settings.overlaySize)
    }

    private var modeColor: Color {
        self.contentState.mode.notchColor
    }

    private var modeLabel: String {
        switch self.contentState.mode {
        case .dictation: return "Dictate"
        case .rewrite: return "Rewrite"
        case .write: return "Write"
        case .command: return "Command"
        }
    }

    private var processingLabel: String {
        switch self.contentState.mode {
        case .dictation: return "Refining..."
        case .rewrite: return "Thinking..."
        case .write: return "Thinking..."
        case .command: return "Working..."
        }
    }

    private var hasTranscription: Bool {
        !self.contentState.transcriptionText.isEmpty
    }

    // Show last ~60 characters of transcription on single line
    private var transcriptionSuffix: String {
        let text = self.contentState.transcriptionText
        let maxChars = 60
        return text.count > maxChars ? "..." + String(text.suffix(maxChars)) : text
    }

    var body: some View {
        VStack(spacing: self.layout.vPadding / 2) {
            // Transcription text area (single line)
            Group {
                if self.hasTranscription && !self.contentState.isProcessing {
                    Text(self.transcriptionSuffix)
                        .font(.system(size: self.layout.transFontSize, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.head)
                } else if self.contentState.isProcessing {
                    Text(self.processingLabel)
                        .font(.system(size: self.layout.transFontSize, weight: .medium))
                        .foregroundStyle(self.modeColor.opacity(0.8))
                }
            }
            .frame(maxWidth: self.layout.waveformWidth * 2.2, minHeight: self.hasTranscription || self.contentState.isProcessing ? self.layout.transFontSize * 1.5 : 0)

            // Waveform + Mode label row
            HStack(spacing: self.layout.hPadding / 1.5) {
                // Target app icon (the app where text will be typed)
                if let appIcon = contentState.targetAppIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: self.layout.iconSize, height: self.layout.iconSize)
                        .clipShape(RoundedRectangle(cornerRadius: self.layout.iconSize / 4))
                }

                // Waveform visualization
                BottomWaveformView(color: self.modeColor, layout: self.layout)
                    .frame(width: self.layout.waveformWidth, height: self.layout.waveformHeight)

                // Mode label
                Text(self.modeLabel)
                    .font(.system(size: self.layout.modeFontSize, weight: .semibold))
                    .foregroundStyle(self.modeColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, self.layout.hPadding)
        .padding(.vertical, self.layout.vPadding)
        .background(
            ZStack {
                // Solid black background
                RoundedRectangle(cornerRadius: self.layout.cornerRadius)
                    .fill(Color.black)

                // Inner border
                RoundedRectangle(cornerRadius: self.layout.cornerRadius)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.15), .white.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
        )
        // TODO: Add tap-to-expand for command mode history (future enhancement)
        // .contentShape(Rectangle())
        // .onTapGesture {
        //     if contentState.mode == .command && !contentState.commandConversationHistory.isEmpty {
        //         NotchOverlayManager.shared.onNotchClicked?()
        //     }
        // }
        .animation(.easeInOut(duration: 0.15), value: self.hasTranscription)
        .animation(.easeInOut(duration: 0.2), value: self.contentState.mode)
        .animation(.easeInOut(duration: 0.2), value: self.contentState.isProcessing)
    }
}

// MARK: - Bottom Waveform View (reads from NotchContentState)

struct BottomWaveformView: View {
    let color: Color
    let layout: BottomOverlayView.LayoutConstants

    @ObservedObject private var contentState = NotchContentState.shared
    // Initialize with max possible bar count (11 for large) to prevent index-out-of-range before onAppear
    @State private var barHeights: [CGFloat] = Array(repeating: 6, count: 11)
    @State private var glowPhase: CGFloat = 0
    @State private var glowTimer: Timer? = nil
    @State private var noiseThreshold: CGFloat = .init(SettingsStore.shared.visualizerNoiseThreshold)

    private var barCount: Int { self.layout.barCount }
    private var barWidth: CGFloat { self.layout.barWidth }
    private var barSpacing: CGFloat { self.layout.barSpacing }
    private var minHeight: CGFloat { self.layout.minBarHeight }
    private var maxHeight: CGFloat { self.layout.maxBarHeight }

    private var currentGlowIntensity: CGFloat {
        self.contentState.isProcessing ? 0.6 + 0.3 * sin(self.glowPhase * .pi * 2) : 0.5
    }

    private var currentGlowRadius: CGFloat {
        self.contentState.isProcessing ? 5 + 7 * sin(self.glowPhase * .pi * 2) : 4
    }

    /// Safe accessor for bar heights to prevent index-out-of-range crashes
    private func safeBarHeight(at index: Int) -> CGFloat {
        guard index >= 0 && index < self.barHeights.count else {
            return self.minHeight
        }
        return self.barHeights[index]
    }

    var body: some View {
        HStack(spacing: self.barSpacing) {
            ForEach(0..<self.barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: self.barWidth / 2)
                    .fill(self.color)
                    .frame(width: self.barWidth, height: self.safeBarHeight(at: index))
                    .shadow(color: self.color.opacity(self.currentGlowIntensity), radius: self.currentGlowRadius, x: 0, y: 0)
            }
        }
        .onChange(of: self.contentState.bottomOverlayAudioLevel) { _, level in
            if !self.contentState.isProcessing {
                self.updateBars(level: level)
            }
        }
        .onChange(of: self.contentState.isProcessing) { _, processing in
            if processing {
                self.setStaticProcessingBars()
                self.startGlowAnimation()
            } else {
                self.stopGlowAnimation()
            }
        }
        .onChange(of: self.layout.barCount) { _, newCount in
            self.barHeights = Array(repeating: self.minHeight, count: newCount)
        }
        .onAppear {
            // Ensure bar count matches current layout
            if self.barHeights.count != self.barCount {
                self.barHeights = Array(repeating: self.minHeight, count: self.barCount)
            }
            if self.contentState.isProcessing {
                self.setStaticProcessingBars()
                self.startGlowAnimation()
            } else {
                self.updateBars(level: 0)
            }
        }
        .onDisappear {
            self.stopGlowAnimation()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            // Update threshold when user changes sensitivity setting
            let newThreshold = CGFloat(SettingsStore.shared.visualizerNoiseThreshold)
            if newThreshold != self.noiseThreshold {
                self.noiseThreshold = newThreshold
            }
        }
    }

    private func startGlowAnimation() {
        self.stopGlowAnimation()
        self.glowPhase = 0

        self.glowTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            withAnimation(.linear(duration: 1.0 / 30.0)) {
                self.glowPhase += 1.0 / 30.0 / 1.5
                if self.glowPhase >= 1.0 {
                    self.glowPhase = 0
                }
            }
        }
    }

    private func stopGlowAnimation() {
        self.glowTimer?.invalidate()
        self.glowTimer = nil
        self.glowPhase = 0
    }

    private func setStaticProcessingBars() {
        // Ensure array is properly sized before modifying
        guard self.barHeights.count >= self.barCount else { return }

        withAnimation(.easeInOut(duration: 0.3)) {
            for i in 0..<self.barCount {
                let centerDistance = abs(CGFloat(i) - CGFloat(self.barCount - 1) / 2)
                let centerFactor = 1.0 - (centerDistance / CGFloat(self.barCount / 2)) * 0.35
                self.barHeights[i] = self.minHeight + (self.maxHeight - self.minHeight) * 0.5 * centerFactor
            }
        }
    }

    private func updateBars(level: CGFloat) {
        // Ensure array is properly sized before modifying
        guard self.barHeights.count >= self.barCount else { return }

        let normalizedLevel = min(max(level, 0), 1)
        let isActive = normalizedLevel > self.noiseThreshold // Use user's sensitivity setting

        withAnimation(.spring(response: 0.08, dampingFraction: 0.55)) {
            for i in 0..<self.barCount {
                let centerDistance = abs(CGFloat(i) - CGFloat(self.barCount - 1) / 2)
                let centerFactor = 1.0 - (centerDistance / CGFloat(self.barCount / 2)) * 0.3

                if isActive, self.noiseThreshold < 1.0 {
                    // Amplify the level for more dramatic response
                    // Safety check: ensure denominator is never zero
                    let denominator = max(1.0 - self.noiseThreshold, 0.001)
                    let adjustedLevel = max(min((normalizedLevel - self.noiseThreshold) / denominator, 1.0), 0.0)

                    let amplifiedLevel = pow(adjustedLevel, 0.6) // More responsive to quieter sounds
                    let randomVariation = CGFloat.random(in: 0.8...1.0)
                    self.barHeights[i] = self.minHeight + (self.maxHeight - self.minHeight) * amplifiedLevel * centerFactor * randomVariation
                } else {
                    self.barHeights[i] = self.minHeight
                }
            }
        }
    }
}
