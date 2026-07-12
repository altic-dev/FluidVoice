import AVFoundation

/// Streaming mono Float32 → 16 kHz mono Float32 conversion with proper
/// anti-alias filtering via AVAudioConverter. Stateful across calls so
/// fractional phase carries over between small hardware callbacks.
/// Not internally synchronized — the owner must serialize calls.
final class StreamingResampler {
    private let targetRate = 16_000.0
    private var lastSourceRate: Double = 0

    private struct ConverterState {
        let sourceRate: Double
        let converter: AVAudioConverter
        let inputFormat: AVAudioFormat
        let outputFormat: AVAudioFormat
        var inputBuffer: AVAudioPCMBuffer
        var outputBuffer: AVAudioPCMBuffer
    }

    private var state: ConverterState?

    func process(_ samples: [Float], sourceRate: Double) -> [Float] {
        defer {
            self.lastSourceRate = sourceRate
        }

        if sourceRate == self.targetRate {
            if abs(self.lastSourceRate - sourceRate) > 0.5 {
                self.state?.converter.reset()
            }
            return samples
        }
        guard samples.isEmpty == false, sourceRate > 0 else { return [] }

        let inputFrameCount = AVAudioFrameCount(samples.count)
        let outputCapacity = AVAudioFrameCount(
            Int(ceil(Double(samples.count) * self.targetRate / sourceRate)) + 64
        )
        guard var state = self.converterState(
            for: sourceRate,
            inputCapacity: inputFrameCount,
            outputCapacity: outputCapacity
        ) else { return [] }

        if inputFrameCount > state.inputBuffer.frameCapacity {
            guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: state.inputFormat,
                frameCapacity: inputFrameCount
            ) else { return [] }
            state.inputBuffer = inputBuffer
        }
        if outputCapacity > state.outputBuffer.frameCapacity {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: state.outputFormat,
                frameCapacity: outputCapacity
            ) else { return [] }
            state.outputBuffer = outputBuffer
        }
        self.state = state

        let inputBuffer = state.inputBuffer
        let outputBuffer = state.outputBuffer
        outputBuffer.frameLength = 0
        inputBuffer.frameLength = inputFrameCount

        guard let inputChannel = inputBuffer.floatChannelData?[0] else { return [] }
        samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            inputChannel.update(from: baseAddress, count: samples.count)
        }

        var servedInput = false
        var conversionError: NSError?
        let status = state.converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if servedInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            servedInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard conversionError == nil, status != .error else { return [] }
        guard let outputChannel = outputBuffer.floatChannelData?[0] else { return [] }

        return Array(UnsafeBufferPointer(
            start: outputChannel,
            count: Int(outputBuffer.frameLength)
        ))
    }

    func reset() {
        self.state?.converter.reset()
        self.lastSourceRate = 0
    }

    /// Drains samples buffered inside the converter (FIR group delay) and
    /// resets it. Call at end of a recording segment so the tail of the
    /// final word is not discarded.
    func flush() -> [Float] {
        defer {
            self.lastSourceRate = 0
        }

        guard let state = self.state else { return [] }

        let outputBuffer: AVAudioPCMBuffer
        if state.outputBuffer.frameCapacity >= 1024 {
            outputBuffer = state.outputBuffer
        } else if let buffer = AVAudioPCMBuffer(
            pcmFormat: state.outputFormat,
            frameCapacity: 1024
        ) {
            outputBuffer = buffer
        } else {
            state.converter.reset()
            return []
        }
        outputBuffer.frameLength = 0

        var conversionError: NSError?
        let status = state.converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }

        defer {
            state.converter.reset()
        }

        guard conversionError == nil, status != .error else { return [] }
        guard let outputChannel = outputBuffer.floatChannelData?[0] else { return [] }

        return Array(UnsafeBufferPointer(
            start: outputChannel,
            count: Int(outputBuffer.frameLength)
        ))
    }

    private func converterState(
        for sourceRate: Double,
        inputCapacity: AVAudioFrameCount,
        outputCapacity: AVAudioFrameCount
    ) -> ConverterState? {
        if let state = self.state,
           abs(state.sourceRate - sourceRate) <= 0.5
        {
            if abs(self.lastSourceRate - sourceRate) > 0.5 {
                state.converter.reset()
            }
            return state
        }

        guard let inputFormat = AVAudioFormat(
            standardFormatWithSampleRate: sourceRate,
            channels: 1
        ),
            let outputFormat = AVAudioFormat(
                standardFormatWithSampleRate: self.targetRate,
                channels: 1
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            self.state = nil
            return nil
        }

        converter.primeMethod = .none
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: inputCapacity
        ),
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outputCapacity
            )
        else {
            self.state = nil
            return nil
        }

        let state = ConverterState(
            sourceRate: sourceRate,
            converter: converter,
            inputFormat: inputFormat,
            outputFormat: outputFormat,
            inputBuffer: inputBuffer,
            outputBuffer: outputBuffer
        )
        self.state = state
        return state
    }
}
