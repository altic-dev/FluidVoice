#!/usr/bin/env python3
"""Compile the actual logger and clipboard audit in production and diagnostic modes.

Uses a FileLogger stub and a named pasteboard; never writes the general clipboard.
Run with DEVELOPER_DIR pointing to a full Xcode installation.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
import AppKit
import Foundation

final class FileLogger: @unchecked Sendable {
    static let shared = FileLogger()
    let lock = NSLock()
    var lines: [String] = []
    let drained = DispatchSemaphore(value: 0)
    func append(line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
        if line.contains("SUPPORT_END") { drained.signal() }
    }
}
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func message() -> String { lock.lock(); defer { lock.unlock() }; value += 1; return "DIAGNOSTIC_PAYLOAD" }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
@main struct Harness {
    static func main() {
        let counter = Counter()
        let boardCounter = Counter()
        func board() -> NSPasteboard {
            _ = boardCounter.message()
            return NSPasteboard(name: .init("FluidVoiceDiagnosticGateTest"))
        }
        let logger = DebugLogger.shared
        logger.debug(counter.message())
        logger.log(counter.message(), level: .debug)
        logger.benchmark("TEST_BENCH", message: counter.message())
        logger.logLazy(level: .debug) { counter.message() }
        ClipboardAudit.record("test", pasteboard: board(), detail: counter.message())
        logger.info("SUPPORT_INFO")
        logger.warning("SUPPORT_WARNING")
        logger.error("SUPPORT_ERROR")
        logger.info("SUPPORT_END")
        precondition(FileLogger.shared.drained.wait(timeout: .now() + 5) == .success)
        let enabled = DebugLogger.diagnosticsEnabled
        precondition(counter.count == (enabled ? 5 : 0), "Eager diagnostic construction")
        precondition(boardCounter.count == (enabled ? 1 : 0), "Production accessed pasteboard")
        let lines = FileLogger.shared.lines
        precondition(lines.count == (enabled ? 9 : 4), "Unexpected logging work")
        for marker in ["SUPPORT_INFO", "SUPPORT_WARNING", "SUPPORT_ERROR"] {
            precondition(lines.contains { $0.contains(marker) })
        }
        print("PASS diagnosticsEnabled=\(enabled)")
    }
}
'''


def main():
    developer_dir = os.environ.get("DEVELOPER_DIR") or subprocess.check_output(
        ["xcode-select", "-p"], text=True
    ).strip()
    if not (Path(developer_dir) / "Platforms/MacOSX.platform").is_dir():
        raise SystemExit("Set DEVELOPER_DIR to a full Xcode installation.")
    with tempfile.TemporaryDirectory(prefix="fv-diagnostic-gate-") as folder:
        folder = Path(folder)
        harness = folder / "Harness.swift"
        harness.write_text(HARNESS)
        for name, flags in [("production", []), ("debug", ["-D", "DEBUG"]),
                            ("diagnostic", ["-D", "FLUIDVOICE_DIAGNOSTICS"])]:
            binary = folder / name
            subprocess.run([
                "xcrun", "swiftc", "-parse-as-library", *flags,
                str(ROOT / "Sources/Fluid/Services/DebugLogger.swift"),
                str(ROOT / "Sources/Fluid/Services/ClipboardService.swift"),
                str(harness), "-o", str(binary),
            ], check=True)
            output = subprocess.check_output([str(binary)], text=True)
            if name == "production":
                assert output == "PASS diagnosticsEnabled=false\n", output
            else:
                assert "PASS diagnosticsEnabled=true" in output, output
            print(f"PASS {name}: logging and message evaluation gates")


if __name__ == "__main__":
    main()
