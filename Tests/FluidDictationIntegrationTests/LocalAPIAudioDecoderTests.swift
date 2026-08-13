import XCTest
@testable import FluidVoice_Debug

final class LocalAPIAudioDecoderTests: XCTestCase {
    @MainActor
    func testLocalAPIInFlightRequestCancellationStopsPendingWork() async {
        let request = LocalAPIInFlightRequest()
        let started = expectation(description: "request started")
        let completed = expectation(description: "request completed")
        completed.isInverted = true

        request.start {
            started.fulfill()
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            completed.fulfill()
        }
        await fulfillment(of: [started], timeout: 1)

        request.cancel()

        await fulfillment(of: [completed], timeout: 0.1)
        XCTAssertTrue(request.isCancelled)

        let restarted = expectation(description: "cancelled request restarted")
        restarted.isInverted = true
        request.start {
            restarted.fulfill()
        }
        await fulfillment(of: [restarted], timeout: 0.1)
    }

    func testTranscribeAPIDecodesBundledOggOpusFixture() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "dictation_fixture", withExtension: "ogg")
        )

        let samples = try LocalAPIAudioDecoder.oggOpusSamples(from: Data(contentsOf: fixtureURL))

        XCTAssertGreaterThan(samples.count, 16_000)
        XCTAssertLessThan(samples.count, 20_000)
        XCTAssertTrue(samples.contains { abs($0) > 0.001 })
    }

    func testTranscribeAPIRejectsOggOpusPageWithCorruptPayload() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "dictation_fixture", withExtension: "ogg")
        )
        var data = try Data(contentsOf: fixtureURL)
        let tagsPage = try XCTUnwrap(data.range(of: Data("OggS".utf8), options: [], in: 1 ..< data.count)?.lowerBound)
        let payloadOffset = tagsPage + 27 + Int(data[tagsPage + 26])
        data[payloadOffset + 8] ^= 0x01

        XCTAssertThrowsError(try LocalAPIAudioDecoder.oggOpusSamples(from: data)) { error in
            XCTAssertEqual(error.localizedDescription, "Invalid OGG/Opus audio: Ogg page checksum mismatch.")
        }
    }

    func testTranscribeAPIRejectsOggOpusTruncatedBeforeEOSPage() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "dictation_fixture", withExtension: "ogg")
        )
        let data = try Data(contentsOf: fixtureURL)
        let lastPage = try XCTUnwrap(data.range(of: Data("OggS".utf8), options: .backwards)?.lowerBound)
        let truncated = Data(data[..<lastPage])

        XCTAssertThrowsError(try LocalAPIAudioDecoder.oggOpusSamples(from: truncated)) { error in
            XCTAssertEqual(error.localizedDescription, "Invalid OGG/Opus audio: stream ended before EOS.")
        }
    }

    func testTranscribeAPIRejectsOggOpusPagesAfterEOS() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "dictation_fixture", withExtension: "ogg")
        )
        var data = try Data(contentsOf: fixtureURL)
        let lastPage = try XCTUnwrap(data.range(of: Data("OggS".utf8), options: .backwards)?.lowerBound)
        let precedingPages = Data(data[..<lastPage])
        let precedingPage = try XCTUnwrap(
            precedingPages.range(of: Data("OggS".utf8), options: .backwards)?.lowerBound
        )
        data[precedingPage + 5] |= 0x04
        self.updateOggPageChecksum(in: &data, pageOffset: precedingPage)

        XCTAssertThrowsError(try LocalAPIAudioDecoder.oggOpusSamples(from: data)) { error in
            XCTAssertEqual(error.localizedDescription, "Invalid OGG/Opus audio: data follows the EOS page.")
        }
    }

    func testTranscribeAPIRejectsInvalidOggWithClearError() {
        XCTAssertThrowsError(try LocalAPIAudioDecoder.oggOpusSamples(from: Data("not ogg".utf8))) { error in
            XCTAssertEqual(error.localizedDescription, "Audio input is not an OGG/Opus stream.")
        }
    }

    func testTranscribeAPIRejectsUnknownFinalOggGranuleWithoutTrapping() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "dictation_fixture", withExtension: "ogg")
        )
        var data = try Data(contentsOf: fixtureURL)
        let lastPage = try XCTUnwrap(data.range(of: Data("OggS".utf8), options: .backwards)?.lowerBound)
        data.replaceSubrange(lastPage + 6 ..< lastPage + 14, with: repeatElement(UInt8.max, count: 8))
        self.updateOggPageChecksum(in: &data, pageOffset: lastPage)

        XCTAssertThrowsError(try LocalAPIAudioDecoder.oggOpusSamples(from: data)) { error in
            XCTAssertEqual(error.localizedDescription, "Invalid OGG/Opus audio: invalid final granule position.")
        }
    }

    func testTranscribeAPIRejectsFinalOggGranuleBeyondDecodedAudio() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "dictation_fixture", withExtension: "ogg")
        )
        var data = try Data(contentsOf: fixtureURL)
        let lastPage = try XCTUnwrap(data.range(of: Data("OggS".utf8), options: .backwards)?.lowerBound)
        let impossibleGranule = UInt64(10 * 48_000)
        data.replaceSubrange(
            lastPage + 6 ..< lastPage + 14,
            with: (0 ..< 8).map { UInt8(truncatingIfNeeded: impossibleGranule >> UInt64($0 * 8)) }
        )
        self.updateOggPageChecksum(in: &data, pageOffset: lastPage)

        XCTAssertThrowsError(try LocalAPIAudioDecoder.oggOpusSamples(from: data)) { error in
            XCTAssertEqual(error.localizedDescription, "Invalid OGG/Opus audio: final granule exceeds decoded audio.")
        }
    }

    func testTranscribeAPIRejectsFinalOggGranuleBeforePreviouslyCompletedAudio() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "dictation_fixture", withExtension: "ogg")
        )
        var data = try Data(contentsOf: fixtureURL)
        let lastPage = try XCTUnwrap(data.range(of: Data("OggS".utf8), options: .backwards)?.lowerBound)
        let impossibleGranule = UInt64(1_000)
        data.replaceSubrange(
            lastPage + 6 ..< lastPage + 14,
            with: (0 ..< 8).map { UInt8(truncatingIfNeeded: impossibleGranule >> UInt64($0 * 8)) }
        )
        self.updateOggPageChecksum(in: &data, pageOffset: lastPage)

        XCTAssertThrowsError(try LocalAPIAudioDecoder.oggOpusSamples(from: data)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Invalid OGG/Opus audio: final granule trims previously completed audio."
            )
        }
    }

    func testTranscribeAPIAcceptsNormalFinalPageTrimming() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "dictation_fixture", withExtension: "ogg")
        )
        var data = try Data(contentsOf: fixtureURL)
        let lastPage = try XCTUnwrap(data.range(of: Data("OggS".utf8), options: .backwards)?.lowerBound)
        let trimmedGranule = UInt64(50_000)
        data.replaceSubrange(
            lastPage + 6 ..< lastPage + 14,
            with: (0 ..< 8).map { UInt8(truncatingIfNeeded: trimmedGranule >> UInt64($0 * 8)) }
        )
        self.updateOggPageChecksum(in: &data, pageOffset: lastPage)

        let samples = try LocalAPIAudioDecoder.oggOpusSamples(from: data)

        XCTAssertEqual(samples.count, 16_562)
    }

    func testTranscribeAPIAcceptsFinalGranuleAtPreviousPageBoundary() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "dictation_fixture", withExtension: "ogg")
        )
        var data = try Data(contentsOf: fixtureURL)
        let lastPage = try XCTUnwrap(data.range(of: Data("OggS".utf8), options: .backwards)?.lowerBound)
        let previousPageGranule = UInt64(48_000)
        data.replaceSubrange(
            lastPage + 6 ..< lastPage + 14,
            with: (0 ..< 8).map { UInt8(truncatingIfNeeded: previousPageGranule >> UInt64($0 * 8)) }
        )
        self.updateOggPageChecksum(in: &data, pageOffset: lastPage)

        let samples = try LocalAPIAudioDecoder.oggOpusSamples(from: data)

        XCTAssertEqual(samples.count, 15_896)
    }

    func testTranscribeAPIRejectsFinalOggGranuleBeforePreSkip() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "dictation_fixture", withExtension: "ogg")
        )
        var data = try Data(contentsOf: fixtureURL)
        let lastPage = try XCTUnwrap(data.range(of: Data("OggS".utf8), options: .backwards)?.lowerBound)
        data.replaceSubrange(lastPage + 6 ..< lastPage + 14, with: repeatElement(UInt8.zero, count: 8))
        self.updateOggPageChecksum(in: &data, pageOffset: lastPage)

        XCTAssertThrowsError(try LocalAPIAudioDecoder.oggOpusSamples(from: data)) { error in
            XCTAssertEqual(error.localizedDescription, "Invalid OGG/Opus audio: final granule precedes Opus pre-skip.")
        }
    }

    func testOggPathPreparationUsesStreamingMetadataForBufferedTranscription() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "dictation_fixture", withExtension: "ogg")
        )

        let prepared = try LocalAPIAudioDecoder.prepareForTranscription(fileURL: fixtureURL)

        XCTAssertTrue(prepared.requiresBufferedTranscription)
        XCTAssertGreaterThan(prepared.estimatedSamples, 16_000)
        XCTAssertLessThan(prepared.estimatedSamples, 20_000)
    }

    func testOggPathPreparationRejectsOversizedFileBeforeDecoding() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "dictation_fixture", withExtension: "ogg")
        )
        let oversizedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fluidvoice-oversized-\(UUID().uuidString).ogg")
        FileManager.default.createFile(atPath: oversizedURL.path, contents: try Data(contentsOf: fixtureURL))
        let handle = try FileHandle(forWritingTo: oversizedURL)
        try handle.truncate(atOffset: UInt64(LocalAPI.maxRequestBytes + 1))
        try handle.close()
        defer { try? FileManager.default.removeItem(at: oversizedURL) }

        XCTAssertThrowsError(try LocalAPIAudioDecoder.prepareForTranscription(fileURL: oversizedURL)) { error in
            XCTAssertEqual(error.localizedDescription, "Audio input exceeds the 25 MB API limit.")
        }
    }

    func testPathPreparationRejectsSpecialFilesBeforeReading() {
        XCTAssertThrowsError(
            try LocalAPIAudioDecoder.prepareForTranscription(fileURL: URL(fileURLWithPath: "/dev/zero"))
        ) { error in
            XCTAssertEqual(error.localizedDescription, "Audio path must reference a regular file.")
        }
    }

    func testOggPathDurationValidationUsesStructuralSampleCount() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "dictation_fixture", withExtension: "ogg")
        )
        let data = try Data(contentsOf: fixtureURL)

        XCTAssertEqual(try OggOpusDecoder.sampleCount(from: data), 55_572)
        XCTAssertEqual(try LocalAPIAudioDecoder.validateDurationWithinLimit(for: fixtureURL), 18_524)
    }

    func testOggPathPreparationRejectsFinalGranuleThatUnderstatesPacketDuration() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "dictation_fixture", withExtension: "ogg")
        )
        var data = try Data(contentsOf: fixtureURL)
        let pageOffsets = self.oggPageOffsets(in: data)
        let lastPage = try XCTUnwrap(pageOffsets.last)

        for pageOffset in pageOffsets.dropFirst().dropLast() {
            data.replaceSubrange(pageOffset + 6 ..< pageOffset + 14, with: repeatElement(UInt8.max, count: 8))
            self.updateOggPageChecksum(in: &data, pageOffset: pageOffset)
        }
        let understatedGranule = UInt64(6_000)
        data.replaceSubrange(
            lastPage + 6 ..< lastPage + 14,
            with: (0 ..< 8).map { UInt8(truncatingIfNeeded: understatedGranule >> UInt64($0 * 8)) }
        )
        self.updateOggPageChecksum(in: &data, pageOffset: lastPage)

        let craftedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fluidvoice-understated-granule-\(UUID().uuidString).ogg")
        try data.write(to: craftedURL)
        defer { try? FileManager.default.removeItem(at: craftedURL) }

        XCTAssertThrowsError(try LocalAPIAudioDecoder.prepareForTranscription(fileURL: craftedURL)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Invalid OGG/Opus audio: final granule understates decoded audio."
            )
        }
    }

    func testOggPathDurationValidationEnforcesRequestSizeLimitBeforeParsing() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "dictation_fixture", withExtension: "ogg")
        )
        var oversizedData = try Data(contentsOf: fixtureURL)
        oversizedData.append(Data(repeating: 0, count: LocalAPI.maxRequestBytes - oversizedData.count + 1))
        let oversizedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fluidvoice-oversized-\(UUID().uuidString).ogg")
        try oversizedData.write(to: oversizedURL)
        defer { try? FileManager.default.removeItem(at: oversizedURL) }

        XCTAssertThrowsError(try LocalAPIAudioDecoder.validateDurationWithinLimit(for: oversizedURL)) { error in
            XCTAssertEqual(error.localizedDescription, "Audio input exceeds the 25 MB API limit.")
        }
    }

    @MainActor
    func testTranscribeRouteAcceptsRawOggOpusBody() async throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "dictation_fixture", withExtension: "ogg")
        )
        let controller = InferenceAPIController { samples in
            XCTAssertGreaterThan(samples.count, 16_000)
            return ("fixture transcript", 0.9, "test provider")
        }
        let request = LocalAPI.Request(
            method: "POST",
            path: "/v1/transcribe",
            query: [:],
            headers: ["content-type": "audio/ogg", "x-filename": "voice.ogg"],
            body: try Data(contentsOf: fixtureURL)
        )

        let response = await controller.handle(request)

        XCTAssertEqual(response.status, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(json["text"] as? String, "fixture transcript")
        XCTAssertEqual(json["provider"] as? String, "test provider")
    }

    private func updateOggPageChecksum(in data: inout Data, pageOffset: Int) {
        let segmentCount = Int(data[pageOffset + 26])
        let payloadOffset = pageOffset + 27 + segmentCount
        let payloadLength = data[pageOffset + 27 ..< payloadOffset].reduce(0) { $0 + Int($1) }
        let pageEnd = payloadOffset + payloadLength
        data.replaceSubrange(pageOffset + 22 ..< pageOffset + 26, with: repeatElement(UInt8.zero, count: 4))

        var checksum: UInt32 = 0
        for byte in data[pageOffset ..< pageEnd] {
            checksum ^= UInt32(byte) << 24
            for _ in 0 ..< 8 {
                checksum = checksum & 0x8000_0000 != 0
                    ? (checksum &<< 1) ^ 0x04C1_1DB7
                    : checksum &<< 1
            }
        }
        data.replaceSubrange(
            pageOffset + 22 ..< pageOffset + 26,
            with: (0 ..< 4).map { UInt8(truncatingIfNeeded: checksum >> UInt32($0 * 8)) }
        )
    }

    private func oggPageOffsets(in data: Data) -> [Int] {
        var offsets: [Int] = []
        var offset = 0
        while offset < data.count {
            offsets.append(offset)
            let segmentCount = Int(data[offset + 26])
            let payloadOffset = offset + 27 + segmentCount
            let payloadLength = data[offset + 27 ..< payloadOffset].reduce(0) { $0 + Int($1) }
            offset = payloadOffset + payloadLength
        }
        return offsets
    }
}
