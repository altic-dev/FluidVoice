import Combine
import SwiftUI

@MainActor
class MousePositionTracker: ObservableObject {
    @Published var mousePosition: CGPoint = .zero
    @Published var windowFrame: CGRect = .zero

    private var lastUpdateTime: TimeInterval = 0
    private var lastFrameUpdateTime: TimeInterval = 0
    private let updateInterval: TimeInterval = 1.0 / 15.0 // 15fps (reduced for performance during gestures)
    private let frameUpdateInterval: TimeInterval = 0.1 // Debounce frame updates during scroll

    var relativePosition: CGPoint {
        guard self.windowFrame.width > 0 && self.windowFrame.height > 0 else { return .zero }
        return CGPoint(
            x: (self.mousePosition.x - self.windowFrame.minX) / self.windowFrame.width,
            y: (self.mousePosition.y - self.windowFrame.minY) / self.windowFrame.height
        )
    }

    func updateMousePosition(_ position: CGPoint) {
        // Validate position to prevent infinity/NaN geometry errors
        guard position.x.isFinite, position.y.isFinite else { return }
        guard position.x >= 0, position.y >= 0 else { return }

        let now = CACurrentMediaTime()
        guard now - self.lastUpdateTime >= self.updateInterval else { return }

        self.mousePosition = position
        self.lastUpdateTime = now
    }

    func updateWindowFrame(_ frame: CGRect) {
        // Validate frame to prevent infinity/NaN geometry errors
        guard frame.width.isFinite, frame.height.isFinite else { return }
        guard frame.minX.isFinite, frame.minY.isFinite else { return }
        guard frame.width > 0, frame.height > 0 else { return }

        // Debounce frame updates during scroll to prevent rapid invalid geometry
        let now = CACurrentMediaTime()
        guard now - self.lastFrameUpdateTime >= self.frameUpdateInterval else { return }

        self.windowFrame = frame
        self.lastFrameUpdateTime = now
    }
}

struct MouseTrackingModifier: ViewModifier {
    let tracker: MousePositionTracker

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    // Validate location is finite before processing
                    guard location.x.isFinite && location.y.isFinite else { return }
                    guard self.tracker.windowFrame != .zero else { return }

                    // Convert to global coordinates for consistent tracking
                    let globalLocation = CGPoint(
                        x: location.x + self.tracker.windowFrame.minX,
                        y: location.y + self.tracker.windowFrame.minY
                    )
                    self.tracker.updateMousePosition(globalLocation)
                case .ended:
                    break
                }
            }
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        let globalFrame = geometry.frame(in: .global)
                        self.tracker.updateWindowFrame(globalFrame)
                    }
                    .onChange(of: geometry.frame(in: .global)) { _, newFrame in
                        // Skip updates when view is scrolled off-screen (prevents invalid geometry)
                        guard newFrame.minY < NSScreen.main?.frame.height ?? 1000 else { return }
                        guard newFrame.maxY > 0 else { return }
                        self.tracker.updateWindowFrame(newFrame)
                    }
            })
    }
}

extension View {
    func withMouseTracking(_ tracker: MousePositionTracker) -> some View {
        modifier(MouseTrackingModifier(tracker: tracker))
    }
}
