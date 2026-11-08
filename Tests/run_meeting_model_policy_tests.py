#!/usr/bin/env python3
"""Exercise production meeting model policy without models, capture, or user preferences."""
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def declaration(source: str, marker: str) -> str:
    start = source.index(marker)
    brace = source.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main() -> None:
    developer = os.environ.get("DEVELOPER_DIR") or subprocess.check_output(["xcode-select", "-p"], text=True).strip()
    if not (Path(developer) / "Platforms/MacOSX.platform").is_dir():
        raise SystemExit("Full Xcode is required; set DEVELOPER_DIR to an installed Xcode.app.")
    env = dict(os.environ, DEVELOPER_DIR=developer)
    provider = (ROOT / "Sources/Fluid/Services/FluidAudioProvider.swift").read_text()
    config = (ROOT / "Sources/Fluid/Services/Meeting/MeetingProcessingConfiguration.swift").read_text()
    pipeline = (ROOT / "Sources/Fluid/Services/Meeting/MeetingProcessingPipeline.swift").read_text()
    catalog = (ROOT / "Sources/Fluid/Services/ParakeetSpeechModelCatalog.swift").read_text()
    languages = re.search(r"supportedLanguageCodes: (\[[\s\S]*?\])", catalog.split("static let v3 =", 1)[1]).group(1)
    swift = '''import Foundation
enum SettingsStore {
    enum SpeechModel: String, Sendable {
        case parakeetTDT = "parakeet-tdt", parakeetTDTv2 = "parakeet-tdt-v2"
        case fluidParakeetPro = "fluid-parakeet-pro", whisperTiny = "whisper-tiny"
    }
}
enum VoiceEngineLanguageCatalog { static let parakeetV3LanguageIDs: Set<String> = LANGUAGES }
enum ParakeetSpeechModelCatalog {
    struct Descriptor: Sendable { let modelID: String; let supportedLanguageCodes: Set<String> }
    static let pro = Descriptor(modelID: "fluid-parakeet-pro", supportedLanguageCodes: VoiceEngineLanguageCatalog.parakeetV3LanguageIDs)
    static let v3 = Descriptor(modelID: "parakeet-tdt", supportedLanguageCodes: VoiceEngineLanguageCatalog.parakeetV3LanguageIDs)
    static func descriptor(forModelID id: String) -> Descriptor? {
        if id == pro.modelID { return pro }
        if id == v3.modelID { return v3 }
        if id == "parakeet-tdt-v2" { return Descriptor(modelID: id, supportedLanguageCodes: ["en"]) }
        return nil
    }
}
enum MeetingProcessingCheckpoint { static let currentDiarizationFingerprint = "fixture" }
@MainActor enum SpeechModelInstallationSnapshot {
    struct Probe { enum Kind { case parakeet(ParakeetSpeechModelCatalog.Descriptor) }; let modelID: String; let kind: Kind }
    static var installed: Set<String> = []
    static var observed: [String] = []
    static var failure = false
    static func scan(_ probes: [Probe]) async throws -> Set<String> {
        observed = probes.map(\\.modelID)
        if failure { throw CocoaError(.fileReadUnknown) }
        await Task.yield()
        return installed
    }
}
'''.replace("LANGUAGES", languages)
    for marker in ["nonisolated enum MeetingProviderOptionsError", "nonisolated struct MeetingProviderOptions"]:
        swift += declaration(provider, marker) + "\n"
    for marker in ["nonisolated enum MeetingConfigFingerprintEncoding", "nonisolated struct MeetingFinalProcessingConfiguration", "nonisolated struct MeetingLiveCaptionsConfiguration"]:
        swift += declaration(config, marker) + "\n"
    swift += declaration((ROOT / "Sources/Fluid/Services/Meeting/Backend/MeetingTranscriptionBackend.swift").read_text(), "nonisolated struct MeetingBackendID:") + "\n"
    swift += "@MainActor enum MeetingProcessingPipeline { nonisolated static let pipelineVersion = 1\n"
    swift += declaration(pipeline, "static func defaultPreferredASRModel()") + "\n}\n"
    swift += '''
@main struct Run {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let pro = "fluid-parakeet-pro", v3 = "parakeet-tdt"
        for (installed, expected): (Set<String>, SettingsStore.SpeechModel) in [
            ([pro, v3], .fluidParakeetPro), ([pro], .fluidParakeetPro), ([v3], .parakeetTDT),
            ([], .fluidParakeetPro), (["parakeet-tdt-v2", "whisper-tiny"], .fluidParakeetPro)
        ] {
            SpeechModelInstallationSnapshot.installed = installed
            let model = try await MeetingProcessingPipeline.defaultPreferredASRModel()
            check(model == expected, "Installation policy")
            check(SpeechModelInstallationSnapshot.observed == [pro, v3], "Only the two meeting models are scanned")
            for language in VoiceEngineLanguageCatalog.parakeetV3LanguageIDs {
                let config = MeetingFinalProcessingConfiguration(preferredASRModel: model, languageCode: language)
                let options = try MeetingProviderOptions.resolve(config)
                check(options.model == expected && config.languageCode == language, "Selected model and language are pinned")
                check(!options.vocabularyBoostingEnabled && !options.pronunciationMatchingEnabled && !options.customDictionaryRewritingEnabled && !options.experimentalUnifiedFinalEnabled, "No dictation enhancements")
            }
        }
        let frozen = MeetingFinalProcessingConfiguration(preferredASRModel: .parakeetTDT, languageCode: "de")
        SpeechModelInstallationSnapshot.installed = [pro]
        let next = try await MeetingProcessingPipeline.defaultPreferredASRModel()
        check(next == .fluidParakeetPro && frozen.asrModel == v3 && frozen.languageCode == "de", "Installation changes affect only later requests")
        check(frozen.identityFingerprint != MeetingFinalProcessingConfiguration(languageCode: "de").identityFingerprint, "Fallback uses its own resume fingerprint")
        check(MeetingFinalProcessingConfiguration().languageCode == "en", "English remains the initial language")
        check(MeetingFinalProcessingConfiguration().asrModel == MeetingFinalProcessingConfiguration.defaultASRModel, "Default model identity")
        let legacy = MeetingFinalProcessingConfiguration(asrModel: "parakeet-tdt-v2", preferredASRModel: .fluidParakeetPro)
        do {
            _ = try MeetingProviderOptions.resolve(legacy)
            preconditionFailure("V2 must be rejected for meeting transcription")
        } catch MeetingProviderOptionsError.unsupportedASRModel("parakeet-tdt-v2") { checks += 1 }
        for language in VoiceEngineLanguageCatalog.parakeetV3LanguageIDs {
            let redirected = MeetingFinalProcessingConfiguration(preferredASRModel: .parakeetTDTv2, languageCode: language)
            check(try MeetingProviderOptions.resolve(redirected).model == .fluidParakeetPro, "V2 preference cannot select V2")
        }
        let saved = MeetingBackendID.legacyCompatibility
        check(saved.forNewMeetingAttempt == .productionDefault, "Old rollback settings use current model policy")
        check(saved == .legacyCompatibility, "The old preference is not rewritten")
        let restored = try JSONDecoder().decode(MeetingBackendID.self, from: JSONEncoder().encode(saved))
        check(restored == saved, "Historical backend identifiers still decode")
        check(MeetingBackendID.parakeetNemotron.forNewMeetingAttempt == .parakeetNemotron, "Current backend remains selected")
        let unknown = MeetingBackendID(rawValue: "unknown")
        check(unknown.forNewMeetingAttempt == unknown, "Unknown selections stay fail-closed")
        do {
            _ = try MeetingProviderOptions.resolve(MeetingFinalProcessingConfiguration(languageCode: "zh"))
            preconditionFailure("Unsupported language must fail")
        } catch MeetingProviderOptionsError.unsupportedLanguageCode { checks += 1 }
        SpeechModelInstallationSnapshot.failure = true
        do {
            _ = try await MeetingProcessingPipeline.defaultPreferredASRModel()
            preconditionFailure("Discovery failure must not become a default")
        } catch is CocoaError { checks += 1 }
        SpeechModelInstallationSnapshot.failure = false
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MeetingProcessingPipeline.defaultPreferredASRModel()
        }
        do { _ = try await cancelled.value; preconditionFailure("Cancellation must propagate") }
        catch is CancellationError { checks += 1 }
        check(MeetingLiveCaptionsConfiguration().modelRepositoryID == "FluidInference/parakeet-realtime-eou-120m-coreml", "Streaming captions remain separate")
        print("PASS: \\(checks) meeting model policy checks")
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="fluidvoice-meeting-model-") as directory:
        path = Path(directory)
        (path / "ModelPolicy.swift").write_text(swift)
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", str(path / "ModelPolicy.swift"), "-o", str(path / "checks")], env=env, check=True)
        subprocess.run([str(path / "checks")], env=env, check=True)


if __name__ == "__main__":
    main()
