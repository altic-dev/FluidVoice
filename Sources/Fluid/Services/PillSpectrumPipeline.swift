import AVFoundation
import Foundation
import QuartzCore
#if canImport(CoreAudioCaptureSupport)
import CoreAudioCaptureSupport
#endif

/// The C ring synchronizes the capture producer with the serial analysis worker.
/// Only the worker owns FFT/history/scratch/timer; latestLock guards the immutable
/// result shared with presentation. No Swift lock is acquired by offer(). Storage
/// lives with the pipeline, which outlives capture and worker access.
final nonisolated class PillSpectrumPipeline: @unchecked Sendable {
    static let shared = PillSpectrumPipeline()
    let transport: OpaquePointer
    private let worker = DispatchQueue(label: "com.fluidvoice.pill-spectrum", qos: .userInteractive)
    private let latestLock = NSLock()
    private var latestFrame: PillSpectrumFrame?
    private var timer: DispatchSourceTimer?
    private var analyzer = PillSpectrumAnalyzer()
    private var scratch = FVPillPacket()
    private var previousEpoch: UInt64 = 0
    private var previousSequence: UInt64 = 0

    init() {
        guard let transport = FVPillCreate() else { preconditionFailure("Unable to allocate Pill transport") }
        self.transport = transport
    }

    deinit {
        // Timer's handler is weak; no queued work can outlive its strong self.
        self.timer?.cancel()
        FVPillDestroy(self.transport)
    }

    var isVisible: Bool {
        FVPillIsVisible(self.transport)
    }

    var isCapturing: Bool {
        FVPillIsActive(self.transport)
    }

    var epoch: UInt64 {
        FVPillEpoch(self.transport)
    }

    var droppedPackets: UInt64 {
        FVPillDropped(self.transport)
    }

    /// Called only at control/lifecycle boundaries, never for an audio packet.
    func begin(session: Int, attempt: UInt64) {
        FVPillBegin(self.transport, UInt64(bitPattern: Int64(session)), attempt)
        self.updateWorkerLifetime()
    }

    func end() {
        FVPillEnd(self.transport)
        self.updateWorkerLifetime()
    }

    func setVisible(_ visible: Bool) {
        guard visible != self.isVisible else { return }
        FVPillSetVisible(self.transport, visible)
        self.updateWorkerLifetime()
    }

    /// Must run inside the existing capture acceptance lock, including begin/end.
    /// Copies accepted PCM into owned preallocated slots; recording data is read-only.
    func offer(_ samples: [Float], sampleRate: Double, hostTime: UInt64, discontinuity: Bool) {
        samples.withUnsafeBufferPointer {
            _ = FVPillPush(self.transport, $0.baseAddress, $0.count, sampleRate, hostTime, discontinuity)
        }
    }

    func latest() -> PillSpectrumFrame? {
        guard self.isVisible, FVPillIsActive(self.transport) else { return nil }
        return self.latestLock.withLock {
            guard let frame = self.latestFrame, frame.epoch == self.epoch else { return nil }
            return frame
        }
    }

    private func updateWorkerLifetime() {
        self.worker.async { [weak self] in
            guard let self else { return }
            self.latestLock.withLock { self.latestFrame = nil }
            self.analyzer.reset()
            self.previousEpoch = 0
            self.previousSequence = 0
            let shouldRun = self.isVisible && FVPillIsActive(self.transport)
            if shouldRun, self.timer == nil {
                let timer = DispatchSource.makeTimerSource(queue: self.worker)
                timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
                timer.setEventHandler { [weak self] in self?.consume() }
                self.timer = timer
                timer.resume()
            } else if !shouldRun {
                self.timer?.cancel()
                self.timer = nil
                // Consumer alone retires queued packets; never reset producer indices.
                _ = FVPillTakeLatest(self.transport, &self.scratch)
            }
        }
    }

    #if DEBUG
    /// Deterministic packet bursts without racing a timer; only used by isolated tests.
    func withWorkerPausedForTesting(_ produce: () -> Void) {
        self.worker.sync(execute: produce)
    }
    #endif

    private func consume() {
        let started = CACurrentMediaTime()
        var hasFreshPCM = false
        var discontinuity = false
        // Bound work to one ring capacity, even if the producer keeps running.
        // Append ALL available PCM, then compute one FFT from the newest window.
        // Normal scheduling jitter must not become a synthetic audio discontinuity.
        for _ in 0..<Int(FV_PILL_QUEUE_CAPACITY) {
            guard FVPillTakeNext(self.transport, &self.scratch) else { break }
            guard self.isVisible, FVPillIsActive(self.transport), self.scratch.epoch == self.epoch else {
                hasFreshPCM = false
                continue
            }
            let queuedAge = AVAudioTime.seconds(forHostTime: mach_absolute_time() - self.scratch.offeredHostTime)
            guard queuedAge < 0.1 else {
                self.analyzer.reset()
                self.previousSequence = 0
                hasFreshPCM = false
                self.latestLock.withLock { self.latestFrame = nil }
                continue
            }
            let gap = self.scratch.discontinuity || self.scratch.epoch != self.previousEpoch
                || self.scratch.sequence != self.previousSequence &+ 1
            if self.analyzer.sampleRate != self.scratch.sampleRate {
                self.analyzer = PillSpectrumAnalyzer(sampleRate: self.scratch.sampleRate)
            } else if gap {
                self.analyzer.reset()
            }
            discontinuity = discontinuity || gap
            let count = Int(self.scratch.count)
            withUnsafePointer(to: &self.scratch.samples) { pointer in
                pointer.withMemoryRebound(to: Float.self, capacity: Int(FV_PILL_PACKET_CAPACITY)) {
                    self.analyzer.append(UnsafeBufferPointer(start: $0, count: count))
                }
            }
            self.previousEpoch = self.scratch.epoch
            self.previousSequence = self.scratch.sequence
            hasFreshPCM = true
        }
        guard hasFreshPCM else { return }
        let result = self.analyzer.currentSpectrum()
        let finished = CACurrentMediaTime()
        let frame = PillSpectrumFrame(
            epoch: self.scratch.epoch,
            session: self.scratch.session,
            attempt: self.scratch.attempt,
            sequence: self.scratch.sequence,
            captureHostTime: self.scratch.hostTime,
            publishedAt: finished,
            amplitudes: result.amplitudes,
            rms: result.rms,
            discontinuity: discontinuity,
            analysisMilliseconds: (finished - started) * 1000
        )
        self.latestLock.withLock {
            if frame.epoch == self.epoch, self.isVisible, FVPillIsActive(self.transport) {
                self.latestFrame = frame
            }
        }
    }
}
