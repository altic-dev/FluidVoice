@testable import FluidVoice_Debug
import XCTest

// Regression tests for Retype Mode's zero-delay settings persistence.
// `slowTypeWarmupMs`/`slowTypeRampDelayMs`/`slowTypeSteadyDelayMs` used to read via
// `defaults.double(forKey:) > 0 ? value : default`, which can't distinguish a genuinely
// stored 0 from an unset key (both read back as 0.0 from UserDefaults) — so a user who
// dragged a slider to its minimum (0ms, which all three ranges explicitly allow) silently
// got the fallback default forever. See PR review on
// https://github.com/altic-dev/FluidVoice/pull/562.

@MainActor
final class RetypeModeSettingsTests: XCTestCase {
    private let warmupKey = "SlowTypeWarmupMs"
    private let rampDelayKey = "SlowTypeRampDelayMs"
    private let steadyDelayKey = "SlowTypeSteadyDelayMs"

    func testZeroWarmupDelayPersists() {
        self.withRestoredDefaults(keys: [self.warmupKey]) {
            SettingsStore.shared.slowTypeWarmupMs = 0
            XCTAssertEqual(SettingsStore.shared.slowTypeWarmupMs, 0)
        }
    }

    func testZeroRampDelayPersists() {
        self.withRestoredDefaults(keys: [self.rampDelayKey]) {
            SettingsStore.shared.slowTypeRampDelayMs = 0
            XCTAssertEqual(SettingsStore.shared.slowTypeRampDelayMs, 0)
        }
    }

    func testZeroSteadyDelayPersists() {
        self.withRestoredDefaults(keys: [self.steadyDelayKey]) {
            SettingsStore.shared.slowTypeSteadyDelayMs = 0
            XCTAssertEqual(SettingsStore.shared.slowTypeSteadyDelayMs, 0)
        }
    }

    func testUnsetWarmupDelayFallsBackToDocumentedDefault() {
        self.withRestoredDefaults(keys: [self.warmupKey]) {
            UserDefaults.standard.removeObject(forKey: self.warmupKey)
            XCTAssertEqual(SettingsStore.shared.slowTypeWarmupMs, 350)
        }
    }

    func testUnsetRampAndSteadyDelaysFallBackToDocumentedDefaults() {
        self.withRestoredDefaults(keys: [self.rampDelayKey, self.steadyDelayKey]) {
            UserDefaults.standard.removeObject(forKey: self.rampDelayKey)
            UserDefaults.standard.removeObject(forKey: self.steadyDelayKey)
            XCTAssertEqual(SettingsStore.shared.slowTypeRampDelayMs, 45)
            XCTAssertEqual(SettingsStore.shared.slowTypeSteadyDelayMs, 18)
        }
    }

    func testNonZeroDelaysRoundTrip() {
        self.withRestoredDefaults(keys: [self.warmupKey, self.rampDelayKey, self.steadyDelayKey]) {
            SettingsStore.shared.slowTypeWarmupMs = 500
            SettingsStore.shared.slowTypeRampDelayMs = 60
            SettingsStore.shared.slowTypeSteadyDelayMs = 25
            XCTAssertEqual(SettingsStore.shared.slowTypeWarmupMs, 500)
            XCTAssertEqual(SettingsStore.shared.slowTypeRampDelayMs, 60)
            XCTAssertEqual(SettingsStore.shared.slowTypeSteadyDelayMs, 25)
        }
    }

    private func withRestoredDefaults(keys: [String], run: () -> Void) {
        let defaults = UserDefaults.standard
        var snapshot: [String: Any] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) {
                snapshot[key] = value
            }
        }

        defer {
            for key in keys {
                if let previous = snapshot[key] {
                    defaults.set(previous, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        run()
    }
}
