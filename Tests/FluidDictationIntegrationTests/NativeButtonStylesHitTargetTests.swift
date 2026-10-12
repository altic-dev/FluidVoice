import AppKit
@testable import FluidVoice_Debug
import SwiftUI
import XCTest

/// Delivers real mouse events to buttons using the shared native button
/// styles and asserts each style's clickable region matches its visible shape.
@MainActor
final class NativeButtonStylesHitTargetTests: XCTestCase {
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
            let margin = NativeButtonStylesHitTargetTests.margin
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

    private struct StyleCase {
        let name: String
        let makeButton: (@escaping () -> Void) -> AnyView
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

    private let styleCases: [StyleCase] = [
        StyleCase(name: "GlassButtonStyle") { action in
            AnyView(Button("Action", action: action).buttonStyle(GlassButtonStyle()))
        },
        StyleCase(name: "PremiumButtonStyle") { action in
            AnyView(Button("Action", action: action).buttonStyle(PremiumButtonStyle()).frame(width: 160))
        },
        StyleCase(name: "AccentButtonStyle") { action in
            AnyView(Button("Action", action: action).buttonStyle(AccentButtonStyle()))
        },
        StyleCase(name: "InlineButtonStyle") { action in
            AnyView(Button("Action", action: action).buttonStyle(InlineButtonStyle()))
        },
        StyleCase(name: "SquareIconButtonStyle") { action in
            AnyView(
                Button(action: action) {
                    Image(systemName: "gear").frame(width: 28, height: 28)
                }
                .buttonStyle(SquareIconButtonStyle())
            )
        },
    ]

    func testButtonStylesAcceptClicksAcrossTheirShape() throws {
        for style in self.styleCases {
            var clicks = 0
            let harness = self.makeHarness(style.makeButton { clicks += 1 })
            defer { harness.tearDown() }
            let size = harness.targetSize

            for (x, y) in [(size.width / 2, size.height / 2), (3, size.height / 2), (size.width - 3, size.height / 2)] {
                try self.simulateClick(in: harness.window, at: harness.hostPoint(x, y), in: harness.hostingView)
            }
            XCTAssertEqual(clicks, 3, "\(style.name) must accept clicks at its center and near its padded edges")
        }
    }

    func testButtonStylesRejectClicksOutsideTheirShape() throws {
        for style in self.styleCases {
            var clicks = 0
            let harness = self.makeHarness(style.makeButton { clicks += 1 })
            defer { harness.tearDown() }
            let size = harness.targetSize

            // First prove this harness window actively delivers clicks to the button
            try self.simulateClick(in: harness.window, at: harness.hostPoint(size.width / 2, size.height / 2), in: harness.hostingView)
            XCTAssertEqual(clicks, 1, "\(style.name) baseline center click must register")
            clicks = 0

            // Corners clipped by the rounded / capsule shape, then just outside the bounds.
            let outsidePoints: [(CGFloat, CGFloat)] = [
                (1, 1),
                (size.width - 1, 1),
                (1, size.height - 1),
                (size.width - 1, size.height - 1),
                (-4, size.height / 2),
                (size.width + 4, size.height / 2),
            ]
            for (x, y) in outsidePoints {
                try self.simulateClick(in: harness.window, at: harness.hostPoint(x, y), in: harness.hostingView)
            }
            XCTAssertEqual(clicks, 0, "\(style.name) must ignore clicks outside its shape")
        }
    }

    func testSquareIconButtonStyleEnforcesMinimumHitTarget() throws {
        var clicks = 0
        let button = Button {
            clicks += 1
        } label: {
            Image(systemName: "xmark").font(.system(size: 8))
        }
        .buttonStyle(SquareIconButtonStyle())

        let harness = self.makeHarness(button)
        defer { harness.tearDown() }
        XCTAssertGreaterThanOrEqual(harness.targetSize.width, 24, "SquareIconButtonStyle must be at least 24pt wide")
        XCTAssertGreaterThanOrEqual(harness.targetSize.height, 24, "SquareIconButtonStyle must be at least 24pt tall")

        // Near each edge midpoint of the 24pt square, well outside the small glyph.
        let size = harness.targetSize
        for (x, y) in [(3, size.height / 2), (size.width - 3, size.height / 2), (size.width / 2, 3), (size.width / 2, size.height - 3)] {
            try self.simulateClick(in: harness.window, at: harness.hostPoint(x, y), in: harness.hostingView)
        }
        XCTAssertEqual(clicks, 4, "SquareIconButtonStyle must accept clicks across its minimum 24pt target")
    }
}
