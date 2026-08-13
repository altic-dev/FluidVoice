import Foundation
#if arch(arm64)
import MediaRemoteAdapter
#endif

#if arch(arm64)
@MainActor
protocol MediaPlaybackControlling {
    func getTrackInfo(_ onReceive: @escaping (TrackInfo?) -> Void)
    func pause()
    func play()
}

extension MediaController: MediaPlaybackControlling {}
#endif

/// Service that wraps MediaRemoteAdapter's MediaController to provide
/// controlled pause/resume functionality during transcription.
///
/// This service ensures we only pause media if it's currently playing,
/// and only resume if we were the ones who paused it.
@MainActor
final class MediaPlaybackService {
    #if arch(arm64)
    typealias TimeoutScheduler = (
        _ delay: TimeInterval,
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> Void

    /// The pinned adapter's two-second deadline can occupy roughly 2.1 seconds
    /// in run-loop slices. Leave additional time for process and callback delivery.
    static let nowPlayingQueryTimeoutSeconds: TimeInterval = 2.5

    private static let productionTimeoutScheduler: TimeoutScheduler = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
    }

    static let shared = MediaPlaybackService(
        mediaController: MediaController(),
        queryTimeoutSeconds: MediaPlaybackService.nowPlayingQueryTimeoutSeconds,
        timeoutScheduler: MediaPlaybackService.productionTimeoutScheduler
    )

    private let mediaController: any MediaPlaybackControlling
    private let queryTimeoutSeconds: TimeInterval
    private let timeoutScheduler: TimeoutScheduler

    /// Creates an isolated service with injectable dependencies for deterministic tests.
    init(
        mediaController: any MediaPlaybackControlling,
        queryTimeoutSeconds: TimeInterval,
        timeoutScheduler: @escaping TimeoutScheduler
    ) {
        self.mediaController = mediaController
        self.queryTimeoutSeconds = queryTimeoutSeconds
        self.timeoutScheduler = timeoutScheduler
    }
    #else
    static let shared = MediaPlaybackService()

    private init() {}
    #endif

    // MARK: - Public API

    #if arch(arm64)
    /// Pauses system media playback if something is currently playing.
    ///
    /// - Returns: `true` if a pause request was issued, `false` if nothing was playing or
    ///   if we couldn't determine playback state. The media adapter does not acknowledge
    ///   command completion.
    ///
    /// - Note: Uses a local one-shot gate to protect against `MediaRemoteAdapter`
    ///   firing the `getTrackInfo` callback more than once, which would otherwise
    ///   crash with `EXC_BREAKPOINT` (SIGTRAP) due to double-resume of a
    ///   `CheckedContinuation`.
    func pauseIfPlaying() async -> Bool {
        return await withCheckedContinuation { continuation in
            let queryStartedAt = DispatchTime.now().uptimeNanoseconds
            let resumeLock = NSLock()
            var didResume = false

            @MainActor
            func elapsedMilliseconds() -> UInt64 {
                (DispatchTime.now().uptimeNanoseconds - queryStartedAt) / 1_000_000
            }

            @discardableResult
            @MainActor
            func resumeOnce(
                _ value: Bool,
                logDuplicate: Bool = true,
                beforeResume: () -> Void = {}
            ) -> Bool {
                var shouldResume = false

                resumeLock.lock()
                if !didResume {
                    didResume = true
                    shouldResume = true
                }
                resumeLock.unlock()

                guard shouldResume else {
                    if logDuplicate {
                        DebugLogger.shared.warning(
                            """
                            MediaPlaybackService: Suppressed late or duplicate media callback \
                            (elapsedMs: \(elapsedMilliseconds()))
                            """,
                            source: "MediaPlaybackService"
                        )
                    }
                    return false
                }

                beforeResume()
                continuation.resume(returning: value)
                return true
            }

            self.timeoutScheduler(self.queryTimeoutSeconds) {
                if resumeOnce(false, logDuplicate: false) {
                    DebugLogger.shared.warning(
                        """
                        MediaPlaybackService: Now Playing query timed out; leaving playback unchanged \
                        (elapsedMs: \(elapsedMilliseconds()))
                        """,
                        source: "MediaPlaybackService"
                    )
                }
            }

            self.mediaController.getTrackInfo { [weak self] trackInfo in
                guard let self = self else {
                    DebugLogger.shared.warning(
                        """
                        MediaPlaybackService: Service released before query completed \
                        (elapsedMs: \(elapsedMilliseconds()))
                        """,
                        source: "MediaPlaybackService"
                    )
                    resumeOnce(false)
                    return
                }

                // If no track info is available, nothing is playing
                guard let trackInfo = trackInfo else {
                    DebugLogger.shared.debug(
                        """
                        MediaPlaybackService: No track info available, nothing to pause \
                        (elapsedMs: \(elapsedMilliseconds()))
                        """,
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
                    - elapsedMs: \(elapsedMilliseconds())
                    """,
                    source: "MediaPlaybackService"
                )

                if isPlaying {
                    resumeOnce(true) {
                        DebugLogger.shared.info(
                            """
                            MediaPlaybackService: Media is playing, sending pause command \
                            (elapsedMs: \(elapsedMilliseconds()))
                            """,
                            source: "MediaPlaybackService"
                        )
                        self.mediaController.pause()
                    }
                } else {
                    DebugLogger.shared.debug(
                        """
                        MediaPlaybackService: Media is not playing, no action needed \
                        (elapsedMs: \(elapsedMilliseconds()))
                        """,
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
}
