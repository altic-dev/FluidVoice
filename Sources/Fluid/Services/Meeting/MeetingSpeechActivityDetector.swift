import Foundation
import CoreML

/// Synchronous, single-owner offline seam. Implementations retain only one recurrent state.
nonisolated protocol MeetingSpeechActivityFrameModel {
    mutating func probability(samples: [Float], reset: Bool) throws -> Float
}

/// Direct adapter for the audited cached Silero 256ms v6 model; never invokes a downloader.
/// Its output is 1-product(1-p_i) across eight internal 32ms outputs, NOT voiced duration,
/// near-end probability, or eight independent observations for policy confidence.
nonisolated struct MeetingLocalSileroActivityModel: MeetingSpeechActivityFrameModel {
    enum Failure: Error { case schema, input, output }
    private let model: MLModel
    private var context = [Float](repeating: 0, count: 64)
    private var hidden = [Float](repeating: 0, count: 128)
    private var cell = [Float](repeating: 0, count: 128)

    init(modelURL: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        func matches(_ descriptions: [String: MLFeatureDescription], _ shapes: [String: [Int]]) -> Bool {
            Set(descriptions.keys) == Set(shapes.keys) && shapes.allSatisfy { key, shape in
                guard let constraint = descriptions[key]?.multiArrayConstraint else { return false }
                return constraint.dataType == .float32 && constraint.shape.map(\.intValue) == shape
            }
        }
        guard matches(model.modelDescription.inputDescriptionsByName,
                      ["audio_input": [1, 4160], "hidden_state": [1, 128], "cell_state": [1, 128]]),
              matches(model.modelDescription.outputDescriptionsByName,
                      ["vad_output": [1, 1, 1], "new_hidden_state": [1, 128], "new_cell_state": [1, 128]])
        else { throw Failure.schema }
    }

    mutating func probability(samples: [Float], reset: Bool) throws -> Float {
        guard samples.count == 4096, samples.allSatisfy(\.isFinite) else { throw Failure.input }
        if reset {
            context = [Float](repeating: 0, count: 64)
            hidden = [Float](repeating: 0, count: 128); cell = hidden
        }
        func array(_ values: [Float]) throws -> MLMultiArray {
            let array = try MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .float32)
            for i in values.indices { array[i] = NSNumber(value: values[i]) }
            return array
        }
        let features = try MLDictionaryFeatureProvider(dictionary: [
            "audio_input": array(context + samples), "hidden_state": array(hidden), "cell_state": array(cell)
        ])
        let output = try model.prediction(from: features)
        func values(_ name: String, count: Int) throws -> [Float] {
            guard let array = output.featureValue(for: name)?.multiArrayValue,
                  array.dataType == .float32, array.count == count else { throw Failure.output }
            let values = (0..<count).map { array[$0].floatValue }
            guard values.allSatisfy(\.isFinite) else { throw Failure.output }
            return values
        }
        let p = try values("vad_output", count: 1)[0]
        guard (0...1).contains(p) else { throw Failure.output }
        let nextHidden = try values("new_hidden_state", count: 128)
        let nextCell = try values("new_cell_state", count: 128)
        hidden = nextHidden; cell = nextCell; context = Array(samples.suffix(64))
        return p
    }
}

nonisolated struct MeetingSpeechActivityDetector<Model: MeetingSpeechActivityFrameModel> {
    static var version: String { "speech-shadow-b2-v1" }
    struct Frame: Codable, Equatable {
        enum Unknown: String, Codable { case invalidInput, unscoredCoverage, contextWarmup, modelFailure, overBudget, cancelled, disabled }
        let start: Double
        let epoch: UInt64
        let probability: Float?
        let unknown: Unknown?
        /// Window-level activity only; not a voiced-duration annotation or near-end decision.
        var active: Bool? { probability.map { $0 >= 0.85 } }
    }
    private var model: Model
    private var lastEnd: Double?
    private var scope: String?
    private var sessionID: UUID?
    private var needsReset = true
    private var failures = 0
    private let clock: () -> Double
    init(model: Model, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.model = model; self.clock = clock
    }
    /// Caller supplies exactly 4096 real 16kHz samples and validity flags. No tail padding.
    /// A first frame after reset is model warmup and intentionally unmeasured in the sidecar.
    /// One prediction cannot be preempted; budget/cancellation are checked before AND after it.
    mutating func process(samples: [Float], valid: [Bool], start: Double, session: UUID,
                          epoch: UInt64, route: String, cancelled: () -> Bool = { false }) -> Frame {
        if sessionID != session { failures = 0; needsReset = true }
        sessionID = session
        func unknown(_ reason: Frame.Unknown) -> Frame {
            Frame(start: start.isFinite ? start : 0, epoch: epoch, probability: nil, unknown: reason)
        }
        guard start.isFinite, start >= 0, !route.isEmpty,
              samples.count == 4096, valid.count == samples.count,
              samples.allSatisfy(\.isFinite) else {
            needsReset = true; if failures < 3 { failures = 0 }; return unknown(.invalidInput)
        }
        let nextScope = "\(session):\(epoch):\(route)"
        if scope != nextScope || lastEnd.map({ abs($0 - start) > 1.0 / 32_000 }) != false { needsReset = true }
        scope = nextScope; lastEnd = start + 0.256
        guard !cancelled() else { needsReset = true; if failures < 3 { failures = 0 }; return unknown(.cancelled) }
        guard failures < 3 else { needsReset = true; return unknown(.disabled) }
        guard valid.allSatisfy({ $0 }) else { needsReset = true; failures = 0; return unknown(.unscoredCoverage) }
        let reset = needsReset, began = clock()
        do {
            let probability = try model.probability(samples: samples, reset: reset)
            guard !cancelled() else { needsReset = true; failures = 0; return unknown(.cancelled) }
            guard clock() - began <= 0.1 else {
                failures += 1; needsReset = true; return unknown(.overBudget)
            }
            guard probability.isFinite, (0...1).contains(probability) else {
                failures += 1; needsReset = true; return unknown(.modelFailure)
            }
            failures = 0; needsReset = false
            if reset { return unknown(.contextWarmup) }
            return Frame(start: start, epoch: epoch, probability: probability, unknown: nil)
        } catch {
            failures += 1; needsReset = true; return unknown(.modelFailure)
        }
    }
}

/// Offline B2 diagnostic combination. Correlated signals are never multiplied into confidence.
/// All combinations remain uncertain: no calibrated near-end/absence evidence exists yet.
nonisolated enum MeetingSpeechPlaybackShadowPolicy {
    enum TemporalContext: String, Codable { case supported, notSupported, mixed, unavailable }
    enum Reason: String, Codable {
        case missingSpeechEvidence, mixedOrLeakedActivity, activityWithoutReliablePlaybackMatch
        case duplicateWithoutDetectedActivity, negativeActivityIsNotAbsence
    }
    static func reason(activity: Bool?, reliableDuplicate: Bool) -> Reason {
        guard let activity else { return .missingSpeechEvidence }
        if activity { return reliableDuplicate ? .mixedOrLeakedActivity : .activityWithoutReliablePlaybackMatch }
        return reliableDuplicate ? .duplicateWithoutDetectedActivity : .negativeActivityIsNotAbsence
    }

    /// Join by interval overlap, not a single enclosing 2s window: 256ms frames often straddle
    /// that grid. All overlapping evidence must cover the frame in the same epoch. Mixed
    /// windows stay explicit and never borrow a sibling's supported state.
    static func temporalContext(start: Double, epoch: UInt64,
                                windows: [MeetingPlaybackDuplicateDetector.Result]) -> TemporalContext {
        guard start.isFinite, start >= 0 else { return .unavailable }
        let end = start + 0.256
        let overlapping = windows.filter { $0.end > start && $0.start < end }.sorted { $0.start < $1.start }
        var cursor = start, supported = false, unsupported = false
        for window in overlapping {
            guard window.epoch == epoch, window.start.isFinite, window.end.isFinite,
                  window.end > window.start, window.start <= cursor + 1e-9,
                  window.state != .insufficientEvidence else { return .unavailable }
            if window.state == .duplicateSupported { supported = true } else { unsupported = true }
            cursor = max(cursor, min(end, window.end))
        }
        guard cursor >= end - 1e-9 else { return .unavailable }
        return supported ? (unsupported ? .mixed : .supported) : .notSupported
    }
}
