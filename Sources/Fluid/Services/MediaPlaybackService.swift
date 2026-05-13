import Foundation
#if arch(arm64)
import MediaRemoteAdapter
#endif

/// What `MediaPlaybackService` did at the start of a transcription session.
/// Stored on `ASRService` so the matching restore at stop knows whether to
/// resume playback, restore the system volume, or do nothing.
///
/// The duck case carries a `SystemVolumeSnapshot` rather than a single
/// `Float` so output devices that expose only per-channel volume (no master)
/// can have their stereo balance restored exactly. A flat scalar would
/// collapse L/R to their average on every duck cycle.
enum MediaSessionAction: Equatable {
    case none
    case paused
    case ducked(previousVolume: SystemVolumeSnapshot)
}

/// Volume the system output is dropped to while ducking. 10% of full scale —
/// quiet enough that the music doesn't compete with dictation, loud enough
/// that the user knows something's still playing.
private let kDuckTargetVolume: Float = 0.10

/// Length of the fade ramp in seconds. Short enough that the duck has
/// fully landed before the user starts dictating, long enough to read as a
/// fade rather than a hard cut.
private let kFadeDuration: TimeInterval = 0.1

/// Number of discrete steps in the fade ramp. 30 steps over 100ms is 300 Hz,
/// well above the threshold where you'd hear the staircase. The fade only
/// covers the second half of the duck (the first half is a synchronous snap
/// in `duckSystemVolume()` for snappy feel) so a relaxed 100ms tail reads
/// as a soft landing rather than a long fade.
private let kFadeSteps = 30

/// Service that wraps MediaRemoteAdapter's MediaController to provide
/// controlled pause/resume functionality during transcription, plus a
/// volume-duck path for users who want music to keep playing quietly.
///
/// Pause path: only pauses if media is currently playing, and only resumes
/// if we were the ones who paused it.
///
/// Duck path: snapshots the current default output device volume, sets it to
/// `kDuckTargetVolume`, and restores the snapshotted value on stop.
@MainActor
final class MediaPlaybackService {
    static let shared = MediaPlaybackService()

    #if arch(arm64)
    private let mediaController = MediaController()
    #endif

    /// Holds the in-flight volume-fade task so a new fade can cancel any
    /// previous one (e.g. the user releases the hotkey before the
    /// fade-down has finished, and the fade-up needs to take over cleanly).
    private var activeFadeTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

    #if arch(arm64)
    /// Pauses system media playback if something is currently playing.
    ///
    /// - Returns: `true` if we successfully paused playback, `false` if nothing was playing
    ///   or if we couldn't determine playback state.
    ///
    /// - Note: Uses a local one-shot gate to protect against `MediaRemoteAdapter`
    ///   firing the `getTrackInfo` callback more than once, which would otherwise
    ///   crash with `EXC_BREAKPOINT` (SIGTRAP) due to double-resume of a
    ///   `CheckedContinuation`.
    func pauseIfPlaying() async -> Bool {
        return await withCheckedContinuation { continuation in
            let resumeLock = NSLock()
            var didResume = false

            func resumeOnce(_ value: Bool) {
                var shouldResume = false

                resumeLock.lock()
                if !didResume {
                    didResume = true
                    shouldResume = true
                }
                resumeLock.unlock()

                guard shouldResume else {
                    DebugLogger.shared.warning(
                        "MediaPlaybackService: Suppressed duplicate resume (MediaRemoteAdapter callback fired more than once)",
                        source: "MediaPlaybackService"
                    )
                    return
                }

                continuation.resume(returning: value)
            }

            self.mediaController.getTrackInfo { [weak self] trackInfo in
                guard let self = self else {
                    resumeOnce(false)
                    return
                }

                // If no track info is available, nothing is playing
                guard let trackInfo = trackInfo else {
                    DebugLogger.shared.debug(
                        "MediaPlaybackService: No track info available, nothing to pause",
                        source: "MediaPlaybackService"
                    )
                    resumeOnce(false)
                    return
                }

                // Determine if media is currently playing
                // Use isPlaying if available, otherwise check playbackRate
                let isPlaying: Bool
                if let playing = trackInfo.payload.isPlaying {
                    isPlaying = playing
                } else {
                    // playbackRate of 1.0 typically means playing, 0.0 means paused
                    isPlaying = (trackInfo.payload.playbackRate ?? 0.0) > 0.0
                }

                // Log what we found
                DebugLogger.shared.debug(
                    """
                    MediaPlaybackService: Track info received
                    - App: \(trackInfo.payload.applicationName ?? "Unknown")
                    - Bundle: \(trackInfo.payload.bundleIdentifier ?? "Unknown")
                    - Title: \(trackInfo.payload.title ?? "Unknown")
                    - isPlaying: \(trackInfo.payload.isPlaying?.description ?? "nil")
                    - playbackRate: \(trackInfo.payload.playbackRate?.description ?? "nil")
                    - Determined playing: \(isPlaying)
                    """,
                    source: "MediaPlaybackService"
                )

                if isPlaying {
                    DebugLogger.shared.info(
                        "MediaPlaybackService: Media is playing, sending pause command",
                        source: "MediaPlaybackService"
                    )
                    self.mediaController.pause()
                    resumeOnce(true)
                } else {
                    DebugLogger.shared.debug(
                        "MediaPlaybackService: Media is not playing, no action needed",
                        source: "MediaPlaybackService"
                    )
                    resumeOnce(false)
                }
            }
        }
    }

    /// Resumes media playback only if we were the ones who paused it.
    ///
    /// - Parameter wePaused: `true` if `pauseIfPlaying()` returned `true` for this session.
    func resumeIfWePaused(_ wePaused: Bool) async {
        guard wePaused else {
            DebugLogger.shared.debug(
                "MediaPlaybackService: We didn't pause media, not resuming",
                source: "MediaPlaybackService"
            )
            return
        }

        DebugLogger.shared.info(
            "MediaPlaybackService: Resuming media playback (we paused it)",
            source: "MediaPlaybackService"
        )

        // Use explicit play() command - never toggle
        self.mediaController.play()
    }
    #else
    // Intel Mac stub - media control not available
    func pauseIfPlaying() async -> Bool {
        DebugLogger.shared.debug(
            "MediaPlaybackService: Not available on Intel Macs",
            source: "MediaPlaybackService"
        )
        return false
    }

    func resumeIfWePaused(_ wePaused: Bool) async {
        // No-op on Intel
    }
    #endif

    // MARK: - Duck path

    /// Snapshots the current system output volume and starts a background
    /// fade-down to `kDuckTargetVolume`. Returns the snapshot so the caller
    /// can hand it back to `restoreSystemVolume(previous:)` on stop.
    ///
    /// Returns `nil` if the volume couldn't be read, or if the user's
    /// volume is already at or below the duck target — in either case we
    /// don't touch the volume at all (and the matching restore becomes a
    /// no-op).
    func duckSystemVolume() -> SystemVolumeSnapshot? {
        guard let snapshot = SystemVolumeController.currentSnapshot() else {
            DebugLogger.shared.debug(
                "MediaPlaybackService: Couldn't read system volume, skipping duck",
                source: "MediaPlaybackService"
            )
            return nil
        }
        let previousScalar = snapshot.averageScalar
        guard previousScalar > kDuckTargetVolume else {
            DebugLogger.shared.debug(
                "MediaPlaybackService: Volume \(String(format: "%.2f", previousScalar)) already ≤ duck target, skipping",
                source: "MediaPlaybackService"
            )
            return nil
        }

        // Snap the volume halfway down to the duck target SYNCHRONOUSLY before
        // starting the detached fade. This puts a clearly audible drop on the
        // user's ear within the round-trip time of one CoreAudio property
        // write (sub-millisecond), bypassing both Task.detached scheduling
        // latency and the fade ramp's first few steps where the per-step
        // volume change is too small to perceive. The detached fade then
        // smoothly lands the rest of the way to kDuckTargetVolume.
        let immediateDrop = (previousScalar + kDuckTargetVolume) / 2
        SystemVolumeController.setVolume(immediateDrop)

        DebugLogger.shared.info(
            "🔉 Snapped \(String(format: "%.2f", previousScalar)) → \(String(format: "%.2f", immediateDrop)), fading to \(String(format: "%.2f", kDuckTargetVolume)) over \(kFadeDuration)s",
            source: "MediaPlaybackService"
        )
        self.startFade(from: immediateDrop, to: kDuckTargetVolume, restoreSnapshot: nil)
        return snapshot
    }

    /// Fades the system output volume back up to the snapshot captured by
    /// `duckSystemVolume()`. Reads the live volume first so a mid-fade
    /// interruption (user released the hotkey before the duck-down had
    /// finished) restarts cleanly from wherever the volume actually is.
    /// Re-applies the snapshot exactly at the end of the ramp so per-channel
    /// detail (e.g. uneven L/R balance) comes back precisely rather than
    /// flattened to the fade scalar.
    func restoreSystemVolume(previous: SystemVolumeSnapshot?) {
        guard let previous else { return }
        let start = SystemVolumeController.currentVolume() ?? kDuckTargetVolume
        let target = previous.averageScalar
        DebugLogger.shared.info(
            "🔊 Fading system volume \(String(format: "%.2f", start)) → \(String(format: "%.2f", target)) over \(kFadeDuration)s",
            source: "MediaPlaybackService"
        )
        self.startFade(from: start, to: target, restoreSnapshot: previous)
    }

    /// Cancels any in-flight fade and starts a new one from `start` to
    /// `target` over `kFadeDuration`. Runs detached so the main actor isn't
    /// blocked between steps; CoreAudio property writes are thread-safe.
    ///
    /// - Parameter restoreSnapshot: If non-nil, this snapshot is applied
    ///   exactly at the end of the ramp instead of writing the scalar
    ///   `target`. Used by the fade-up so per-channel volume detail
    ///   (uneven L/R balance) is restored precisely. Pass `nil` for the
    ///   fade-down — there's nothing to preserve at the duck target.
    private func startFade(from start: Float, to target: Float, restoreSnapshot: SystemVolumeSnapshot?) {
        self.activeFadeTask?.cancel()

        let stepCount = kFadeSteps
        let stepDelay = kFadeDuration / Double(stepCount)
        let stepDelayNanos = UInt64(stepDelay * 1_000_000_000)
        let delta = (target - start) / Float(stepCount)

        self.activeFadeTask = Task.detached(priority: .userInitiated) {
            for step in 1...stepCount {
                if Task.isCancelled { return }
                let value = start + delta * Float(step)
                _ = SystemVolumeController.setVolume(value)
                if step < stepCount {
                    try? await Task.sleep(nanoseconds: stepDelayNanos)
                }
            }
            // Land exactly on the target if we weren't cancelled —
            // floating-point drift across the steps could otherwise leave
            // us a hair off (e.g. 0.0997 instead of 0.10). If the caller
            // asked for an exact snapshot restore, prefer that over the
            // scalar target so per-channel detail comes back intact.
            if !Task.isCancelled {
                if let restoreSnapshot {
                    _ = SystemVolumeController.restore(restoreSnapshot)
                } else {
                    _ = SystemVolumeController.setVolume(target)
                }
            }
        }
    }

    // MARK: - Unified restore

    /// Undoes whatever `MediaSessionAction` was taken at recording start.
    func restore(from action: MediaSessionAction) async {
        switch action {
        case .none:
            return
        case .paused:
            await self.resumeIfWePaused(true)
        case .ducked(let previousVolume):
            self.restoreSystemVolume(previous: previousVolume)
        }
    }
}
