import AVFoundation
import Foundation

// Stage E of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md` (§3): materializing one analysis
// epoch's audio from the validated manifest. Every span re-opens only its confined, verified
// chunk path, slices exactly its `sourceLocalInterval` out of the decoded file, mono-mixes and
// resamples to the 16 kHz analysis stream, and concatenates in analysis order. The returned
// per-span sample ranges are the exact analysis-span mappings the backend's word/activity
// conversion relies on.
//
// Fail-closed on any TOCTOU drift: the file's byte count, SHA-256 and decoded facts must still
// match what the manifest observed, and the slice must be backed by real decoded frames. Nothing
// here guesses priming, invents samples or bridges across spans that are not in the epoch.

/// Sample range of one span inside its epoch's materialized buffer, in analysis order.
nonisolated struct MeetingMaterializedSpanSamples: Equatable, Sendable {
    let spanID: String
    let sampleRange: Range<Int>
}

/// One epoch's 16 kHz mono analysis audio plus its exact span mappings.
nonisolated struct MeetingMaterializedEpoch: Equatable, Sendable {
    let epochID: MeetingAnalysisEpochID
    let samples: [Float]
    let sampleRate: Double
    let spanSamples: [MeetingMaterializedSpanSamples]

    var durationSeconds: Double {
        self.sampleRate > 0 ? Double(self.samples.count) / self.sampleRate : 0
    }
}

nonisolated enum MeetingEpochMaterializationError: LocalizedError, Equatable {
    case unknownSpan(spanID: String)
    case pathRejected(spanID: String)
    case fileMissing(spanID: String)
    case byteCountChanged(spanID: String)
    case hashChanged(spanID: String)
    case unreadable(spanID: String)
    /// The file on disk no longer decodes to what the manifest observed (rate, channels, frames),
    /// or it no longer contains the frames the span's source interval requires. The payload lists
    /// the mismatched facts only, never a localized system string.
    case decodedFactsChanged(spanID: String, detail: String)
    case emptySlice(spanID: String)
    /// Conservative in-memory safety bound for the pre-production PCM working buffer. A durable
    /// disk-backed working store is the production follow-up; this bound keeps the current
    /// immutable in-memory implementation from growing without limit.
    case sampleLimitExceeded(spanID: String, sampleCount: Int)

    var errorDescription: String? {
        switch self {
        case let .unknownSpan(spanID):
            return "Analysis span \"\(spanID)\" is not part of its track manifest."
        case let .pathRejected(spanID):
            return "Analysis span \"\(spanID)\" resolves outside the session directory."
        case let .fileMissing(spanID):
            return "The chunk file for analysis span \"\(spanID)\" is missing."
        case let .byteCountChanged(spanID):
            return "The chunk file for analysis span \"\(spanID)\" changed size since observation."
        case let .hashChanged(spanID):
            return "The chunk file for analysis span \"\(spanID)\" changed content since observation."
        case let .unreadable(spanID):
            return "The chunk file for analysis span \"\(spanID)\" could not be decoded."
        case let .decodedFactsChanged(spanID, detail):
            return "The chunk file for analysis span \"\(spanID)\" no longer decodes to the observed facts (\(detail))."
        case let .emptySlice(spanID):
            return "Analysis span \"\(spanID)\" maps to no decodable audio frames."
        case let .sampleLimitExceeded(spanID, sampleCount):
            return "Analysis span \"\(spanID)\" exceeds the PCM materialization safety limit (\(sampleCount) samples)."
        }
    }

    var isSampleLimitExceeded: Bool {
        if case .sampleLimitExceeded = self { return true }
        return false
    }
}

/// Epoch materialization is backend work, injectable so backend tests exercise orchestration
/// without real audio; the production implementation below is the single file-touching one.
nonisolated protocol MeetingEpochAudioMaterializing: Sendable {
    func materialize(
        epoch: MeetingAnalysisEpochRecord,
        track: MeetingAnalysisTrackManifest,
        manifest: MeetingAnalysisManifest,
        sessionDirectory: URL
    ) async throws -> MeetingMaterializedEpoch
}

nonisolated struct MeetingEpochAudioMaterializer: MeetingEpochAudioMaterializing {
    /// 256M mono Float32 samples occupies 1 GiB, allowing about 140 minutes across two
    /// continuous 16 kHz tracks. This bounds retained PCM, not total process memory: decoding
    /// and conversion need additional buffers. Replace with a scoped immutable disk working
    /// store before production retention requirements grow further.
    static let conservativeSampleLimit = 256 * 1024 * 1024
    let sampleRate: Double

    init(sampleRate: Double = 16_000) {
        self.sampleRate = sampleRate
    }

    func materialize(
        epoch: MeetingAnalysisEpochRecord,
        track: MeetingAnalysisTrackManifest,
        manifest _: MeetingAnalysisManifest,
        sessionDirectory: URL
    ) async throws -> MeetingMaterializedEpoch {
        let spansByID = Dictionary(
            track.spans.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Read all spans first, then convert one contiguous format/era run in one converter call.
        // This is deliberately not a per-span resampler: converter state (including its filter
        // tail) is preserved across chunk boundaries, while a changed era/format/layout forces a
        // clean restart. Epochs contain no gaps, so concatenating only their spans cannot bridge
        // an uncovered interval.
        var sourceSlices: [SourceSlice] = []
        sourceSlices.reserveCapacity(epoch.spanIDs.count)
        for spanID in epoch.spanIDs {
            try Task.checkCancellation()
            guard let span = spansByID[spanID] else {
                throw MeetingEpochMaterializationError.unknownSpan(spanID: spanID)
            }
            let slice = try autoreleasepool {
                try self.readSpanAudio(span, sessionDirectory: sessionDirectory)
            }
            sourceSlices.append(slice)
        }

        var samples: [Float] = []
        var spanSamples: [MeetingMaterializedSpanSamples] = []
        spanSamples.reserveCapacity(sourceSlices.count)
        var runStart = 0
        while runStart < sourceSlices.count {
            var runEnd = runStart + 1
            while runEnd < sourceSlices.count,
                  sourceSlices[runEnd].conversionKey == sourceSlices[runStart].conversionKey
            {
                runEnd += 1
            }
            let run = Array(sourceSlices[runStart..<runEnd])
            let converted = try autoreleasepool {
                try self.convert(run)
            }
            guard samples.count + converted.samples.count <= Self.conservativeSampleLimit else {
                throw MeetingEpochMaterializationError.sampleLimitExceeded(
                    spanID: run.last?.spanID ?? "unknown",
                    sampleCount: samples.count + converted.samples.count
                )
            }
            let outputOffset = samples.count
            samples.append(contentsOf: converted.samples)
            var previousSourceFrames = 0
            for slice in run {
                let sourceEnd = previousSourceFrames + slice.samples.count
                let lower = Int((Double(previousSourceFrames) / slice.sampleRate * self.sampleRate).rounded())
                let upper = Int((Double(sourceEnd) / slice.sampleRate * self.sampleRate).rounded())
                let runLower = min(max(lower, 0), converted.samples.count)
                let runUpper = min(max(upper, runLower), converted.samples.count)
                spanSamples.append(MeetingMaterializedSpanSamples(
                    spanID: slice.spanID,
                    sampleRange: (outputOffset + runLower)..<(outputOffset + runUpper)
                ))
                previousSourceFrames = sourceEnd
            }
            // The converter's actual frame count is authoritative. Rounding above normally lands
            // exactly on it; pin the final range to the actual end so no converter tail is lost.
            if let last = spanSamples.indices.last {
                let current = spanSamples[last]
                spanSamples[last] = MeetingMaterializedSpanSamples(
                    spanID: current.spanID,
                    sampleRange: current.sampleRange.lowerBound..<(outputOffset + converted.samples.count)
                )
            }
            runStart = runEnd
        }

        return MeetingMaterializedEpoch(
            epochID: epoch.id,
            samples: samples,
            sampleRate: self.sampleRate,
            spanSamples: spanSamples
        )
    }

    private struct SourceSlice {
        let spanID: String
        let samples: [Float]
        let sampleRate: Double
        let conversionKey: String
    }

    private struct ConvertedRun {
        let samples: [Float]
    }

    private func convert(_ run: [SourceSlice]) throws -> ConvertedRun {
        guard let first = run.first,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: first.sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(run.reduce(0) { $0 + $1.samples.count })
              )
        else {
            throw MeetingEpochMaterializationError.emptySlice(spanID: run.first?.spanID ?? "unknown")
        }
        buffer.frameLength = buffer.frameCapacity
        guard let destination = buffer.floatChannelData?[0] else {
            throw MeetingEpochMaterializationError.emptySlice(spanID: first.spanID)
        }
        // Copy directly into the converter input. Flattening first retained another entire
        // native-rate recording alongside the slices and this PCM buffer.
        var offset = 0
        for slice in run {
            slice.samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress {
                    destination.advanced(by: offset).update(from: base, count: source.count)
                }
            }
            offset += slice.samples.count
        }
        do {
            return try ConvertedRun(samples: AudioBufferConverter.monoSamples(
                from: buffer,
                targetSampleRate: self.sampleRate
            ))
        } catch {
            throw MeetingEpochMaterializationError.unreadable(spanID: first.spanID)
        }
    }

    /// Re-verifies the chunk against the manifest's observation, then decodes exactly the span's
    /// source-local interval and returns native-rate mono samples. Resampling is performed once per
    /// contiguous run by `convert(_:)`, rather than once per span.
    private func readSpanAudio(
        _ span: MeetingAnalysisSpan,
        sessionDirectory: URL
    ) throws -> SourceSlice {
        if let encoding = span.chunk.analysisEncoding, encoding != .linearPCMFloat32CAFV1 {
            throw MeetingEpochMaterializationError.unreadable(spanID: span.id)
        }
        let url: URL
        do {
            url = try MeetingChunkPathConfinement.containedURL(
                sessionDirectory: sessionDirectory,
                relativePath: span.chunk.relativeFilePath
            )
        } catch {
            throw MeetingEpochMaterializationError.pathRejected(spanID: span.id)
        }

        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular
        else {
            throw MeetingEpochMaterializationError.fileMissing(spanID: span.id)
        }
        guard (attributes[.size] as? NSNumber)?.int64Value == span.storedByteCount else {
            throw MeetingEpochMaterializationError.byteCountChanged(spanID: span.id)
        }
        guard let digest = MeetingChunkPathConfinement.sha256Hex(contentsOf: url) else {
            try Task.checkCancellation()
            throw MeetingEpochMaterializationError.unreadable(spanID: span.id)
        }
        guard digest == span.storedSHA256.lowercased() else {
            throw MeetingEpochMaterializationError.hashChanged(spanID: span.id)
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw MeetingEpochMaterializationError.unreadable(spanID: span.id)
        }
        let format = file.processingFormat
        let observed = span.observed.decoded
        guard format.sampleRate == observed.sampleRate,
              Int(format.channelCount) == observed.channelCount,
              Int64(file.length) == observed.frameCount
        else {
            let detail = "rate \(format.sampleRate) vs \(observed.sampleRate); channels \(format.channelCount) vs \(observed.channelCount); frames \(file.length) vs \(observed.frameCount)"
            throw MeetingEpochMaterializationError.decodedFactsChanged(spanID: span.id, detail: detail)
        }

        let startFrame = AVAudioFramePosition(
            (span.sourceLocalInterval.start * observed.sampleRate).rounded(.down)
        )
        let endFrame = min(
            AVAudioFramePosition((span.sourceLocalInterval.end * observed.sampleRate).rounded(.up)),
            file.length
        )
        guard endFrame > startFrame else {
            throw MeetingEpochMaterializationError.emptySlice(spanID: span.id)
        }
        let frameCount = AVAudioFrameCount(endFrame - startFrame)
        guard format.commonFormat == .pcmFormatFloat32,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else {
            throw MeetingEpochMaterializationError.unreadable(spanID: span.id)
        }
        file.framePosition = startFrame
        // Reuse one bounded read buffer and copy each returned block into its final position.
        // AVAudioFile can return short reads; never assume a read filled the requested frames.
        guard let part = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: min(frameCount, 32_768)) else {
            throw MeetingEpochMaterializationError.unreadable(spanID: span.id)
        }
        var framesRead: AVAudioFrameCount = 0
        while framesRead < frameCount {
            try Task.checkCancellation()
            let requested = min(frameCount - framesRead, part.frameCapacity)
            part.frameLength = 0
            do {
                try file.read(into: part, frameCount: requested)
            } catch {
                throw MeetingEpochMaterializationError.unreadable(spanID: span.id)
            }
            guard part.frameLength > 0 else { break }
            let copied = Int(part.frameLength)
            guard let sourceChannels = part.floatChannelData,
                  let destinationChannels = buffer.floatChannelData else { break }
            let destinationOffset = Int(framesRead)
            if format.isInterleaved {
                // Interleaved Float32 exposes one channel pointer containing all channels.
                destinationChannels[0].advanced(by: destinationOffset * Int(format.channelCount)).update(
                    from: sourceChannels[0], count: copied * Int(format.channelCount)
                )
            } else {
                for channel in 0..<Int(format.channelCount) {
                    destinationChannels[channel].advanced(by: destinationOffset).update(
                        from: sourceChannels[channel], count: copied
                    )
                }
            }
            framesRead += part.frameLength
        }
        buffer.frameLength = framesRead
        guard AVAudioFramePosition(framesRead) == endFrame - startFrame else {
            let detail = "read \(framesRead) frames of \(endFrame - startFrame) required"
            throw MeetingEpochMaterializationError.decodedFactsChanged(spanID: span.id, detail: detail)
        }

        guard let channels = buffer.floatChannelData else {
            throw MeetingEpochMaterializationError.unreadable(spanID: span.id)
        }
        var mono = [Float](repeating: 0, count: Int(buffer.frameLength))
        if format.isInterleaved {
            let source = channels[0]
            let channelCount = Int(format.channelCount)
            for frame in 0..<mono.count {
                var value: Float = 0
                for channel in 0..<channelCount {
                    value += source[frame * channelCount + channel]
                }
                mono[frame] = value / Float(channelCount)
            }
        } else {
            let channelCount = Int(format.channelCount)
            for frame in 0..<mono.count {
                var value: Float = 0
                for channel in 0..<channelCount {
                    value += channels[channel][frame]
                }
                mono[frame] = value / Float(channelCount)
            }
        }
        try Task.checkCancellation()
        // Close the hash/open/read race: the path must still name the same bytes after decoding.
        // A replacement or in-place rewrite during the read is therefore refused rather than
        // becoming evidence under the manifest's earlier digest.
        guard MeetingChunkPathConfinement.sha256Hex(contentsOf: url) == span.storedSHA256.lowercased() else {
            try Task.checkCancellation()
            throw MeetingEpochMaterializationError.hashChanged(spanID: span.id)
        }
        let layoutDescription = format.channelLayout.map { layout in
            let ptr = layout.layout.pointee
            return "tag=\(ptr.mChannelLayoutTag);count=\(ptr.mNumberChannelDescriptions)"
        } ?? "none"
        return SourceSlice(
            spanID: span.id,
            samples: mono,
            sampleRate: observed.sampleRate,
            conversionKey: "epoch=\(span.analysisEpochID);era=\(span.captureEra.index);rate=\(observed.sampleRate);channels=\(observed.channelCount);interleaved=\(format.isInterleaved);layout=\(layoutDescription)"
        )
    }
}
