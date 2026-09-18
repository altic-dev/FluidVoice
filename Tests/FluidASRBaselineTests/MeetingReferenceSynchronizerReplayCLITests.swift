@testable import FluidASRBaselineHost
import Foundation
import XCTest

@MainActor
final class MeetingReferenceSynchronizerReplayCLITests: XCTestCase {
    private func fixture(
        microphone: [MeetingSynchronizerReplayMicrophoneFrame] = [],
        reference: [MeetingSynchronizerReplayReferenceFrame] = [],
        configuration: MeetingSynchronizerReplayConfiguration = .init()
    ) -> MeetingSynchronizerReplayFixture {
        .init(configuration: configuration, microphone: microphone, reference: reference)
    }

    private func frameFixture(
        hostTime: Double? = 1,
        configuration: MeetingSynchronizerReplayConfiguration = .init()
    ) -> MeetingSynchronizerReplayFixture {
        fixture(
            microphone: (0..<3).map {
                let index = $0
                return .init(sequenceNumber: index, sampleTime: Int64(index * 160), hostTime: hostTime.map { base in base + Double(index) * 0.01 },
                      sampleRate: 16_000, samples: [Float](repeating: Float(index + 1), count: 160))
            },
            reference: (0..<3).map {
                .init(sequenceNumber: $0, presentationTime: Double($0) * 0.01,
                      sampleRate: 16_000, samples: [Float](repeating: 2, count: 160))
            },
            configuration: configuration
        )
    }

    private func encoded(_ fixture: MeetingSynchronizerReplayFixture) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(fixture)
    }

    private func run(_ fixture: MeetingSynchronizerReplayFixture, environment: [String: String] = [:]) throws -> (Int32, Data) {
        var output = Data()
        let status = MeetingReferenceSynchronizerReplayCLI.run(
            arguments: ["replay", MeetingReferenceSynchronizerReplayCLI.argument],
            environment: environment, inputData: try encoded(fixture), output: { output = $0 })
        return (status, output)
    }

    func testReplayIsDeterministicAndOutputContainsNoPCM() throws {
        let fixture = frameFixture()
        let first = try run(fixture)
        let second = try run(fixture)
        XCTAssertEqual(first.0, 0)
        XCTAssertEqual(first.1, second.1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: first.1) as? [String: Any])
        XCTAssertNil(object["samples"])
        XCTAssertNil(object["transcript"])
        XCTAssertNotNil(object["replayIdentity"])
        XCTAssertNotNil(object["captureValidSampleCount"])
    }

    func testUnknownMasksGapsEpochsAndSynthTimingAreSummarized() throws {
        let mic = [
            MeetingSynchronizerReplayMicrophoneFrame(sequenceNumber: 0, sampleTime: 0, hostTime: nil,
                sampleRate: 16_000, samples: [Float](repeating: 1, count: 160)),
            MeetingSynchronizerReplayMicrophoneFrame(sequenceNumber: 2, sampleTime: 320, hostTime: 1.02,
                sampleRate: 16_000, samples: [Float](repeating: 1, count: 160))
        ]
        let (status, data) = try run(fixture(microphone: mic, reference: frameFixture().reference))
        XCTAssertEqual(status, 0)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let reasons = try XCTUnwrap(object["unknownReasonCounts"] as? [String: Int])
        XCTAssertGreaterThan(reasons[MeetingSynchronizerUnknownReason.captureGap.rawValue] ?? 0, 0)
        XCTAssertGreaterThan(reasons[MeetingSynchronizerUnknownReason.captureTimingSynthesized.rawValue] ?? 0, 0)
        XCTAssertGreaterThan((object["frameCount"] as? Int) ?? 0, 0)
    }

    func testMalformedSchemaAndNonFiniteInputFailClosedWithoutPathLeak() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(frameFixture())) as? [String: Any])
        json["unexpected"] = "rejected"
        let data = try JSONSerialization.data(withJSONObject: json)
        var output = Data()
        let status = MeetingReferenceSynchronizerReplayCLI.run(
            arguments: ["replay", MeetingReferenceSynchronizerReplayCLI.argument],
            inputData: data, output: { output = $0 })
        XCTAssertEqual(status, 2)
        let error = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        XCTAssertEqual(error["errorCode"] as? String, "invalidInput")
        XCTAssertNil(error["path"])
    }

    func testResourceBoundsAndOfflineGateAreExplicit() throws {
        var output = Data()
        let noGate = MeetingReferenceSynchronizerReplayCLI.run(
            arguments: ["replay"], inputData: try encoded(frameFixture()), output: { output = $0 })
        XCTAssertEqual(noGate, 2)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: output) as? [String: Any])?["errorCode"] as? String, "offlineGateRequired")

        let limited = MeetingSynchronizerReplayConfiguration(maximumOutputFrameCount: 1)
        let (status, boundedOutput) = try run(frameFixture(configuration: limited))
        XCTAssertEqual(status, 1)
        let bounded = try XCTUnwrap(JSONSerialization.jsonObject(with: boundedOutput) as? [String: Any])
        XCTAssertEqual(bounded["failedOpen"] as? Bool, true)
        XCTAssertEqual((bounded["diagnostics"] as? [String: Any])?["boundedResourceFailure"] as? Bool, true)

        let totalFrameLimit = MeetingSynchronizerReplayConfiguration(maximumInputFrameCount: 3)
        let (totalFrameStatus, totalFrameData) = try run(frameFixture(configuration: totalFrameLimit))
        XCTAssertEqual(totalFrameStatus, 2)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: totalFrameData) as? [String: Any])?["errorCode"] as? String, "invalidInput")
    }

    func testNilHostTimeAndEmptySamplesAreHandledStrictly() throws {
        let nilHost = frameFixture(hostTime: nil)
        let (nilStatus, nilData) = try run(nilHost)
        XCTAssertEqual(nilStatus, 0)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: nilData))

        let emptyMic = MeetingSynchronizerReplayMicrophoneFrame(
            sequenceNumber: 0, sampleTime: 0, hostTime: 1, sampleRate: 16_000, samples: [])
        let (emptyStatus, emptyData) = try run(fixture(microphone: [emptyMic], reference: frameFixture().reference))
        XCTAssertEqual(emptyStatus, 2)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: emptyData) as? [String: Any])?["errorCode"] as? String, "invalidInput")
    }

    func testOversizedInputIsRejectedBeforeJSONDecode() throws {
        var output = Data()
        let oversized = Data(repeating: 0x20, count: MeetingReferenceSynchronizerReplayCLI.maximumInputBytes + 1)
        let status = MeetingReferenceSynchronizerReplayCLI.run(
            arguments: ["replay", MeetingReferenceSynchronizerReplayCLI.argument], inputData: oversized,
            output: { output = $0 })
        XCTAssertEqual(status, 2)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: output) as? [String: Any])?["errorCode"] as? String, "invalidInput")
    }

    func testOutputAllocationBudgetHasAnExactFrameCap() throws {
        let accepted = MeetingSynchronizerReplayConfiguration(maximumOutputFrameCount: 6_000)
        let (acceptedStatus, _) = try run(frameFixture(configuration: accepted))
        XCTAssertEqual(acceptedStatus, 0)

        let tooManyFrames = MeetingSynchronizerReplayConfiguration(maximumOutputFrameCount: 6_001)
        let (frameStatus, frameData) = try run(frameFixture(configuration: tooManyFrames))
        XCTAssertEqual(frameStatus, 2)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: frameData) as? [String: Any])?["errorCode"] as? String, "invalidInput")

        let tooLargeFrame = MeetingSynchronizerReplayConfiguration(
            analysisSampleRate: 384_000, frameDuration: 10, maximumOutputFrameCount: 1)
        let (sampleStatus, sampleData) = try run(frameFixture(configuration: tooLargeFrame))
        XCTAssertEqual(sampleStatus, 2)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: sampleData) as? [String: Any])?["errorCode"] as? String, "invalidInput")
    }

    func testConfiguredFixtureFamiliesReplayWithoutClassificationClaims() throws {
        let sampleCount = 3 * 160
        let broadbandReference = (0..<sampleCount).map { index -> Float in
            index == 8 ? 1 : Float(sin(Double(index) * 0.071) * 0.4)
        }
        let impulseReference = (0..<sampleCount).map { $0 == 8 ? Float(1) : 0 }
        let nearSignal = (0..<sampleCount).map { index -> Float in
            Float(sin(Double(index) * 0.113 + 0.4) * 0.25)
        }
        func firEcho(_ reference: [Float]) -> [Float] {
            let taps: [(delay: Int, gain: Float)] = [(16, 0.7), (31, 0.2), (47, -0.1)]
            return (0..<reference.count).map { index in
                taps.reduce(Float(0)) { partial, tap in
                    index >= tap.delay ? partial + tap.gain * reference[index - tap.delay] : partial
                }
            }
        }
        let impulseFIR = firEcho(impulseReference)
        let broadbandEcho = firEcho(broadbandReference)
        let silent = [Float](repeating: 0, count: sampleCount)
        let lowReference = broadbandReference.map { $0 * 0.00001 }
        let families: [(name: String, capture: [Float], reference: [Float])] = [
            ("impulseFIR", impulseFIR, impulseReference),
            ("echoOnly", broadbandEcho, broadbandReference),
            ("nearEndOnly", nearSignal, silent),
            ("doubleTalkLowEcho", zip(nearSignal, broadbandEcho).map { $0 + 0.25 * $1 }, broadbandReference),
            ("doubleTalkUnity", zip(nearSignal, broadbandEcho).map(+), broadbandReference),
            ("doubleTalkHighEcho", zip(nearSignal, broadbandEcho).map { $0 + 4 * $1 }, broadbandReference),
            ("nonlinearClippedEcho", broadbandEcho.map { max(-0.3, min(0.3, $0 * 3)) }, broadbandReference),
            ("lowExcitation", firEcho(lowReference), lowReference),
            ("silence", silent, silent),
            ("exactLocalRepetition", broadbandReference, broadbandReference),
        ]
        for family in families {
            let mic = (0..<3).map { index in
                let slice = Array(family.capture[(index * 160)..<((index + 1) * 160)])
                return MeetingSynchronizerReplayMicrophoneFrame(sequenceNumber: index, sampleTime: Int64(index * 160),
                    hostTime: 1 + Double(index) * 0.01, sampleRate: 16_000, samples: slice)
            }
            let ref = (0..<3).map { index in
                let slice = Array(family.reference[(index * 160)..<((index + 1) * 160)])
                return MeetingSynchronizerReplayReferenceFrame(sequenceNumber: index, presentationTime: Double(index) * 0.01,
                    sampleRate: 16_000, samples: slice)
            }
            let replay = fixture(microphone: mic, reference: ref)
            let (status, data) = try run(replay)
            XCTAssertEqual(status, 0)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["frameCount"] as? Int, 3)

            // The family inputs are signal-shape controls only. Assert pairing and
            // coverage invariants directly; do not make an attribution/classification claim.
            let synchronizer = MeetingReferenceSynchronizer()
            let result = synchronizer.synchronize(
                microphone: mic.map {
                    MeetingMicrophonePCMFrame(sequenceNumber: $0.sequenceNumber, sampleTime: $0.sampleTime,
                        hostTime: $0.hostTime, sampleRate: $0.sampleRate, channelCount: $0.channelCount,
                        samples: $0.samples, routeIdentifier: $0.routeIdentifier, discontinuity: $0.discontinuity)
                },
                reference: ref.map {
                    MeetingReferencePCMFrame(sequenceNumber: $0.sequenceNumber, presentationTime: $0.presentationTime,
                        sampleRate: $0.sampleRate, channelCount: $0.channelCount, samples: $0.samples,
                        discontinuity: $0.discontinuity)
                })
            XCTAssertFalse(result.failedOpen)
            XCTAssertEqual(result.frames.count, 3)
            XCTAssertTrue(result.frames.allSatisfy { $0.captureValidMask.count == 160 && $0.renderValidMask.count == 160 })
            XCTAssertTrue(result.frames.allSatisfy { $0.captureValidMask.allSatisfy { $0 } && $0.renderValidMask.allSatisfy { $0 } })
            XCTAssertEqual(result.frames.flatMap(\.captureSamples), family.capture, family.name)
            XCTAssertEqual(result.frames.flatMap(\.renderSamples), family.reference, family.name)
        }
    }
}
