@testable import FluidVoice_Debug
import Foundation
import XCTest

final class MeetingWindowSelectorTests: XCTestCase {
    private func candidate(
        _ windowID: UInt32,
        title: String? = nil,
        frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
        layer: Int = 0,
        zOrderIndex: Int = 0
    ) -> MeetingWindowCandidate {
        MeetingWindowCandidate(windowID: windowID, title: title, frame: frame, layer: layer, zOrderIndex: zOrderIndex)
    }

    func testEmptyCandidateListReturnsNil() {
        XCTAssertNil(MeetingWindowSelector.selectWindow(from: []))
    }

    func testTitledBeatsUntitledRegardlessOfArea() {
        let untitledLarge = self.candidate(1, title: nil, frame: CGRect(x: 0, y: 0, width: 2000, height: 2000), zOrderIndex: 0)
        let titledSmall = self.candidate(2, title: "Standup", frame: CGRect(x: 0, y: 0, width: 300, height: 300), zOrderIndex: 5)
        let winner = MeetingWindowSelector.selectWindow(from: [untitledLarge, titledSmall])
        XCTAssertEqual(winner?.windowID, 2)
    }

    func testFrontmostBeatsLargerButBehindAmongTitled() {
        let frontSmall = self.candidate(1, title: "Meeting", frame: CGRect(x: 0, y: 0, width: 400, height: 300), zOrderIndex: 0)
        let behindLarge = self.candidate(2, title: "Other", frame: CGRect(x: 0, y: 0, width: 2000, height: 1500), zOrderIndex: 3)
        let winner = MeetingWindowSelector.selectWindow(from: [behindLarge, frontSmall])
        XCTAssertEqual(winner?.windowID, 1)
    }

    func testNonZeroLayerIsExcluded() {
        let panel = self.candidate(1, title: "Panel", layer: 25)
        XCTAssertNil(MeetingWindowSelector.selectWindow(from: [panel]))
    }

    func testSubMinimumSizeIsExcluded() {
        let sliver = self.candidate(1, title: "Toolbar", frame: CGRect(x: 0, y: 0, width: 150, height: 60))
        XCTAssertNil(MeetingWindowSelector.selectWindow(from: [sliver]))
    }

    func testDeterministicWindowIDTiebreakOnFullTies() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let a = self.candidate(42, title: "Same", frame: frame, zOrderIndex: 1)
        let b = self.candidate(7, title: "Same", frame: frame, zOrderIndex: 1)
        let winner = MeetingWindowSelector.selectWindow(from: [a, b])
        XCTAssertEqual(winner?.windowID, 7)
    }

    /// Zoom-like fixture: a small floating toolbar (excluded by size), an untitled main window,
    /// and the frontmost titled meeting window. The meeting window should win.
    func testRealisticZoomFixture() {
        let toolbar = self.candidate(
            1, title: "Zoom Toolbar", frame: CGRect(x: 0, y: 0, width: 180, height: 60), layer: 0, zOrderIndex: 0
        )
        let mainWindow = self.candidate(
            2, title: nil, frame: CGRect(x: 0, y: 0, width: 1200, height: 800), layer: 0, zOrderIndex: 2
        )
        let meetingWindow = self.candidate(
            3, title: "Zoom Meeting", frame: CGRect(x: 0, y: 0, width: 1000, height: 700), layer: 0, zOrderIndex: 1
        )
        let winner = MeetingWindowSelector.selectWindow(from: [toolbar, mainWindow, meetingWindow])
        XCTAssertEqual(winner?.windowID, 3)
    }

    func testExactMinimumSizeIsIncludedAndOnePixelUnderIsNot() {
        let atMinimum = candidate(1, title: "Meeting", frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(MeetingWindowSelector.selectWindow(from: [atMinimum])?.windowID, 1)
        let underWidth = candidate(2, title: "Meeting", frame: CGRect(x: 0, y: 0, width: 199, height: 100))
        let underHeight = candidate(3, title: "Meeting", frame: CGRect(x: 0, y: 0, width: 200, height: 99))
        XCTAssertNil(MeetingWindowSelector.selectWindow(from: [underWidth, underHeight]))
    }

    func testWhitespaceOnlyTitleCountsAsUntitled() {
        let whitespace = candidate(1, title: "   \n", frame: CGRect(x: 0, y: 0, width: 2000, height: 1500), zOrderIndex: 0)
        let titled = candidate(2, title: "Meeting", frame: CGRect(x: 0, y: 0, width: 400, height: 300), zOrderIndex: 5)
        XCTAssertEqual(MeetingWindowSelector.selectWindow(from: [whitespace, titled])?.windowID, 2)
    }

    func testLargerAreaBeatsSmallerWindowIDWhenTitleAndZOrderTie() {
        let smallEarlyID = candidate(1, title: "A", frame: CGRect(x: 0, y: 0, width: 400, height: 300), zOrderIndex: 2)
        let largeLateID = candidate(9, title: "B", frame: CGRect(x: 0, y: 0, width: 900, height: 700), zOrderIndex: 2)
        XCTAssertEqual(MeetingWindowSelector.selectWindow(from: [smallEarlyID, largeLateID])?.windowID, 9)
    }

    func testFrontmostBeatsSmallerWindowID() {
        let behindEarlyID = candidate(1, title: "A", frame: CGRect(x: 0, y: 0, width: 800, height: 600), zOrderIndex: 4)
        let frontLateID = candidate(9, title: "B", frame: CGRect(x: 0, y: 0, width: 800, height: 600), zOrderIndex: 1)
        XCTAssertEqual(MeetingWindowSelector.selectWindow(from: [behindEarlyID, frontLateID])?.windowID, 9)
    }
}
