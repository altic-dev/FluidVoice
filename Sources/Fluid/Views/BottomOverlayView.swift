//
//  BottomOverlayView.swift
//  Fluid
//
//  Bottom overlay for transcription
//

import SwiftUI
import Combine
import AppKit

// MARK: - Bottom Overlay Window Controller

@MainActor
final class BottomOverlayWindowController {
    static let shared = BottomOverlayWindowController()

    private var window: NSPanel?
    private var audioSubscription: AnyCancellable?

    private init() {}

    func show(audioPublisher: AnyPublisher<CGFloat, Never>, mode: OverlayMode) {
        // Update mode in content state
        NotchContentState.shared.mode = mode
        NotchContentState.shared.updateTranscription("")
        NotchContentState.shared.bottomOverlayAudioLevel = 0

        // Subscribe to audio levels and route through NotchContentState
        audioSubscription?.cancel()
        audioSubscription = audioPublisher
            .receive(on: DispatchQueue.main)
            .sink { level in
                NotchContentState.shared.bottomOverlayAudioLevel = level
            }

        // Create window if needed
        if window == nil {
            createWindow()
        }

        // Position at bottom center of main screen
        positionWindow()

        // Show with animation
        window?.alphaValue = 0
        window?.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window?.animator().alphaValue = 1
        }
    }

    func hide() {
        // Cancel audio subscription
        audioSubscription?.cancel()
        audioSubscription = nil

        // Reset state
        NotchContentState.shared.setProcessing(false)
        NotchContentState.shared.bottomOverlayAudioLevel = 0

        guard let window = window else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.window?.orderOut(nil)
        })
    }

    func setProcessing(_ processing: Bool) {
        NotchContentState.shared.setProcessing(processing)
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
        panel.hasShadow = false  // SwiftUI handles shadow
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
        guard let window = window, let screen = NSScreen.main else { return }

        let fullFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let windowSize = window.frame.size

        let x = fullFrame.midX - windowSize.width / 2
        let y = visibleFrame.minY + 80

        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Bottom Overlay SwiftUI View

struct BottomOverlayView: View {
    @ObservedObject private var contentState = NotchContentState.shared

    private var modeColor: Color {
        contentState.mode.notchColor
    }

    private var modeLabel: String {
        switch contentState.mode {
        case .dictation: return "Dictate"
        case .rewrite: return "Rewrite"
        case .write: return "Write"
        case .command: return "Command"
        }
    }

    private var processingLabel: String {
        switch contentState.mode {
        case .dictation: return "Refining..."
        case .rewrite: return "Thinking..."
        case .write: return "Thinking..."
        case .command: return "Working..."
        }
    }

    private var hasTranscription: Bool {
        !contentState.transcriptionText.isEmpty
    }

    // Show last ~60 characters of transcription on single line
    private var transcriptionSuffix: String {
        let text = contentState.transcriptionText
        let maxChars = 60
        return text.count > maxChars ? "..." + String(text.suffix(maxChars)) : text
    }

    var body: some View {
        VStack(spacing: 10) {
            // Transcription text area (single line)
            Group {
                if hasTranscription && !contentState.isProcessing {
                    Text(transcriptionSuffix)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.head)
                } else if contentState.isProcessing {
                    Text(processingLabel)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(modeColor.opacity(0.8))
                } else {
                    // Placeholder when no text yet
                    Text("Listening...")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(maxWidth: 300, minHeight: 22)

            // Waveform + Mode label row
            HStack(spacing: 14) {
                // Waveform visualization
                BottomWaveformView(color: modeColor)
                    .frame(width: 160, height: 48)

                // Mode label
                Text(modeLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(modeColor)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(
            ZStack {
                // Solid black background
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.black)

                // Inner border with same radius
                RoundedRectangle(cornerRadius: 24)
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
        .animation(.easeInOut(duration: 0.15), value: hasTranscription)
        .animation(.easeInOut(duration: 0.2), value: contentState.mode)
        .animation(.easeInOut(duration: 0.2), value: contentState.isProcessing)
    }
}

// MARK: - Bottom Waveform View (reads from NotchContentState)

struct BottomWaveformView: View {
    let color: Color

    @ObservedObject private var contentState = NotchContentState.shared
    @State private var barHeights: [CGFloat] = Array(repeating: 8, count: 11)
    @State private var glowPhase: CGFloat = 0
    @State private var glowTimer: Timer? = nil

    private let barCount = 11
    private let barWidth: CGFloat = 5
    private let barSpacing: CGFloat = 6
    private let minHeight: CGFloat = 8
    private let maxHeight: CGFloat = 44
    private let noiseThreshold: CGFloat = 0.02

    private var currentGlowIntensity: CGFloat {
        contentState.isProcessing ? 0.6 + 0.3 * sin(glowPhase * .pi * 2) : 0.5
    }

    private var currentGlowRadius: CGFloat {
        contentState.isProcessing ? 5 + 7 * sin(glowPhase * .pi * 2) : 4
    }

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(color)
                    .frame(width: barWidth, height: barHeights[index])
                    .shadow(color: color.opacity(currentGlowIntensity), radius: currentGlowRadius, x: 0, y: 0)
            }
        }
        .onChange(of: contentState.bottomOverlayAudioLevel) { level in
            if !contentState.isProcessing {
                updateBars(level: level)
            }
        }
        .onChange(of: contentState.isProcessing) { processing in
            if processing {
                setStaticProcessingBars()
                startGlowAnimation()
            } else {
                stopGlowAnimation()
            }
        }
        .onAppear {
            if contentState.isProcessing {
                setStaticProcessingBars()
                startGlowAnimation()
            } else {
                updateBars(level: 0)
            }
        }
        .onDisappear {
            stopGlowAnimation()
        }
    }

    private func startGlowAnimation() {
        stopGlowAnimation()
        glowPhase = 0

        glowTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            withAnimation(.linear(duration: 1.0 / 30.0)) {
                glowPhase += 1.0 / 30.0 / 1.5
                if glowPhase >= 1.0 {
                    glowPhase = 0
                }
            }
        }
    }

    private func stopGlowAnimation() {
        glowTimer?.invalidate()
        glowTimer = nil
        glowPhase = 0
    }

    private func setStaticProcessingBars() {
        withAnimation(.easeInOut(duration: 0.3)) {
            for i in 0..<barCount {
                let centerDistance = abs(CGFloat(i) - CGFloat(barCount - 1) / 2)
                let centerFactor = 1.0 - (centerDistance / CGFloat(barCount / 2)) * 0.35
                barHeights[i] = minHeight + (maxHeight - minHeight) * 0.5 * centerFactor
            }
        }
    }

    private func updateBars(level: CGFloat) {
        let normalizedLevel = min(max(level, 0), 1)
        let isActive = normalizedLevel > noiseThreshold

        withAnimation(.spring(response: 0.08, dampingFraction: 0.55)) {
            for i in 0..<barCount {
                let centerDistance = abs(CGFloat(i) - CGFloat(barCount - 1) / 2)
                let centerFactor = 1.0 - (centerDistance / CGFloat(barCount / 2)) * 0.3

                if isActive {
                    // Amplify the level for more dramatic response
                    let adjustedLevel = (normalizedLevel - noiseThreshold) / (1.0 - noiseThreshold)
                    let amplifiedLevel = pow(adjustedLevel, 0.6)  // More responsive to quieter sounds
                    let randomVariation = CGFloat.random(in: 0.8...1.0)
                    barHeights[i] = minHeight + (maxHeight - minHeight) * amplifiedLevel * centerFactor * randomVariation
                } else {
                    barHeights[i] = minHeight
                }
            }
        }
    }
}
