#if DICTIONARY_ARCHIVE_STANDALONE
import AVFoundation
import Foundation

@main
enum DictionaryCorrectionArchiveTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("correction-archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let samples: [Float] = (0..<16_000).map { sin(Float($0) * 0.01) * 0.25 }
        guard let recording = DictionaryCorrectionRecording(model: "fixture", rawTranscript: "Send Nora the report.", samples: samples, now: now) else { fatalError("recording") }
        let before = "PRIVATE PREFIX 🐈 Send Nora the report. PRIVATE SUFFIX"
        let after = "PRIVATE PREFIX 🐈 Send Norah the report. PRIVATE SUFFIX"
        let range = (before as NSString).range(of: "Send Nora the report.")
        let id = UUID()
        guard let example = DictionaryCorrectionExample.make(
            id: id,
            recording: recording,
            before: before,
            after: after,
            insertedRange: range,
            heardWord: "Nora",
            correctedWord: "Norah",
            now: now
        ) else { fatalError("example") }
        precondition(example.originalText == "Send Nora the report.")
        precondition(example.correctedText == "Send Norah the report.")
        precondition(!FileManager.default.fileExists(atPath: root.path), "Detection alone must not write anything")
        precondition(DictionaryCorrectionExample.make(
            id: id,
            recording: recording,
            before: before,
            after: after.replacingOccurrences(of: "SUFFIX", with: "EDIT"),
            insertedRange: range,
            heardWord: "Nora",
            correctedWord: "Norah",
            now: now
        ) == nil)
        for invalid in [NSRange(location: NSNotFound, length: 1), NSRange(location: 0, length: Int.max), NSRange(location: 0, length: 0)] {
            precondition(DictionaryCorrectionExample.make(
                id: id,
                recording: recording,
                before: before,
                after: after,
                insertedRange: invalid,
                heardWord: "Nora",
                correctedWord: "Norah",
                now: now
            ) == nil)
        }
        precondition(DictionaryCorrectionExample.make(
            id: id,
            recording: recording,
            before: before,
            after: after,
            insertedRange: range,
            heardWord: "Nora",
            correctedWord: "Norah",
            now: now.addingTimeInterval(121)
        ) == nil)
        let archive = DictionaryCorrectionArchive(directory: root)
        try await archive.saveAccepted(example, now: now)
        let folder = root.appendingPathComponent(id.uuidString)
        let json = try Data(contentsOf: folder.appendingPathComponent("example.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(DictionaryCorrectionArchive.Metadata.self, from: json)
        precondition(metadata.originalText == example.originalText && metadata.correctedText == example.correctedText)
        precondition(metadata.rawTranscript == recording.rawTranscript && metadata.recordingID == recording.id)
        precondition(String(data: json, encoding: .utf8)?.contains("PRIVATE") == false)
        let audio = try AVAudioFile(forReading: folder.appendingPathComponent("audio.wav"))
        precondition(audio.length == Int64(samples.count) && audio.processingFormat.sampleRate == 16_000)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096) else { fatalError("buffer") }
        var decoded: [Float] = []
        while audio.framePosition < audio.length {
            try audio.read(into: buffer)
            precondition(buffer.frameLength > 0)
            decoded.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData?[0], count: Int(buffer.frameLength)))
        }
        precondition(decoded == samples, "No missing or changed PCM")
        try await archive.saveAccepted(example)
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        precondition(Set(entries) == Set([id.uuidString, "README.txt"]), "Duplicate acceptance must not duplicate audio")
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("audio.wav").path)[.posixPermissions] as? NSNumber
        precondition(permissions?.intValue == 0o600)
        let limited = DictionaryCorrectionArchive(directory: root, maximumBytes: 1)
        let other = DictionaryCorrectionExample(
            id: UUID(),
            recording: recording,
            originalText: example.originalText,
            correctedText: example.correctedText,
            heardWord: "Nora",
            correctedWord: "Norah"
        )
        do { try await limited.saveAccepted(other); fatalError("Quota must reject") } catch DictionaryCorrectionArchive.ArchiveError.capacityReached {}
        let preserved = try Data(contentsOf: folder.appendingPathComponent("example.json"))
        precondition(preserved == json, "A full archive must preserve existing examples")
        let reopened = DictionaryCorrectionArchive(directory: root)
        try await reopened.saveAccepted(example)
        precondition(FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio.wav").path))
        print("PASS: insertion-only text, UTF-16 ranges, stale/invalid rejection, no detection writes, complete WAV/JSON round trip, exact PCM, deduplication, permissions, quota preservation, reopen")
    }
}
#endif
