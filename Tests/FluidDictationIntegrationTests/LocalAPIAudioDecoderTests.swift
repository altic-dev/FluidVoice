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
