@testable import FluidVoice_Debug
import Foundation
import XCTest

final class MeetingTimelineMigrationTests: XCTestCase {
    func testCanonicalAbsoluteTimelineMigratesSegmentsAndGapsExactlyOnce() throws {
        let origin = 505_879.706
        let fixture = self.session(
            origin: origin,
            segmentStart: origin + 0.24,
            segmentEnd: origin + 78.56,
            gapStart: origin + 2.09,
            gapEnd: origin + 4.25
        )

        let migrated = try XCTUnwrap(MeetingSessionStore.migratingCanonicalTimelineToMeetingRelative(
            fixture,
            presentationOriginSeconds: origin
        ))

        XCTAssertEqual(migrated.transcriptTimeDomain, .meetingRelative)
        XCTAssertEqual(migrated.transcriptSegments[0].start.seconds, 0.24, accuracy: 0.001)
        XCTAssertEqual(migrated.transcriptSegments[0].end.seconds, 78.56, accuracy: 0.001)
        XCTAssertEqual(migrated.transcriptCoverageGaps?[0].start ?? -1, 2.09, accuracy: 0.000_001)
        XCTAssertEqual(migrated.transcriptCoverageGaps?[0].end ?? -1, 4.25, accuracy: 0.000_001)
        XCTAssertEqual(migrated.transcriptSegments[0].id, fixture.transcriptSegments[0].id)
        XCTAssertEqual(migrated.transcriptSegments[0].speakerID, fixture.transcriptSegments[0].speakerID)
        XCTAssertNil(MeetingSessionStore.migratingCanonicalTimelineToMeetingRelative(
            migrated,
            presentationOriginSeconds: origin
        ))
    }

    func testSmallHostOriginIsMigratedByExplicitDomainNotMagnitudeHeuristic() throws {
        let origin = 30.0
        let fixture = self.session(
            origin: origin,
            segmentStart: 30.25,
            segmentEnd: 79.75,
            gapStart: 31,
            gapEnd: 32
        )

        let migrated = try XCTUnwrap(MeetingSessionStore.migratingCanonicalTimelineToMeetingRelative(
            fixture,
            presentationOriginSeconds: origin
        ))
        XCTAssertEqual(migrated.transcriptSegments[0].start.seconds, 0.25, accuracy: 0.001)
        XCTAssertEqual(migrated.transcriptSegments[0].end.seconds, 49.75, accuracy: 0.001)
    }

    func testMigrationRefusesOriginThatWouldMakeTranscriptNegative() {
        let fixture = self.session(
            origin: 100,
            segmentStart: 99,
            segmentEnd: 101,
            gapStart: 100,
            gapEnd: 101
        )
        XCTAssertNil(MeetingSessionStore.migratingCanonicalTimelineToMeetingRelative(
            fixture,
            presentationOriginSeconds: 100
        ))
    }

    private func session(
        origin: TimeInterval,
        segmentStart: TimeInterval,
        segmentEnd: TimeInterval,
        gapStart: TimeInterval,
        gapEnd: TimeInterval
    ) -> MeetingSession {
        let configuration = MeetingCaptureConfiguration(
            mode: .inRoom,
            title: "Timeline migration",
            microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic", displayName: "Mic")
        )
        var session = MeetingSession(
            configuration: configuration,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 1,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: self.mediaTime(origin)
            )
        )
        let trackID = UUID()
        let speakerID = UUID()
        session.audioTracks = [MeetingAudioTrack(
            id: trackID,
            kind: .microphone,
            sourceIdentifier: "mic",
            sourceDisplayName: "Mic",
            format: nil,
            timebase: session.timebase,
            health: .waiting,
            chunks: []
        )]
        session.speakers = [MeetingSessionSpeaker(
            id: speakerID,
            displayName: "Speaker 1",
            diarizationClusterID: "slot-0",
            trackKind: .microphone,
            isLocalUser: false,
            identityCandidates: []
        )]
        session.transcriptSegments = [MeetingTranscriptSegment(
            id: UUID(),
            start: self.mediaTime(segmentStart),
            end: self.mediaTime(segmentEnd),
            sourceTrackID: trackID,
            speakerID: speakerID,
            text: "hello",
            revision: 0,
            status: .final,
            overlap: .none,
            completeness: .complete
        )]
        session.transcriptCoverageGaps = [MeetingTranscriptCoverageGap(
            trackID: trackID,
            start: gapStart,
            end: gapEnd,
            reason: .processingFailed
        )]
        return session
    }

    private func mediaTime(_ seconds: TimeInterval) -> MeetingMediaTime {
        MeetingMediaTime(value: Int64((seconds * 1_000).rounded()), timescale: 1_000)
    }
}
