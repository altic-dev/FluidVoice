import AppKit
import Combine
@testable import FluidVoice_Debug
import SwiftUI
import XCTest

@MainActor
final class OverlayCaptionPresentationTests: XCTestCase {
    private func animationState(_ layer: CALayer?) -> String {
        guard let layer else { return "no layer" }
        return (layer.animationKeys() ?? []).map { key in
            guard let animation = layer.animation(forKey: key) else { return key }
            return "\(key): begin=\(animation.beginTime), duration=\(animation.duration), localNow=\(layer.convertTime(CACurrentMediaTime(), from: nil)), speed=\(layer.speed), removed=\(animation.isRemovedOnCompletion)"
        }.joined(separator: "; ")
    }

    private func waitForAnimationRemoval(_ layer: CALayer?, key: String) async throws {
        let layer = try XCTUnwrap(layer)
        let deadline = CACurrentMediaTime() + 1
        // The presentation can finish before Core Animation retires its client-side
        // animation record. Check the visual deadline separately, then drain commits.
        while layer.animation(forKey: key) != nil, CACurrentMediaTime() < deadline {
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(layer.animation(forKey: key), self.animationState(layer))
    }

    private func visibilityState(_ view: NSView) -> String {
        "hidden=\(view.isHiddenOrHasHiddenAncestor), frame=\(view.frame), visible=\(view.window?.isVisible ?? false), alpha=\(view.window?.alphaValue ?? 0), " +
            "occlusion=\(view.window?.occlusionState.rawValue ?? 0), reduceMotion=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)"
    }

    func testQueuedAppActivationDoesNotRestoreTheDismissedTarget() async {
        let monitor = ActiveAppMonitor.shared
        let state = NotchContentState.shared
        let previousIcon = state.targetAppIcon
        defer { monitor.stopMonitoring(); state.targetAppIcon = previousIcon }
        monitor.startMonitoring()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        monitor.stopMonitoring()
        state.targetAppIcon = nil
        await Task.yield()
        await Task.yield()
        XCTAssertNil(monitor.activeApp)
        XCTAssertNil(monitor.activeAppIcon)
        XCTAssertNil(state.targetAppIcon, "An already queued activation must not repopulate a dismissed overlay")
    }

    func testDismissCancelsACommandPanelThatHasNotOpenedYet() async throws {
        let settings = SettingsStore.shared
        let previousPosition = settings.overlayPosition
        let previousMode = settings.notchPresentationMode
        let manager = NotchOverlayManager.shared
        defer {
            manager.hideExpandedCommandOutput()
            settings.overlayPosition = previousPosition
            settings.notchPresentationMode = previousMode
        }
        settings.overlayPosition = .top
        settings.notchPresentationMode = .standard
        XCTAssertTrue(manager.canShowExpandedCommandOutput)
        for _ in 0..<3 {
            manager.showExpandedCommandOutput()
            XCTAssertTrue(manager.hasCommandOutputToDismiss, "Escape and mode changes must recognize the pending panel")
            manager.hideExpandedCommandOutput()
            XCTAssertFalse(manager.hasCommandOutputToDismiss)
        }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(manager.isCommandOutputExpanded, "A canceled delayed presentation must not reopen the command panel")
        XCTAssertFalse(NotchContentState.shared.isExpandedForCommandOutput)
        manager.showExpandedCommandOutput()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(manager.isCommandOutputExpanded, "Cancellation must not block a fresh presentation")
        manager.hideExpandedCommandOutput()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(manager.isCommandOutputExpanded)
    }

    func testNewRecordingSupersedesPendingCommandOutput() async throws {
        let settings = SettingsStore.shared
        let previousPosition = settings.overlayPosition
        let previousMode = settings.notchPresentationMode
        let manager = NotchOverlayManager.shared
        defer {
            manager.hideImmediately()
            manager.hideExpandedCommandOutput()
            settings.overlayPosition = previousPosition
            settings.notchPresentationMode = previousMode
        }
        settings.overlayPosition = .bottom
        settings.notchPresentationMode = .standard
        manager.showExpandedCommandOutput()
        manager.show(audioLevelPublisher: Just(CGFloat.zero).eraseToAnyPublisher(), mode: .dictation)
        manager.updateTranscriptionText("The new dictation owns the preview")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(manager.isCommandOutputExpanded)
        XCTAssertFalse(manager.hasCommandOutputToDismiss)
        XCTAssertTrue(manager.isBottomOverlayVisible)
        XCTAssertEqual(NotchContentState.shared.mode, .dictation)
        XCTAssertEqual(NotchContentState.shared.transcriptionText, "The new dictation owns the preview")
        manager.hideImmediately()
        try await Task.sleep(for: .milliseconds(150))
    }

    func testManagerHideStopsHiddenUpdatesAndDoesNotResizeTheParkedPanel() async throws {
        let settings = SettingsStore.shared
        let state = NotchContentState.shared
        let previousPosition = settings.overlayPosition
        let previousSize = settings.overlaySize
        let previousPreview = settings.enableStreamingPreview
        let manager = NotchOverlayManager.shared
        let controller = BottomOverlayWindowController.shared
        let levels = PassthroughSubject<CGFloat, Never>()
        defer {
            manager.hideImmediately()
            settings.overlayPosition = previousPosition
            settings.overlaySize = previousSize
            settings.enableStreamingPreview = previousPreview
        }
        settings.overlayPosition = .bottom
        settings.overlaySize = .medium
        settings.enableStreamingPreview = true
        manager.show(audioLevelPublisher: levels.eraseToAnyPublisher(), mode: .dictation)
        manager.updateTranscriptionText("These pending words must stop when the whole dictation overlay has finished its work.")
        manager.setProcessing(true)
        try await Task.sleep(for: .milliseconds(40))
        manager.hideImmediately()
        XCTAssertTrue(controller.isVisuallyHiddenForTests)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(state.isBottomOverlayPresented, "The manager must preserve bottom-panel cleanup")
        XCTAssertFalse(state.isProcessing)
        XCTAssertFalse(state.isBottomOverlayDismissing)
        XCTAssertFalse(state.isBottomOverlayReleaseTransitioning)
        let panel = try XCTUnwrap(controller.contentViewForTests?.window)
        let anchor = CGRect(x: panel.frame.minX + 10, y: panel.frame.minY + 10, width: 80, height: 24)
        let visibleWindows = Set(NSApp.windows.filter { $0.isVisible && $0.alphaValue > 0 }.map(\.windowNumber))
        BottomOverlayPromptMenuController.shared.updateAnchor(selectorFrameInScreen: anchor, parentWindow: panel, maxWidth: 220, menuGap: 6)
        BottomOverlayModeMenuController.shared.updateAnchor(selectorFrameInScreen: anchor, parentWindow: panel, maxWidth: 220, menuGap: 6)
        BottomOverlayActionsMenuController.shared.updateAnchor(selectorFrameInScreen: anchor, parentWindow: panel, maxWidth: 220, menuGap: 6)
        BottomOverlayPromptMenuController.shared.toggleFromTap()
        BottomOverlayModeMenuController.shared.toggleFromTap()
        BottomOverlayActionsMenuController.shared.toggleFromTap()
        XCTAssertEqual(Set(NSApp.windows.filter { $0.isVisible && $0.alphaValue > 0 }.map(\.windowNumber)), visibleWindows, "A late menu action must not reopen controls from a hidden overlay")
        let parkedSize = controller.windowSizeForTests
        levels.send(0.9)
        settings.overlaySize = .large
        controller.refreshSizeForContent()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(OverlayAudioLevelState.shared.level, 0, "Hidden panels must unsubscribe from audio levels")
        XCTAssertEqual(controller.windowSizeForTests, parkedSize, "Settings and stale resize requests must not lay out a hidden panel")
        manager.show(audioLevelPublisher: levels.eraseToAnyPublisher(), mode: .dictation)
        manager.hideImmediately()
        manager.show(audioLevelPublisher: levels.eraseToAnyPublisher(), mode: .dictation)
        manager.updateTranscriptionText("Only the new recording may remain visible")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(state.isBottomOverlayPresented)
        XCTAssertFalse(controller.isVisuallyHiddenForTests)
        XCTAssertEqual(state.transcriptionText, "Only the new recording may remain visible")
        manager.hideImmediately()
        try await Task.sleep(for: .milliseconds(200))
    }

    func testProcessingShimmerStopsAcrossEveryBottomSize() async throws {
        let settings = SettingsStore.shared
        let state = NotchContentState.shared
        let previousPosition = settings.overlayPosition
        let previousSize = settings.overlaySize
        let previousProcessing = state.isProcessing
        let controller = BottomOverlayWindowController.shared
        let manager = NotchOverlayManager.shared
        defer {
            manager.hideImmediately()
            settings.overlayPosition = previousPosition
            settings.overlaySize = previousSize
            state.isProcessing = previousProcessing
        }
        settings.overlayPosition = .bottom
        func shimmers(in view: NSView) -> [CompositorShimmerSweepView] {
            (view as? CompositorShimmerSweepView).map { [$0] } ?? view.subviews.flatMap { shimmers(in: $0) }
        }
        for size in [SettingsStore.OverlaySize.pill, .small, .medium, .large] {
            settings.overlaySize = size
            // Use the recording entry point so a previous manager hide cannot
            // clear this presentation after its transaction finishes.
            manager.show(audioLevelPublisher: Just(CGFloat.zero).eraseToAnyPublisher(), mode: .dictation)
            controller.setProcessing(true)
            try await Task.sleep(for: .milliseconds(180))
            let host = try XCTUnwrap(controller.contentViewForTests)
            XCTAssertEqual(host.frame.size, host.superview?.bounds.size, "Hosting content must fit its window after every preset change")
            if size == .pill {
                let container = try XCTUnwrap(host.window?.contentView)
                XCTAssertNil(container.hitTest(NSPoint(x: 1, y: 1)), "Transparent padding must not intercept clicks")
                XCTAssertNotNil(container.hitTest(NSPoint(x: container.bounds.midX, y: container.bounds.midY)), "Visible pill controls must remain clickable")
            }
            let waitingViews = shimmers(in: host)
            XCTAssertFalse(waitingViews.isEmpty, "Exercise the real waiting view for \(size): \(self.visibilityState(host)), processing=\(state.isProcessing), muted=\(state.isDictationMuted)")
            let visibility = waitingViews.map { self.visibilityState($0) }.joined(separator: "; ")
            let hasAnimation = waitingViews.contains { $0.layer?.sublayers?.first?.animation(forKey: "fluid.shimmer.locations") != nil }
            XCTAssertEqual(hasAnimation, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Processing must respect Reduce Motion for \(size): \(visibility)")
            XCTAssertTrue(state.isProcessing, "A previous presentation must not clear this processing state")
            if let output = ProcessInfo.processInfo.environment["CAPTION_TEST_OUTPUT"] {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("processing-\(size.rawValue).png"))
            }
            manager.hideImmediately()
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertFalse(state.isBottomOverlayPresented)
            XCTAssertTrue(waitingViews.allSatisfy { $0.layer?.sublayers?.first?.animationKeys()?.isEmpty != false }, "No waiting shimmer may survive dismissal for \(size)")
        }
    }

    func testWaitingShimmerStopsWhenItsViewOrWindowIsHidden() async throws {
        let view = CompositorShimmerSweepView(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(50))
        let gradient = try XCTUnwrap(view.layer?.sublayers?.first)
        XCTAssertNotNil(gradient.animation(forKey: "fluid.shimmer.locations"))
        window.alphaValue = 0
        XCTAssertNil(gradient.animation(forKey: "fluid.shimmer.locations"), "A cached alpha-zero panel must stop immediately")
        window.alphaValue = 1
        XCTAssertNotNil(gradient.animation(forKey: "fluid.shimmer.locations"))
        view.isHidden = true
        XCTAssertNil(gradient.animation(forKey: "fluid.shimmer.locations"), "A retained hidden view must stop its infinite shimmer")
        view.isHidden = false
        XCTAssertNotNil(gradient.animation(forKey: "fluid.shimmer.locations"))
        window.orderOut(nil)
        XCTAssertNil(gradient.animation(forKey: "fluid.shimmer.locations"), "Ordering out a retained window must stop the shimmer")
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(gradient.animation(forKey: "fluid.shimmer.locations"))
        view.configure(duration: 1, peakOpacity: 0.88, isActive: false)
        XCTAssertNil(gradient.animation(forKey: "fluid.shimmer.locations"), "Inactive and Reduce Motion presentations must remain static")
        view.configure(duration: 1, peakOpacity: 0.88, isActive: true)
        XCTAssertNotNil(gradient.animation(forKey: "fluid.shimmer.locations"))
        window.contentView = nil
        XCTAssertNil(gradient.animation(forKey: "fluid.shimmer.locations"))
    }

    func testRetainedVisibleLineUpdatesWhenTheShortPreviewIsUnchanged() async throws {
        let view = OverlayCaptionNSView(frame: CGRect(x: 0, y: 0, width: 304, height: 54))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { view.stopScrolling(); window.orderOut(nil); window.contentView = nil; window.close() }
        func drawnLines(_ text: String) async throws -> [Data] {
            view.update(caption: .tail(text, limit: 50), context: .tail(text, limit: 800), fontSize: 13, opacity: 1, reduceMotion: true)
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 304,
                pixelsHigh: 54,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ))
            let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            try XCTUnwrap(view.layer?.presentation()).render(in: graphics.cgContext)
            let pixels = try XCTUnwrap(bitmap.bitmapData)
            return (0..<3).map { line in
                Data(bytes: pixels.advanced(by: line * 18 * bitmap.bytesPerRow), count: 18 * bitmap.bytesPerRow)
            }
        }
        let original = "The old word sits on line one.\nThe second line is unchanged.\nThe last line is unchanged."
        let corrected = original.replacingOccurrences(of: "old", with: "new")
        XCTAssertEqual(OverlayCaptionText.tail(original, limit: 50), .tail(corrected, limit: 50))
        let before = try await drawnLines(original)
        let after = try await drawnLines(corrected)
        XCTAssertEqual(zip(before, after).filter { $0 != $1 }.count, 1, "Redraw the corrected visible line while preserving both unchanged lines")
        XCTAssertEqual(view.accessibilityValue() as? String, OverlayCaptionText.tail(corrected, limit: 50).text)
        XCTAssertEqual(view.layer?.sublayerTransform.m42, 0)
        XCTAssertTrue(view.layer?.animationKeys()?.isEmpty ?? true, self.animationState(view.layer))
    }

    func testWordsAppearInStepsWithACompositorFade() async throws {
        let view = OverlayCaptionNSView(frame: CGRect(x: 0, y: 0, width: 304, height: 54))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { view.stopScrolling(); window.orderOut(nil); window.contentView = nil; window.close() }
        let phrase = "Words gently flow into place instead of arriving as a whole pasted chunk."
        view.update(caption: .tail(phrase, limit: 100), fontSize: 13, opacity: 1, reduceMotion: false)
        view.layoutSubtreeIfNeeded()
        let initial = try XCTUnwrap(view.accessibilityValue() as? String)
        XCTAssertFalse(initial.isEmpty)
        XCTAssertTrue(phrase.hasPrefix(initial))
        XCTAssertNotEqual(initial, phrase)
        let fade = try XCTUnwrap(view.layer?.sublayers?.last)
        XCTAssertEqual(try XCTUnwrap(fade.animation(forKey: "captionReveal")).duration, OverlayCaptionNSView.revealDuration)
        try await Task.sleep(for: .milliseconds(35))
        let opacity = try XCTUnwrap(fade.presentation()).opacity
        XCTAssertGreaterThan(opacity, 0)
        XCTAssertLessThan(opacity, 1, "New words must actually fade, not just change the text snapshot")
        try await Task.sleep(for: .milliseconds(75))
        let intermediate = try XCTUnwrap(view.accessibilityValue() as? String)
        XCTAssertGreaterThan(intermediate.count, initial.count)
        XCTAssertLessThan(intermediate.count, phrase.count)
        try await Task.sleep(for: .milliseconds(480))
        XCTAssertEqual(view.accessibilityValue() as? String, phrase)
        XCTAssertEqual(try XCTUnwrap(fade.presentation()).opacity, 1, accuracy: 0.01)
        try await self.waitForAnimationRemoval(fade, key: "captionReveal")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 304,
            pixelsHigh: 54,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        try XCTUnwrap(view.layer?.presentation()).render(in: graphics.cgContext)
        let ink = (0..<54).reduce(0) { count, y in
            count + (0..<304).filter { (bitmap.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.1 }.count
        }
        XCTAssertGreaterThan(ink, 400, "Both the settled prefix and the final faded word must remain drawn")
        if let output = ProcessInfo.processInfo.environment["CAPTION_TEST_OUTPUT"] {
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("word-reveal-settled.png"))
        }
    }

    func testBufferedRevisionKeepsThreeDrawnLinesAndCancelsOnClear() async throws {
        let view = OverlayCaptionNSView(frame: CGRect(x: 0, y: 0, width: 304, height: 54))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { view.stopScrolling(); window.orderOut(nil); window.contentView = nil; window.close() }
        func update(_ text: String) {
            view.update(caption: .tail(text, limit: 50), context: .tail(text, limit: 800), fontSize: 13, opacity: 1, reduceMotion: false)
        }
        let original = "Earlier complete lines stay readable. The latest words may be corrected as the recognizer hears more speech."
        update(original)
        view.flushPendingCaption()
        view.layoutSubtreeIfNeeded()
        let revision = original + " A much larger chunk arrives together with enough new words to replace the entire short preview."
        update(revision + " provisional")
        update(revision)
        XCTAssertNotEqual(view.accessibilityValue() as? String, OverlayCaptionText.tail(revision, limit: 50).text)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(view.accessibilityValue() as? String, OverlayCaptionText.tail(revision, limit: 50).text)
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(220))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 304,
            pixelsHigh: 54,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        try XCTUnwrap(view.layer?.presentation()).render(in: graphics.cgContext)
        for line in 0..<3 {
            let ink = (line * 18..<(line + 1) * 18).reduce(0) { count, y in
                count + (0..<304).filter { (bitmap.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.1 }.count
            }
            XCTAssertGreaterThan(ink, 40, "A large revision must preserve all three drawn lines")
        }
        update(revision + " first")
        update(revision + " stale pending result")
        update("")
        update("New recording")
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertEqual(view.accessibilityValue() as? String, "New recording")
        XCTAssertEqual(view.layer?.sublayerTransform.m42, 0)
    }

    func testVisibleLinesSurviveTrimmingAndScrollingFinishesOnTime() async throws {
        let view = OverlayCaptionNSView(frame: CGRect(x: 0, y: 0, width: 304, height: 54))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func update(_ text: String, reduceMotion: Bool = false) {
            view.update(caption: .tail(text, limit: 50), fontSize: 13, opacity: 1, reduceMotion: reduceMotion)
            view.flushPendingCaption()
            view.layoutSubtreeIfNeeded()
        }
        var text = ""
        for word in String(repeating: "Every visible line stays readable as the preview limit advances through the sentence. ", count: 5).split(separator: " ") {
            text += "\(word) "
            update(text, reduceMotion: true)
        }
        try await Task.sleep(for: .milliseconds(50))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 304,
            pixelsHigh: 54,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        try XCTUnwrap(view.layer?.presentation()).render(in: context.cgContext)
        for line in 0..<3 {
            let ink = (line * 18..<(line + 1) * 18).reduce(0) { count, y in
                count + (0..<304).filter { (bitmap.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.1 }.count
            }
            XCTAssertGreaterThan(ink, 40, "Trimming must keep all three visible lines drawn")
        }
        update("")
        let prefix = "First sentence.\nSecond sentence.\nThird sentence."
        update(prefix)
        try await Task.sleep(for: .milliseconds(50))
        update(prefix + "\nNext")
        let begin = try XCTUnwrap(view.layer?.animation(forKey: "captionScroll")).beginTime
        try await Task.sleep(for: .milliseconds(60))
        update(prefix + "\nNext word at a time")
        XCTAssertEqual(try XCTUnwrap(view.layer?.animation(forKey: "captionScroll")).beginTime, begin)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(
            try XCTUnwrap(view.layer?.presentation()).sublayerTransform.m42,
            try XCTUnwrap(view.layer).sublayerTransform.m42,
            accuracy: 0.5
        )
        try await self.waitForAnimationRemoval(view.layer, key: "captionScroll")
    }

    func testScrollInterpolatesThenStopsAndHonorsReduceMotion() async throws {
        let view = OverlayCaptionNSView(frame: CGRect(x: 0, y: 0, width: 180, height: 32))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func update(_ text: String, reduceMotion: Bool = false) {
            view.update(caption: .tail(text, limit: 100), fontSize: 13, opacity: 1, reduceMotion: reduceMotion)
            view.flushPendingCaption()
            view.layoutSubtreeIfNeeded()
        }
        update("First line\nSecond line")
        try await Task.sleep(for: .milliseconds(50))
        let start = try XCTUnwrap(view.layer).sublayerTransform.m42
        update("First line\nSecond line\nThird")
        let target = try XCTUnwrap(view.layer).sublayerTransform.m42
        try await Task.sleep(for: .milliseconds(60))
        let intermediate = try XCTUnwrap(view.layer?.presentation()).sublayerTransform.m42
        XCTAssertLessThan(intermediate, start)
        XCTAssertGreaterThan(intermediate, target)
        update("First line\nSecond line\nThird word")
        XCTAssertEqual(view.layer?.sublayerTransform.m42, target)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try XCTUnwrap(view.layer?.presentation()).sublayerTransform.m42, target, accuracy: 0.5)
        try await self.waitForAnimationRemoval(view.layer, key: "captionScroll")
        update("First line\nSecond line\nThird word\nFourth", reduceMotion: true)
        XCTAssertTrue(view.layer?.animationKeys()?.isEmpty ?? true, self.animationState(view.layer))
        view.frame.size.height = 16
        update("First line\nSecond line\nThird word\nFourth\nFifth\nLatest caption", reduceMotion: true)
        try await Task.sleep(for: .milliseconds(50))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 180,
            pixelsHigh: 16,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        // Read the compositor's already-rendered contents; forcing NSView.draw here would
        // hide the regression where AppKit culled the offscreen lines before scrolling.
        try XCTUnwrap(view.layer?.presentation()).render(in: context.cgContext)
        let inkPixels = (0..<16).reduce(0) { count, y in
            count + (0..<180).filter { (bitmap.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.1 }.count
        }
        XCTAssertGreaterThan(inkPixels, 40, "The latest line must remain drawn after older lines scroll out")
        update("")
        XCTAssertEqual(view.layer?.sublayerTransform.m42, 0)
    }

    func testWindowAndControlsStayStillThroughWrappingAndCorrections() async throws {
        let settings = SettingsStore.shared
        let state = NotchContentState.shared
        let previousSize = settings.overlaySize
        let previousPreview = settings.enableStreamingPreview
        let previousText = state.transcriptionText
        let controller = BottomOverlayWindowController.shared
        defer {
            controller.hideImmediately()
            settings.overlaySize = previousSize
            settings.enableStreamingPreview = previousPreview
            state.updateTranscription(previousText)
        }
        settings.overlaySize = .medium
        settings.enableStreamingPreview = true
        state.updateTranscription("")
        controller.show(audioPublisher: Just(CGFloat.zero).eraseToAnyPublisher(), mode: .dictation)
        try await Task.sleep(for: .milliseconds(350))
        let initial = try XCTUnwrap(controller.windowSizeForTests)
        XCTAssertEqual(initial.height, 114, accuracy: 1, "Keep all three caption lines while removing excess outer padding")
        for text in ["Short", String(repeating: "W", count: 34), String(repeating: "A full caption with three visible lines. ", count: 6), "A short correction", ""] {
            state.updateTranscription(text)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(try XCTUnwrap(controller.windowSizeForTests), initial, "Text updates must not resize the overlay")
        }
    }

    func testHiddenBottomOverlayStopsPendingWordsWithoutClearingTheTranscript() async throws {
        let settings = SettingsStore.shared
        let state = NotchContentState.shared
        let previousSize = settings.overlaySize
        let previousPreview = settings.enableStreamingPreview
        let previousText = state.transcriptionText
        let previousProcessing = state.isProcessing
        let controller = BottomOverlayWindowController.shared
        defer {
            controller.hideImmediately()
            settings.overlaySize = previousSize
            settings.enableStreamingPreview = previousPreview
            state.updateTranscription(previousText)
            state.isProcessing = previousProcessing
        }
        func caption(in view: NSView) -> OverlayCaptionNSView? {
            if let caption = view as? OverlayCaptionNSView { return caption }
            return view.subviews.lazy.compactMap { caption(in: $0) }.first
        }
        settings.overlaySize = .medium
        settings.enableStreamingPreview = true
        state.isProcessing = false
        controller.show(audioPublisher: Just(CGFloat.zero).eraseToAnyPublisher(), mode: .dictation)
        let text = "The hidden preview must stop revealing this long sentence while preserving the transcript for the next action."
        state.updateTranscription(text)
        try await Task.sleep(for: .milliseconds(35))
        let host = try XCTUnwrap(controller.contentViewForTests)
        let view = try XCTUnwrap(caption(in: host))
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertEqual(view.accessibilityValue() as? String, state.cachedPreviewText, "Reduce Motion presents all words immediately")
        } else {
            XCTAssertNotEqual(view.accessibilityValue() as? String, state.cachedPreviewText, self.visibilityState(view))
        }
        controller.hideImmediately()
        for _ in 0..<30 where state.isBottomOverlayPresented {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(state.isBottomOverlayPresented)
        host.layoutSubtreeIfNeeded()
        let hiddenValue = view.accessibilityValue() as? String
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(view.accessibilityValue() as? String, hiddenValue)
        XCTAssertEqual(state.transcriptionText, text)
        XCTAssertTrue(view.layer?.sublayers?.allSatisfy { $0.animationKeys()?.isEmpty != false } == true)
        controller.show(audioPublisher: Just(CGFloat.zero).eraseToAnyPublisher(), mode: .dictation)
        state.updateTranscription("Fresh words after reopening")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(try XCTUnwrap(caption(in: host)).accessibilityValue() as? String, "Fresh words after reopening")
    }

    func testPreviewTracksItsPositionWithoutChangingRecordingState() {
        let state = NotchContentState.shared
        let settings = SettingsStore.shared
        let previousLimit = settings.transcriptionPreviewCharLimit
        let previousText = state.transcriptionText
        let mode = state.mode
        let processing = state.isProcessing
        let muted = state.isDictationMuted
        let target = state.recordingTargetPID
        let commandOutput = state.commandOutput
        defer {
            settings.transcriptionPreviewCharLimit = previousLimit
            state.updateTranscription(previousText)
        }
        settings.transcriptionPreviewCharLimit = 100
        let source = String(repeating: "Captions stay readable while the user keeps speaking. 👩🏽‍💻 ", count: 100)
        state.updateTranscription(source)
        XCTAssertEqual(state.captionPreview, OverlayCaptionText.tail(source, limit: 100))
        XCTAssertEqual(state.transcriptionText.count, 800)
        state.updateTranscription(source + "New words")
        XCTAssertEqual(state.captionPreview, OverlayCaptionText.tail(source + "New words", limit: 100))
        state.updateTranscription("")
        XCTAssertEqual(state.captionPreview, .empty)
        XCTAssertEqual(state.mode, mode)
        XCTAssertEqual(state.isProcessing, processing)
        XCTAssertEqual(state.isDictationMuted, muted)
        XCTAssertEqual(state.recordingTargetPID, target)
        XCTAssertEqual(state.commandOutput, commandOutput)
    }
}
