@testable import FluidVoice_Debug
import Foundation
import XCTest

final class SpeechModelIdleUnloadTests: XCTestCase {
    private let idleUnloadMinutesKey = "SpeechModelIdleUnloadMinutes"

    func testCanUnloadOnlyWhenServiceIsFullyIdle() {
        XCTAssertTrue(ASRService.canUnloadIdleSpeechModel(
            isAsrReady: true,
            isRunning: false,
            isStarting: false,
            hasActiveModelPreparation: false,
            hasActiveModelDownload: false,
            activeSpeechModelUseCount: 0
        ))
    }

    func testCannotUnloadWithoutLoadedModel() {
        XCTAssertFalse(ASRService.canUnloadIdleSpeechModel(
            isAsrReady: false,
            isRunning: false,
            isStarting: false,
            hasActiveModelPreparation: false,
            hasActiveModelDownload: false,
            activeSpeechModelUseCount: 0
        ))
    }

    func testCannotUnloadWhileRecordingOrStarting() {
        XCTAssertFalse(ASRService.canUnloadIdleSpeechModel(
            isAsrReady: true,
            isRunning: true,
            isStarting: false,
            hasActiveModelPreparation: false,
            hasActiveModelDownload: false,
            activeSpeechModelUseCount: 0
        ))
        XCTAssertFalse(ASRService.canUnloadIdleSpeechModel(
            isAsrReady: true,
            isRunning: false,
            isStarting: true,
            hasActiveModelPreparation: false,
            hasActiveModelDownload: false,
            activeSpeechModelUseCount: 0
        ))
    }

    func testCannotUnloadDuringModelPreparationOrDownload() {
        XCTAssertFalse(ASRService.canUnloadIdleSpeechModel(
            isAsrReady: true,
            isRunning: false,
            isStarting: false,
            hasActiveModelPreparation: true,
            hasActiveModelDownload: false,
            activeSpeechModelUseCount: 0
        ))
        XCTAssertFalse(ASRService.canUnloadIdleSpeechModel(
            isAsrReady: true,
            isRunning: false,
            isStarting: false,
            hasActiveModelPreparation: false,
            hasActiveModelDownload: true,
            activeSpeechModelUseCount: 0
        ))
    }

    func testCannotUnloadWhileTranscriptionWorkHoldsTheModel() {
        // Final transcription in stop(), Local API requests, and long file
        // transcription jobs all hold a use token that must block unload.
        XCTAssertFalse(ASRService.canUnloadIdleSpeechModel(
            isAsrReady: true,
            isRunning: false,
            isStarting: false,
            hasActiveModelPreparation: false,
            hasActiveModelDownload: false,
            activeSpeechModelUseCount: 1
        ))
    }

    func testOnlyAppleModelsHoldNoInProcessMemory() {
        for model in SettingsStore.SpeechModel.allCases {
            let isAppleManaged = model == .appleSpeech || model == .appleSpeechAnalyzer
            XCTAssertEqual(
                model.holdsModelInProcessMemory,
                !isAppleManaged,
                "Unexpected in-process memory classification for \(model.rawValue)"
            )
        }
    }

    func testIdleUnloadMinutesDefaultAndClamping() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: self.idleUnloadMinutesKey)
        defer {
            if let original {
                defaults.set(original, forKey: self.idleUnloadMinutesKey)
            } else {
                defaults.removeObject(forKey: self.idleUnloadMinutesKey)
            }
        }

        defaults.removeObject(forKey: self.idleUnloadMinutesKey)
        XCTAssertEqual(
            SettingsStore.shared.speechModelIdleUnloadMinutes,
            SettingsStore.defaultSpeechModelIdleUnloadMinutes
        )

        SettingsStore.shared.speechModelIdleUnloadMinutes = 15
        XCTAssertEqual(SettingsStore.shared.speechModelIdleUnloadMinutes, 15)

        SettingsStore.shared.speechModelIdleUnloadMinutes = 0
        XCTAssertEqual(SettingsStore.shared.speechModelIdleUnloadMinutes, 0)

        SettingsStore.shared.speechModelIdleUnloadMinutes = -5
        XCTAssertEqual(SettingsStore.shared.speechModelIdleUnloadMinutes, 0)
    }
}
