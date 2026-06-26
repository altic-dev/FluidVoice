@testable import FluidVoice_Debug
import XCTest

final class CommandModeDestructiveCommandTests: XCTestCase {
    // MARK: - Chained separators hide a destructive command

    func testAndSeparatorHidesDestructiveCommand() {
        XCTAssertTrue(CommandModeService.isDestructiveCommand("echo ok && killall Finder"))
    }

    func testSemicolonSeparatorHidesDestructiveCommand() {
        XCTAssertTrue(CommandModeService.isDestructiveCommand("true; shred secret.txt"))
    }

    func testOrSeparatorHidesDestructiveCommand() {
        XCTAssertTrue(CommandModeService.isDestructiveCommand("echo a || killall Finder"))
    }

    func testNewlineSeparatorHidesDestructiveCommand() {
        XCTAssertTrue(CommandModeService.isDestructiveCommand("echo hi\nsudo reboot"))
    }

    func testBackgroundSeparatorHidesDestructiveCommand() {
        XCTAssertTrue(CommandModeService.isDestructiveCommand("echo ok & killall Finder"))
    }

    func testOrSeparatorWithRemoveIsDetected() {
        XCTAssertTrue(CommandModeService.isDestructiveCommand("foo || rm bar"))
    }

    func testTrailingSegmentDeepInChainIsDetected() {
        XCTAssertTrue(CommandModeService.isDestructiveCommand("cd /tmp && echo hi && sudo rm -rf /"))
    }

    // MARK: - Safe chains stay allowed

    func testSafeAndChainIsAllowed() {
        XCTAssertFalse(CommandModeService.isDestructiveCommand("cd /tmp && ls"))
    }

    func testSafeSemicolonChainIsAllowed() {
        XCTAssertFalse(CommandModeService.isDestructiveCommand("echo a; echo b"))
    }

    func testBackgroundedSafeCommandIsAllowed() {
        XCTAssertFalse(CommandModeService.isDestructiveCommand("sleep 10 & echo done"))
    }

    // MARK: - Existing single-command detection is preserved

    func testSingleRemoveCommandIsDetected() {
        XCTAssertTrue(CommandModeService.isDestructiveCommand("rm -rf /tmp/foo"))
    }

    func testSingleSudoCommandIsDetected() {
        XCTAssertTrue(CommandModeService.isDestructiveCommand("sudo reboot"))
    }

    func testSingleKillallCommandIsDetected() {
        XCTAssertTrue(CommandModeService.isDestructiveCommand("killall Finder"))
    }

    func testPipedDestructiveCommandIsDetected() {
        XCTAssertTrue(CommandModeService.isDestructiveCommand("cat foo | rm bar"))
    }

    func testSafeSingleCommandIsAllowed() {
        XCTAssertFalse(CommandModeService.isDestructiveCommand("ls -la"))
    }
}
