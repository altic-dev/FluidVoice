import AppKit
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class OverlayPlacementTests: XCTestCase {
    private let overlaySize = NSSize(width: 300, height: 60)
    private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let laptopVisible = CGRect(x: 0, y: 70, width: 1512, height: 879)
    private let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
    private let externalVisible = CGRect(x: 1512, y: 0, width: 2560, height: 1415)

    private func isUsable(
        _ point: NSPoint,
        chosenOn arrangement: [CGRect],
        screens: [CGRect],
        visibleFrames: [CGRect]
    ) -> Bool {
        OverlayPlacement.originIsUsable(
            OverlayPlacedOrigin(point: point, screenFrames: arrangement),
            size: self.overlaySize,
            screens: screens,
            visibleFrames: visibleFrames
        )
    }

    func testSameArrangementKeepsAPositionDraggedPastTheScreenEdge() {
        // Deliberately parked almost entirely off the left edge.
        XCTAssertTrue(self.isUsable(
            NSPoint(x: -290, y: 400),
            chosenOn: [self.laptop],
            screens: [self.laptop],
            visibleFrames: [self.laptopVisible]
        ))
    }

    func testArrangementMatchIgnoresScreenOrder() {
        XCTAssertTrue(OverlayPlacement.arrangementsMatch(
            [self.laptop, self.external],
            [self.external, self.laptop]
        ))
        XCTAssertFalse(OverlayPlacement.arrangementsMatch([self.laptop, self.external], [self.laptop]))
    }

    func testChangedArrangementKeepsAPositionThatIsStillMostlyVisible() {
        XCTAssertTrue(self.isUsable(
            NSPoint(x: 600, y: 400),
            chosenOn: [self.laptop, self.external],
            screens: [self.laptop],
            visibleFrames: [self.laptopVisible]
        ))
    }

    func testChangedArrangementRejectsAPositionOnTheUnpluggedDisplay() {
        XCTAssertFalse(self.isUsable(
            NSPoint(x: 2500, y: 600),
            chosenOn: [self.laptop, self.external],
            screens: [self.laptop],
            visibleFrames: [self.laptopVisible]
        ))
    }

    func testChangedArrangementRejectsASliverTooThinToGrab() {
        // One point of the overlay is left on the laptop once the external display is gone.
        XCTAssertFalse(self.isUsable(
            NSPoint(x: self.laptop.maxX - 1, y: 400),
            chosenOn: [self.laptop, self.external],
            screens: [self.laptop],
            visibleFrames: [self.laptopVisible]
        ))
    }

    func testChangedArrangementRejectsAPositionOnlyUnderTheMenuBar() {
        // Overlaps the screen frame but not its visible area.
        XCTAssertFalse(self.isUsable(
            NSPoint(x: 600, y: self.laptopVisible.maxY + 5),
            chosenOn: [self.laptop, self.external],
            screens: [self.laptop],
            visibleFrames: [self.laptopVisible]
        ))
    }

    func testLegacyPositionWithoutAnArrangementFallsBackToTheVisibilityTest() {
        XCTAssertTrue(self.isUsable(
            NSPoint(x: 600, y: 400),
            chosenOn: [],
            screens: [self.laptop],
            visibleFrames: [self.laptopVisible]
        ))
        XCTAssertFalse(self.isUsable(
            NSPoint(x: -1000, y: 400),
            chosenOn: [],
            screens: [self.laptop],
            visibleFrames: [self.laptopVisible]
        ))
    }

    func testNoScreensMeansNoStoredPosition() {
        XCTAssertFalse(self.isUsable(
            NSPoint(x: 600, y: 400),
            chosenOn: [self.laptop],
            screens: [],
            visibleFrames: []
        ))
    }
}
