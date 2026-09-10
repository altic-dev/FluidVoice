import Foundation

// Display-only fixture; the test executable does not load the private provider or settings.
enum PrivateAIModelRegistry {
    struct Model { let displayName: String }
    static func canonicalModelID(for value: String) -> String? {
        value == "legacy-mini" ? "mini-internal" : nil
    }

    static func model(id: String) -> Model? {
        id == "mini-internal" ? Model(displayName: "Fluid-1 Mini") : nil
    }
}

@main
struct HistoryPresentationTests {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let savedFile = directory.appendingPathComponent("saved.wav")
        try Data([0]).write(to: savedFile)
        let exists: @Sendable (String) -> Bool = { name in
            precondition(!Thread.isMainThread, "Availability checks must not run on the main thread")
            return FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        let initial = await HistoryAudioAvailability.scan(fileNames: ["saved.wav", "missing.wav", "saved.wav"], exists: exists)
        precondition(initial == ["saved.wav"], "Missing restored files must not appear available")
        try FileManager.default.removeItem(at: savedFile)
        let deleted = await HistoryAudioAvailability.scan(fileNames: ["saved.wav"], exists: exists)
        precondition(deleted.isEmpty, "Refresh must remove externally deleted files")
        let emptyAudio = await HistoryAudioAvailability.scan(fileNames: []) { _ in
            preconditionFailure("No metadata must mean no file queries")
        }
        precondition(emptyAudio.isEmpty)
        let cancelled = Task {
            await HistoryAudioAvailability.scan(fileNames: ["saved.wav"], exists: exists)
        }
        cancelled.cancel()
        _ = await cancelled.value
        print("PASS: background audio availability, missing/deleted files, empty metadata and cancellation completion")
        let audio = DictationAudioMetadata(
            fileName: "saved.wav",
            durationMilliseconds: 10_300,
            byteCount: 331_000,
            sampleRate: 16_000,
            channels: 1,
            model: nil
        )
        let enhanced = TranscriptionHistoryEntry(
            rawText: " raw words ",
            processedText: " final words ",
            appName: "Notes",
            windowTitle: "",
            wasAIProcessed: true,
            processingModel: "historical-model",
            transcriptionDurationMilliseconds: 57,
            aiProcessingDurationMilliseconds: 104,
            aiTokensPerSecond: 746,
            audio: audio
        )
        let before = enhanced
        precondition(enhanced.clipboardText == "final words")
        precondition(enhanced == before, "Reading copy text must not mutate an entry")
        let raw = TranscriptionHistoryEntry(
            rawText: " raw words ",
            processedText: "  ",
            appName: "Notes",
            windowTitle: "",
            wasAIProcessed: false
        )
        precondition(raw.clipboardText == "raw words")
        let empty = TranscriptionHistoryEntry(
            rawText: " ",
            processedText: " ",
            appName: "Notes",
            windowTitle: "",
            wasAIProcessed: false
        )
        precondition(empty.clipboardText == nil)
        let decoded = try JSONDecoder().decode(TranscriptionHistoryEntry.self, from: JSONEncoder().encode(enhanced))
        precondition(decoded == enhanced, "Presentation must preserve persisted fields")
        precondition(decoded.processingModel == "historical-model")
        precondition(TranscriptionHistoryEntry.formattedTokensPerSecond(746, compact: true) == "746 tok/s")
        precondition(TranscriptionHistoryEntry.formattedDuration(milliseconds: 104) == "104 ms")
        let cases = [
            ("Hello world", "Hello world"),
            ("Hello world", "Hello, world!"),
            ("red blue", "green blue"),
            ("", "new words"),
            ("old words", ""),
            ("one  two\nthree", "One two\n\nthree."),
            ("hello hello world", "hello world"),
            ("வணக்கம் 👋🏽 café", "வணக்கம் 👋🏽 Café!"),
        ]
        for (original, final) in cases {
            guard let diff = HistoryTextDiff.compare(original: original, final: final) else {
                preconditionFailure("Expected a bounded comparison")
            }
            precondition(diff.original.map(\.text).joined() == original)
            precondition(diff.final.map(\.text).joined() == final)
            precondition(diff.hasChanges == (original != final))
        }
        guard let replacement = HistoryTextDiff.compare(original: "red blue", final: "green blue") else {
            preconditionFailure("Expected a replacement comparison")
        }
        precondition(replacement.original.filter(\.changed).map(\.text).joined() == "red")
        precondition(replacement.final.filter(\.changed).map(\.text).joined() == "green")
        precondition(HistoryTextDiff.compare(original: String(repeating: "a ", count: 2000), final: "") == nil)
        precondition(HistoryTextDiff.compare(original: String(repeating: "x", count: 24_001), final: "") == nil)
        precondition(ModelDisplayName.forID("mini-internal") == "Fluid 1 Mini")
        precondition(ModelDisplayName.forID("legacy-mini") == "Fluid 1 Mini")
        precondition(ModelDisplayName.forID("  mini-internal  ") == "Fluid 1 Mini")
        precondition(ModelDisplayName.forID("external/model-v2") == "external/model-v2")
        precondition(ModelDisplayName.forID("") == "")
        precondition(decoded.processingModel == "historical-model", "Display lookup cannot rewrite stored model IDs")
        print("PASS: final/raw/empty copy, immutable entry, audio and timing round-trip, metric labels")
        print("PASS: unchanged/replaced/added/deleted text, punctuation, whitespace, Unicode, repeated words and bounded diff")
        print("PASS: display names, aliases, unknown-provider fallback and original stored model ID")
    }
}
