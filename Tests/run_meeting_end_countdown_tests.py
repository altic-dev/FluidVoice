#!/usr/bin/env python3
"""Run the real countdown, controller, detector and session gate without capture or app defaults."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def declaration(source: str, marker: str) -> str:
    start = source.index(marker)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main() -> None:
    developer = os.environ.get("DEVELOPER_DIR") or subprocess.check_output(["xcode-select", "-p"], text=True).strip()
    if not (Path(developer) / "Platforms/MacOSX.platform").is_dir():
        raise SystemExit("Full Xcode is required; set DEVELOPER_DIR to an installed Xcode.app.")
    env = dict(os.environ, DEVELOPER_DIR=developer)
    with tempfile.TemporaryDirectory(prefix="fluidvoice-meeting-end-") as directory:
        work = Path(directory)
        signals = (ROOT / "Sources/Fluid/Services/Meeting/MeetingAutoDetectSignals.swift").read_text().split("// MARK: - Live implementations")[0]
        (work / "Signals.swift").write_text(signals)
        fixtures = (ROOT / "Tests/FluidDictationIntegrationTests/MeetingAutoDetectorTests.swift").read_text().split("@MainActor\nfinal class MeetingAutoDetectorTests")[0]
        fixtures = fixtures.replace("@testable import FluidVoice_Debug\n", "").replace("import XCTest\n", "").replace("private final class", "final class")
        (work / "Fixtures.swift").write_text(fixtures)
        ui = (ROOT / "Sources/Fluid/UI/MeetingDetectionPrompt.swift").read_text()
        controller = declaration(ui, "final class MeetingStillRecordingNudgeController")
        layout = declaration(ui, "enum MeetingPromptLayout")
        (work / "Controller.swift").write_text("import AppKit\nimport Combine\nimport SwiftUI\n" + layout + "\n@MainActor\n" + controller)
        services = (ROOT / "Sources/Fluid/Services/AppServices.swift").read_text()
        callback = declaration(services, "detector.onAutomaticTargetChanged =")
        gate = declaration(services, "static func recordingSessionID(") + "\n" + declaration(services, "static func meetingEndWatchApplication(") + "\n" + declaration(services, "static func synchronizeMeetingEndWatch(")
        can_stop = declaration(services, "private func canStopMeetingAfterEndConfirmation(").replace("private func", "func", 1)
        stop = declaration(services, "private func stopMeetingAfterEndConfirmation(").replace("private func", "func", 1)
        (work / "SessionGate.swift").write_text(
            "import Foundation\n@MainActor final class AppServices {\n"
            "var _meetingSessionCoordinator: MeetingSessionCoordinator?\n"
            "var _meetingAutoDetector: MeetingAutoDetector?\n"
            "var meetingAutomaticTarget: MeetingAutoDetector.ResolvedTarget?\n"
            "func wireTarget(_ detector: MeetingAutoDetector) {\n" + callback + "\n}\n" + gate + "\n" + can_stop + "\n" + stop + "\n}\n"
        )
        sources = [
            ROOT / "Sources/Fluid/Services/Meeting/MeetingEndCountdown.swift",
            ROOT / "Sources/Fluid/Services/Meeting/MeetingAutoDetector.swift",
            ROOT / "Sources/Fluid/Services/Meeting/MeetingAppRegistry.swift",
            ROOT / "Sources/Fluid/Services/Meeting/MeetingBrowserCallEvidence.swift",
            work / "Signals.swift", work / "Fixtures.swift", work / "Controller.swift", work / "SessionGate.swift",
            ROOT / "Tests/MeetingEndCountdownTests.swift",
        ]
        executable = work / "tests"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", *map(str, sources), "-o", str(executable)], check=True, env=env)
        subprocess.run([str(executable)], check=True, env=env)


if __name__ == "__main__":
    main()
