import AudioToolbox
import AVFoundation
import Foundation

/// Writes packets produced by the repository's realtime-safe direct-capture ring.
final class CallPCMTrackWriter: @unchecked Sendable {
    private static let maximumFramesPerPacket: AVAudioFrameCount = 8192
    private static let maximumInsertedSilenceSeconds: Double = 1

    private let source: CallAudioSource
    private let url: URL
    private let captureStartedHostTime: UInt64
    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private var reusableBuffer: AVAudioPCMBuffer?
    private var streamSampleRate: Double?
    private var firstHostTime: UInt64?
    private var previousHostTime: UInt64?
    private var previousFrameCount = 0
    private var hasWrittenAudio = false
    private var storedError: Error?

    init(source: CallAudioSource, url: URL, captureStartedHostTime: UInt64) {
        self.source = source
        self.url = url
        self.captureStartedHostTime = captureStartedHostTime
    }

    func append(
        samples: UnsafePointer<Float>,
        frameCount: Int,
        sampleRate: Double,
        hostTime: UInt64
    ) throws {
        guard frameCount > 0, sampleRate > 0 else { return }
        self.lock.lock()
        defer { self.lock.unlock() }
        if let storedError = self.storedError {
            throw storedError
        }

        if self.audioFile == nil {
            try self.prepare(sampleRate: sampleRate)
            self.firstHostTime = hostTime
            self.streamSampleRate = sampleRate
        } else if let streamSampleRate = self.streamSampleRate,
                  abs(streamSampleRate - sampleRate) > 0.5
        {
            throw CallTranscriptionError.audioWriterFailed(
                "Captured audio sample rate changed during the call."
            )
        }

        guard let audioFile = self.audioFile,
              let buffer = self.reusableBuffer,
              let channel = buffer.floatChannelData?.pointee,
              let streamSampleRate = self.streamSampleRate
        else {
            throw CallTranscriptionError.audioWriterFailed("Could not prepare the PCM writer.")
        }
        guard frameCount <= Int(buffer.frameCapacity) else {
            throw CallTranscriptionError.audioWriterFailed(
                "Captured audio packet exceeded the supported frame count."
            )
        }

        try self.insertMissingSilence(
            beforeHostTime: hostTime,
            sampleRate: streamSampleRate,
            audioFile: audioFile,
            buffer: buffer,
            channel: channel
        )

        buffer.frameLength = AVAudioFrameCount(frameCount)
        channel.update(from: samples, count: frameCount)
        try audioFile.write(from: buffer)
        self.previousHostTime = hostTime
        self.previousFrameCount = frameCount
        self.hasWrittenAudio = true
    }

    func record(error: Error) {
        self.lock.lock()
        if self.storedError == nil {
            self.storedError = error
        }
        self.lock.unlock()
    }

    func finish() throws -> CapturedAudioTrack? {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let storedError = self.storedError {
            throw storedError
        }
        guard self.hasWrittenAudio, let firstHostTime = self.firstHostTime else {
            self.audioFile = nil
            self.reusableBuffer = nil
            try? FileManager.default.removeItem(at: self.url)
            return nil
        }

        self.audioFile = nil
        self.reusableBuffer = nil

        let delta = firstHostTime >= self.captureStartedHostTime
            ? firstHostTime - self.captureStartedHostTime
            : 0
        let offset = Double(AudioConvertHostTimeToNanos(delta)) / 1_000_000_000
        return CapturedAudioTrack(
            source: self.source,
            url: self.url,
            startOffsetSeconds: offset.isFinite ? max(0, offset) : 0
        )
    }

    private func prepare(sampleRate: Double) throws {
        try? FileManager.default.removeItem(at: self.url)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: Self.maximumFramesPerPacket
            )
        else {
            throw CallTranscriptionError.audioWriterFailed("Could not create the PCM format.")
        }

        self.audioFile = try AVAudioFile(
            forWriting: self.url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        self.reusableBuffer = buffer
    }

    private func insertMissingSilence(
        beforeHostTime hostTime: UInt64,
        sampleRate: Double,
        audioFile: AVAudioFile,
        buffer: AVAudioPCMBuffer,
        channel: UnsafeMutablePointer<Float>
    ) throws {
        guard let previousHostTime = self.previousHostTime,
              self.previousFrameCount > 0,
              hostTime >= previousHostTime
        else { return }

        let hostDeltaSeconds = Double(
            AudioConvertHostTimeToNanos(hostTime - previousHostTime)
        ) / 1_000_000_000
        let expectedDeltaSeconds = Double(self.previousFrameCount) / sampleRate
        let missingSeconds = hostDeltaSeconds - expectedDeltaSeconds
        let toleranceSeconds = max(0.001, expectedDeltaSeconds * 0.25)
        guard missingSeconds > toleranceSeconds else { return }

        let insertedSilenceSeconds = min(missingSeconds, Self.maximumInsertedSilenceSeconds)
        var missingFrames = Int((insertedSilenceSeconds * sampleRate).rounded())
        while missingFrames > 0 {
            let frameCount = min(missingFrames, Int(buffer.frameCapacity))
            buffer.frameLength = AVAudioFrameCount(frameCount)
            channel.update(repeating: 0, count: frameCount)
            try audioFile.write(from: buffer)
            missingFrames -= frameCount
        }
    }
}
