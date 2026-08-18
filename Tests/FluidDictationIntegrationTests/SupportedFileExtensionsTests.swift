import AVFoundation
import UniformTypeIdentifiers
@testable import FluidVoice_Debug
import XCTest

/// #868: the accepted-extension set is built from every filename extension a
/// type declares, not just its preferred one — the Ogg audio type tags
/// `["ogg", "oga", "opus"]` with `ogg` preferred, so a preferred-only set
/// rejected WhatsApp `.opus` voice notes (and `.oga`) even though macOS
/// decodes them natively.
final class SupportedFileExtensionsTests: XCTestCase {
    func testOggFamilyExtensionsAreAccepted() throws {
        let supported = MeetingTranscriptionService.supportedFileExtensions
        XCTAssertTrue(supported.contains("ogg"), "preferred Ogg extension must stay accepted")
        XCTAssertTrue(supported.contains("opus"), ".opus (WhatsApp voice notes) must be accepted")
        XCTAssertTrue(supported.contains("oga"), ".oga must be accepted")
    }

    func testWellKnownExtensionsStayAccepted() throws {
        let supported = MeetingTranscriptionService.supportedFileExtensions
        for ext in ["wav", "mp3", "m4a", "mp4", "mov"] {
            XCTAssertTrue(supported.contains(ext), "\(ext) must remain accepted")
        }
    }

    func testEveryAcceptedExtensionComesFromADecodableAVType() throws {
        // Build the full tag set the same way the service does and confirm
        // the service's set is exactly it — no hand-maintained drift.
        let avTypes = AVURLAsset.audiovisualTypes()
        var expected = Set<String>()
        for fileType in avTypes {
            guard let utType = UTType(fileType.rawValue) else { continue }
            guard utType.conforms(to: .audio) || utType.conforms(to: .movie) else { continue }
            for tag in utType.tags where tag.isFilenameExtension {
                expected.insert(tag)
            }
            if let preferred = utType.preferredFilenameExtension {
                expected.insert(preferred)
            }
        }
        XCTAssertEqual(MeetingTranscriptionService.supportedFileExtensions, expected)
    }

    func testNonMediaExtensionsStayRejected() throws {
        let supported = MeetingTranscriptionService.supportedFileExtensions
        XCTAssertFalse(supported.contains("txt"))
        XCTAssertFalse(supported.contains("pdf"))
    }
}
