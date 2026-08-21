@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Covers three confirm-gate bypass classes in `CommandModeService.isDestructiveCommand`:
/// the primary command invoked via an absolute path, `find -delete`/`-exec rm`, and
/// `diskutil`'s destructive subcommands. None of the three require anything adversarial-
/// looking from the model -- an absolute path, `find`, and `diskutil` are all ordinary,
/// unremarkable tool choices.
final class CommandModeDestructiveCommandGapTests: XCTestCase {
    // MARK: - Regression: existing bare-command detection still works

    func testBareDestructiveCommandsAreStillCaught() {
        let cases = [
            "rm -rf ~/Documents",
            "sudo reboot",
            "mv secret.txt /tmp/",
            "chmod 000 /etc/hosts",
            "killall Finder",
            "rmdir ~/Documents",
        ]
        for command in cases {
            XCTAssertTrue(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" to require confirmation"
            )
        }
    }

    // MARK: - Fix 1: absolute-path invocation

    func testAbsolutePathInvocationIsCaught() {
        let cases = [
            "/usr/bin/sudo reboot",
            "/bin/mv secret.txt /tmp/",
            "/bin/chmod 000 /etc/hosts",
            "/usr/bin/killall Finder",
            "/bin/rmdir ~/Documents",
            "/bin/rm somefile.txt", // rm with no dash flag -- the "rm -" fallback doesn't apply here
            "/bin/rm -rf ~/Documents", // still caught (now redundantly, by both the old fallback and the new check)
        ]
        for command in cases {
            XCTAssertTrue(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" to require confirmation despite the absolute path"
            )
        }
    }

    // MARK: - Fix 2: find -delete / find -exec rm

    func testFindDeleteAndExecRmAreCaught() {
        let cases = [
            "find ~/Documents -delete",
            "find ~/Documents -type f -delete",
            "find / -name '*.important' -exec rm {} \\;",
        ]
        for command in cases {
            XCTAssertTrue(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" to require confirmation"
            )
        }
    }

    // MARK: - Fix 3: diskutil destructive subcommands

    func testDiskutilDestructiveSubcommandsAreCaught() {
        let cases = [
            "diskutil eraseDisk JHFS+ Untitled disk0",
            "diskutil secureErase 0 /dev/disk0",
            "diskutil eraseVolume APFS Wiped /Volumes/Backup",
            "diskutil reformat /dev/disk2s1",
            "diskutil partitionDisk disk0 1 JHFS+ Untitled 100%",
            "diskutil zeroDisk /dev/disk0",
        ]
        for command in cases {
            XCTAssertTrue(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" to require confirmation"
            )
        }
    }

    // MARK: - Fix 4: quoted absolute-path invocation

    func testQuotedAbsolutePathInvocationIsCaught() {
        let cases = [
            "\"/bin/rm\" -rf ~/Documents",
            "'/bin/rm' -rf ~/Documents",
            "\"/usr/bin/sudo\" reboot",
        ]
        for command in cases {
            XCTAssertTrue(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" to require confirmation despite the quoted absolute path"
            )
        }
    }

    // MARK: - Fix 5: diskutil subcommand matching doesn't false-positive on arguments

    func testDiskutilArgumentContainingSubcommandNameIsNotFlagged() {
        let cases = [
            "diskutil info /Volumes/EraseDisk",
            "diskutil list /Volumes/ReformatBackup",
        ]
        for command in cases {
            XCTAssertFalse(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" NOT to require confirmation -- the destructive-looking "
                    + "text is in an argument, not the diskutil subcommand"
            )
        }
    }

    // MARK: - No new false positives on benign commands

    func testBenignCommandsAreNotFlagged() {
        let cases = [
            "ls -la",
            "git status",
            "git commit -m \"fix bug\"",
            "find . -name '*.txt'", // find WITHOUT -delete or -exec rm
            "find . -type f -name '*.log' -exec cat {} \\;", // -exec, but not rm
            "diskutil list", // read-only
            "diskutil info disk0", // read-only
            "diskutil activity", // read-only
            "echo hello world",
            "cat README.md",
            "curl -s https://example.com",
            "python3 script.py",
            "/usr/bin/python3 --version", // absolute path but not a destructive command name
        ]
        for command in cases {
            XCTAssertFalse(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" NOT to require confirmation"
            )
        }
    }
}
