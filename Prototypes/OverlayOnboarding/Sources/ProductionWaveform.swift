import SwiftUI
struct BottomWaveformView: View {
    let color: Color
    let layout: BottomOverlayView.LayoutConstants
    let visibleBarCount: Int?
    private let contentState = FrozenOverlayState()
    private let barHeights: [CGFloat] = Array(repeating: 6, count: 11)
    private var barCount: Int {
        self.visibleBarCount ?? self.layout.barCount
    }

    private var barWidth: CGFloat {
        self.layout.barWidth
    }

    private var barSpacing: CGFloat {
        self.layout.barSpacing
    }

    private var minHeight: CGFloat {
        self.layout.minBarHeight
    }

    private var maxHeight: CGFloat {
        self.layout.maxBarHeight
    }

    private var isPillStyle: Bool {
        !self.layout.showsModeLabel
    }

    private var isProcessingVisualActive: Bool {
        self.contentState.isProcessing || self.isReleaseAnimationActive
    }

    private var currentGlowIntensity: CGFloat {
        if self.isPillStyle {
            return 0.0
        }
        return self.isProcessingVisualActive ? 0.0 : 0.5
    }

    private var currentGlowRadius: CGFloat {
        if self.isPillStyle {
            return 0.0
        }
        return self.isProcessingVisualActive ? 0.0 : 4
    }

    private var barFillColor: Color {
        if self.isPillStyle {
            return Color.white.opacity(self.isProcessingVisualActive ? 0.32 : 0.88)
        }
        return self.color.opacity(self.isProcessingVisualActive ? 0.16 : 1.0)
    }

    private var isReleaseAnimationActive: Bool {
        self.contentState.isBottomOverlayReleaseTransitioning || self.contentState.isBottomOverlayDismissing
    }

    private var barsView: some View {
        HStack(spacing: self.barSpacing) {
            ForEach(0..<self.barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: self.barWidth / 2)
                    .frame(width: self.barWidth, height: self.displayHeight(at: index))
                    .shadow(
                        color: self.color.opacity(self.isReleaseAnimationActive ? 0 : self.currentGlowIntensity),
                        radius: self.isReleaseAnimationActive ? 0 : self.currentGlowRadius,
                        x: 0,
                        y: 0
                    )
            }
        }
    }

    private func safeBarHeight(at index: Int) -> CGFloat {
        guard index >= 0 && index < self.barHeights.count else {
            return self.minHeight
        }
        return self.barHeights[index]
    }

    private func displayHeight(at index: Int) -> CGFloat {
        if self.isReleaseAnimationActive || self.contentState.isProcessing {
            return self.minHeight
        }
        return self.safeBarHeight(at: index)
    }
    var body: some View {
        ZStack {
            self.barsView
                .foregroundStyle(self.barFillColor)

            if self.isProcessingVisualActive {
                CompositorShimmerSweep(duration: 1.05, peakOpacity: 0.9)
                    .mask {
                        self.barsView
                    }
                    .shadow(color: .white.opacity(0.28), radius: 2.5, x: 0, y: 0)
            }
        }
    }
}
