@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Covers `CommandModeService.isDestructiveCommand`'s allowlist model: a command
/// requires confirmation unless every simple command in it resolves, after
/// dropping a leading env assignment, to a name on a short known-safe list, with
/// no redirect riding along. Anything not recognized asks for confirmation by
/// default, rather than trying to enumerate every way a command could be
/// dangerous.
final class CommandModeDestructiveCommandGapTests: XCTestCase {
    // MARK: - Known-safe commands pass through

    func testKnownSafeCommandsAreNotFlagged() {
        let cases = [
            "ls -la",
            "cat README.md",
            "echo hello world",
            "pwd",
            "whoami",
            "date",
            "hostname",
            "uname -a",
            "head -n 5 file.txt",
            "tail -f log.txt",
            "wc -l file.txt",
            "file image.png",
            "stat file.txt",
            "which python3",
            "printenv PATH",
        ]
        for command in cases {
            XCTAssertFalse(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" NOT to require confirmation"
            )
        }
    }

    // MARK: - Everything not on the safe list requires confirmation, even when benign

    /// This is the actual tradeoff of the allowlist model, stated as a test rather
    /// than left implicit: ordinary, harmless commands not on the short safe list
    /// now require confirmation too, since the model is "prove it's safe" rather
    /// than "prove it's dangerous."
    func testCommandsNotOnTheSafeListRequireConfirmation() {
        let cases = [
            "cd /tmp",
            "git status",
            "find . -name '*.txt'",
            "curl -s https://example.com",
            "python3 script.py",
            "diskutil list",
            "npm install",
            "mkdir newfolder",
            "touch file.txt",
        ]
        for command in cases {
            XCTAssertTrue(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" to require confirmation, it isn't on the known-safe list"
            )
        }
    }

    // MARK: - Genuinely destructive commands still require confirmation

    func testDestructiveCommandsAreCaught() {
        let cases = [
            "rm -rf ~/Documents",
            "sudo reboot",
            "mv secret.txt /tmp/",
            "chmod 000 /etc/hosts",
            "killall Finder",
            "rmdir ~/Documents",
            "dd if=/dev/zero of=/dev/disk0",
            "diskutil eraseDisk JHFS+ Untitled disk0",
        ]
        for command in cases {
            XCTAssertTrue(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" to require confirmation"
            )
        }
    }

    // MARK: - Path-qualified, quoted, and escaped forms still resolve correctly

    func testAbsoluteAndQuotedPathsStillResolveToTheBareCommand() {
        let safeCases = [
            "/bin/ls -la",
            "\"/bin/cat\" README.md",
        ]
        for command in safeCases {
            XCTAssertFalse(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" NOT to require confirmation, it resolves to a safe basename"
            )
        }

        let unsafeCases = [
            "/bin/rm -rf ~/Documents",
            "\"/bin/rm\" -rf ~/Documents",
            "/tmp/tools\\ dir/rm file",
        ]
        for command in unsafeCases {
            XCTAssertTrue(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" to require confirmation, it resolves to rm"
            )
        }
    }

    // MARK: - Accepted tradeoff: no escape-aware tokenizing, so an escaped
    // whitespace character in the leading command's own path isn't specially
    // handled. It fails toward confirmation, not toward silently allowing
    // something, and it's a genuinely rare shape for a leading command to take.

    func testEscapedWhitespaceInLeadingCommandPathAsksForConfirmation() {
        XCTAssertTrue(
            CommandModeService.isDestructiveCommand("/tmp/tools\\ dir/ls"),
            "expected an escaped-space path to require confirmation rather than resolve to a safe basename"
        )
    }

    // MARK: - A leading env assignment doesn't change the verdict

    func testLeadingEnvironmentAssignmentIsSkippedBeforeChecking() {
        XCTAssertFalse(
            CommandModeService.isDestructiveCommand("LC_ALL=C ls -la"),
            "expected an env-prefixed safe command NOT to require confirmation"
        )
        XCTAssertTrue(
            CommandModeService.isDestructiveCommand("LC_ALL=C rm -rf victim"),
            "expected an env-prefixed destructive command to still require confirmation"
        )
    }

    // MARK: - A redirect makes an otherwise-safe command unsafe

    func testRedirectOnAnOtherwiseSafeCommandIsCaught() {
        let cases = [
            "echo malicious > /etc/hosts",
            "cat file.txt > /etc/hosts",
            "> important.txt",
            "2>/dev/null ls",
        ]
        for command in cases {
            XCTAssertTrue(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" to require confirmation because of the redirect"
            )
        }
    }

    // MARK: - A quoted or escaped unsafe character is an argument, not a redirect

    func testQuotedOrEscapedUnsafeCharacterIsNotFlagged() {
        let cases = [
            "echo '>'",
            "echo \\>",
            "echo \"(hello)\"",
        ]
        for command in cases {
            XCTAssertFalse(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" NOT to require confirmation, the character is quoted or escaped"
            )
        }
    }

    // MARK: - A backslash-escaped quote doesn't hide a real separator

    func testEscapedQuoteDoesNotHideSeparator() {
        XCTAssertTrue(
            CommandModeService.isDestructiveCommand("echo \"foo\\\"bar\" && rm -rf victim"),
            "expected the destructive command after && to require confirmation, the escaped quote shouldn't close the string early"
        )
    }

    func testEscapedQuoteInsideAnOtherwiseSafeCommandIsNotFlagged() {
        XCTAssertFalse(
            CommandModeService.isDestructiveCommand("echo \"foo\\\"bar\""),
            "expected a genuinely safe command with an escaped quote NOT to require confirmation"
        )
    }

    // MARK: - Command substitution inside double quotes is still substitution

    func testCommandSubstitutionInsideDoubleQuotesIsCaught() {
        XCTAssertTrue(
            CommandModeService.isDestructiveCommand("echo \"$(rm -rf victim)\""),
            "expected a double-quoted command substitution to require confirmation, a real shell still evaluates it"
        )
    }

    func testSingleQuotedSubstitutionSyntaxIsNotFlagged() {
        XCTAssertFalse(
            CommandModeService.isDestructiveCommand("echo '$(rm -rf victim)'"),
            "expected single-quoted text NOT to require confirmation, single quotes suppress all substitution"
        )
    }

    func testParenthesesInsideDoubleQuotesAreStillInert() {
        XCTAssertFalse(
            CommandModeService.isDestructiveCommand("echo \"(hello)\""),
            "expected literal parentheses inside double quotes NOT to require confirmation, they aren't substitution on their own"
        )
    }

    // MARK: - A path-qualified safe command is only trusted from a real system directory

    func testPathQualifiedSafeCommandOutsideATrustedDirectoryIsFlagged() {
        let cases = ["./ls", "/tmp/cat -la", "ls_backup/ls"]
        for command in cases {
            XCTAssertTrue(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" to require confirmation, it isn't in a trusted system directory"
            )
        }
    }

    func testPathQualifiedSafeCommandInATrustedDirectoryIsNotFlagged() {
        let cases = ["/bin/ls -la", "/usr/bin/cat README.md"]
        for command in cases {
            XCTAssertFalse(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" NOT to require confirmation, it's a real system path"
            )
        }
    }

    // MARK: - Every simple command in a chain is checked, not just the first

    func testEverySimpleCommandInAChainIsChecked() {
        let allSafe = "ls -la; cat README.md && echo done"
        XCTAssertFalse(
            CommandModeService.isDestructiveCommand(allSafe),
            "expected a chain of only safe commands NOT to require confirmation"
        )

        let oneUnsafe = "ls -la && rm -rf victim"
        XCTAssertTrue(
            CommandModeService.isDestructiveCommand(oneUnsafe),
            "expected a chain with one destructive command to require confirmation"
        )

        let oneUnrecognized = "ls -la && git status"
        XCTAssertTrue(
            CommandModeService.isDestructiveCommand(oneUnrecognized),
            "expected a chain with one unrecognized command to require confirmation"
        )
    }

    // MARK: - The bypass constructs raised across the original review are all closed,
    // for the same reason: none of these leading commands are on the safe list.

    func testPreviouslyReportedBypassConstructsAllRequireConfirmation() {
        let cases = [
            "\"/bin/rm\" -rf ~/Documents",
            "diskutil quiet eraseDisk JHFS+ Untitled disk0",
            "/usr/local/bin/format /dev/disk2",
            "/sbin/mkfs.ext4 /dev/disk2",
            "cd /tmp && /bin/rm victim",
            "xargs -I{} /bin/rm {}",
            "find . -exec /bin/rm {} \\;",
            "sh -c 'rm -rf victim'",
            "env sh -c 'rm -rf victim'",
            "eval 'rm -rf victim'",
            "env diskutil eraseDisk JHFS+ Untitled disk0",
            "nohup find . -delete",
            "(rm -rf victim)",
            "if true; then rm -rf victim; fi",
            "echo $(rm -rf victim)",
        ]
        for command in cases {
            XCTAssertTrue(
                CommandModeService.isDestructiveCommand(command),
                "expected \"\(command)\" to require confirmation"
            )
        }
    }



}
