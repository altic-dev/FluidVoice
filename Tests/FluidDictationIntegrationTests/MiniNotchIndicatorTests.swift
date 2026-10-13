import AppKit
import Combine
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class MiniNotchIndicatorTests: XCTestCase {
    func testSavedIdleChoiceIsPresentedAfterLaunchRefresh() throws {
        try self.withMiniSettings {
            let settings = SettingsStore.shared
            settings.miniNotchIndicatorEnabled = true
            settings.miniNotchHideWhenIdle = false
            let controller = MiniNotchIndicatorController.shared
            defer { settings.miniNotchIndicatorEnabled = false; controller.finish() }
            controller.refreshVisibility()
            XCTAssertTrue(controller.isPresented)
        }
    }

    func testDisablingMiniDefersHidingUntilRecordingFinishes() throws {
        try self.withMiniSettings {
            let settings = SettingsStore.shared
            settings.miniNotchIndicatorEnabled = true
            settings.miniNotchHideWhenIdle = true
            let controller = MiniNotchIndicatorController.shared
            defer { settings.miniNotchIndicatorEnabled = false; controller.finish() }
            controller.start(Just(CGFloat(0.4)).eraseToAnyPublisher(), screen: NSScreen.main)
            settings.miniNotchIndicatorEnabled = false
            controller.refreshVisibility()
            XCTAssertTrue(controller.isPresented)
            controller.finish()
            XCTAssertFalse(controller.isPresented)
        }
    }

    func testIdleHiddenChoiceStillPresentsRecordingAndRemovesItOnFinish() throws {
        try self.withMiniSettings {
            let settings = SettingsStore.shared
            settings.miniNotchIndicatorEnabled = true
            settings.miniNotchHideWhenIdle = true
            let controller = MiniNotchIndicatorController.shared
            defer { settings.miniNotchIndicatorEnabled = false; controller.finish() }
            controller.refreshVisibility()
            XCTAssertFalse(controller.isPresented)
            controller.start(Just(CGFloat(0.2)).eraseToAnyPublisher(), screen: NSScreen.main)
            XCTAssertTrue(controller.isPresented)
            controller.finish()
            XCTAssertFalse(controller.isPresented)
        }
    }

    func testAnimatedManagerDismissalFinishesMiniAndExpandedRecording() throws {
        try self.withMiniSettings {
            let settings = SettingsStore.shared
            let controller = MiniNotchIndicatorController.shared
            let manager = NotchOverlayManager.shared
            let closingAnimation = settings.overlayClosingAnimationEnabled
            let expand = controller.expand
            defer {
                manager.hideImmediately()
                settings.overlayClosingAnimationEnabled = closingAnimation
                controller.expand = expand
            }
            settings.overlayClosingAnimationEnabled = true
            settings.miniNotchIndicatorEnabled = true
            settings.miniNotchHideWhenIdle = true
            controller.expand = nil
            manager.hideImmediately()
            for expanded in [false, true] {
                controller.start(Just(CGFloat(0.4)).eraseToAnyPublisher(), screen: NSScreen.main)
                if expanded { controller.expandOverlay() }
                XCTAssertTrue(controller.isRecording)
                XCTAssertEqual(controller.isExpanded, expanded)
                manager.hide()
                XCTAssertFalse(controller.isRecording)
                XCTAssertFalse(controller.isExpanded)
                XCTAssertFalse(controller.isPresented)
                manager.hideImmediately()
            }
        }
    }

    func testNonKeyKeyboardFocusDoesNotExpandIdleIndicator() throws {
        try self.withMiniSettings {
            let settings = SettingsStore.shared
            let controller = MiniNotchIndicatorController.shared
            settings.miniNotchIndicatorEnabled = false
            controller.finish()
            settings.miniNotchIndicatorEnabled = true
            settings.miniNotchHideWhenIdle = false
            controller.refreshVisibility()
            defer { settings.miniNotchIndicatorEnabled = false; controller.finish() }
            controller.keyboardFocusChanged(true)
            XCTAssertTrue(controller.isPresented)
            XCTAssertFalse(controller.isFocused)
            XCTAssertFalse(controller.showsControls)
            controller.hoverChanged(true)
            XCTAssertTrue(controller.showsControls)
        }
    }

    func testAccessibilityFocusExpandsIdleAndHidingClearsIt() throws {
        try self.withMiniSettings {
            let settings = SettingsStore.shared
            let controller = MiniNotchIndicatorController.shared
            settings.miniNotchIndicatorEnabled = true
            settings.miniNotchHideWhenIdle = false
            controller.finish()
            defer { settings.miniNotchIndicatorEnabled = false; controller.finish() }
            controller.accessibilityFocusChanged(true)
            XCTAssertTrue(controller.isFocused)
            XCTAssertTrue(controller.showsControls)
            settings.miniNotchIndicatorEnabled = false
            controller.refreshVisibility()
            XCTAssertFalse(controller.isFocused)
            XCTAssertFalse(controller.showsControls)
            settings.miniNotchIndicatorEnabled = true
            controller.refreshVisibility()
            XCTAssertTrue(controller.isPresented)
            XCTAssertFalse(controller.showsControls)
        }
    }

    private func withMiniSettings(_ operation: () throws -> Void) throws {
        guard NSScreen.main != nil else { throw XCTSkip("Requires a macOS display for panel presentation") }
        let settings = SettingsStore.shared
        let enabled = settings.miniNotchIndicatorEnabled
        let hidden = settings.miniNotchHideWhenIdle
        defer {
            settings.miniNotchIndicatorEnabled = enabled
            settings.miniNotchHideWhenIdle = hidden
        }
        try operation()
    }
}
