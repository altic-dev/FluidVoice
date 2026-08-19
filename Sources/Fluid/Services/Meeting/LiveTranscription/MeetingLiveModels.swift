import AVFoundation
import CoreMedia
import Foundation

/// "You" is the microphone track, "Them" is the application-audio track. No diarization live —
/// the offline pipeline resolves real speaker identity and replaces this transcript on completion.
nonisolated enum MeetingLiveSpeaker: Sendable, Equatable {
    case you
    case them
}

nonisolated enum MeetingLiveAvailability: Sendable, Equatable {
    case unavailable(reason: String)
    case degraded(reason: String)
    case available
}

nonisolated struct MeetingLiveUtterance: Identifiable, Sendable, Equatable {
    var id: UUID
    var speaker: MeetingLiveSpeaker
    var text: String
    /// Session-relative seconds, derived from capture PTS — never from arrival order.
    var start: TimeInterval
    var end: TimeInterval
}

/// `id` is minted at the turn's first partial and reused as the `MeetingLiveUtterance.id` at EOU,
/// so SwiftUI keeps one continuous row identity as the bubble "solidifies".
nonisolated struct MeetingLivePartial: Sendable, Equatable, Identifiable {
    var id: UUID
    var text: String
    var start: TimeInterval
}

/// In-memory only. Never written into `MeetingSession.transcriptSegments`, so it can never reach
/// the manifest, Copy Transcript, or Export — those all read a `MeetingSession` value, a type this
/// struct cannot become.
nonisolated struct MeetingLiveTranscriptSnapshot: Sendable, Equatable {
    private static let finalizedTurnIDCap = 64

    var utterances: [MeetingLiveUtterance] = []
    var partials: [MeetingLiveSpeaker: MeetingLivePartial] = [:]
    var availability: MeetingLiveAvailability = .unavailable(reason: "Live captions have not started.")
    /// Turn IDs whose EOU already fired — a partial for one of these is a stale, out-of-order
    /// arrival that must not resurrect a bubble. Oldest-first so eviction trims from the front.
    private(set) var finalizedTurnIDs: [UUID] = []

    static let empty = MeetingLiveTranscriptSnapshot()

    /// Inserts keeping `utterances` sorted by `start` — two engines finalize independently, so a
    /// later-arriving utterance with an earlier PTS must still land in the right place.
    func inserting(_ utterance: MeetingLiveUtterance) -> MeetingLiveTranscriptSnapshot {
        var copy = self
        let index = copy.utterances.firstIndex { $0.start > utterance.start } ?? copy.utterances.count
        copy.utterances.insert(utterance, at: index)
        copy.markFinalized(utterance.id)
        return copy
    }

    /// Replaces, never appends — and drops a partial whose turn already finalized.
    func settingPartial(_ partial: MeetingLivePartial?, for speaker: MeetingLiveSpeaker) -> MeetingLiveTranscriptSnapshot {
        var copy = self
        if let partial, !partial.text.isEmpty {
            guard !copy.finalizedTurnIDs.contains(partial.id) else { return copy }
            copy.partials[speaker] = partial
        } else {
            copy.partials.removeValue(forKey: speaker)
        }
        return copy
    }

    /// Finalizes a turn without an utterance — the echo-suppression path, where the bubble is
    /// discarded rather than solidified.
    func markingFinalized(_ id: UUID) -> MeetingLiveTranscriptSnapshot {
        var copy = self
        copy.markFinalized(id)
        return copy
    }

    private mutating func markFinalized(_ id: UUID) {
        guard !self.finalizedTurnIDs.contains(id) else { return }
        self.finalizedTurnIDs.append(id)
        if self.finalizedTurnIDs.count > Self.finalizedTurnIDCap {
            self.finalizedTurnIDs.removeFirst(self.finalizedTurnIDs.count - Self.finalizedTurnIDCap)
        }
    }

    func settingAvailability(_ availability: MeetingLiveAvailability) -> MeetingLiveTranscriptSnapshot {
        var copy = self
        copy.availability = availability
        return copy
    }
}

/// Pure row composition for the live captions card: finalized turns in transcript order, then
/// active partials bottom-pinned by turn start, so a solidifying bubble keeps its row identity.
nonisolated enum MeetingLiveBubbleComposer {
    nonisolated struct Row: Identifiable, Equatable {
        var id: UUID
        var speaker: MeetingLiveSpeaker
        var text: String
        var isPartial: Bool
        var showsLabel: Bool
    }

    static func rows(for snapshot: MeetingLiveTranscriptSnapshot) -> [Row] {
        var rows = snapshot.utterances.map {
            Row(id: $0.id, speaker: $0.speaker, text: $0.text, isPartial: false, showsLabel: false)
        }
        let activePartials = [MeetingLiveSpeaker.you, .them]
            .compactMap { speaker in snapshot.partials[speaker].map { (speaker, $0) } }
            .sorted { $0.1.start < $1.1.start }
        for (speaker, partial) in activePartials {
            rows.append(Row(id: partial.id, speaker: speaker, text: partial.text, isPartial: true, showsLabel: false))
        }

        var previousSpeaker: MeetingLiveSpeaker?
        for index in rows.indices {
            rows[index].showsLabel = rows[index].speaker != previousSpeaker
            previousSpeaker = rows[index].speaker
        }
        return rows
    }

}

nonisolated enum MeetingLiveTimeConversion {
    /// Mirrors the batch pipeline: session time is capture PTS relative to the capture origin,
    /// clamped at zero. Never derived from converted-sample counts or wall-clock arrival time.
    static func sessionSeconds(pts: CMTime, origin: CMTime) -> TimeInterval {
        guard pts.isValid, pts.isNumeric, origin.isValid, origin.isNumeric else { return 0 }
        return max(0, CMTimeGetSeconds(pts - origin))
    }
}

/// Thread-safe, set-once-per-session capture origin shared by both tracks so "You" and "Them"
/// timestamps land on the same clock.
final nonisolated class MeetingLiveOriginBox: @unchecked Sendable {
    private let lock = NSLock()
    private var origin: CMTime?

    @discardableResult
    func establish(_ pts: CMTime) -> CMTime {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let existing = self.origin {
            if pts < existing { self.origin = pts }
            return self.origin!
        }
        self.origin = pts
        return pts
    }

    var current: CMTime? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.origin
    }
}

/// Echo suppression: on speakers, the far end bleeds into the microphone track. This is text-only
/// (the offline signal scorer needs data live capture can't produce), comparing a mic utterance
/// against recently finalized "Them" text.
nonisolated enum MeetingLiveEchoFilter {
    static func recentThemText(
        from themUtterances: [MeetingLiveUtterance],
        before cutoff: TimeInterval,
        windowSeconds: TimeInterval
    ) -> String {
        themUtterances
            .filter { $0.end > cutoff - windowSeconds && $0.start < cutoff }
            .sorted { $0.start < $1.start }
            .map(\.text)
            .joined(separator: " ")
    }

    static func shouldSuppress(micText: String, recentThemText: String) -> Bool {
        guard !recentThemText.isEmpty else { return false }
        return MeetingEchoDetector.isLikelyEcho(micText: micText, remoteText: recentThemText)
    }
}

/// Copies PCM data out of a `CMSampleBuffer` immediately so nothing captured on the capture queue
/// outlives this call. Never throws into the capture callback — invalid buffers are simply dropped.
nonisolated enum MeetingLiveSampleCopy {
    struct Sample: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let pts: CMTime
        let duration: CMTime
    }

    static func copy(_ sampleBuffer: CMSampleBuffer) -> Sample? {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return nil }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let sourceFormat = AVAudioFormat(streamDescription: streamDescription)
        else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount)
        else { return nil }
        buffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.isNumeric else { return nil }

        var duration = CMSampleBufferGetDuration(sampleBuffer)
        if !duration.isValid || !duration.isNumeric || duration <= .zero {
            duration = CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(sourceFormat.sampleRate.rounded()))
        }
        return Sample(buffer: buffer, pts: pts, duration: duration)
    }
}
