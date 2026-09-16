//
//  AudioEnvelopeFollower.swift
//  Fluid
//
//  Damping for the raw microphone level that the ASR engine already publishes.
//

import Foundation

/// Converts the raw, jumpy level published by the audio engine into the damped
/// envelope the premium visualizers draw.
///
/// This is pure value logic: it reads no audio hardware, opens no second capture
/// path, and only ever owns one fixed-size history ring.
nonisolated struct AudioEnvelopeFollower {
    /// Number of delayed samples kept for the travelling-light effect.
    static let historyLength = 18

    /// Most recent sample last.
    private(set) var history: [CGFloat]
    /// Current smoothed level in 0...1.
    private(set) var smoothed: CGFloat = 0

    /// Fraction of the gap closed per update while the level is rising.
    let attack: CGFloat
    /// Fraction of the gap closed per update while the level is falling.
    let release: CGFloat

    init(attack: CGFloat = 0.6, release: CGFloat = 0.14) {
        self.attack = attack
        self.release = release
        self.history = Array(repeating: 0, count: Self.historyLength)
    }

    /// Maps a raw 0...1 level through the user's visualizer sensitivity.
    static func normalized(_ level: CGFloat, noiseThreshold: CGFloat) -> CGFloat {
        let clampedLevel = min(max(level, 0), 1)
        let clampedThreshold = min(max(noiseThreshold, 0), 0.95)
        let denominator = max(1 - clampedThreshold, 0.001)
        let gated = max(min((clampedLevel - clampedThreshold) / denominator, 1), 0)
        return pow(gated, 0.62)
    }

    /// Feeds one normalized sample and returns the new smoothed level.
    @discardableResult
    mutating func update(with level: CGFloat) -> CGFloat {
        let target = min(max(level, 0), 1)
        let coefficient = target > self.smoothed ? self.attack : self.release
        self.smoothed += (target - self.smoothed) * coefficient
        if self.history.isEmpty {
            self.history = Array(repeating: 0, count: Self.historyLength)
        }
        self.history.removeFirst()
        self.history.append(self.smoothed)
        return self.smoothed
    }

    /// Offset 0 is the newest sample; higher offsets are older.
    func delayedSample(at offset: Int) -> CGFloat {
        let index = self.history.count - 1 - offset
        guard index >= 0, index < self.history.count else { return 0 }
        return self.history[index]
    }

    mutating func reset() {
        self.smoothed = 0
        for index in self.history.indices {
            self.history[index] = 0
        }
    }

    /// Follower pre-filled with a smooth speech envelope.
    ///
    /// Used only by offscreen previews and tests, so the audio-reactive styles
    /// can be rendered at a known level without a live microphone. The production
    /// path never calls it: at runtime the follower is fed by the real level.
    static func preview(level: CGFloat) -> AudioEnvelopeFollower {
        var follower = AudioEnvelopeFollower()
        let span = CGFloat(max(AudioEnvelopeFollower.historyLength - 1, 1))
        for index in 0..<AudioEnvelopeFollower.historyLength {
            let t = CGFloat(index) / span
            let hump = 0.32 + 0.68 * sin(t * CGFloat.pi)
            follower.update(with: min(max(level * hump, 0), 1))
        }
        return follower
    }
}
