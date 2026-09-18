import Foundation
import CryptoKit

/// Codable, local-only input for the offline synchronizer replay command. The schema
/// deliberately contains numeric PCM fixture samples plus timing metadata and enum strings;
/// it never contains transcript text, embeddings, labels, or model artifacts. Raw fixture
/// samples are accepted as input but are never copied into command output.
nonisolated public struct MeetingSynchronizerReplayFixture: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let configuration: MeetingSynchronizerReplayConfiguration
    public let microphone: [MeetingSynchronizerReplayMicrophoneFrame]
    public let reference: [MeetingSynchronizerReplayReferenceFrame]

    public init(
        schemaVersion: Int = 1,
        configuration: MeetingSynchronizerReplayConfiguration = .init(),
        microphone: [MeetingSynchronizerReplayMicrophoneFrame] = [],
        reference: [MeetingSynchronizerReplayReferenceFrame] = []
    ) {
        self.schemaVersion = schemaVersion
        self.configuration = configuration
        self.microphone = microphone
        self.reference = reference
    }
}

nonisolated public struct MeetingSynchronizerReplayConfiguration: Codable, Equatable, Sendable {
    public var analysisSampleRate: Double
    public var frameDuration: Double
    public var microphoneAlgorithmicDelaySeconds: Double
    public var referenceAlgorithmicDelaySeconds: Double
    public var referenceToMicrophoneOffsetSeconds: Double
    public var referenceClockDriftPPM: Double
    public var maximumClockDriftPPM: Double
    public var referenceScope: String
    public var referenceCompleteness: String
    public var codecPrimingSamples: Int
    public var codecRemainderSamples: Int
    public var editListOffsetSeconds: Double
    public var maximumInputFrameCount: Int
    public var maximumInputSampleCount: Int
    public var maximumOutputFrameCount: Int
    public var engineAvailable: Bool

    public init(
        analysisSampleRate: Double = 16_000,
        frameDuration: Double = 0.010,
        microphoneAlgorithmicDelaySeconds: Double = 0,
        referenceAlgorithmicDelaySeconds: Double = 0,
        referenceToMicrophoneOffsetSeconds: Double = 0,
        referenceClockDriftPPM: Double = 0,
        maximumClockDriftPPM: Double = 100,
        referenceScope: String = MeetingReferenceScope.selectedApplication.rawValue,
        referenceCompleteness: String = MeetingReferenceCompleteness.unobservable.rawValue,
        codecPrimingSamples: Int = 0,
        codecRemainderSamples: Int = 0,
        editListOffsetSeconds: Double = 0,
        maximumInputFrameCount: Int = 16_384,
        maximumInputSampleCount: Int = 2_000_000,
        maximumOutputFrameCount: Int = 6_000,
        engineAvailable: Bool = true
    ) {
        self.analysisSampleRate = analysisSampleRate
        self.frameDuration = frameDuration
        self.microphoneAlgorithmicDelaySeconds = microphoneAlgorithmicDelaySeconds
        self.referenceAlgorithmicDelaySeconds = referenceAlgorithmicDelaySeconds
        self.referenceToMicrophoneOffsetSeconds = referenceToMicrophoneOffsetSeconds
        self.referenceClockDriftPPM = referenceClockDriftPPM
        self.maximumClockDriftPPM = maximumClockDriftPPM
        self.referenceScope = referenceScope
        self.referenceCompleteness = referenceCompleteness
        self.codecPrimingSamples = codecPrimingSamples
        self.codecRemainderSamples = codecRemainderSamples
        self.editListOffsetSeconds = editListOffsetSeconds
        self.maximumInputFrameCount = maximumInputFrameCount
        self.maximumInputSampleCount = maximumInputSampleCount
        self.maximumOutputFrameCount = maximumOutputFrameCount
        self.engineAvailable = engineAvailable
    }

    fileprivate func makeSynchronizerConfiguration() -> MeetingReferenceSynchronizerConfiguration? {
        guard let scope = MeetingReferenceScope(rawValue: referenceScope),
              let completeness = MeetingReferenceCompleteness(rawValue: referenceCompleteness) else { return nil }
        return MeetingReferenceSynchronizerConfiguration(
            analysisSampleRate: analysisSampleRate, frameDuration: frameDuration,
            microphoneConverter: .init(algorithmicDelaySeconds: microphoneAlgorithmicDelaySeconds),
            referenceConverter: .init(algorithmicDelaySeconds: referenceAlgorithmicDelaySeconds),
            referenceToMicrophoneOffsetSeconds: referenceToMicrophoneOffsetSeconds,
            referenceClockDriftPPM: referenceClockDriftPPM, maximumClockDriftPPM: maximumClockDriftPPM,
            referenceScope: scope, referenceCompleteness: completeness,
            codecPrimingSamples: codecPrimingSamples, codecRemainderSamples: codecRemainderSamples,
            editListOffsetSeconds: editListOffsetSeconds,
            maximumInputFrameCount: maximumInputFrameCount,
            maximumInputSampleCount: maximumInputSampleCount,
            maximumOutputFrameCount: maximumOutputFrameCount, engineAvailable: engineAvailable)
    }
}

nonisolated public struct MeetingSynchronizerReplayMicrophoneFrame: Codable, Equatable, Sendable {
    public let sequenceNumber: Int
    public let sampleTime: Int64
    public let hostTime: Double?
    public let sampleRate: Double
    public let channelCount: Int
    public let samples: [Float]
    public let routeIdentifier: String
    public let discontinuity: Bool

    public init(sequenceNumber: Int, sampleTime: Int64, hostTime: Double?, sampleRate: Double,
                channelCount: Int = 1, samples: [Float], routeIdentifier: String = "default",
                discontinuity: Bool = false) {
        self.sequenceNumber = sequenceNumber; self.sampleTime = sampleTime; self.hostTime = hostTime
        self.sampleRate = sampleRate; self.channelCount = channelCount; self.samples = samples
        self.routeIdentifier = routeIdentifier; self.discontinuity = discontinuity
    }

    fileprivate func makeFrame() -> MeetingMicrophonePCMFrame {
        .init(sequenceNumber: sequenceNumber, sampleTime: sampleTime, hostTime: hostTime,
              sampleRate: sampleRate, channelCount: channelCount, samples: samples,
              routeIdentifier: routeIdentifier, discontinuity: discontinuity)
    }
}

nonisolated public struct MeetingSynchronizerReplayReferenceFrame: Codable, Equatable, Sendable {
    public let sequenceNumber: Int
    public let presentationTime: Double
    public let sampleRate: Double
    public let channelCount: Int
    public let samples: [Float]
    public let discontinuity: Bool

    public init(sequenceNumber: Int, presentationTime: Double, sampleRate: Double,
                channelCount: Int = 1, samples: [Float], discontinuity: Bool = false) {
        self.sequenceNumber = sequenceNumber; self.presentationTime = presentationTime
        self.sampleRate = sampleRate; self.channelCount = channelCount; self.samples = samples
        self.discontinuity = discontinuity
    }

    fileprivate func makeFrame() -> MeetingReferencePCMFrame {
        .init(sequenceNumber: sequenceNumber, presentationTime: presentationTime,
              sampleRate: sampleRate, channelCount: channelCount, samples: samples,
              discontinuity: discontinuity)
    }
}

nonisolated public struct MeetingSynchronizerReplayOutput: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let replayIdentity: String
    public let failedOpen: Bool
    public let failureReason: String?
    public let frameCount: Int
    public let captureValidSampleCount: Int
    public let captureInvalidSampleCount: Int
    public let renderValidSampleCount: Int
    public let renderInvalidSampleCount: Int
    public let unknownReasonCounts: [String: Int]
    public let epochFrameCounts: [Int]
    public let sessionStartTime: Double?
    public let sessionEndTime: Double?
    public let microphoneSourceObservedMinimumTime: Double?
    public let microphoneSourceObservedMaximumTime: Double?
    public let referencePTSObservedMinimumTime: Double?
    public let referencePTSObservedMaximumTime: Double?
    public let diagnostics: MeetingSynchronizerReplayDiagnostics
}

nonisolated public struct MeetingSynchronizerReplayDiagnostics: Codable, Equatable, Sendable {
    public let inputFrameCount: Int
    public let droppedFrameCount: Int
    public let duplicateOrLateFrameCount: Int
    public let nonFiniteSampleCount: Int
    public let epochCount: Int
    public let synthesizedMicrophoneFrameCount: Int
    public let boundedResourceFailure: Bool
    public let referenceClockDriftPPM: Double?
}

/// Local-only command implementation. It is inert unless the caller supplies the explicit
/// `--offline-synchronizer-replay` argument or `FLUID_ASR_OFFLINE_REPLAY=1` environment gate.
nonisolated public enum MeetingReferenceSynchronizerReplayCLI {
    public static let argument = "--offline-synchronizer-replay"
    public static let environmentKey = "FLUID_ASR_OFFLINE_REPLAY"

    /// Replay is a fixture tool, not an arbitrary file decoder. Keep the largest
    /// accepted allocation comfortably bounded even if the caller raises config limits.
    public static let maximumInputBytes = 64 * 1024 * 1024
    private static let hardMaximumInputFrames = 50_000
    private static let hardMaximumInputSamples = 2_000_000
    private static let hardMaximumOutputFrames = 6_000
    private static let hardMaximumOutputSamples = 1_000_000
    private static let hardMaximumSourceSampleRate = 384_000.0
    private static let hardMaximumChannelCount = 32

    @discardableResult
    public static func run(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
                           inputData stdinData: Data, output: (Data) -> Void) -> Int32 {
        let gate = arguments.contains(argument) || environment[environmentKey] == "1"
        guard gate else { output(errorData(code: "offlineGateRequired")); return 2 }
        guard let data = inputData(arguments: arguments, stdin: stdinData),
              let fixture = decodeFixture(data), validate(fixture), let config = fixture.configuration.makeSynchronizerConfiguration() else {
            output(errorData(code: "invalidInput")); return 2
        }
        let result = MeetingReferenceSynchronizer(configuration: config).synchronize(
            microphone: fixture.microphone.map { $0.makeFrame() }, reference: fixture.reference.map { $0.makeFrame() })
        guard let canonical = try? canonicalData(fixture) else {
            output(errorData(code: "canonicalEncodingFailed")); return 3
        }
        let identity = "synchronizer-replay-v1-" + SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        let summary = makeOutput(result, identity: identity)
        guard let data = try? encoded(summary) else { output(errorData(code: "outputEncodingFailed")); return 3 }
        output(data); return result.failedOpen ? 1 : 0
    }

    /// Read at most `maximumInputBytes + 1` bytes so oversized stdin cannot be
    /// materialized without bound before JSON validation.
    public static func readBoundedStandardInput() -> Data? {
        readBounded(FileHandle.standardInput)
    }

    private static func inputData(arguments: [String], stdin: Data) -> Data? {
        guard let index = arguments.firstIndex(of: "--input") else {
            return stdin.count <= maximumInputBytes ? stdin : nil
        }
        guard arguments.indices.contains(index + 1), !arguments[index + 1].isEmpty else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: arguments[index + 1])) else { return nil }
        defer { try? handle.close() }
        return readBounded(handle)
    }

    private static func readBounded(_ handle: FileHandle) -> Data? {
        var result = Data()
        while true {
            let remaining = maximumInputBytes - result.count
            guard remaining >= 0 else { return nil }
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: min(64 * 1024, remaining + 1)) ?? Data()
            } catch {
                return nil
            }
            guard !chunk.isEmpty else { return result }
            result.append(chunk)
            if result.count > maximumInputBytes { return nil }
        }
    }

    private static func decodeFixture(_ data: Data) -> MeetingSynchronizerReplayFixture? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any], strictKeys(root, ["schemaVersion", "configuration", "microphone", "reference"]) else { return nil }
        guard let configuration = root["configuration"] as? [String: Any],
              strictKeys(configuration, ["analysisSampleRate", "frameDuration", "microphoneAlgorithmicDelaySeconds", "referenceAlgorithmicDelaySeconds", "referenceToMicrophoneOffsetSeconds", "referenceClockDriftPPM", "maximumClockDriftPPM", "referenceScope", "referenceCompleteness", "codecPrimingSamples", "codecRemainderSamples", "editListOffsetSeconds", "maximumInputFrameCount", "maximumInputSampleCount", "maximumOutputFrameCount", "engineAvailable"]),
              let microphone = root["microphone"] as? [[String: Any]],
              let reference = root["reference"] as? [[String: Any]],
              microphone.allSatisfy({ strictKeys($0,
                  required: ["sequenceNumber", "sampleTime", "sampleRate", "channelCount", "samples", "routeIdentifier", "discontinuity"],
                  allowed: ["sequenceNumber", "sampleTime", "hostTime", "sampleRate", "channelCount", "samples", "routeIdentifier", "discontinuity"]) }),
              reference.allSatisfy({ strictKeys($0, ["sequenceNumber", "presentationTime", "sampleRate", "channelCount", "samples", "discontinuity"]) }) else { return nil }
        return try? JSONDecoder().decode(MeetingSynchronizerReplayFixture.self, from: data)
    }

    private static func validate(_ fixture: MeetingSynchronizerReplayFixture) -> Bool {
        guard fixture.schemaVersion == 1,
              finitePositive(fixture.configuration.analysisSampleRate), fixture.configuration.analysisSampleRate <= 384_000,
              finitePositive(fixture.configuration.frameDuration), fixture.configuration.frameDuration <= 10,
              finite(fixture.configuration.microphoneAlgorithmicDelaySeconds), finite(fixture.configuration.referenceAlgorithmicDelaySeconds),
              finite(fixture.configuration.referenceToMicrophoneOffsetSeconds), finite(fixture.configuration.editListOffsetSeconds),
              finite(fixture.configuration.referenceClockDriftPPM), finite(fixture.configuration.maximumClockDriftPPM),
              fixture.configuration.maximumClockDriftPPM >= 0,
              abs(fixture.configuration.referenceClockDriftPPM) <= fixture.configuration.maximumClockDriftPPM,
              fixture.configuration.codecPrimingSamples >= 0, fixture.configuration.codecRemainderSamples >= 0,
              fixture.configuration.maximumInputFrameCount > 0, fixture.configuration.maximumInputFrameCount <= hardMaximumInputFrames,
              fixture.configuration.maximumInputSampleCount > 0, fixture.configuration.maximumInputSampleCount <= hardMaximumInputSamples,
              fixture.configuration.maximumOutputFrameCount > 0, fixture.configuration.maximumOutputFrameCount <= hardMaximumOutputFrames,
              fixture.microphone.count <= fixture.configuration.maximumInputFrameCount,
              fixture.reference.count <= fixture.configuration.maximumInputFrameCount else { return false }
        let (inputFrames, inputFrameOverflow) = fixture.microphone.count
            .addingReportingOverflow(fixture.reference.count)
        guard !inputFrameOverflow, inputFrames <= fixture.configuration.maximumInputFrameCount else { return false }
        let frameProduct = fixture.configuration.analysisSampleRate * fixture.configuration.frameDuration
        let frameSize = frameProduct.rounded()
        guard frameProduct.isFinite, frameSize >= 1, frameSize <= Double(hardMaximumOutputSamples),
              frameSize < Double(Int.max) else { return false }
        let (outputSamples, outputOverflow) = fixture.configuration.maximumOutputFrameCount
            .multipliedReportingOverflow(by: Int(frameSize))
        guard !outputOverflow, outputSamples <= hardMaximumOutputSamples else { return false }
        var allSamples = 0
        for count in fixture.microphone.map(\.samples.count) + fixture.reference.map(\.samples.count) {
            let (sum, overflow) = allSamples.addingReportingOverflow(max(0, count))
            guard !overflow else { return false }
            allSamples = sum
        }
        guard allSamples <= fixture.configuration.maximumInputSampleCount else { return false }
        guard fixture.microphone.allSatisfy(validate), fixture.reference.allSatisfy(validate) else { return false }
        return true
    }

    private static func validate(_ frame: MeetingSynchronizerReplayMicrophoneFrame) -> Bool {
        !frame.samples.isEmpty && frame.channelCount > 0 && frame.channelCount <= hardMaximumChannelCount
            && finitePositive(frame.sampleRate) && frame.sampleRate <= hardMaximumSourceSampleRate
            && frame.samples.count % frame.channelCount == 0
            && frame.samples.allSatisfy(\.isFinite) && (frame.hostTime.map(finite) ?? true)
    }

    private static func validate(_ frame: MeetingSynchronizerReplayReferenceFrame) -> Bool {
        !frame.samples.isEmpty && frame.channelCount > 0 && frame.channelCount <= hardMaximumChannelCount
            && finitePositive(frame.sampleRate) && frame.sampleRate <= hardMaximumSourceSampleRate
            && finite(frame.presentationTime)
            && frame.samples.count % frame.channelCount == 0 && frame.samples.allSatisfy(\.isFinite)
    }

    private static func makeOutput(_ result: MeetingSynchronizationResult, identity: String) -> MeetingSynchronizerReplayOutput {
        let frames = result.frames
        let captureValid = frames.reduce(0) { $0 + $1.captureValidMask.filter { $0 }.count }
        let renderValid = frames.reduce(0) { $0 + $1.renderValidMask.filter { $0 }.count }
        var reasons: [String: Int] = [:]
        for frame in frames { for reason in frame.unknownReasons { reasons[reason.rawValue, default: 0] += 1 } }
        var epochs = [Int](repeating: 0, count: max(0, (frames.map(\.epochID).max() ?? -1) + 1))
        for frame in frames where frame.epochID >= 0 && frame.epochID < epochs.count { epochs[frame.epochID] += 1 }
        let sessions = frames.map { ($0.sessionStartTime, $0.sessionEndTime) }
        let micTimes = frames.compactMap { $0.timelines.microphoneSourceTime }
        let refTimes = frames.compactMap { $0.timelines.referencePTSTime }
        return .init(schemaVersion: 1, replayIdentity: identity, failedOpen: result.failedOpen,
            failureReason: result.failureReason?.rawValue, frameCount: frames.count,
            captureValidSampleCount: captureValid, captureInvalidSampleCount: frames.reduce(0) { $0 + $1.captureValidMask.filter { !$0 }.count },
            renderValidSampleCount: renderValid, renderInvalidSampleCount: frames.reduce(0) { $0 + $1.renderValidMask.filter { !$0 }.count },
            unknownReasonCounts: reasons, epochFrameCounts: epochs,
            sessionStartTime: sessions.map(\.0).min(), sessionEndTime: sessions.map(\.1).max(),
            microphoneSourceObservedMinimumTime: micTimes.min(), microphoneSourceObservedMaximumTime: micTimes.max(),
            referencePTSObservedMinimumTime: refTimes.min(), referencePTSObservedMaximumTime: refTimes.max(),
            diagnostics: .init(inputFrameCount: result.diagnostics.inputFrameCount,
                droppedFrameCount: result.diagnostics.droppedFrameCount,
                duplicateOrLateFrameCount: result.diagnostics.duplicateOrLateFrameCount,
                nonFiniteSampleCount: result.diagnostics.nonFiniteSampleCount,
                epochCount: result.diagnostics.epochCount,
                synthesizedMicrophoneFrameCount: result.diagnostics.synthesizedMicrophoneFrameCount,
                boundedResourceFailure: result.diagnostics.boundedResourceFailure,
                referenceClockDriftPPM: result.diagnostics.referenceClockDriftPPM))
    }

    private static func canonicalData(_ fixture: MeetingSynchronizerReplayFixture) throws -> Data {
        try encoded(fixture)
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func errorData(code: String) -> Data {
        struct ErrorOutput: Encodable { let schemaVersion: Int; let errorCode: String }
        return (try? encoded(ErrorOutput(schemaVersion: 1, errorCode: code)))
            ?? Data("{\"schemaVersion\":1,\"errorCode\":\"outputEncodingFailed\"}".utf8)
    }

    private static func strictKeys(_ dictionary: [String: Any], _ allowed: Set<String>) -> Bool {
        Set(dictionary.keys) == allowed
    }

    private static func strictKeys(_ dictionary: [String: Any], required: Set<String>, allowed: Set<String>) -> Bool {
        Set(dictionary.keys).isSubset(of: allowed) && required.isSubset(of: Set(dictionary.keys))
    }

    private static func finite(_ value: Double) -> Bool { value.isFinite }
    private static func finitePositive(_ value: Double) -> Bool { value.isFinite && value > 0 }
}
