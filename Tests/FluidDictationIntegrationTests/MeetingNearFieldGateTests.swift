@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Levels are the ones measured on a real speakerphone session: the user at 0.0287 RMS
/// (-30.8 dBFS) against room audio — a TV — at 0.0023 (-52.4 dBFS).
final class MeetingNearFieldGateTests: XCTestCase {
    private let userRMS = 0.0287
    private let roomRMS = 0.0023

    func testRoomAudioIsRejectedAgainstMeasuredUserLevel() {
        let turns = [(rms: self.userRMS, duration: 43.0), (rms: self.roomRMS, duration: 66.9)]
        let reference = MeetingNearFieldGate.referenceRMS(turns: turns)
        XCTAssertNotNil(reference)
        XCTAssertTrue(MeetingNearFieldGate.isNearField(rms: self.userRMS, reference: reference))
        XCTAssertFalse(MeetingNearFieldGate.isNearField(rms: self.roomRMS, reference: reference))
    }

    /// The user's quieter moments must survive; only the 22 dB gap is being cut.
    func testQuieterUserSpeechIsKept() {
        let reference = MeetingNearFieldGate.referenceRMS(
            turns: [(rms: self.userRMS, duration: 30.0), (rms: self.userRMS / 2, duration: 10.0)]
        )
        XCTAssertTrue(MeetingNearFieldGate.isNearField(rms: self.userRMS / 4, reference: reference))
    }

    func testAbsoluteFloorRejectsSilenceEvenWithoutAReference() {
        XCTAssertFalse(MeetingNearFieldGate.isNearField(rms: 0.0001, reference: nil))
        XCTAssertTrue(MeetingNearFieldGate.isNearField(rms: self.userRMS, reference: nil))
    }

    /// A track holding nothing but distant audio anchors on that audio, so nothing is gated —
    /// the same transcript as before the gate existed, rather than an empty one.
    func testTrackOfOnlyRoomAudioGatesNothing() {
        let turns = Array(repeating: (rms: self.roomRMS, duration: 20.0), count: 4)
        let reference = MeetingNearFieldGate.referenceRMS(turns: turns)
        for turn in turns {
            XCTAssertTrue(MeetingNearFieldGate.isNearField(rms: turn.rms, reference: reference))
        }
    }

    func testTooLittleAudioYieldsNoReference() {
        XCTAssertNil(MeetingNearFieldGate.referenceRMS(turns: [(rms: self.userRMS, duration: 1.0)]))
        XCTAssertNil(MeetingNearFieldGate.referenceRMS(turns: []))
    }

    func testReferenceIgnoresNonPositiveEntries() {
        let reference = MeetingNearFieldGate.referenceRMS(
            turns: [(rms: 0, duration: 100.0), (rms: self.userRMS, duration: 5.0)]
        )
        XCTAssertEqual(reference ?? 0, self.userRMS, accuracy: 1e-9)
    }

    /// The whole point of the gate: with the far-field turns removed, the user's cluster is the
    /// only surviving evidence and the winner-margin rule can elect it.
    func testElectionSucceedsOnceFarFieldTurnsAreRemoved() {
        let user = UUID()
        let room = UUID()
        let evidence = MeetingLocalSpeakerEvidenceSelector.candidate(
            evidenceDurationByCluster: [user: 43.0],
            prototypeSpeakerIDs: [user, room]
        )
        XCTAssertEqual(evidence, user)

        let blocked = MeetingLocalSpeakerEvidenceSelector.candidate(
            evidenceDurationByCluster: [user: 43.0, room: 66.9],
            prototypeSpeakerIDs: [user, room]
        )
        XCTAssertNil(blocked, "66.9/43.0 is below the 1.75x margin, so nothing may be elected")
    }
}
