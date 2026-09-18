import CoreMedia
import Foundation

nonisolated struct MeetingAECClockAttestor: Equatable, Sendable {
    private(set) var startGrid: Int64?
    private(set) var nextExpectedGrid: Int64?
    private(set) var pairedFrameCount = 0
    private(set) var attested = false

    mutating func observe(
        grid: Int64,
        renderPresentationTime: CMTime,
        capturePresentationTime: CMTime
    ) -> Bool {
        if let nextExpectedGrid, grid != nextExpectedGrid { return false }
        let residual = CMTimeSubtract(renderPresentationTime, capturePresentationTime)
        guard residual.isValid, residual.isNumeric else { return false }
        let residualSamples = abs(CMTimeGetSeconds(residual) * Double(MeetingAECConstants.sampleRateHz))
        guard residualSamples.isFinite,
              residualSamples <= Double(MeetingAECConstants.maximumClockResidualSamples) + 1e-9
        else { return false }

        if self.startGrid == nil { self.startGrid = grid }
        self.pairedFrameCount += 1
        self.nextExpectedGrid = grid + Int64(MeetingAECConstants.frameSamples)
        if self.pairedFrameCount >= MeetingAECConstants.attestationFrames {
            let covered = self.pairedFrameCount * MeetingAECConstants.frameSamples
            self.attested = covered >= MeetingAECConstants.attestationSamples
        }
        return true
    }
}

/// Bounded, serial-owner joiner for the two 48 kHz SCK PCM timelines. It never fills a render gap
/// with zeros. All timestamps emitted here are derived from an original callback PTS plus an exact
/// source-sample offset.
nonisolated struct MeetingAECStreamJoiner: Sendable {
    private struct BufferedBlock: Equatable, Sendable {
        let source: MeetingAECPCMBlock
        let startGrid: Int64
        var consumed = 0

        var effectiveStart: Int64 { self.startGrid + Int64(self.consumed) }
        var endGrid: Int64 { self.startGrid + Int64(self.source.samples.count) }
        var remainingCount: Int { self.source.samples.count - self.consumed }
        var effectivePresentationTime: CMTime {
            CMTimeAdd(
                self.source.presentationTime,
                CMTime(value: CMTimeValue(self.consumed), timescale: 48_000)
            )
        }
    }

    private struct TrackState: Equatable, Sendable {
        var anchorPresentationTime: CMTime?
        var anchorGrid: Int64?
        var cumulativeSamples: Int64 = 0
        var previousPresentationTime: CMTime?
        var format: MeetingAECPCMFormat?
        var blocks: [BufferedBlock] = []

        var retainedSamples: Int { self.blocks.reduce(0) { $0 + $1.remainingCount } }
        var latestEndGrid: Int64? { self.blocks.last?.endGrid }
        var firstGrid: Int64? { self.blocks.first?.effectiveStart }
    }

    private(set) var diagnostics = MeetingAECDiagnostics()
    private var stream: MeetingAECStreamToken?
    private var epoch: CMTimeEpoch?
    private var render = TrackState()
    private var capture = TrackState()
    private var nextFrameGrid: Int64?
    private var attestor = MeetingAECClockAttestor()

    init() {}

    mutating func append(_ block: MeetingAECPCMBlock) -> [MeetingAECJoinerEmission] {
        if let stream = self.stream, stream != block.stream {
            return self.failAndReset(
                .streamChanged,
                including: block.kind == .capture ? block : nil,
                drainCompletePairs: true
            )
        }
        if let epoch = self.epoch, epoch != block.presentationTime.epoch {
            return self.failAndReset(
                .timestampEpochChanged,
                including: block.kind == .capture ? block : nil,
                drainCompletePairs: true
            )
        }
        self.stream = block.stream
        self.epoch = block.presentationTime.epoch

        let accepted: Result<Void, MeetingAECFailure>
        switch block.kind {
        case .render:
            accepted = Self.accept(block, into: &self.render)
            if case .success = accepted { self.diagnostics.acceptedRenderBlocks += 1 }
        case .capture:
            accepted = Self.accept(block, into: &self.capture)
            if case .success = accepted { self.diagnostics.acceptedCaptureBlocks += 1 }
        }
        if case let .failure(failure) = accepted {
            return self.failAndReset(
                failure,
                including: block.kind == .capture ? block : nil,
                drainCompletePairs: true
            )
        }

        // Bounds govern what remains *after* draining; a burst that pairs cleanly is not backlog.
        var emissions = self.drainPairs()
        if self.render.blocks.count > MeetingAECConstants.maximumBlocksPerInput
            || self.capture.blocks.count > MeetingAECConstants.maximumBlocksPerInput
        {
            emissions.append(contentsOf: self.failAndReset(.callbackBlockLimit))
        } else if self.render.retainedSamples > MeetingAECConstants.maximumSamplesPerInput
            || self.capture.retainedSamples > MeetingAECConstants.maximumSamplesPerInput
        {
            emissions.append(contentsOf: self.failAndReset(.retainedSampleLimit))
        } else if self.captureWaitExceeded() {
            emissions.append(contentsOf: self.failAndReset(.renderLate))
        }
        self.updateRetainedDiagnostics()
        return emissions
    }

    /// Stop/invalidate drains every complete pair through the normal path first; only the
    /// incomplete capture tail is emitted raw, with its original PTS and no padding.
    mutating func flush(reason: MeetingAECFailure = .stopped) -> [MeetingAECJoinerEmission] {
        self.failAndReset(reason, drainCompletePairs: true)
    }

    private static func accept(
        _ block: MeetingAECPCMBlock,
        into track: inout TrackState
    ) -> Result<Void, MeetingAECFailure> {
        if let format = track.format, format != block.sourceFormat {
            return .failure(.formatChanged)
        }
        track.format = block.sourceFormat
        guard let roundedGrid = Self.gridValue(block.presentationTime) else {
            return .failure(.invalidTimestamp)
        }
        let startGrid: Int64
        if let anchorPTS = track.anchorPresentationTime,
           let anchorGrid = track.anchorGrid
        {
            if let previousPTS = track.previousPresentationTime, block.presentationTime <= previousPTS {
                return .failure(.timestampMovedBackward)
            }
            let expectedPTS = CMTimeAdd(
                anchorPTS,
                CMTime(value: CMTimeValue(track.cumulativeSamples), timescale: 48_000)
            )
            let residualTime = CMTimeSubtract(block.presentationTime, expectedPTS)
            guard residualTime.isValid, residualTime.isNumeric else {
                return .failure(.invalidTimestamp)
            }
            let residualSamples = CMTimeGetSeconds(residualTime)
                * Double(MeetingAECConstants.sampleRateHz)
            guard residualSamples.isFinite else { return .failure(.invalidTimestamp) }
            let tolerance = Double(MeetingAECConstants.maximumClockResidualSamples) + 1e-9
            if residualSamples > tolerance {
                return .failure(.timestampGap)
            }
            if residualSamples < -tolerance {
                return .failure(.timestampOverlap)
            }
            startGrid = anchorGrid + track.cumulativeSamples
        } else {
            track.anchorPresentationTime = block.presentationTime
            track.anchorGrid = roundedGrid
            startGrid = roundedGrid
        }
        guard Int64(block.samples.count) <= Int64.max - track.cumulativeSamples else {
            return .failure(.retainedSampleLimit)
        }
        track.blocks.append(BufferedBlock(source: block, startGrid: startGrid))
        track.cumulativeSamples += Int64(block.samples.count)
        track.previousPresentationTime = block.presentationTime
        return .success(())
    }

    private static func gridValue(_ time: CMTime) -> Int64? {
        guard time.isValid, time.isNumeric else { return nil }
        let rounded = CMTimeConvertScale(time, timescale: 48_000, method: .default)
        guard rounded.isValid, rounded.isNumeric else { return nil }
        let residual = CMTimeSubtract(time, rounded)
        let residualSamples = abs(CMTimeGetSeconds(residual) * 48_000)
        guard residualSamples.isFinite,
              residualSamples <= Double(MeetingAECConstants.maximumClockResidualSamples) + 1e-9
        else { return nil }
        return rounded.value
    }

    private mutating func drainPairs() -> [MeetingAECJoinerEmission] {
        var emissions: [MeetingAECJoinerEmission] = []
        if self.nextFrameGrid == nil {
            emissions.append(contentsOf: self.establishFirstCommonGrid())
        }

        while let grid = self.nextFrameGrid,
              Self.availableSamples(in: self.render, from: grid) >= MeetingAECConstants.frameSamples,
              Self.availableSamples(in: self.capture, from: grid) >= MeetingAECConstants.frameSamples
        {
            guard let renderSlice = Self.consumeFrame(
                from: grid, track: &self.render
            ), let captureSlice = Self.consumeFrame(
                from: grid, track: &self.capture
            ) else {
                emissions.append(contentsOf: self.failAndReset(.timestampGap))
                break
            }
            guard self.attestor.observe(
                grid: grid,
                renderPresentationTime: renderSlice.presentationTime,
                capturePresentationTime: captureSlice.presentationTime
            ) else {
                emissions.append(.bypass(
                    MeetingAECBypassSlice(
                        presentationTime: captureSlice.presentationTime,
                        samples: captureSlice.samples
                    ),
                    .clockResidualExceeded
                ))
                emissions.append(contentsOf: self.failAndReset(.clockResidualExceeded))
                break
            }
            self.diagnostics.pairedFrames += 1
            emissions.append(.paired(MeetingAECJoinedFrame(
                render: renderSlice,
                capture: captureSlice,
                clockAttested: self.attestor.attested,
                pairedFrameCount: self.attestor.pairedFrameCount
            )))
            self.nextFrameGrid = grid + Int64(MeetingAECConstants.frameSamples)
        }
        return emissions
    }

    private mutating func establishFirstCommonGrid() -> [MeetingAECJoinerEmission] {
        var emissions: [MeetingAECJoinerEmission] = []
        while let renderStart = self.render.firstGrid,
              let captureStart = self.capture.firstGrid,
              let renderEnd = self.render.blocks.first?.endGrid,
              let captureEnd = self.capture.blocks.first?.endGrid
        {
            let common = max(renderStart, captureStart)
            if renderEnd <= common {
                _ = self.render.blocks.removeFirst()
                continue
            }
            if captureEnd <= common {
                if let bypass = Self.consumeSlice(
                    count: self.capture.blocks[0].remainingCount,
                    from: captureStart,
                    track: &self.capture
                ) {
                    emissions.append(.bypass(
                        MeetingAECBypassSlice(
                            presentationTime: bypass.presentationTime,
                            samples: bypass.samples
                        ),
                        .renderLate
                    ))
                    self.diagnostics.bypassFrames += 1
                }
                continue
            }
            if captureStart < common,
               let bypass = Self.consumeSlice(
                   count: Int(common - captureStart),
                   from: captureStart,
                   track: &self.capture
               )
            {
                emissions.append(.bypass(
                    MeetingAECBypassSlice(
                        presentationTime: bypass.presentationTime,
                        samples: bypass.samples
                    ),
                    .renderLate
                ))
                self.diagnostics.bypassFrames += 1
            }
            Self.discard(before: common, track: &self.render)
            self.nextFrameGrid = common
            break
        }
        return emissions
    }

    private func captureWaitExceeded() -> Bool {
        guard self.capture.retainedSamples > MeetingAECConstants.maximumCaptureWaitSamples else {
            return false
        }
        guard let captureEnd = self.capture.latestEndGrid else { return false }
        guard let renderEnd = self.render.latestEndGrid else { return true }
        return captureEnd - renderEnd > Int64(MeetingAECConstants.maximumCaptureWaitSamples)
    }

    private static func availableSamples(in track: TrackState, from grid: Int64) -> Int {
        var cursor = grid
        var total = 0
        for block in track.blocks {
            if block.endGrid <= cursor { continue }
            guard block.effectiveStart <= cursor else { break }
            let count = Int(block.endGrid - cursor)
            total += count
            cursor = block.endGrid
        }
        return total
    }

    private static func consumeFrame(
        from grid: Int64,
        track: inout TrackState
    ) -> MeetingAECFrame? {
        guard let slice = self.consumeSlice(
            count: MeetingAECConstants.frameSamples,
            from: grid,
            track: &track
        ) else { return nil }
        return MeetingAECFrame(presentationTime: slice.presentationTime, samples: slice.samples)
    }

    private static func consumeSlice(
        count: Int,
        from grid: Int64,
        track: inout TrackState
    ) -> MeetingAECBypassSlice? {
        guard count > 0, self.availableSamples(in: track, from: grid) >= count else { return nil }
        self.discard(before: grid, track: &track)
        guard let first = track.blocks.first, first.effectiveStart == grid else { return nil }
        let presentationTime = first.effectivePresentationTime
        var remaining = count
        var samples: [Float] = []
        samples.reserveCapacity(count)
        while remaining > 0 {
            guard !track.blocks.isEmpty else { return nil }
            let take = min(remaining, track.blocks[0].remainingCount)
            let start = track.blocks[0].consumed
            samples.append(contentsOf: track.blocks[0].source.samples[start..<(start + take)])
            track.blocks[0].consumed += take
            remaining -= take
            if track.blocks[0].remainingCount == 0 { track.blocks.removeFirst() }
        }
        return MeetingAECBypassSlice(presentationTime: presentationTime, samples: samples)
    }

    private static func discard(before grid: Int64, track: inout TrackState) {
        while let first = track.blocks.first, first.endGrid <= grid {
            track.blocks.removeFirst()
        }
        guard !track.blocks.isEmpty, track.blocks[0].effectiveStart < grid else { return }
        track.blocks[0].consumed += Int(grid - track.blocks[0].effectiveStart)
    }

    private mutating func failAndReset(
        _ failure: MeetingAECFailure,
        including newCapture: MeetingAECPCMBlock? = nil,
        drainCompletePairs: Bool = false
    ) -> [MeetingAECJoinerEmission] {
        var emissions: [MeetingAECJoinerEmission] = []
        if drainCompletePairs {
            // Older windows already holding both sides stay on the processed path. Draining can
            // itself discover a clock fault and reset the joiner; in that case preserve the
            // incoming capture as raw, but do not emit a second reset for the outer failure.
            let drained = self.drainPairs()
            emissions.append(contentsOf: drained)
            if drained.contains(where: {
                if case .reset = $0 { return true }
                return false
            }) {
                if let newCapture, !newCapture.samples.isEmpty {
                    emissions.append(.bypass(
                        MeetingAECBypassSlice(
                            presentationTime: newCapture.presentationTime,
                            samples: newCapture.samples
                        ),
                        failure
                    ))
                    self.diagnostics.bypassFrames += 1
                }
                return emissions
            }
        }
        for block in self.capture.blocks {
            guard block.remainingCount > 0 else { continue }
            emissions.append(.bypass(
                MeetingAECBypassSlice(
                    presentationTime: block.effectivePresentationTime,
                    samples: Array(block.source.samples[block.consumed...])
                ),
                failure
            ))
            self.diagnostics.bypassFrames += 1
        }
        if let newCapture, !newCapture.samples.isEmpty {
            emissions.append(.bypass(
                MeetingAECBypassSlice(
                    presentationTime: newCapture.presentationTime,
                    samples: newCapture.samples
                ),
                failure
            ))
            self.diagnostics.bypassFrames += 1
        }
        emissions.append(.reset(failure))
        self.diagnostics.resets += 1
        self.diagnostics.lastFailure = failure
        self.stream = nil
        self.epoch = nil
        self.render = TrackState()
        self.capture = TrackState()
        self.nextFrameGrid = nil
        self.attestor = MeetingAECClockAttestor()
        self.updateRetainedDiagnostics()
        return emissions
    }

    private mutating func updateRetainedDiagnostics() {
        self.diagnostics.retainedRenderBlocks = self.render.blocks.count
        self.diagnostics.retainedCaptureBlocks = self.capture.blocks.count
        self.diagnostics.retainedRenderSamples = self.render.retainedSamples
        self.diagnostics.retainedCaptureSamples = self.capture.retainedSamples
    }
}
