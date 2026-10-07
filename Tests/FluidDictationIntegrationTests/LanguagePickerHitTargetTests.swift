import AppKit
@testable import FluidVoice_Debug
import SwiftUI
import XCTest

/// Delivers real mouse events to hosted Voice Engine language picker views and
/// asserts the clickable region matches the visible chip / row bounds.
@MainActor
final class LanguagePickerHitTargetTests: XCTestCase {
    /// Empty margin around the view under test so clicks just outside its
    /// bounds still land inside the hosting view and reach SwiftUI hit testing.
    private static let margin: CGFloat = 20

    private final class HitTestWindow: NSWindow {
        override var canBecomeKey: Bool {
            true
        }

        override var canBecomeMain: Bool {
            true
        }
    }

    private final class HitTestHostingView: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }
    }

    private struct Harness {
        let window: HitTestWindow
        let hostingView: HitTestHostingView
        let targetSize: CGSize

        /// Converts a point in the target's top-left-origin space into the
        /// hosting view's coordinate space.
        func hostPoint(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            let margin = LanguagePickerHitTargetTests.margin
            let flippedY = self.hostingView.isFlipped ? margin + y : self.hostingView.bounds.height - margin - y
            return NSPoint(x: margin + x, y: flippedY)
        }

        func tearDown() {
            self.window.contentView = nil
            self.window.orderOut(nil)
            self.window.close()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private var eventNumber = 0

    private func makeHarness(_ content: some View) -> Harness {
        let targetSize = NSHostingView(rootView: content.fixedSize()).fittingSize
        let root = AnyView(
            content
                .frame(width: targetSize.width, height: targetSize.height)
                .padding(Self.margin)
        )
        let size = NSSize(width: targetSize.width + Self.margin * 2, height: targetSize.height + Self.margin * 2)
        let hostingView = HitTestHostingView(rootView: root)
        hostingView.frame = NSRect(origin: .zero, size: size)

        let window = HitTestWindow(
            contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return Harness(window: window, hostingView: hostingView, targetSize: targetSize)
    }

    private func simulateClick(in window: NSWindow, at point: NSPoint, in view: NSView? = nil) throws {
        let windowPoint = view.map { $0.convert(point, to: nil) } ?? point
        let timestamp = ProcessInfo.processInfo.systemUptime

        self.eventNumber += 1
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: self.eventNumber,
            clickCount: 1,
            pressure: 1.0
        ))
        self.eventNumber += 1
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: [],
            timestamp: timestamp + 0.05,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: self.eventNumber,
            clickCount: 1,
            pressure: 0.0
        ))

        window.sendEvent(down)
        // Let SwiftUI's gesture recognizer observe the press before the release.
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        window.sendEvent(up)
        for _ in 0..<5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func makeVoiceEngineView() -> VoiceEngineSettingsView {
        let viewModel = VoiceEngineSettingsViewModel(settings: SettingsStore.shared, appServices: AppServices.shared)
        return VoiceEngineSettingsView(viewModel: viewModel, settings: SettingsStore.shared, theme: .light)
    }

    func testLanguageChipHitTargetBoundedAcrossPill() throws {
        // The getter stays false so the popover never opens and every click
        // lands on the chip; each setter call records one toggle by the button.
        var presentationWrites: [Bool] = []
        let isPresented = Binding(get: { false }, set: { presentationWrites.append($0) })
        let harness = self.makeHarness(self.makeVoiceEngineView().whisperLanguagePickerButton(isPresented: isPresented))
        defer { harness.tearDown() }

        let size = harness.targetSize
        XCTAssertGreaterThan(size.width, 50)
        XCTAssertGreaterThanOrEqual(size.height, 24)

        // Inside the 12pt horizontal padding, left and right.
        try self.simulateClick(in: harness.window, at: harness.hostPoint(6, size.height / 2), in: harness.hostingView)
        XCTAssertEqual(presentationWrites, [true], "Click inside the chip's left padding must toggle the picker")

        try self.simulateClick(in: harness.window, at: harness.hostPoint(size.width - 6, size.height / 2), in: harness.hostingView)
        XCTAssertEqual(presentationWrites, [true, true], "Click inside the chip's right padding must toggle the picker")

        presentationWrites.removeAll()

        // Just outside the pill horizontally.
        try self.simulateClick(in: harness.window, at: harness.hostPoint(-5, size.height / 2), in: harness.hostingView)
        try self.simulateClick(in: harness.window, at: harness.hostPoint(size.width + 5, size.height / 2), in: harness.hostingView)
        XCTAssertTrue(presentationWrites.isEmpty, "Clicks outside the chip must not toggle the picker")

        // Inside the bounding box but outside the 10pt rounded corners.
        try self.simulateClick(in: harness.window, at: harness.hostPoint(1, 1), in: harness.hostingView)
        try self.simulateClick(in: harness.window, at: harness.hostPoint(size.width - 1, size.height - 1), in: harness.hostingView)
        XCTAssertTrue(presentationWrites.isEmpty, "Clicks in the clipped corners must not toggle the picker")
    }

    func testLanguagePickerRowHitTargetEnclosesPaddedBounds() throws {
        let voiceView = self.makeVoiceEngineView()
        var rowClicks = 0
        // Mirrors the popover: a plain button whose label is the row, laid out 280pt wide.
        let row = Button {
            rowClicks += 1
        } label: {
            voiceView.whisperLanguagePickerRow(title: "English", isSelected: true)
        }
        .buttonStyle(.plain)
        .frame(width: 280)

        let harness = self.makeHarness(row)
        defer { harness.tearDown() }
        XCTAssertEqual(harness.targetSize.width, 280)
        XCTAssertEqual(harness.targetSize.height, 28)

        try self.simulateClick(in: harness.window, at: harness.hostPoint(5, 14), in: harness.hostingView)
        XCTAssertEqual(rowClicks, 1, "Click inside the row's left padding must select the row")

        try self.simulateClick(in: harness.window, at: harness.hostPoint(275, 14), in: harness.hostingView)
        XCTAssertEqual(rowClicks, 2, "Click inside the row's right padding must select the row")

        try self.simulateClick(in: harness.window, at: harness.hostPoint(-5, 14), in: harness.hostingView)
        try self.simulateClick(in: harness.window, at: harness.hostPoint(285, 14), in: harness.hostingView)
        try self.simulateClick(in: harness.window, at: harness.hostPoint(140, -5), in: harness.hostingView)
        try self.simulateClick(in: harness.window, at: harness.hostPoint(140, 33), in: harness.hostingView)
        XCTAssertEqual(rowClicks, 2, "Clicks outside the row must not select it")
    }
}
