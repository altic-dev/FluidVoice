import Foundation
import XCTest
@testable import FluidVoice_Debug

final class MeetingReferenceAttributionContractsTests: XCTestCase {
    private func result(
        _ outcome: MeetingReferenceAttributionOutcome,
        duration: Double,
        epoch: UInt64 = 0,
        index: Int = 0,
        speech: MeetingReferenceAttributionSpeechState = .unknown,
        residual: MeetingReferenceAttributionResidualVariant? = nil,
        reasons: [MeetingReferenceAttributionReasonCode] = []
    ) -> MeetingReferenceAttributionFrameResult {
        MeetingReferenceAttributionFrameResult(
            frameIndex: index, epoch: epoch, startSeconds: Double(index) * duration,
            durationSeconds: duration, outcome: outcome, speechState: speech,
            residualVariant: residual, reasons: reasons,
            metrics: MeetingReferenceAttributionMetrics(
                delaySeconds: 0.04, convergence: 0.9, erlDB: 5, erleDB: 12,
                originalEnergy: 1, residualEnergy: 0.25,
                residualToOriginalEnergyRatio: 0.25),
            fallback: outcome == .unscored ? .originalMicrophone : .none)
    }

    func testSidecarJSONRoundTripIsNumericOnlyAndPreservesResidualIdentity() throws {
        let configuration = MeetingReferenceAttributionConfiguration(candidateID: "native-multiband")
        let identity = MeetingReferenceAttributionEngineIdentity(
            engineID: "native-multiband", engineVersion: "candidate-a-v1",
            sourceHashes: [
                .init(name: "accelerate", hash: "sha256:abc"),
                .init(name: "source", hash: "sha256:def")
            ], buildHash: "sha256:build", configurationHash: configuration.configurationHash)
        let frames = [
            result(.acceptedNearEndSpeech, duration: 0.1, speech: .nearEndSpeech,
                   residual: .linearResidual, reasons: [.residualSpeechDetected]),
            result(.likelyPlaybackOnly, duration: 0.1, index: 1, speech: .noSpeech,
                   residual: .suppressedResidual, reasons: [.playbackAttributed])
        ]
        let sidecar = MeetingReferenceAttributionSidecar(
            engineIdentity: identity, configuration: configuration,
            epochs: [.init(epoch: 0)], frameResults: frames)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(sidecar)
        let decoded = try JSONDecoder().decode(MeetingReferenceAttributionSidecar.self, from: data)

        XCTAssertEqual(decoded, sidecar)
        XCTAssertEqual(sidecar.sidecarHash, MeetingReferenceAttributionSidecar(
            engineIdentity: identity, configuration: configuration,
            epochs: [.init(epoch: 0)], frameResults: frames).sidecarHash)
        let json = String(decoding: data, as: UTF8.self)
        for forbidden in ["samples", "transcript", "embedding", "windowTitle", "absolutePath"] {
            XCTAssertFalse(json.contains(forbidden), "sidecar leaked (forbidden)")
        }
        XCTAssertNotEqual(frames[0].residualVariant, frames[1].residualVariant)
    }

    func testCanonicalEncodingSortsCountEntriesAndInputOrderDoesNotAffectHash() throws {
        let configuration = MeetingReferenceAttributionConfiguration(candidateID: "canonical")
        let identity = MeetingReferenceAttributionEngineIdentity(
            engineID: "engine", engineVersion: "1", configuration: configuration)
        let first = result(.acceptedNearEndSpeech, duration: 0.1, index: 0,
                           speech: .nearEndSpeech,
                           reasons: [.residualSpeechDetected, .mixedEvidence])
        let second = result(.unscored, duration: 0.2, index: 1,
                            reasons: [.referenceGap, .unknownSpeechState])
        let left = MeetingReferenceAttributionSidecar(
            engineIdentity: identity, configuration: configuration,
            frameResults: [first, second])
        let right = MeetingReferenceAttributionSidecar(
            engineIdentity: identity, configuration: configuration,
            frameResults: [second, first])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let leftData = try encoder.encode(left)
        let rightData = try encoder.encode(right)

        XCTAssertEqual(leftData, rightData)
        XCTAssertEqual(left.sidecarHash, right.sidecarHash)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: leftData) as? [String: Any])
        let aggregate = try XCTUnwrap(object["aggregate"] as? [String: Any])
        XCTAssertTrue(aggregate["outcomeCounts"] is [[String: Any]])
        XCTAssertTrue(aggregate["reasonCounts"] is [[String: Any]])
        let entries = try XCTUnwrap(aggregate["reasonCounts"] as? [[String: Any]])
        XCTAssertEqual(entries.compactMap { $0["reason"] as? String },
                       entries.compactMap { $0["reason"] as? String }.sorted())
    }

    func testFailOpenPreservesUnknownAndOriginalFallback() {
        let frame = MeetingReferenceAttributionFrame(
            frameIndex: 4, epoch: 2, startSeconds: .nan, durationSeconds: .nan,
            microphone: .init(samples: [0], valid: [true]), reference: nil)
        let output = MeetingReferenceAttributionFrameResult.failOpen(frame: frame, reason: .referenceAbsent)

        XCTAssertEqual(output.outcome, .unscored)
        XCTAssertEqual(output.speechState, .unknown)
        XCTAssertNil(output.residualVariant)
        XCTAssertEqual(output.fallback, .originalMicrophone)
        XCTAssertTrue(output.reasons.contains(.referenceAbsent))
        XCTAssertTrue(output.reasons.contains(.unknownSpeechState))
        XCTAssertFalse(output.reasons.contains(.silenceMeasured))
        XCTAssertFalse(output.reasons.contains(.noSpeechMeasured))

        let unsafe = MeetingReferenceAttributionFrameResult(
            frameIndex: 0, epoch: 0, startSeconds: 0, durationSeconds: 0.01,
            outcome: .acceptedNearEndSpeech, speechState: .unknown)
        XCTAssertEqual(unsafe.outcome, .unscored)
        XCTAssertEqual(unsafe.fallback, .originalMicrophone)
    }

    func testAggregateCoverageUsesDurationWeightsAndCounts() {
        let frames = [
            result(.likelyPlaybackOnly, duration: 0.1, speech: .noSpeech),
            result(.acceptedNearEndSpeech, duration: 0.3, index: 1, speech: .nearEndSpeech),
            result(.mixedOrUncertain, duration: 0.2, index: 2, speech: .mixedSpeech),
            result(.scopeLimited, duration: 0.1, index: 3, reasons: [.referenceScopeLimited]),
            result(.unscored, duration: 0.3, index: 4, reasons: [.referenceGap, .unknownSpeechState])
        ]
        let aggregate = MeetingReferenceAttributionAggregate(frameResults: frames)

        XCTAssertEqual(aggregate.coverage.totalDurationSeconds, 1, accuracy: 0.000001)
        XCTAssertEqual(aggregate.coverage.scoredDurationSeconds, 0.6, accuracy: 0.000001)
        XCTAssertEqual(aggregate.coverage.likelyPlaybackOnlyDurationSeconds, 0.1, accuracy: 0.000001)
        XCTAssertEqual(aggregate.coverage.acceptedNearEndSpeechDurationSeconds, 0.3, accuracy: 0.000001)
        XCTAssertEqual(aggregate.coverage.unscoredFraction, 0.3, accuracy: 0.000001)
        XCTAssertEqual(aggregate.outcomeCounts[.acceptedNearEndSpeech], 1)
        XCTAssertEqual(aggregate.outcomeCounts[.unscored], 1)
        XCTAssertEqual(aggregate.reasonCounts[.referenceGap], 1)
    }

    func testScopeLimitedAndUnknownRemainDistinctFromMeasuredNoSpeech() {
        let scopeLimited = result(.scopeLimited, duration: 0.1, reasons: [.referenceScopeLimited])
        let unknown = result(.unscored, duration: 0.1, index: 1, reasons: [.referenceAbsent, .unknownSpeechState])
        let silence = result(.likelyPlaybackOnly, duration: 0.1, index: 2, speech: .silence,
                             residual: .suppressedResidual, reasons: [.silenceMeasured])
        let aggregate = MeetingReferenceAttributionAggregate(frameResults: [scopeLimited, unknown, silence])

        XCTAssertEqual(aggregate.outcomeCounts[.scopeLimited], 1)
        XCTAssertEqual(aggregate.outcomeCounts[.unscored], 1)
        XCTAssertEqual(aggregate.outcomeCounts[.likelyPlaybackOnly], 1)
        XCTAssertEqual(aggregate.reasonCounts[.referenceAbsent], 1)
        XCTAssertEqual(silence.speechState, .silence)
        XCTAssertNotEqual(unknown.speechState, silence.speechState)
    }

    func testIdentityAndConfigurationAreDeterministicAcrossHashOrder() {
        let first = MeetingReferenceAttributionConfiguration(candidateID: "a")
        let second = MeetingReferenceAttributionConfiguration(candidateID: "a")
        XCTAssertEqual(first.configurationHash, second.configurationHash)

        let one = MeetingReferenceAttributionEngineIdentity(
            engineID: "engine", engineVersion: "1",
            sourceHashes: [.init(name: "z", hash: "2"), .init(name: "a", hash: "1")],
            configurationHash: first.configurationHash)
        let two = MeetingReferenceAttributionEngineIdentity(
            engineID: "engine", engineVersion: "1",
            sourceHashes: [.init(name: "a", hash: "1"), .init(name: "z", hash: "2")],
            configurationHash: second.configurationHash)
        XCTAssertEqual(one.stableIdentity, two.stableIdentity)
        XCTAssertNotEqual(one.stableIdentity, MeetingReferenceAttributionEngineIdentity(
            engineID: "different", engineVersion: "1", configurationHash: first.configurationHash).stableIdentity)
    }

    func testInvalidNonFiniteMetricsAndCoverageDoNotBecomeMeasuredValues() {
        let metrics = MeetingReferenceAttributionMetrics(
            delaySeconds: .infinity, delayJitterSeconds: -.nan, convergence: 2,
            erlDB: .nan, erleDB: -.infinity, candidateScore: -0.1,
            originalEnergy: -.infinity, residualEnergy: .nan,
            residualToOriginalEnergyRatio: -0.1, processingMilliseconds: .nan,
            peakMemoryBytes: -1)
        XCTAssertNil(metrics.delaySeconds)
        XCTAssertNil(metrics.delayJitterSeconds)
        XCTAssertNil(metrics.convergence)
        XCTAssertNil(metrics.erlDB)
        XCTAssertNil(metrics.candidateScore)
        XCTAssertNil(metrics.originalEnergy)
        XCTAssertNil(metrics.residualEnergy)
        XCTAssertNil(metrics.residualToOriginalEnergyRatio)
        XCTAssertNil(metrics.processingMilliseconds)
        XCTAssertNil(metrics.peakMemoryBytes)

        XCTAssertNil(MeetingReferenceAttributionCoverage(
            totalDurationSeconds: 1, scoredDurationSeconds: 1.1,
            likelyPlaybackOnlyDurationSeconds: 0, acceptedNearEndSpeechDurationSeconds: 0,
            mixedOrUncertainDurationSeconds: 0, scopeLimitedDurationSeconds: 0,
            unscoredDurationSeconds: 0, frameCount: 1))
    }

    func testFrameValidationRejectsBadShapeNonFinitePCMAndOverflowTiming() {
        let badShape = MeetingReferenceAttributionFrame(
            frameIndex: 0, epoch: 0, startSeconds: 0, durationSeconds: 0.01,
            microphone: .init(samples: [0, 1], valid: [true]), reference: nil)
        XCTAssertFalse(badShape.isValid)
        XCTAssertTrue(badShape.validationReasons.contains(.invalidInput))
        XCTAssertThrowsError(try badShape.validate())

        let badPCM = MeetingReferenceAttributionFrame(
            frameIndex: 0, epoch: 0, startSeconds: 0, durationSeconds: 0.01,
            microphone: .init(samples: [.nan], valid: [true]), reference: nil)
        XCTAssertTrue(badPCM.validationReasons.contains(.nonFiniteInput))

        let overflow = MeetingReferenceAttributionFrame(
            frameIndex: 0, epoch: 0, startSeconds: .greatestFiniteMagnitude,
            durationSeconds: .greatestFiniteMagnitude,
            microphone: .init(samples: [0], valid: [true]), reference: nil)
        XCTAssertFalse(overflow.hasValidTiming)
    }

    func testFrameResultDecodeRejectsOutcomeSpeechAndFallbackContradictions() throws {
        let configuration = MeetingReferenceAttributionConfiguration()
        let identity = MeetingReferenceAttributionEngineIdentity(
            engineID: "engine", engineVersion: "1", configuration: configuration)
        let sidecar = MeetingReferenceAttributionSidecar(
            engineIdentity: identity, configuration: configuration,
            frameResults: [result(.acceptedNearEndSpeech, duration: 0.1, speech: .nearEndSpeech)])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(sidecar)) as? [String: Any])
        var frames = try XCTUnwrap(object["frameResults"] as? [[String: Any]])
        frames[0]["speechState"] = MeetingReferenceAttributionSpeechState.unknown.rawValue
        object["frameResults"] = frames
        let corrupt = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(MeetingReferenceAttributionSidecar.self, from: corrupt))
    }

    func testPlaybackOnlyConflictingSpeechDegradesAndNoncanonicalReasonsAreRejected() throws {
        let conflicting = result(
            .likelyPlaybackOnly, duration: 0.1, speech: .nearEndSpeech,
            reasons: [.playbackAttributed]
        )
        XCTAssertEqual(conflicting.outcome, .mixedOrUncertain)
        XCTAssertEqual(conflicting.speechState, .nearEndSpeech)
        XCTAssertTrue(conflicting.reasons.contains(.mixedEvidence))

        let configuration = MeetingReferenceAttributionConfiguration()
        let identity = MeetingReferenceAttributionEngineIdentity(
            engineID: "engine", engineVersion: "1", configuration: configuration)
        let sidecar = MeetingReferenceAttributionSidecar(
            engineIdentity: identity, configuration: configuration,
            frameResults: [result(
                .likelyPlaybackOnly, duration: 0.1, speech: .noSpeech,
                reasons: [.playbackAttributed, .noSpeechMeasured])])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(sidecar)) as? [String: Any])
        var frames = try XCTUnwrap(object["frameResults"] as? [[String: Any]])
        let canonicalReasons = try XCTUnwrap(frames[0]["reasons"] as? [String])
        frames[0]["reasons"] = Array(canonicalReasons.reversed())
        object["frameResults"] = frames
        let noncanonical = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(
            MeetingReferenceAttributionSidecar.self, from: noncanonical))
    }

    func testSidecarDecodeRejectsAggregateEpochAndConfigurationMismatches() throws {
        let configuration = MeetingReferenceAttributionConfiguration()
        let identity = MeetingReferenceAttributionEngineIdentity(
            engineID: "engine", engineVersion: "1", configuration: configuration)
        let sidecar = MeetingReferenceAttributionSidecar(
            engineIdentity: identity, configuration: configuration,
            frameResults: [result(.acceptedNearEndSpeech, duration: 0.1, speech: .nearEndSpeech)])
        let encoder = JSONEncoder()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: encoder.encode(sidecar)) as? [String: Any])

        var identityObject = try XCTUnwrap(object["engineIdentity"] as? [String: Any])
        identityObject["configurationHash"] = "mismatch"
        object["engineIdentity"] = identityObject
        XCTAssertThrowsError(try JSONDecoder().decode(
            MeetingReferenceAttributionSidecar.self,
            from: JSONSerialization.data(withJSONObject: object)))

        object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: encoder.encode(sidecar)) as? [String: Any])
        var epochs = try XCTUnwrap(object["epochs"] as? [[String: Any]])
        epochs.append(epochs[0])
        object["epochs"] = epochs
        XCTAssertThrowsError(try JSONDecoder().decode(
            MeetingReferenceAttributionSidecar.self,
            from: JSONSerialization.data(withJSONObject: object)))

        object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: encoder.encode(sidecar)) as? [String: Any])
        var aggregate = try XCTUnwrap(object["aggregate"] as? [String: Any])
        var coverage = try XCTUnwrap(aggregate["coverage"] as? [String: Any])
        coverage["totalDurationSeconds"] = 0.2
        aggregate["coverage"] = coverage
        object["aggregate"] = aggregate
        XCTAssertThrowsError(try JSONDecoder().decode(
            MeetingReferenceAttributionSidecar.self,
            from: JSONSerialization.data(withJSONObject: object)))
    }

    func testProgrammaticSidecarExposesDuplicateFrameKeyAsInvalid() {
        let configuration = MeetingReferenceAttributionConfiguration()
        let identity = MeetingReferenceAttributionEngineIdentity(
            engineID: "engine", engineVersion: "1", configuration: configuration)
        let frame = result(.acceptedNearEndSpeech, duration: 0.1, speech: .nearEndSpeech)
        let sidecar = MeetingReferenceAttributionSidecar(
            engineIdentity: identity, configuration: configuration,
            frameResults: [frame, frame])
        XCTAssertEqual(sidecar.validationError, .invalid("duplicate epoch/frame key"))
        XCTAssertFalse(sidecar.isValid)
    }

    func testProgrammaticDuplicateEpochsDoNotTrapAndRemainInvalid() {
        let configuration = MeetingReferenceAttributionConfiguration()
        let identity = MeetingReferenceAttributionEngineIdentity(
            engineID: "engine", engineVersion: "1", configuration: configuration)
        let frame = result(.acceptedNearEndSpeech, duration: 0.1, speech: .nearEndSpeech)
        let sidecar = MeetingReferenceAttributionSidecar(
            engineIdentity: identity, configuration: configuration,
            epochs: [.init(epoch: 0), .init(epoch: 0)], frameResults: [frame])

        XCTAssertEqual(sidecar.epochs.count, 2)
        XCTAssertEqual(sidecar.validationError, .invalid("duplicate epoch"))
        XCTAssertFalse(sidecar.isValid)
    }

    func testContradictoryFrameResultsNormalizeToDecodableFailOpenValues() throws {
        let cases: [MeetingReferenceAttributionFrameResult] = [
            result(.acceptedNearEndSpeech, duration: 0.1, speech: .playbackSpeech,
                   residual: .linearResidual, reasons: [.residualSpeechDetected]),
            result(.likelyPlaybackOnly, duration: 0.1, index: 1, speech: .unknown,
                   residual: .suppressedResidual),
            MeetingReferenceAttributionFrameResult(
                frameIndex: 2, epoch: 0, startSeconds: 0.2, durationSeconds: 0.1,
                outcome: .unscored, speechState: .nearEndSpeech,
                residualVariant: .linearResidual, fallback: .none),
            MeetingReferenceAttributionFrameResult(
                frameIndex: 3, epoch: 0, startSeconds: 0.3, durationSeconds: 0.1,
                outcome: .scopeLimited, speechState: .unknown, fallback: .originalMicrophone),
            MeetingReferenceAttributionFrameResult(
                frameIndex: -1, epoch: 0, startSeconds: 0.4, durationSeconds: 0.1,
                outcome: .mixedOrUncertain, speechState: .mixedSpeech),
            MeetingReferenceAttributionFrameResult(
                frameIndex: 5, epoch: 0, startSeconds: .greatestFiniteMagnitude,
                durationSeconds: .greatestFiniteMagnitude, outcome: .mixedOrUncertain,
                speechState: .mixedSpeech)
        ]

        for (offset, value) in cases.enumerated() {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(
                MeetingReferenceAttributionFrameResult.self, from: data)
            XCTAssertEqual(decoded, value)
            XCTAssertEqual(decoded.fallback, decoded.outcome == .unscored
                           ? .originalMicrophone : .none)
            if decoded.outcome == .unscored {
                XCTAssertEqual(decoded.speechState, .unknown)
                XCTAssertNil(decoded.residualVariant)
                XCTAssertEqual(decoded.durationSeconds, offset >= 4 ? 0 : 0.1)
            }
        }
    }

    func testSidecarDecodeRejectsOverlapAndAdversarialContractPayloads() throws {
        let configuration = MeetingReferenceAttributionConfiguration()
        let identity = MeetingReferenceAttributionEngineIdentity(
            engineID: "engine", engineVersion: "1",
            sourceHashes: [.init(name: "source", hash: "sha256:1")],
            configuration: configuration)
        let frames = [
            result(.acceptedNearEndSpeech, duration: 0.1, speech: .nearEndSpeech),
            result(.likelyPlaybackOnly, duration: 0.1, index: 1, speech: .noSpeech)
        ]
        let sidecar = MeetingReferenceAttributionSidecar(
            engineIdentity: identity, configuration: configuration,
            frameResults: frames)
        let encoder = JSONEncoder()

        func object() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(sidecar))
                          as? [String: Any])
        }
        func assertRejects(_ object: [String: Any], _ label: String = "") throws {
            XCTAssertThrowsError(try JSONDecoder().decode(
                MeetingReferenceAttributionSidecar.self,
                from: JSONSerialization.data(withJSONObject: object)), label)
        }

        var value = try object()
        value["schemaVersion"] = 999
        try assertRejects(value, "schema")

        value = try object()
        var badIdentity = try XCTUnwrap(value["engineIdentity"] as? [String: Any])
        badIdentity["engineID"] = "../leak"
        value["engineIdentity"] = badIdentity
        try assertRejects(value, "logical identity")

        value = try object()
        var duplicateIdentity = try XCTUnwrap(value["engineIdentity"] as? [String: Any])
        duplicateIdentity["sourceHashes"] = [
            ["name": "source", "hash": "sha256:1"],
            ["name": "source", "hash": "sha256:2"]
        ]
        value["engineIdentity"] = duplicateIdentity
        try assertRejects(value, "duplicate source")

        value = try object()
        var aggregate = try XCTUnwrap(value["aggregate"] as? [String: Any])
        var wouldChange = try XCTUnwrap(aggregate["wouldChange"] as? [String: Any])
        wouldChange["words"] = -1
        aggregate["wouldChange"] = wouldChange
        value["aggregate"] = aggregate
        try assertRejects(value, "negative would-change")

        value = try object()
        aggregate = try XCTUnwrap(value["aggregate"] as? [String: Any])
        var coverage = try XCTUnwrap(aggregate["coverage"] as? [String: Any])
        coverage["scoredDurationSeconds"] = 0
        aggregate["coverage"] = coverage
        value["aggregate"] = aggregate
        try assertRejects(value, "inconsistent scored coverage")

        value = try object()
        aggregate = try XCTUnwrap(value["aggregate"] as? [String: Any])
        var resourceCost = try XCTUnwrap(aggregate["resourceCost"] as? [String: Any])
        resourceCost["processingMilliseconds"] = -1
        aggregate["resourceCost"] = resourceCost
        value["aggregate"] = aggregate
        try assertRejects(value, "negative resource cost")

        value = try object()
        aggregate = try XCTUnwrap(value["aggregate"] as? [String: Any])
        resourceCost = try XCTUnwrap(aggregate["resourceCost"] as? [String: Any])
        resourceCost["overBudget"] = true
        resourceCost["fallback"] = MeetingReferenceAttributionFallback.none.rawValue
        aggregate["resourceCost"] = resourceCost
        value["aggregate"] = aggregate
        try assertRejects(value, "over-budget fallback")

        value = try object()
        var frameObjects = try XCTUnwrap(value["frameResults"] as? [[String: Any]])
        frameObjects[1]["startSeconds"] = 0.05
        value["frameResults"] = frameObjects
        try assertRejects(value, "overlapping frames")
    }

    func testResourceCostRejectsNonFiniteJSON() {
        let data = Data(#"{"processingMilliseconds":1e400,"peakMemoryBytes":null,"derivedSidecarBytes":null,"overBudget":false,"fallback":"none"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(
            MeetingReferenceAttributionResourceCost.self, from: data))
    }

    func testProgrammaticProvenanceAndEpochsRemainCanonicalAndRejectDuplicates() {
        let configuration = MeetingReferenceAttributionConfiguration()
        let duplicateIdentity = MeetingReferenceAttributionEngineIdentity(
            engineID: "engine", engineVersion: "1",
            sourceHashes: [
                .init(name: "source", hash: "sha256:1"),
                .init(name: "source", hash: "sha256:2")
            ], configuration: configuration)
        let frames = [
            result(.acceptedNearEndSpeech, duration: 0.1, epoch: 0, speech: .nearEndSpeech),
            result(.acceptedNearEndSpeech, duration: 0.1, epoch: 1, index: 1,
                   speech: .nearEndSpeech)
        ]
        let duplicateSourceSidecar = MeetingReferenceAttributionSidecar(
            engineIdentity: duplicateIdentity, configuration: configuration,
            epochs: [.init(epoch: 0), .init(epoch: 1)], frameResults: frames)
        XCTAssertFalse(duplicateSourceSidecar.isValid)

        let validIdentity = MeetingReferenceAttributionEngineIdentity(
            engineID: "engine", engineVersion: "1", configuration: configuration)
        let duplicateEpochSidecar = MeetingReferenceAttributionSidecar(
            engineIdentity: validIdentity, configuration: configuration,
            epochs: [.init(epoch: 2), .init(epoch: 0), .init(epoch: 2)], frameResults: frames)

        XCTAssertEqual(duplicateEpochSidecar.epochs.map(\.epoch), [0, 2, 2])
        XCTAssertEqual(duplicateEpochSidecar.validationError, .invalid("duplicate epoch"))
        XCTAssertFalse(duplicateEpochSidecar.isValid)
    }

    func testSidecarRejectsUnsortedEpochsAndCrossEpochOverlap() throws {
        let configuration = MeetingReferenceAttributionConfiguration()
        let identity = MeetingReferenceAttributionEngineIdentity(
            engineID: "engine", engineVersion: "1", configuration: configuration)
        let first = result(.acceptedNearEndSpeech, duration: 0.1, epoch: 0,
                           speech: .nearEndSpeech)
        let second = result(.likelyPlaybackOnly, duration: 0.1, epoch: 1, speech: .noSpeech)
        let sidecar = MeetingReferenceAttributionSidecar(
            engineIdentity: identity, configuration: configuration,
            frameResults: [first, second])
        XCTAssertEqual(sidecar.epochs.map(\.epoch), [0, 1])

        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(sidecar)) as? [String: Any])
        object["epochs"] = [["epoch": 1], ["epoch": 0]]
        XCTAssertThrowsError(try JSONDecoder().decode(
            MeetingReferenceAttributionSidecar.self,
            from: JSONSerialization.data(withJSONObject: object)))

        let overlapping = MeetingReferenceAttributionSidecar(
            engineIdentity: identity, configuration: configuration,
            frameResults: [first, MeetingReferenceAttributionFrameResult(
                frameIndex: 0, epoch: 1, startSeconds: 0.05, durationSeconds: 0.1,
                outcome: .likelyPlaybackOnly, speechState: .noSpeech)])
        XCTAssertEqual(overlapping.validationError, .invalid("non-monotonic frame timing"))
    }
}
