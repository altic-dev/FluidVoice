import AVFoundation
import CoreMedia
import Foundation

/// PCM-first capture boundary beneath `MeetingAudioChunkWriter`. `MeetingAudioChunkWriter` remains
/// the sole ordering/producer-epoch/canonical
/// retiming/format-boundary/gap/splice authority; a sink only durably persists the exact bytes it
/// is handed.
///
/// One accepted `append` call's durability facts. `framesAccepted` is what the caller's timeline
/// counted for this call; `framesWritten` is what the sink actually persisted for the same call.
/// The sink's packet-writing API reports the count it actually accepted. A conforming sink reports
/// `framesWritten == framesAccepted` on success and throws a poisoning short-write error otherwise.
/// A caller comparing the two fields never needs to infer persistence from producer enqueue.
nonisolated struct MeetingPCMAppendReceipt: Equatable, Sendable {
    var framesAccepted: Int64
    var framesWritten: Int64
    var presentationStart: CMTime
    var presentationDuration: CMTime
}

/// Immutable facts about a successfully finalized, durably published container. Every field is
/// independently re-derived from the finalized file on disk after a fresh read-only reopen — never
/// carried forward from the in-memory append tally — so a caller can trust this value even if the
/// in-process writer state were somehow wrong.
nonisolated struct MeetingPCMFinalization: Equatable, Sendable {
    var relativeFilePath: String
    var byteCount: Int64
    var sha256: String
    var sampleRate: Double
    var channelCount: Int
    var frameCount: Int64
}

nonisolated enum MeetingPCMSinkError: Error, Equatable, Sendable {
    case alreadyBegun
    case notBegun
    case unsupportedClientFormat(String)
    case invalidRelativePath(String)
    case pathEscapesSessionDirectory(String)
    case symlinkComponentRejected(String)
    case finalPathAlreadyExists(String)
    case partialPathAlreadyExists(String)
    case invalidSampleBuffer(String)
    case nonFiniteSample
    case formatMismatch(expected: String, actual: String)
    case invalidPresentationTime
    case shortWrite(expectedFrames: Int64, writtenFrames: Int64)
    case writeFailed(OSStatus)
    case alreadyFinalizedOrCancelled
    case finalizationVerificationFailed(String)
    case underlyingFileError(String)
}

nonisolated extension MeetingPCMSinkError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .formatMismatch(expected, actual): return "PCM format mismatch (expected \(expected); received \(actual))."
        case let .unsupportedClientFormat(detail): return "Unsupported PCM format: \(detail)."
        case let .shortWrite(expected, written): return "PCM short write (expected \(expected) frames; wrote \(written))."
        case let .writeFailed(status): return "PCM write failed (OSStatus \(status))."
        case let .invalidSampleBuffer(detail): return "Invalid PCM sample buffer: \(detail)."
        case let .finalizationVerificationFailed(detail): return "PCM finalization verification failed: \(detail)."
        case let .underlyingFileError(detail): return "PCM file error: \(detail)."
        default: return String(describing: self)
        }
    }
}

/// Threading contract (load-bearing, not advisory): real-time audio producers may only enqueue
/// work onto the existing serialized, non-real-time writer queue that already owns canonical
/// ordering/timing (e.g. `MeetingAudioChunkWriter`'s internal dispatch queue). Every method on this
/// protocol — `begin`, `append`, and `cancel` — is called exclusively from that one serialized
/// writer queue, off the real-time audio callback thread. After a chunk is removed from active
/// capture, exclusive ownership may transfer to a finalization queue for `finalize`; no append or
/// cancel may then overlap it. No method here performs internal locking against concurrent callers.
///
/// Producer enqueue is not durability: a real-time producer successfully enqueuing a buffer onto
/// the writer queue says nothing about whether that buffer has reached, or will ever reach, stable
/// storage. `append` returning success only means the sink's underlying container write call
/// completed for that one buffer; it is `finalize()` succeeding — after a full close, reopen and
/// decoded-frame/format re-verification — that is this protocol's only durability boundary. A
/// crash, sink failure, or cancellation at any point before `finalize()` returns success must be
/// treated by the caller as an unfinalized/failed chunk, never as a partially-durable one; this
/// protocol makes no partial-recovery claim.
nonisolated protocol MeetingAudioChunkSink: AnyObject, Sendable {
    /// The owned staging path selected by `begin`, when available. This is recorded in the
    /// durability ledger so recovery can identify the exact partial artifact for this chunk.
    var partialRelativeFilePath: String? { get }

    /// Opens the sink for exactly one chunk at `relativeFilePath`, which must be confined to the
    /// implementation's session directory (non-absolute, no traversal, no symlink component).
    /// `contract` is fixed for the sink's entire lifetime: every subsequent `append` must match its
    /// semantic rate/channel/layout identity. Interleaved and planar Float32 payloads are both
    /// accepted only when their AudioBufferList topology validates. May be called at most once.
    func begin(relativeFilePath: String, format: AVAudioFormat, contract: MeetingPCMFormatContract) throws

    /// Appends one already-retimed, already-canonical, ready Float32 LPCM `CMSampleBuffer`. Only
    /// buffers with finite samples, a valid numeric presentation timestamp, and a format matching
    /// the one passed to `begin` are accepted; everything else throws without touching durable
    /// state. No resampling, channel clamping, or sample-value conversion is performed; a sink may
    /// pack planar channels into canonical interleaved storage without changing order or values.
    func append(_ sampleBuffer: CMSampleBuffer) throws -> MeetingPCMAppendReceipt

    /// Finalizes: closes the underlying container, reopens it read-only, verifies decoded frame
    /// count/sample rate/channel count against the sink's own written totals, then atomically
    /// publishes it at its final (non-`.partial`) path only if every check passes. Any poisoning
    /// write recorded by a prior `append`, or any verification failure here, fails this call and
    /// guarantees the final path is never created.
    func finalize() -> Result<MeetingPCMFinalization, MeetingPCMSinkError>

    /// Abandons the in-progress chunk and removes any partial artifact. After `cancel()` — and
    /// after any unresolved write failure — the final (non-`.partial`) path must never come into
    /// existence for this instance.
    func cancel()
}
