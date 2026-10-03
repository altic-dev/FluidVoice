import AppKit
@testable import FluidVoice_Debug
import SwiftUI
import XCTest

@MainActor
final class HoldToMutePresentationTests: XCTestCase {
    func testMutedOverlayFitsEverySizeAndPreservesPreview() throws {
        let state = NotchContentState.shared
        let settings = SettingsStore.shared
        let priorSize = settings.overlaySize
        let priorMuted = state.isDictationMuted
        let priorText = state.transcriptionText
        let priorProcessing = state.isProcessing
        let priorMode = state.mode
        defer {
            settings.overlaySize = priorSize
            state.isDictationMuted = priorMuted
            state.updateTranscription(priorText)
            state.isProcessing = priorProcessing
            state.mode = priorMode
        }
        state.mode = .dictation
        state.isProcessing = false
        state.isDictationMuted = true
        state.updateTranscription("This is the thought I want to keep.")

        for size in SettingsStore.OverlaySize.allCases {
            settings.overlaySize = size
            for scheme in [ColorScheme.light, .dark] {
                let layout = BottomOverlayView.LayoutConstants.get(for: size)
                let view = BottomOverlayView()
                    .padding(24)
                    .frame(width: max(400, layout.overlayWidth + 48), height: max(220, layout.overlayHeight + 80))
                    .background(scheme == .dark ? Color(white: 0.08) : Color(white: 0.94))
                    .appTheme(.adaptive(accent: FluidBrandColors.blue, colorScheme: scheme))
                    .environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: view)
                host.frame.size = host.fittingSize
                host.layoutSubtreeIfNeeded()
                XCTAssertTrue(host.frame.width.isFinite)
                XCTAssertTrue(host.frame.height.isFinite)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "hold-to-mute-\(size.rawValue)-\(scheme)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        XCTAssertEqual(state.transcriptionText, "This is the thought I want to keep.")
        XCTAssertTrue(state.isDictationMuted)
    }
}
