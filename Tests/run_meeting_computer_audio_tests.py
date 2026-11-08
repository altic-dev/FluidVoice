#!/usr/bin/env python3
"""Execute production source/configuration/filter code with inert ScreenCaptureKit doubles."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def declaration(source, marker):
    start = source.index(marker)
    brace = source.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main():
    developer = os.environ.get("DEVELOPER_DIR") or subprocess.check_output(["xcode-select", "-p"], text=True).strip()
    if not (Path(developer) / "Platforms/MacOSX.platform").is_dir():
        raise SystemExit("Full Xcode is required")
    env = dict(os.environ, DEVELOPER_DIR=developer)
    models = (ROOT / "Sources/Fluid/Services/Meeting/MeetingModels.swift").read_text()
    engine = (ROOT / "Sources/Fluid/Services/Meeting/MeetingCaptureEngine.swift").read_text()
    swift = '''import Foundation
import CoreMedia
enum VoiceEngineLanguageCatalog { static let parakeetV3LanguageIDs: Set<String> = ["en", "de"] }
enum MeetingAutoDetector { struct ResolvedTarget { var bundleIdentifier: String; var pid: Int32; var windowID: UInt32? } }
enum MeetingCaptureError: Error { case applicationNotSelected, applicationUnavailable(String), noCaptureDisplay, screenCapturePermissionDenied(String) }
struct SCRunningApplication { let bundleIdentifier: String; let processID: Int32; let applicationName: String }
struct SCDisplay { let displayID: UInt32 }
struct SCWindow {}
struct SCShareableContent {
    static var fixture = Self(applications: [], displays: [SCDisplay(displayID: 1)])
    static var fail = false
    static var current: Self { get async throws { if fail { throw CocoaError(.fileReadNoPermission) }; return fixture } }
    let applications: [SCRunningApplication]; let displays: [SCDisplay]
}
struct SCContentFilter {
    enum Kind: Equatable { case all, applications([Int32]), window }
    let kind: Kind
    init(display: SCDisplay, excludingApplications: [SCRunningApplication], exceptingWindows: [SCWindow]) {
        precondition(excludingApplications.isEmpty && exceptingWindows.isEmpty); kind = .all
    }
    init(display: SCDisplay, including: [SCRunningApplication], exceptingWindows: [SCWindow]) { kind = .applications(including.map(\\.processID)) }
    init(desktopIndependentWindow: SCWindow) { kind = .window }
}
final class SCStreamConfiguration {
    var width = 0, height = 0, queueDepth = 0, sampleRate = 0, channelCount = 0
    var minimumFrameInterval = CMTime.zero
    var showsCursor = true, capturesAudio = false, excludesCurrentProcessAudio = false, captureMicrophone = false
    var microphoneCaptureDeviceID: String?
}
struct ScreenCaptureRuntimeDelegateProxy {}
struct SCStream { let filter: SCContentFilter; let configuration: SCStreamConfiguration; let delegate: ScreenCaptureRuntimeDelegateProxy }
struct MeetingSession { let timebase = 0 }
enum Health { case waiting }
enum CaptureMethod { case screenCaptureKit, avCaptureSession }
struct MeetingAudioTrack {
    let id: UUID; let kind: MeetingAudioTrackKind; let sourceIdentifier: String; let sourceDisplayName: String
    let format: Int?; let timebase: Int; let health: Health; let chunks: [Int]; let captureMethod: CaptureMethod
}
'''
    for marker in ["nonisolated enum MeetingCaptureMode:", "nonisolated enum MeetingMicrophoneRole:", "nonisolated struct MeetingMicrophoneIdentity:", "nonisolated struct MeetingApplicationIdentity:", "nonisolated struct MeetingRecordingDefaults:", "nonisolated struct MeetingPlatformProfile:", "nonisolated struct MeetingCaptureConfiguration:", "nonisolated enum MeetingModelValidationError:", "nonisolated enum MeetingCaptureScope:", "nonisolated enum MeetingAudioTrackKind:"]:
        swift += declaration(models, marker) + "\n"
    swift += (ROOT / "Sources/Fluid/Services/Meeting/MeetingRecordingSource.swift").read_text() + "\n"
    swift += (ROOT / "Sources/Fluid/Services/Meeting/MeetingPCMStoragePolicy.swift").read_text() + "\n"
    swift += declaration(engine, "nonisolated enum MeetingScreenCaptureAudioSettings") + "\n"
    swift += "enum Catalog { static let preferredFallbackBundleIdentifiers: [String] = []\n" + declaration(engine, "static func resolveApplication(") + "\n}\n"
    swift += "enum Runtime {\n" + declaration(engine, "private struct BuiltStream").replace("private ", "") + "\n"
    swift += declaration(engine, "private static func buildStream(").replace("private ", "") + "\n"
    swift += declaration(engine, "private nonisolated static func makeTracks(").replace("private ", "") + "\n"
    swift += "static func selectWindow(for app: SCRunningApplication, in content: SCShareableContent, preferredWindowID: UInt32?) -> SCWindow? { nil }\n}\n"
    swift += '''
@main struct Run {
    static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ reason: String) { precondition(value, reason); count += 1 }
        let mic = MeetingMicrophoneIdentity(captureDeviceID: "mic", avCaptureDeviceID: "av-mic", displayName: "Mic")
        let copies = [MeetingApplicationIdentity(bundleIdentifier: "chrome", processID: 10, displayName: "Chrome"), MeetingApplicationIdentity(bundleIdentifier: "chrome", processID: 20, displayName: "Chrome")]
        let detected = try Catalog.resolveApplication(from: copies, preferredBundleIdentifier: "chrome", preferredProcessID: 20, requirePreferredApplication: true)
        check(detected.processID == 20, "Detected start preserves process identity instead of choosing the first copy")
        do {
            _ = try Catalog.resolveApplication(from: copies, preferredBundleIdentifier: "chrome", preferredProcessID: 30, requirePreferredApplication: true)
            preconditionFailure("Missing detected process cannot capture a different copy")
        } catch { check(true, "Missing detected process fails closed") }
        let all = MeetingCaptureConfiguration(mode: .systemAudio, title: "Meeting", microphone: mic)
        try all.validate()
        let tracks = Runtime.makeTracks(session: MeetingSession(), configuration: all)
        check(Set(tracks.map(\\.kind)) == [.applicationAudio, .microphone], "System capture always has two tracks")
        check(tracks.first?.sourceIdentifier == "system-audio", "System audio is not attributed to an arbitrary app")
        check(MeetingPCMStoragePolicy.trackCount(for: .systemAudio) == 2, "Storage reserves both tracks")
        check(MeetingRecordingDefaults.unconfigured.mode == .systemAudio, "New default captures computer audio")
        var old = MeetingRecordingDefaults.unconfigured
        old.mode = .inRoom; old.languageCode = "de"
        let normalized = old.preferringLastPickedApplication(nil)
        check(normalized.mode == .systemAudio && normalized.languageCode == "de" && old.mode == .inRoom, "Old mic-only defaults normalize without rewriting history or language")
        old.mode = .onlineCall
        check(old.preferringLastPickedApplication(nil).mode == .systemAudio, "Old Automatic becomes system audio")
        let legacy = MeetingCaptureConfiguration(mode: .inRoom, title: "Old", microphone: mic)
        try legacy.validate()
        check(Runtime.makeTracks(session: MeetingSession(), configuration: legacy).count == 1, "Old mic-only recordings remain supported")
        let decoded = try JSONDecoder().decode(MeetingCaptureConfiguration.self, from: JSONEncoder().encode(all))
        check(decoded == all, "System source round-trips")
        let chrome = MeetingApplicationIdentity(bundleIdentifier: "chrome", processID: 10, displayName: "Chrome")
        let second = MeetingApplicationIdentity(bundleIdentifier: "chrome", processID: 20, displayName: "Chrome")
        let other = MeetingApplicationIdentity(bundleIdentifier: "other", processID: 30, displayName: "Other")
        let choices = MeetingRecordingSourceResolver.applicationChoices(from: [chrome, other, second])
        check(choices.count == 2 && choices[0].processID == nil && choices[0].capturesAllInstances == true, "One app row explicitly covers every instance")
        SCShareableContent.fixture = .init(applications: [chrome, second, other].map { .init(bundleIdentifier: $0.bundleIdentifier, processID: $0.processID!, applicationName: $0.displayName) }, displays: [.init(displayID: 1)])
        let broad = try await Runtime.buildStream(application: nil, microphone: mic, includeMicrophone: true)
        check(broad.stream.filter.kind == .all, "Automatic includes all apps, not a first-app fallback")
        check(broad.stream.configuration.capturesAudio && broad.stream.configuration.captureMicrophone, "System and microphone capture are enabled")
        check(broad.stream.configuration.microphoneCaptureDeviceID == "av-mic", "Selected microphone is preserved")
        check(!broad.stream.configuration.showsCursor && broad.stream.configuration.width == 2, "Audio capture uses minimal video configuration")
        let group = try await Runtime.buildStream(application: choices[0], microphone: mic, includeMicrophone: true)
        check(group.stream.filter.kind == .applications([10, 20]), "All Chrome instances included, other app excluded")
        let exact = try await Runtime.buildStream(application: second, microphone: mic, includeMicrophone: true)
        check(exact.stream.filter.kind == .applications([20]), "Detected call keeps exact process")
        SCShareableContent.fixture = .init(applications: [], displays: [.init(displayID: 1)])
        let empty = try await Runtime.buildStream(application: nil, microphone: mic, includeMicrophone: true)
        check(empty.stream.filter.kind == .all, "No open app is required for Automatic")
        do { _ = try await Runtime.buildStream(application: choices[0], microphone: mic, includeMicrophone: true); preconditionFailure("Missing app cannot broaden capture") }
        catch MeetingCaptureError.applicationUnavailable { count += 1 }
        SCShareableContent.fail = true
        do { _ = try await Runtime.buildStream(application: nil, microphone: mic, includeMicrophone: true); preconditionFailure("Denied audio access cannot become mic-only") }
        catch MeetingCaptureError.screenCapturePermissionDenied { count += 1 }
        SCShareableContent.fail = false
        SCShareableContent.fixture = .init(applications: [], displays: [])
        do { _ = try await Runtime.buildStream(application: nil, microphone: mic, includeMicrophone: true); preconditionFailure("No display cannot become mic-only") }
        catch MeetingCaptureError.noCaptureDisplay { count += 1 }
        var missingApp = all; missingApp.mode = .onlineCall
        do { try missingApp.validate(); preconditionFailure("App mode requires its app") }
        catch MeetingModelValidationError.missingOnlineApplication { count += 1 }
        var wrongScope = all; wrongScope.application = chrome
        do { try wrongScope.validate(); preconditionFailure("System mode cannot hide an app filter") }
        catch MeetingModelValidationError.unexpectedSystemApplication { count += 1 }
        print("PASS: \\(count) production computer-audio checks")
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="fluidvoice-system-audio-") as directory:
        path = Path(directory)
        (path / "Checks.swift").write_text(swift)
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(path / "Checks.swift"), "-o", str(path / "checks")], env=env, check=True)
        subprocess.run([str(path / "checks")], env=env, check=True)


if __name__ == "__main__":
    main()
