@testable import FluidVoice_Debug
import XCTest

// Regression tests for file-type acceptance in meeting/file transcription.
// WhatsApp voice notes are Ogg Opus files with a `.opus` extension. macOS maps
// `.opus` (and `.oga`) to the same UTType as `.ogg` (`org.xiph.ogg-audio`) and can
// decode them natively, but the accepted-extension set was built from each UTType's
// single `preferredFilenameExtension`, which dropped every alternate extension —
// so drag-and-dropping a WhatsApp `.opus` file was rejected as unsupported.

@MainActor
final class SupportedFileExtensionsTests: XCTestCase {
    func testWhatsAppOpusExtensionsAreAccepted() {
        let supported = FileTranscriptionService.supportedFileExtensions

        XCTAssertTrue(supported.contains("opus"), "WhatsApp voice notes use .opus — macOS decodes them as Ogg Opus")
        XCTAssertTrue(supported.contains("oga"), ".oga is an alternate Ogg audio extension macOS decodes natively")
        XCTAssertTrue(supported.contains("ogg"), ".ogg must remain accepted")
    }

    func testCommonFormatsRemainAccepted() {
        let supported = FileTranscriptionService.supportedFileExtensions

        for ext in ["wav", "mp3", "m4a", "mp4", "mov", "flac", "aac"] {
            XCTAssertTrue(supported.contains(ext), ".\(ext) must remain accepted")
        }
    }

    func testOnlyDecodableExtensionsAreAccepted() {
        let supported = FileTranscriptionService.supportedFileExtensions

        // Every accepted extension must map to a UTType AVFoundation reports as decodable
        // audio/video — the set must not drift into subtitles, playlists, or arbitrary types.
        XCTAssertFalse(supported.contains("srt"), "subtitle files are not transcribable audio")
        XCTAssertFalse(supported.contains("m3u"), "playlists are not transcribable audio")
        XCTAssertFalse(supported.contains("txt"))
    }
}
