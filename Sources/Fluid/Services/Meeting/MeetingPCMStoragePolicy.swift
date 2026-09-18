import Foundation

/// Storage budget for PCM-first meeting capture.
///
/// Meeting capture keeps the authoritative recording as native Float32 PCM until the
/// transcript is published.  This policy deliberately budgets for a normal one-hour
/// meeting plus analysis working space instead of using the old compressed-audio floor.
nonisolated enum MeetingPCMStoragePolicy {
    static let sampleRate: Int64 = 48_000
    static let bytesPerSample: Int64 = 4 // Float32
    static let defaultMeetingDuration: TimeInterval = 60 * 60
    static let safetyMultiplier: Double = 1.25
    static let materializationHeadroomBytes: Int64 = 1 * 1024 * 1024 * 1024
    static let stagingHeadroomBytes: Int64 = 512 * 1024 * 1024

    static func trackCount(for mode: MeetingCaptureMode) -> Int {
        mode == .onlineCall ? 2 : 1
    }

    /// Worst-case PCM bytes per second for the capture topology.
    /// Online calls are application stereo + microphone mono; in-room meetings are microphone
    /// mono.  The count is intentionally bounded to the supported topology.
    static func pcmBytesPerSecond(trackCount: Int) -> Int64 {
        let channels = trackCount >= 2 ? 3 : 1
        return sampleRate * bytesPerSample * Int64(channels)
    }

    static func estimatedPCMBytes(
        trackCount: Int,
        duration: TimeInterval = Self.defaultMeetingDuration
    ) -> Int64 {
        guard duration.isFinite, duration > 0 else { return 0 }
        let seconds = Int64(ceil(duration))
        return pcmBytesPerSecond(trackCount: trackCount) * seconds
    }

    /// Free-space floor required before starting a capture.  The safety multiplier covers file
    /// headers, short overruns, and timeline duplication; the two fixed reserves cover the
    /// canonical 16 kHz materialization and temporary processing/staging files.
    static func requiredFreeBytes(
        trackCount: Int,
        duration: TimeInterval = Self.defaultMeetingDuration
    ) -> Int64 {
        let pcm = Double(estimatedPCMBytes(trackCount: trackCount, duration: duration))
        let protectedPCM = Int64(ceil(pcm * safetyMultiplier))
        return protectedPCM + materializationHeadroomBytes + stagingHeadroomBytes
    }

    static func requiredFreeSpaceDescription(trackCount: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: requiredFreeBytes(trackCount: trackCount))
    }
}
