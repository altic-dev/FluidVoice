import SwiftUI
import Combine

@MainActor
class MousePositionTracker: ObservableObject {
    @Published var mousePosition: CGPoint = .zero
    @Published var windowFrame: CGRect = .zero
    
    private var lastUpdateTime: TimeInterval = 0
    private var lastFrameUpdateTime: TimeInterval = 0
    private let updateInterval: TimeInterval = 1.0/15.0 // 15fps (reduced for performance during gestures)
    private let frameUpdateInterval: TimeInterval = 0.1 // Debounce frame updates during scroll
    
    var relativePosition: CGPoint {
        guard windowFrame.width > 0 && windowFrame.height > 0 else { return .zero }
        return CGPoint(
            x: (mousePosition.x - windowFrame.minX) / windowFrame.width,
            y: (mousePosition.y - windowFrame.minY) / windowFrame.height
        )
    }
    
    func updateMousePosition(_ position: CGPoint) {
        // Validate position to prevent infinity/NaN geometry errors
        guard position.x.isFinite && position.y.isFinite else { return }
        guard position.x >= 0 && position.y >= 0 else { return }
        
        let now = CACurrentMediaTime()
        guard now - lastUpdateTime >= updateInterval else { return }
        
        mousePosition = position
        lastUpdateTime = now
    }
    
    func updateWindowFrame(_ frame: CGRect) {
        // Validate frame to prevent infinity/NaN geometry errors
        guard frame.width.isFinite && frame.height.isFinite else { return }
        guard frame.minX.isFinite && frame.minY.isFinite else { return }
        guard frame.width > 0 && frame.height > 0 else { return }
        
        // Debounce frame updates during scroll to prevent rapid invalid geometry
        let now = CACurrentMediaTime()
        guard now - lastFrameUpdateTime >= frameUpdateInterval else { return }
        
        windowFrame = frame
        lastFrameUpdateTime = now
    }
}

struct MouseTrackingModifier: ViewModifier {
    let tracker: MousePositionTracker
    
    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    // Validate location is finite before processing
                    guard location.x.isFinite && location.y.isFinite else { return }
                    guard tracker.windowFrame != .zero else { return }
                    
                    // Convert to global coordinates for consistent tracking
                    let globalLocation = CGPoint(
                        x: location.x + tracker.windowFrame.minX,
                        y: location.y + tracker.windowFrame.minY
                    )
                    tracker.updateMousePosition(globalLocation)
                case .ended:
                    break
                }
            }
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            let globalFrame = geometry.frame(in: .global)
                            tracker.updateWindowFrame(globalFrame)
                        }
                        .onChange(of: geometry.frame(in: .global)) { _, newFrame in
                            // Skip updates when view is scrolled off-screen (prevents invalid geometry)
                            guard newFrame.minY < NSScreen.main?.frame.height ?? 1000 else { return }
                            guard newFrame.maxY > 0 else { return }
                            tracker.updateWindowFrame(newFrame)
                        }
                }
            )
    }
}

extension View {
    func withMouseTracking(_ tracker: MousePositionTracker) -> some View {
        self.modifier(MouseTrackingModifier(tracker: tracker))
    }
}