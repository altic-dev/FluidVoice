@testable import FluidVoice_Debug
import XCTest

// Regression tests for `TypingService.settleDelayMs`. Retype Mode used to hardcode this to
// 0 unconditionally, reasoning its own warm-up delay (inside `insertTextSlowly`) covered the
// same need — but that warm-up runs *after* `insertTextSlowly` resolves `targetPID`, so it
// doesn't substitute for the pre-capture settle needed when `preferredTargetPID` is nil
// (e.g. a caller hides our own window and expects focus to land back on the real target
// before we ask "what's focused now?"). Dropping the settle risked capturing a stale PID
// and typing into the wrong app. See PR review on https://github.com/altic-dev/FluidVoice/pull/562.

final class RetypeModeFocusSettleTests: XCTestCase {
    func testSlowTypeSettlesWhenTargetPIDIsUnknown() {
        XCTAssertEqual(TypingService.settleDelayMs(mode: .slowType, preferredTargetPID: nil), 200)
    }

    func testSlowTypeSkipsSettleWhenTargetPIDIsKnown() {
        XCTAssertEqual(TypingService.settleDelayMs(mode: .slowType, preferredTargetPID: 123), 0)
    }

    func testStandardModeSettlesWhenTargetPIDIsUnknown() {
        XCTAssertEqual(TypingService.settleDelayMs(mode: .standard, preferredTargetPID: nil), 200)
    }

    func testStandardModeSkipsSettleWhenTargetPIDIsKnown() {
        XCTAssertEqual(TypingService.settleDelayMs(mode: .standard, preferredTargetPID: 123), 0)
    }

    func testReliablePasteUsesShorterSettleWhenTargetPIDIsUnknown() {
        XCTAssertEqual(TypingService.settleDelayMs(mode: .reliablePaste, preferredTargetPID: nil), 80)
    }

    func testReliablePasteSkipsSettleWhenTargetPIDIsKnown() {
        XCTAssertEqual(TypingService.settleDelayMs(mode: .reliablePaste, preferredTargetPID: 123), 0)
    }
}
