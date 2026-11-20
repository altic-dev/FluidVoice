import AVFoundation
import Foundation

/// Kept only in memory until a correction is explicitly saved. Independent of pronunciation matching.
nonisolated struct DictionaryCorrectionRecording: Sendable {
    static let sampleRate = 16_000
    static let maximumSamples = sampleRate * 60 * 15
    static let lifetime: TimeInterval = 120

    let id = UUID()
    let capturedAt: Date
    let model: String
    let rawTranscript: String
    let samples: [Float]

    init?(model: String, rawTranscript: String, samples: [Float], now: Date = Date()) {
        guard !model.isEmpty, !rawTranscript.isEmpty, rawTranscript.utf16.count <= 100_000,
              !samples.isEmpty, samples.count <= Self.maximumSamples else { return nil }
        self.capturedAt = now
        self.model = model
        self.rawTranscript = rawTranscript
        self.samples = samples
    }
}

nonisolated struct DictionaryCorrectionExample: Sendable {
    let id: UUID
    let recording: DictionaryCorrectionRecording
    let originalText: String
    let correctedText: String
    let heardWord: String
    let correctedWord: String

    /// Store only the dictated insertion, never the surrounding document or conversation.
    static func make(
        id: UUID, recording: DictionaryCorrectionRecording, before: String, after: String,
        insertedRange: NSRange, heardWord: String, correctedWord: String, now: Date = Date()
    ) -> Self? {
        let old = before as NSString, new = after as NSString
        let start = insertedRange.location, length = insertedRange.length
        guard now.timeIntervalSince(recording.capturedAt) < DictionaryCorrectionRecording.lifetime,
              old.length <= 100_000, new.length <= 100_000,
              start >= 0, length > 0, start <= old.length, length <= old.length - start,
              start <= new.length, !heardWord.isEmpty, !correctedWord.isEmpty else { return nil }
        let newLength = length + new.length - old.length
        guard newLength > 0, newLength <= new.length - start,
              old.substring(to: start) == new.substring(to: start),
              old.substring(from: start + length) == new.substring(from: start + newLength) else { return nil }
        let original = old.substring(with: insertedRange)
        let corrected = new.substring(with: NSRange(location: start, length: newLength))
        guard original != corrected else { return nil }
        return Self(
            id: id,
            recording: recording,
            originalText: original,
            correctedText: corrected,
            heardWord: heardWord,
            correctedWord: correctedWord
        )
    }
}

/// A local, portable dataset. No upload, automatic training, or age-based deletion.
actor DictionaryCorrectionArchive {
    static let shared = DictionaryCorrectionArchive()
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FluidVoice/Dictionary/TrainingExamples", isDirectory: true)

    struct Metadata: Codable, Sendable {
        let schemaVersion: Int
        let id: UUID
        let recordingID: UUID
        let capturedAt: Date
        let acceptedAt: Date
        let model: String
        let rawTranscript: String
        let originalText: String
        let correctedText: String
        let heardWord: String
        let correctedWord: String
        let audioFile: String
        let sampleRate: Int
        let frameCount: Int
    }

    enum ArchiveError: Error { case capacityReached, invalidAudio, unsafeDirectory }

    private let directory: URL
    private let maximumBytes: Int
    private let maximumExamples: Int

    init(directory: URL = DictionaryCorrectionArchive.directory, maximumBytes: Int = 512 * 1024 * 1024, maximumExamples: Int = 2000) {
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.maximumExamples = maximumExamples
    }

    func saveAccepted(_ example: DictionaryCorrectionExample, now: Date = Date()) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: self.directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard try self.directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw ArchiveError.unsafeDirectory
        }
        let final = self.directory.appendingPathComponent(example.id.uuidString, isDirectory: true)
        if fm.fileExists(atPath: final.path) { return }
        let items = try fm.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let exampleCount = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.count
        guard exampleCount < self.maximumExamples else { throw ArchiveError.capacityReached }
        var usedBytes = 0
        for item in items {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw ArchiveError.unsafeDirectory }
            if values.isDirectory == true {
                // Inspect just our two fixed files, never traverse user-added subdirectories.
                for name in ["audio.wav", "example.json"] {
                    let file = item.appendingPathComponent(name)
                    if fm.fileExists(atPath: file.path) {
                        usedBytes += try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    }
                }
            }
        }
        let samples = example.recording.samples
        guard !samples.isEmpty, samples.count <= DictionaryCorrectionRecording.maximumSamples,
              samples.allSatisfy(\.isFinite) else { throw ArchiveError.invalidAudio }
        let metadata = Metadata(
            schemaVersion: 1,
            id: example.id,
            recordingID: example.recording.id,
            capturedAt: example.recording.capturedAt,
            acceptedAt: now,
            model: example.recording.model,
            rawTranscript: example.recording.rawTranscript,
            originalText: example.originalText,
            correctedText: example.correctedText,
            heardWord: example.heardWord,
            correctedWord: example.correctedWord,
            audioFile: "audio.wav",
            sampleRate: DictionaryCorrectionRecording.sampleRate,
            frameCount: samples.count
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(metadata)
        guard usedBytes + samples.count * MemoryLayout<Float>.size + json.count + 4096 <= self.maximumBytes else {
            throw ArchiveError.capacityReached
        }
        let staging = self.directory.appendingPathComponent(".pending-\(example.id.uuidString)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let audio = staging.appendingPathComponent("audio.wav")
        try Self.writeAudio(samples, to: audio)
        let metadataURL = staging.appendingPathComponent("example.json")
        try json.write(to: metadataURL, options: .atomic)
        for file in [audio, metadataURL] {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let readme = self.directory.appendingPathComponent("README.txt")
        if !fm.fileExists(atPath: readme.path) {
            let description = """
            FluidVoice local correction examples (schema version 1)

            Each UUID folder contains audio.wav and example.json from an explicitly saved dictionary correction.
            Audio is the complete dictation: mono, 16000 Hz, Float32 PCM WAV.
            rawTranscript is the speech result; originalText is the delivered text; correctedText is the user edit.
            AI cleanup may have changed originalText. Review examples before using them for training.
            Surrounding document text is excluded. Nothing is uploaded or automatically trained.
            Saved examples do not expire and are independent of transcription history.
            You can copy or delete these folders. Collection stops at 512 MiB or 2000 folders without deleting examples.
            Folders beginning with .pending- are incomplete writes and should not be used for training.
            """
            try Data(description.utf8).write(to: readme, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: readme.path)
        }
        // Publish only complete audio/text pairs. History cleanup never owns this folder.
        try fm.moveItem(at: staging, to: final)
    }

    private static func writeAudio(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(DictionaryCorrectionRecording.sampleRate), channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
              let channel = buffer.floatChannelData?[0] else { throw ArchiveError.invalidAudio }
        // Bounded scratch space; retain original Float32 PCM without lossy encoding.
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for start in stride(from: 0, to: samples.count, by: 4096) {
            let count = min(4096, samples.count - start)
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { channel.update(from: base.advanced(by: start), count: count) }
            }
            try file.write(from: buffer)
        }
    }
}
