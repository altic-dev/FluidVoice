import Foundation
import IOKit.pwr_mgt

/// Holds an `IOPMAssertion` that prevents the display (and the system) from
/// going idle while the user is dictating. Released as soon as recording
/// stops so the laptop returns to its normal sleep behaviour.
///
/// Uses `kIOPMAssertionTypePreventUserIdleDisplaySleep` rather than
/// `kIOPMAssertionTypePreventUserIdleSystemSleep`. The display assertion
/// implies the system one (display can't be on if the system's asleep), so
/// it's strictly stronger; and it stops the screen-lock timer that fires
/// after display sleep, which is the visible symptom Andrew was seeing.
@MainActor
final class SleepPreventionService {
    static let shared = SleepPreventionService()

    private var assertionID: IOPMAssertionID = 0
    private var isActive = false

    private init() {}

    /// Creates the sleep-prevention assertion. No-op if already active so the
    /// service is safe to call from re-entrant code paths.
    func preventSleep(reason: String = "FluidVoice transcribing") {
        guard !self.isActive else { return }

        var newID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &newID
        )

        if result == kIOReturnSuccess {
            self.assertionID = newID
            self.isActive = true
            DebugLogger.shared.info(
                "☕ Sleep prevention assertion created (\(reason))",
                source: "SleepPreventionService"
            )
        } else {
            DebugLogger.shared.warning(
                "SleepPreventionService: IOPMAssertionCreateWithName failed (\(result))",
                source: "SleepPreventionService"
            )
        }
    }

    /// Releases the assertion. No-op if there's nothing to release.
    func allowSleep() {
        guard self.isActive else { return }
        let result = IOPMAssertionRelease(self.assertionID)
        self.assertionID = 0
        self.isActive = false
        if result == kIOReturnSuccess {
            DebugLogger.shared.info(
                "💤 Sleep prevention assertion released",
                source: "SleepPreventionService"
            )
        } else {
            DebugLogger.shared.warning(
                "SleepPreventionService: IOPMAssertionRelease failed (\(result))",
                source: "SleepPreventionService"
            )
        }
    }
}
