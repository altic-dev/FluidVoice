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

    struct SuppressionConfiguration {
        let duckInsteadOfPausing: Bool
        let duckVolumeLevel: Float
    }

    typealias SuppressionConfigurationProvider = @MainActor () -> SuppressionConfiguration

    /// The pinned adapter's two-second deadline can occupy roughly 2.1 seconds
    /// in run-loop slices. Leave additional time for process and callback delivery.
    static let nowPlayingQueryTimeoutSeconds: TimeInterval = 2.5

    private static let productionTimeoutScheduler: TimeoutScheduler = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
    }

    static let shared = MediaPlaybackService(
        mediaController: MediaController(),
        volumeController: SystemAudioVolumeController(),
        suppressionConfigurationProvider: {
            let settings = SettingsStore.shared
            return SuppressionConfiguration(
                duckInsteadOfPausing: settings.duckMediaInsteadOfPausing,
                duckVolumeLevel: Float(settings.duckMediaVolumeLevel)
            )
        },
        queryTimeoutSeconds: MediaPlaybackService.nowPlayingQueryTimeoutSeconds,
        timeoutScheduler: MediaPlaybackService.productionTimeoutScheduler
    )

    private let mediaController: any MediaPlaybackControlling
    private let volumeController: any SystemAudioVolumeControlling
    private let suppressionConfigurationProvider: SuppressionConfigurationProvider
    private let queryTimeoutSeconds: TimeInterval
    private let timeoutScheduler: TimeoutScheduler

    /// Tracks the action we took for the current transcription session so that
    /// `resumeIfWePaused(_:)` can revert exactly what was applied.
    private enum ActiveSuppression {
        /// We sent a pause command and should send play() to restore.
        case paused
        /// We lowered the output volume. `original` is the pre-duck snapshot to
        /// restore (preserving per-channel balance); `applied` is what the device
        /// actually snapped to, used to detect user changes mid-dictation.
        case ducked(original: OutputVolumeSnapshot, applied: OutputVolumeSnapshot)
    }

    private var activeSuppression: ActiveSuppression?

    /// Creates an isolated service with injectable dependencies for deterministic tests.
    init(
        mediaController: any MediaPlaybackControlling,
        volumeController: any SystemAudioVolumeControlling,
        suppressionConfigurationProvider: @escaping SuppressionConfigurationProvider,
        queryTimeoutSeconds: TimeInterval,
        timeoutScheduler: @escaping TimeoutScheduler
    ) {
        self.mediaController = mediaController
        self.volumeController = volumeController
        self.suppressionConfigurationProvider = suppressionConfigurationProvider
        self.queryTimeoutSeconds = queryTimeoutSeconds
        self.timeoutScheduler = timeoutScheduler
    }
    #else
    static let shared = MediaPlaybackService()

    private init() {}
    #endif

    // MARK: - Public API

    #if arch(arm64)
    /// Suppresses system media while transcription is active, if something is
    /// currently playing.
    ///
    /// Depending on `SettingsStore.duckMediaInsteadOfPausing`, this either fully
    /// pauses playback or lowers the system output volume ("ducking"). The action
    /// taken is recorded so `resumeIfWePaused(_:)` can revert exactly what was done.
    ///
    /// - Returns: `true` if we took an action (pause or duck) that must later be
    ///   reverted, `false` if nothing was playing or if we couldn't determine
    ///   playback state. The media adapter does not acknowledge command completion.
    ///
    /// - Note: Uses a local one-shot gate to protect against `MediaRemoteAdapter`
    ///   firing the `getTrackInfo` callback more than once, which would otherwise
    ///   crash with `EXC_BREAKPOINT` (SIGTRAP) due to double-resume of a
    ///   `CheckedContinuation`.
    func pauseIfPlaying() async -> Bool {
        // A suppression from a previous session may not have been reverted yet: stop() flips
        // isRunning false before its (slow) final transcription pass, and only reverts media
        // afterwards, so a new dictation can start during that window. Don't begin a second
        // suppression — capturing the already-ducked volume would lose the true original and
        // could leave the Mac stuck at the ducked level. Report no new action; the in-flight
        // revert from the prior session restores the original volume.
        guard self.activeSuppression == nil else {
            DebugLogger.shared.warning(
                "MediaPlaybackService: Suppression already active from a prior session, not starting another",
                source: "MediaPlaybackService"
            )
            return false
        }

        // Keep the action stable for this request even if Settings changes while
        // MediaRemoteAdapter's asynchronous Now Playing query is in flight.
        let suppressionConfiguration = self.suppressionConfigurationProvider()

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

                // Runs exactly once, only for the winning callback, before resuming the
                // continuation, so suppression cannot be applied by a duplicate callback.
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
                    // Gate the suppression behind the same one-shot as the resume.
                    // MediaRemoteAdapter can fire this callback more than once, and ducking
                    // is not idempotent (it reads the current volume as the "original"), so a
                    // duplicate must not re-duck or overwrite `activeSuppression`.
                    resumeOnce(true) {
                        self.applySuppression(configuration: suppressionConfiguration)
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

    /// Reverts the media suppression applied for this session — resuming playback
    /// if we paused it, or restoring the output volume if we ducked it.
    ///
    /// - Parameter wePaused: `true` if `pauseIfPlaying()` returned `true` for this session.
    func resumeIfWePaused(_ wePaused: Bool) async {
        guard wePaused else {
            DebugLogger.shared.debug(
                "MediaPlaybackService: We didn't suppress media, nothing to revert",
                source: "MediaPlaybackService"
            )
            return
        }

        self.revertSuppression()
    }

    // MARK: - Suppression helpers

    /// Either pauses playback or ducks the system output volume, based on the
    /// user's setting, and records what was done in `activeSuppression`.
    private func applySuppression(configuration: SuppressionConfiguration) {
        // Ducking: lower the output volume instead of stopping playback entirely.
        if configuration.duckInsteadOfPausing,
           let original = self.volumeController.captureOutputVolume()
        {
            let target = original.scaled(by: configuration.duckVolumeLevel)
            switch self.volumeController.apply(target) {
            case .applied:
                // Re-read what the device actually snapped to (volume can be quantized to
                // coarse steps) so the restore-time change check is accurate.
                let applied = self.volumeController.reread(target) ?? target
                self.activeSuppression = .ducked(original: original, applied: applied)
                DebugLogger.shared.info(
                    "MediaPlaybackService: Ducked output volume \(original.averageLevel) -> \(applied.averageLevel) for transcription",
                    source: "MediaPlaybackService"
                )
                return

            case .partial:
                // Only some channels ducked. Undo before falling back to pausing —
                // otherwise the device would stay in a mixed left/right state for the
                // whole session with nothing left to restore it.
                if self.volumeController.apply(original) != .applied {
                    DebugLogger.shared.warning(
                        "MediaPlaybackService: Could not fully undo a partial duck, output channels may be unbalanced",
                        source: "MediaPlaybackService"
                    )
                }
                DebugLogger.shared.warning(
                    "MediaPlaybackService: Volume duck only partially applied, falling back to pausing media",
                    source: "MediaPlaybackService"
                )

            case .failed:
                DebugLogger.shared.warning(
                    "MediaPlaybackService: Failed to lower output volume, falling back to pausing media",
                    source: "MediaPlaybackService"
                )
            }
        }

        DebugLogger.shared.info(
            "MediaPlaybackService: Media is playing, sending pause command",
            source: "MediaPlaybackService"
        )
        self.mediaController.pause()
        self.activeSuppression = .paused
    }

    /// Reverts whatever `applySuppression()` did for the current session.
    private func revertSuppression() {
        switch self.activeSuppression {
        case .paused:
            DebugLogger.shared.info(
                "MediaPlaybackService: Resuming media playback (we paused it)",
                source: "MediaPlaybackService"
            )
            // Use explicit play() command - never toggle
            self.mediaController.play()

        case let .ducked(original, applied):
            // Only restore if the volume is still roughly where we left it. If the
            // user adjusted it during dictation, respect their choice and leave it.
            // Mute is checked separately from the tolerance: a deeply ducked level can
            // sit within 0.02 of zero, and restoring over a mute would turn the user's
            // audio back on against their explicit intent.
            let currentSnapshot = self.volumeController.reread(applied)
            if let currentSnapshot, self.userChangedVolume(currentSnapshot, from: applied) {
                DebugLogger.shared.info(
                    "MediaPlaybackService: Output volume changed during dictation (\(applied.averageLevel) -> \(currentSnapshot.averageLevel)), leaving as-is",
                    source: "MediaPlaybackService"
                )
            } else {
                DebugLogger.shared.info(
                    "MediaPlaybackService: Restoring output volume to \(original.averageLevel) (we ducked it)",
                    source: "MediaPlaybackService"
                )
                if self.volumeController.apply(original) != .applied {
                    // Some or all raw channel writes failed. Fall back to the HAL virtual
                    // main volume so a channel isn't left stuck at the ducked level.
                    if self.volumeController.applyVirtualMainVolume(original) {
                        DebugLogger.shared.warning(
                            "MediaPlaybackService: Raw channel restore incomplete, restored via the virtual main volume instead",
                            source: "MediaPlaybackService"
                        )
                    } else {
                        DebugLogger.shared.warning(
                            "MediaPlaybackService: Failed to restore output volume — the ducked output device may no longer be available",
                            source: "MediaPlaybackService"
                        )
                    }
                }
            }

        case .none:
            DebugLogger.shared.debug(
                "MediaPlaybackService: No active suppression to revert",
                source: "MediaPlaybackService"
            )
        }

        self.activeSuppression = nil
    }

    private func userChangedVolume(
        _ current: OutputVolumeSnapshot,
        from applied: OutputVolumeSnapshot
    ) -> Bool {
        guard current.channels.count == applied.channels.count else { return true }

        return zip(current.channels, applied.channels).contains { currentChannel, appliedChannel in
            guard currentChannel.selector == appliedChannel.selector,
                  currentChannel.element == appliedChannel.element
            else { return true }

            let userMuted = currentChannel.volume <= 0.001 && appliedChannel.volume > 0.001
            return userMuted || abs(currentChannel.volume - appliedChannel.volume) > 0.02
        }
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
