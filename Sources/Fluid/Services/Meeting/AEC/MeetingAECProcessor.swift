import FluidAEC3Bridge
import Foundation

nonisolated protocol MeetingAECProcessing: AnyObject, Sendable {
    var upstreamRevision: String { get }
    var configurationID: String { get }
    func process(render: [Float], capture: [Float]) throws
        -> (samples: [Float], statistics: MeetingAECBridgeStatistics)
    func reset() throws
}

/// Single-owner Swift wrapper around the opaque C ABI. The runtime calls it only on the shared
/// SCK callback queue; the bridge itself performs reverse-stream then capture-stream processing.
final nonisolated class MeetingAECProcessor: MeetingAECProcessing, @unchecked Sendable {
    private var engine: OpaquePointer?

    let upstreamRevision: String
    let configurationID: String

    init() throws {
        guard let revisionPointer = fv_aec3_upstream_revision(),
              let configurationPointer = fv_aec3_configuration_id()
        else { throw MeetingAECFailure.bridgeInitialization }
        self.upstreamRevision = String(cString: revisionPointer)
        self.configurationID = String(cString: configurationPointer)
        guard self.upstreamRevision == MeetingAECConstants.provenance.upstreamRevision,
              self.configurationID == MeetingAECConstants.provenance.bridgeConfigurationID,
              let engine = fv_aec3_create_48k_mono()
        else { throw MeetingAECFailure.bridgeInitialization }
        self.engine = engine
    }

    deinit {
        if let engine = self.engine { fv_aec3_destroy(engine) }
    }

    func reset() throws {
        guard let engine = self.engine else { throw MeetingAECFailure.bridgeInitialization }
        guard fv_aec3_reset(engine) == FV_AEC3_OK else {
            throw MeetingAECFailure.bridgeInitialization
        }
    }

    func process(render: [Float], capture: [Float]) throws
        -> (samples: [Float], statistics: MeetingAECBridgeStatistics)
    {
        guard let engine = self.engine,
              render.count == MeetingAECConstants.frameSamples,
              capture.count == MeetingAECConstants.frameSamples,
              render.allSatisfy(\.isFinite),
              capture.allSatisfy(\.isFinite)
        else { throw MeetingAECFailure.bridgeProcessing }

        var output = [Float](repeating: 0, count: MeetingAECConstants.frameSamples)
        var stats = FVAEC3Stats(
            render_frames: 0,
            capture_frames: 0,
            resets: 0,
            estimated_delay_ms: -1,
            residual_echo_likelihood: .nan
        )
        let status = render.withUnsafeBufferPointer { renderBuffer in
            capture.withUnsafeBufferPointer { captureBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    fv_aec3_process_10ms(
                        engine,
                        renderBuffer.baseAddress,
                        captureBuffer.baseAddress,
                        outputBuffer.baseAddress,
                        &stats
                    )
                }
            }
        }
        guard status == FV_AEC3_OK else {
            if status == FV_AEC3_NONFINITE_OUTPUT {
                throw MeetingAECFailure.bridgeNonFiniteOutput
            }
            throw MeetingAECFailure.bridgeProcessing
        }
        guard output.allSatisfy({ $0.isFinite && $0 >= -1 && $0 <= 1 }) else {
            throw MeetingAECFailure.bridgeNonFiniteOutput
        }

        return (
            output,
            MeetingAECBridgeStatistics(
                renderFrames: stats.render_frames,
                captureFrames: stats.capture_frames,
                resets: stats.resets,
                estimatedDelayMilliseconds: stats.estimated_delay_ms >= 0
                    ? Int(stats.estimated_delay_ms)
                    : nil,
                residualEchoLikelihood: stats.residual_echo_likelihood.isFinite
                    ? stats.residual_echo_likelihood
                    : nil
            )
        )
    }
}
