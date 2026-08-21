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

    // MARK: - Fix 6: diskutil's `quiet` modifier doesn't hide the destructive verb

    func testDiskutilQuietModifierStillCatchesDestructiveVerb() {
        let cases = [
            "diskutil quiet eraseDisk JHFS+ Untitled disk0",
            "diskutil quiet secureErase 0 /dev/disk0",
        ]
        for command in cases {
            XCTAssertTrue(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" to require confirmation -- `quiet` precedes the verb, "
                    + "it isn't the verb"
            )
        }
    }

    func testDiskutilQuietModifierAloneIsNotFlagged() {
        XCTAssertFalse(
            CommandModeService.isDestructiveCommand("diskutil quiet list"),
            "expected a read-only verb after `quiet` NOT to require confirmation"
        )
    }

    // MARK: - Fix 7: format/mkfs.* basenames

    func testFormatAndMkfsVariantBasenamesAreCaught() {
        let cases = [
            "/usr/local/bin/format /dev/disk2",
            "/sbin/mkfs.ext4 /dev/sdb1",
            "mkfs.vfat /dev/disk3",
        ]
        for command in cases {
            XCTAssertTrue(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" to require confirmation"
            )
        }
    }

    // MARK: - Fix 8: quoted path with an internal space

    func testQuotedPathWithInternalSpaceIsCaught() {
        XCTAssertTrue(
            CommandModeService.isDestructiveCommand("\"/tmp/tools dir/rm\" file"),
            "expected the quoted path to resolve to rm despite the internal space"
        )
    }

    // MARK: - Fix 9: destructive command after a compound-command separator

    func testDestructiveCommandAfterSeparatorIsCaught() {
        let cases = [
            "cd /tmp && /bin/rm victim",
            "echo done; rm -rf ~/Documents",
            "true || sudo reboot",
            "find . -name '*.log' | xargs rm",
        ]
        for command in cases {
            XCTAssertTrue(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" to require confirmation for the command after the separator"
            )
        }
    }

    func testBenignCommandsChainedWithSeparatorsAreNotFlagged() {
        let cases = [
            "cd /tmp && ls -la",
            "git status; git log",
            "find . -name '*.log' | xargs cat",
        ]
        for command in cases {
            XCTAssertFalse(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" NOT to require confirmation"
            )
        }
    }

    // MARK: - Fix 10: redirect anywhere in the command, not just as a leading prefix

    func testRedirectAnywhereInCommandIsCaught() {
        XCTAssertTrue(
            CommandModeService.isDestructiveCommand("echo malicious > /etc/hosts"),
            "expected a mid-command redirect to require confirmation"
        )
    }

    // MARK: - Fix 11: path-qualified xargs target

    func testPathQualifiedXargsTargetIsCaught() {
        XCTAssertTrue(
            CommandModeService.isDestructiveCommand("find . -print0 | xargs -0 /bin/rm"),
            "expected the path-qualified xargs target to resolve to rm"
        )
    }

    // MARK: - Fix 12: bare redirect as the entire simple command

    func testBareRedirectAsEntireCommandIsCaught() {
        let cases = [
            "> important.txt",
            ">> important.txt",
        ]
        for command in cases {
            XCTAssertTrue(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" to require confirmation"
            )
        }
    }

    // MARK: - Fix 13: leading environment assignment before a destructive command

    func testLeadingEnvironmentAssignmentIsCaught() {
        let cases = [
            "LC_ALL=C rm -rf victim",
            "A=1 B=2 sudo reboot",
        ]
        for command in cases {
            XCTAssertTrue(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" to require confirmation despite the leading assignment"
            )
        }
    }

    func testLeadingEnvironmentAssignmentAloneIsNotFlagged() {
        XCTAssertFalse(
            CommandModeService.isDestructiveCommand("LC_ALL=C ls -la"),
            "expected a benign command after an assignment NOT to require confirmation"
        )
    }

    // MARK: - Fix 14: backslash-escaped whitespace in an executable path

    func testEscapedWhitespaceInPathIsCaught() {
        let cases = [
            "/tmp/tools\\ dir/rm -rf victim",
            "/tmp/tools\\ dir/sudo reboot",
        ]
        for command in cases {
            XCTAssertTrue(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" to resolve past the escaped space to the real basename"
            )
        }
    }

    // MARK: - Fix 15: program passed as an argument to a runner resolves by basename

    func testPathQualifiedProgramInRunnersIsCaught() {
        let cases = [
            "find . -exec /bin/rm -rf {} \\;",
            "find . -execdir /bin/rm {} \\;",
            "env /bin/rm -rf victim",
            "nohup /bin/rm -rf victim",
            "time /bin/rm victim",
        ]
        for command in cases {
            XCTAssertTrue(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" to resolve the argument program to its basename"
            )
        }
    }

    func testBenignProgramsInRunnersAreNotFlagged() {
        let cases = [
            "env /bin/ls -la",
            "nohup /usr/bin/python3 script.py",
            "time git status",
            "find . -type f -exec /bin/cat {} \\;",
        ]
        for command in cases {
            XCTAssertFalse(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" NOT to require confirmation"
            )
        }
    }

    // MARK: - Fix 16: shell -c payload is parsed, not treated as an opaque argument

    func testShellWrapperPayloadIsParsed() {
        let cases = [
            "sh -c 'rm -rf victim'",
            "bash -c \"rm -rf victim\"",
            "zsh -c 'cd /tmp && /bin/rm victim'",
            "sh -c 'sh -c \"rm -rf victim\"'",
        ]
        for command in cases {
            XCTAssertTrue(
                CommandModeService.isDestructiveCommand(command),
                "expected the shell payload in \"\(command)\" to be parsed for destructive commands"
            )
        }
    }

    func testBenignShellWrapperPayloadIsNotFlagged() {
        let cases = [
            "sh -c 'ls -la'",
            "bash -c \"git status\"",
        ]
        for command in cases {
            XCTAssertFalse(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" NOT to require confirmation"
            )
        }
    }

    // MARK: - Fix 17: a shell in argument position is a nested invocation, not a leaf

    func testNestedShellPayloadInArgumentPositionIsCaught() {
        let cases = [
            "xargs sh -c 'rm -rf victim'",
            "find . -exec sh -c 'rm -rf victim' \\;",
            "find . -execdir bash -c 'rm -rf victim' \\;",
            "env sh -c 'rm -rf victim'",
            "nohup zsh -c 'rm -rf victim'",
            "timeout 5 sh -c 'rm -rf victim'",
            "xargs -I{} /bin/sh -c 'rm -rf {}'",
            "cd /tmp && xargs sh -c 'rm -rf victim'",
        ]
        for command in cases {
            XCTAssertTrue(
                CommandModeService.isDestructiveCommand(command),
                "expected the nested shell payload in \"\(command)\" to be parsed"
            )
        }
    }

    func testNestedBenignShellPayloadInArgumentPositionIsNotFlagged() {
        let cases = [
            "xargs sh -c 'ls -la'",
            "find . -exec sh -c 'cat {}' \\;",
            "env bash -c 'git status'",
        ]
        for command in cases {
            XCTAssertFalse(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" NOT to require confirmation"
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
