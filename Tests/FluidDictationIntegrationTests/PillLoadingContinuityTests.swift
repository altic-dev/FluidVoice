import AppKit
import Combine
@testable import FluidVoice_Debug
import QuartzCore
import SwiftUI
import XCTest

final class PillLoadingContinuityTests: XCTestCase {
    @MainActor
    func testFreezeDoesNotStartLoadingInAHiddenBottomOverlay() {
        let settings = SettingsStore.shared
        let previous = settings.overlaySize
        let controller = BottomOverlayWindowController.shared
        defer {
            settings.overlaySize = previous
            OverlayAudioLevelState.shared.isFrozenForStop = false
        }
        settings.overlaySize = .pill
        controller.hideImmediately()
        controller.endReleaseTransition(flushDeferredUpdate: false)
        NotchContentState.shared.setBottomOverlayPresented(false)
        controller.freezeForStop()
        XCTAssertFalse(NotchContentState.shared.isBottomOverlayReleaseTransitioning)
        XCTAssertFalse(OverlayAudioLevelState.shared.isFrozenForStop)
        XCTAssertFalse(PillSpectrumPipeline.shared.isVisible)
    }

    @MainActor
    func testUpstreamLoadingIdentityAndLifecycle() async throws {
        let settings = SettingsStore.shared
        let oldSize = settings.overlaySize
        settings.overlaySize = .pill
        let controller = BottomOverlayWindowController.shared
        let state = NotchContentState.shared
        defer {
            controller.hideImmediately()
            state.updateTranscription("")
            settings.overlaySize = oldSize
        }
        controller.show(audioPublisher: Just(CGFloat(0.6)).eraseToAnyPublisher(), mode: .dictation)
        OverlayAudioLevelState.shared.isLive = true
        try await Task.sleep(nanoseconds: 200_000_000)
        controller.freezeForStop()
        XCTAssertTrue(OverlayAudioLevelState.shared.isFrozenForStop)
        XCTAssertFalse(PillSpectrumPipeline.shared.isVisible)
        // Longer than the release bridge: pending processing must still shimmer.
        try await Task.sleep(nanoseconds: 500_000_000)
        func findSweep(_ view: NSView) -> CompositorShimmerSweepView? {
            if let sweep = view as? CompositorShimmerSweepView {
                return sweep
            }
            return view.subviews.lazy.compactMap { findSweep($0) }.first
        }
        let sweep = try XCTUnwrap(NSApp.windows.compactMap { $0.contentView.flatMap(findSweep) }.first)
        let gradient = try XCTUnwrap(sweep.layer?.sublayers?.first as? CAGradientLayer)
        let animation = try XCTUnwrap(gradient.animation(forKey: "fluid.shimmer.locations") as? CABasicAnimation)
        XCTAssertEqual(animation.duration, 1.05, accuracy: 0.0001)
        XCTAssertEqual(animation.repeatCount, .infinity)
        XCTAssertEqual(animation.fromValue as? [Double], [-0.45, -0.15, 0.15])
        XCTAssertEqual(animation.toValue as? [Double], [0.85, 1.15, 1.45])
        let colors = try XCTUnwrap(gradient.colors as? [CGColor])
        XCTAssertEqual(colors.first?.alpha, 0)
        XCTAssertEqual(colors[1].alpha, 0.9, accuracy: 0.001)
        let identity = ObjectIdentifier(sweep)
        controller.setProcessing(true)
        for _ in 0..<3 {
            controller.setProcessing(true)
            state.updateTranscription("processing phase update")
            try await Task.sleep(nanoseconds: 400_000_000)
            let current = try XCTUnwrap(NSApp.windows.compactMap { $0.contentView.flatMap(findSweep) }.first)
            XCTAssertEqual(ObjectIdentifier(current), identity)
            XCTAssertNotNil(gradient.animation(forKey: "fluid.shimmer.locations"))
        }
        print("PILL_LOADING_BASELINE duration=\(animation.duration) bounds=\(sweep.bounds) identityStable=true mask=8x3 gap=2.5 height=4")
        if ProcessInfo.processInfo.environment["PILL_VISUAL_HOLD"] == "1" {
            let preview = NSWindow(
                contentRect: NSRect(x: 250, y: 300, width: 360, height: 180),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            preview.title = "Pill loading baseline"
            preview.contentView = NSHostingView(rootView:
                BottomWaveformView(color: .white, layout: .get(for: .pill), visibleBarCount: nil)
                    .frame(width: 46, height: 30).padding(12).background(.black)
                    .scaleEffect(3).frame(width: 360, height: 180))
            preview.makeKeyAndOrderFront(nil)
            try await Task.sleep(nanoseconds: 20_000_000_000)
            preview.orderOut(nil)
        }
        controller.setProcessing(false)
        _ = await controller.hideAndWait()
        XCTAssertTrue(controller.isVisuallyHiddenForTests)
        controller.show(audioPublisher: Just(CGFloat.zero).eraseToAnyPublisher(), mode: .dictation)
        XCTAssertFalse(state.isProcessing)
        XCTAssertFalse(state.isBottomOverlayReleaseTransitioning)
        XCTAssertFalse(OverlayAudioLevelState.shared.isFrozenForStop)
        // Fast completion and cancellation cannot leave a frozen layer in the next session.
        controller.freezeForStop()
        controller.setProcessing(true)
        controller.hideImmediately()
        controller.show(audioPublisher: Just(CGFloat.zero).eraseToAnyPublisher(), mode: .dictation)
        XCTAssertFalse(OverlayAudioLevelState.shared.isFrozenForStop)
        XCTAssertTrue(PillSpectrumPipeline.shared.isVisible)
        controller.hideImmediately()
    }
}
