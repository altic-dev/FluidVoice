import XCTest
@testable import FluidVoice_Debug

final class LocalAPIAudioDecoderTests: XCTestCase {
    func testTranscribeAPIDecodesBundledOggOpusFixture() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "dictation_fixture", withExtension: "ogg")
        )

        let samples = try LocalAPIAudioDecoder.oggOpusSamples(from: Data(contentsOf: fixtureURL))

        XCTAssertGreaterThan(samples.count, 16_000)
        XCTAssertLessThan(samples.count, 20_000)
        XCTAssertTrue(samples.contains { abs($0) > 0.001 })
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

        XCTAssertThrowsError(try LocalAPIAudioDecoder.oggOpusSamples(from: data)) { error in
            XCTAssertEqual(error.localizedDescription, "Invalid OGG/Opus audio: final granule exceeds decoded audio.")
        }
    }

    func testTranscribeAPIRejectsFinalOggGranuleBeforePreSkip() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "dictation_fixture", withExtension: "ogg")
        )
        var data = try Data(contentsOf: fixtureURL)
        let lastPage = try XCTUnwrap(data.range(of: Data("OggS".utf8), options: .backwards)?.lowerBound)
        data.replaceSubrange(lastPage + 6 ..< lastPage + 14, with: repeatElement(UInt8.zero, count: 8))

        XCTAssertThrowsError(try LocalAPIAudioDecoder.oggOpusSamples(from: data)) { error in
            XCTAssertEqual(error.localizedDescription, "Invalid OGG/Opus audio: final granule precedes Opus pre-skip.")
        }
    }

    func testOggPathRequiresBufferedTranscription() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "dictation_fixture", withExtension: "ogg")
        )

        XCTAssertTrue(try LocalAPIAudioDecoder.requiresBufferedTranscription(for: fixtureURL))
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
}
