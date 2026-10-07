import AppKit
@testable import FluidVoice_Debug
import SwiftUI
import XCTest

/// Delivers real mouse events to settings action controls and asserts each
/// click reaches the control itself rather than an enclosing row gesture.
@MainActor
final class SettingsActionsHitTargetTests: XCTestCase {
    /// Empty margin around the view under test so clicks just outside its
    /// bounds still land inside the hosting view and reach SwiftUI hit testing.
    private static let margin: CGFloat = 20
    /// Row padding around the icon button, mirroring a speech model row.
    private static let rowInset: CGFloat = 16

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
            let margin = SettingsActionsHitTargetTests.margin
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

    // MARK: - Speech model row icon buttons

    /// Hosts `button` inside a padded row that, like the speech model row,
    /// selects itself via `.onTapGesture`, then clicks across the icon's
    /// 24x24pt target and the surrounding row.
    private func assertIconButtonOwnsClicks(
        _ name: String,
        makeButton: (@escaping () -> Void) -> SpeechModelRowIconButton
    ) throws {
        var buttonClicks = 0
        var rowTaps = 0
        let row = makeButton { buttonClicks += 1 }
            .padding(Self.rowInset)
            .contentShape(Rectangle())
            .onTapGesture { rowTaps += 1 }

        let harness = self.makeHarness(row)
        defer { harness.tearDown() }

        let inset = Self.rowInset
        XCTAssertEqual(harness.targetSize.width, 24 + inset * 2, "\(name) must lay out a 24pt wide target")
        XCTAssertEqual(harness.targetSize.height, 24 + inset * 2, "\(name) must lay out a 24pt tall target")

        for (x, y) in [(12.0, 12.0), (2.0, 2.0), (22.0, 22.0), (2.0, 22.0), (22.0, 2.0)] {
            try self.simulateClick(in: harness.window, at: harness.hostPoint(inset + x, inset + y), in: harness.hostingView)
        }
        XCTAssertEqual(buttonClicks, 5, "\(name) must receive clicks anywhere in its 24x24pt target")
        XCTAssertEqual(rowTaps, 0, "Clicks on \(name) must not fall through to the row's tap gesture")

        // Row padding outside the icon still selects the row.
        try self.simulateClick(in: harness.window, at: harness.hostPoint(4, 4), in: harness.hostingView)
        XCTAssertEqual(rowTaps, 1, "Clicks on the row outside \(name) must select the row")
        XCTAssertEqual(buttonClicks, 5)
    }

    func testSpeechModelTrashButtonOwnsClicksOverRowGesture() throws {
        try self.assertIconButtonOwnsClicks("trash button") { action in
            SpeechModelRowIconButton(systemName: "trash", fontSize: 15, accessibilityLabel: "Delete Whisper", action: action)
        }
    }

    func testExternalModelSourceButtonOwnsClicksOverRowGesture() throws {
        try self.assertIconButtonOwnsClicks("external source button") { action in
            SpeechModelRowIconButton(
                systemName: "arrow.up.right.square",
                fontSize: 14,
                accessibilityLabel: "Open Whisper source",
                action: action
            )
        }
    }

    // MARK: - AI configuration help button

    func testAIConfigurationHelpButtonTogglesHelpAcrossCapsule() throws {
        let viewModel = AIEnhancementSettingsViewModel(
            settings: SettingsStore.shared,
            menuBarManager: MenuBarManager(),
            promptTest: DictationPromptTestCoordinator.shared
        )
        let view = AIEnhancementSettingsView(
            viewModel: viewModel,
            privateAIController: PrivateAISettingsController(viewModel: viewModel),
            settings: SettingsStore.shared,
            promptTest: DictationPromptTestCoordinator.shared,
            theme: .light,
            selectedConfigurationSection: .constant(.providers),
            activeShortcutRecordingTarget: .constant(nil),
            shortcutRecordingMessage: .constant(nil)
        )
        viewModel.showHelp = false

        let harness = self.makeHarness(view.helpButton)
        defer { harness.tearDown() }
        let size = harness.targetSize

        // Center, then inside the 10pt horizontal padding on each side.
        try self.simulateClick(in: harness.window, at: harness.hostPoint(size.width / 2, size.height / 2), in: harness.hostingView)
        XCTAssertTrue(viewModel.showHelp, "Click on the Help label must show help")

        try self.simulateClick(in: harness.window, at: harness.hostPoint(size.width - 6, size.height / 2), in: harness.hostingView)
        XCTAssertFalse(viewModel.showHelp, "Click inside the Help capsule's right padding must hide help")

        try self.simulateClick(in: harness.window, at: harness.hostPoint(6, size.height / 2), in: harness.hostingView)
        XCTAssertTrue(viewModel.showHelp, "Click inside the Help capsule's left padding must show help")

        // Outside the capsule: beside it, and in its rounded-off corners.
        try self.simulateClick(in: harness.window, at: harness.hostPoint(-5, size.height / 2), in: harness.hostingView)
        try self.simulateClick(in: harness.window, at: harness.hostPoint(1, 1), in: harness.hostingView)
        try self.simulateClick(in: harness.window, at: harness.hostPoint(size.width - 1, size.height - 1), in: harness.hostingView)
        XCTAssertTrue(viewModel.showHelp, "Clicks outside the Help capsule must not toggle help")
    }

    func testProviderAccordionHeaderPaddingOwnsClicks() throws {
        var toggles = 0
        let header = Button(action: { toggles += 1 }) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "cpu")
                    .frame(width: 34, height: 34)
                Text("OpenAI")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 300, height: 54)

        let harness = self.makeHarness(header)
        defer { harness.tearDown() }

        // Click inside horizontal padding (left edge, 5pt inside 12pt padding)
        try self.simulateClick(in: harness.window, at: harness.hostPoint(5, 27), in: harness.hostingView)
        XCTAssertEqual(toggles, 1, "Click inside left horizontal padding must toggle provider")

        // Click inside horizontal padding (right edge, 5pt inside 12pt padding)
        try self.simulateClick(in: harness.window, at: harness.hostPoint(295, 27), in: harness.hostingView)
        XCTAssertEqual(toggles, 2, "Click inside right horizontal padding must toggle provider")

        // Click inside vertical padding (top edge, 4pt inside 10pt padding)
        try self.simulateClick(in: harness.window, at: harness.hostPoint(150, 4), in: harness.hostingView)
        XCTAssertEqual(toggles, 3, "Click inside top vertical padding must toggle provider")

        // Click inside vertical padding (bottom edge, 4pt inside 10pt padding)
        try self.simulateClick(in: harness.window, at: harness.hostPoint(150, 50), in: harness.hostingView)
        XCTAssertEqual(toggles, 4, "Click inside bottom vertical padding must toggle provider")

        // Clicks outside the header frame must not toggle
        try self.simulateClick(in: harness.window, at: harness.hostPoint(-5, 27), in: harness.hostingView)
        try self.simulateClick(in: harness.window, at: harness.hostPoint(305, 27), in: harness.hostingView)
        try self.simulateClick(in: harness.window, at: harness.hostPoint(150, -5), in: harness.hostingView)
        try self.simulateClick(in: harness.window, at: harness.hostPoint(150, 60), in: harness.hostingView)
        XCTAssertEqual(toggles, 4, "Clicks outside header bounds must not toggle provider")
    }
}
