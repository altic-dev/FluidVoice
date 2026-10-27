import AppKit
import AVFoundation
@testable import FluidVoice_Debug
import XCTest

final class HoldToMuteTests: XCTestCase {
    func testTimelineRejectsClosedIntervalsAndKeepsSpeechOnBothSides() {
        var timeline = DictationMuteTimeline()
        timeline.setMuted(true, at: 1200)
        timeline.setMuted(false, at: 1600)
        XCTAssertEqual(timeline.audibleRanges(in: 0..<1000, packetHostTime: 1000, sampleRate: 1000, hostTicksPerSecond: 1000), [0..<200, 600..<1000])
        // A whole delayed packet acquired while muted must still be excluded.
        XCTAssertEqual(timeline.audibleRanges(in: 0..<200, packetHostTime: 1300, sampleRate: 1000, hostTicksPerSecond: 1000), [])
    }

    func testTimelineHandlesMultipleCyclesAndPartialFramesConservatively() {
        var timeline = DictationMuteTimeline()
        timeline.setMuted(true, at: 1025)
        timeline.setMuted(false, at: 1075)
        timeline.setMuted(true, at: 1150)
        timeline.setMuted(false, at: 1175)
        XCTAssertEqual(timeline.audibleRanges(in: 0..<30, packetHostTime: 1000, sampleRate: 100, hostTicksPerSecond: 1000), [0..<2, 8..<15, 18..<30])
        XCTAssertEqual(timeline.audibleRanges(in: 10..<20, packetHostTime: 1000, sampleRate: 100, hostTicksPerSecond: 1000), [10..<15, 18..<20])
    }

    func testUntimestampedAudioCannotLeakAfterMute() {
        var timeline = DictationMuteTimeline()
        XCTAssertEqual(timeline.audibleRanges(in: 0..<10, packetHostTime: 0, sampleRate: 100, hostTicksPerSecond: 1000), [0..<10])
        timeline.setMuted(true, at: 1000)
        timeline.setMuted(false, at: 2000)
        XCTAssertEqual(timeline.audibleRanges(in: 0..<10, packetHostTime: 0, sampleRate: 100, hostTicksPerSecond: 1000), [])
    }

    func testPipelineExcludesBackgroundSpeechAcrossPacketBoundariesAndSampleRates() {
        for rate in [16_000.0, 44_100.0, 48_000.0] {
            let buffer = ThreadSafeAudioBuffer()
            let pipeline = self.pipeline(buffer: buffer)
            pipeline.setRecordingEnabled(true, sessionID: 1, startHostTime: self.hostTime(1))
            pipeline.setDictationMuted(true, at: self.hostTime(1.1))
            pipeline.setDictationMuted(false, at: self.hostTime(1.3))
            // All packets are delivered after release. Muted samples are distinct and loud.
            let frameCount = Int(rate * 0.4)
            let samples: [Float] = (0..<frameCount).map { frame in
                let time = Double(frame) / rate
                return time < 0.1 ? 0.1 : (time < 0.3 ? 0.9 : 0.2)
            }
            var offset = 0
            for length in [83, 517, 4096, frameCount] {
                let end = min(frameCount, offset + length)
                self.feed(pipeline, samples: Array(samples[offset..<end]), rate: rate, time: 1 + Double(offset) / rate, sampleTime: Int64(offset))
                offset = end
                if offset == frameCount {
                    break
                }
            }
            let captured = buffer.getAll()
            XCTAssertTrue(captured.contains(0.1), "Leading speech missing at \(rate)")
            XCTAssertTrue(captured.contains(0.2), "Resumed speech missing at \(rate)")
            XCTAssertTrue(captured.allSatisfy { $0 <= 0.201 }, "Muted audio leaked through resampling at \(rate)")
            XCTAssertEqual(captured.count, 4800, accuracy: 5, "Expected 200 ms of speech plus a 100 ms boundary")
        }
    }

    func testLongMuteDoesNotAccumulateAudioAndStillSignalsCaptureReadiness() {
        let buffer = ThreadSafeAudioBuffer()
        let ready = expectation(description: "Capture is ready even if initially muted")
        let pipeline = AudioCapturePipeline(audioBuffer: buffer, onFirstAudio: { _, _, _, _, _, _, _ in ready.fulfill() }, onLevel: { _ in }, onCaptureHealth: { _, _, _, _, _, _ in })
        pipeline.setRecordingEnabled(true, sessionID: 1, startHostTime: self.hostTime(1))
        pipeline.setDictationMuted(true, at: self.hostTime(1))
        for second in 1...60 {
            self.feed(pipeline, samples: Array(repeating: 0.9, count: 16_000), time: Double(second))
        }
        XCTAssertEqual(buffer.count, 0)
        pipeline.setDictationMuted(false, at: self.hostTime(61))
        self.feed(pipeline, samples: Array(repeating: 0.2, count: 1600), time: 61)
        XCTAssertEqual(buffer.getAll(), Array(repeating: Float(0.2), count: 1600))
        wait(for: [ready], timeout: 1)
    }

    func testStopWhileMutedRejectsTailAndNewSessionResets() {
        let buffer = ThreadSafeAudioBuffer()
        let pipeline = self.pipeline(buffer: buffer)
        pipeline.setRecordingEnabled(true, sessionID: 1, startHostTime: self.hostTime(1))
        self.feed(pipeline, samples: Array(repeating: 0.1, count: 1600), time: 1)
        pipeline.setDictationMuted(true, at: self.hostTime(1.1))
        pipeline.markRecordingEnd(atHostTime: self.hostTime(1.2))
        self.feed(pipeline, samples: Array(repeating: 0.9, count: 3200), time: 1.1)
        pipeline.finishRecording()
        XCTAssertEqual(buffer.getAll(), Array(repeating: Float(0.1), count: 1600))
        buffer.clear()
        pipeline.resetDictationMute()
        pipeline.setRecordingEnabled(true, sessionID: 2, startHostTime: self.hostTime(2))
        self.feed(pipeline, samples: Array(repeating: 0.2, count: 1600), time: 2)
        XCTAssertEqual(buffer.getAll(), Array(repeating: Float(0.2), count: 1600))
    }

    func testAudioRouteRetryRetainsMute() {
        let buffer = ThreadSafeAudioBuffer()
        let pipeline = self.pipeline(buffer: buffer)
        pipeline.setRecordingEnabled(true, sessionID: 1, attemptID: 1, startHostTime: self.hostTime(1))
        pipeline.setDictationMuted(true, at: self.hostTime(1))
        pipeline.setRecordingEnabled(false)
        pipeline.setRecordingEnabled(true, sessionID: 1, attemptID: 2, startHostTime: self.hostTime(2))
        self.feed(pipeline, samples: Array(repeating: 0.9, count: 1600), time: 2)
        XCTAssertEqual(buffer.count, 0)
    }

    func testSpeechFixtureIsPreservedAndMutedFixtureIsExcluded() throws {
        let speech = try AudioFixtureLoader.load16kMonoFloatSamples(named: "dictation_fixture", ext: "wav")
        let buffer = ThreadSafeAudioBuffer()
        let pipeline = self.pipeline(buffer: buffer)
        let duration = Double(speech.count) / 16_000
        pipeline.setRecordingEnabled(true, sessionID: 1, startHostTime: self.hostTime(1))
        self.feed(pipeline, samples: speech, time: 1)
        pipeline.setDictationMuted(true, at: self.hostTime(1 + duration))
        pipeline.setDictationMuted(false, at: self.hostTime(1 + duration * 2))
        // Even speech delivered after release is discarded by acquisition time.
        self.feed(pipeline, samples: speech, time: 1 + duration)
        self.feed(pipeline, samples: speech, time: 1 + duration * 2)
        XCTAssertEqual(buffer.getAll(), speech + Array(repeating: Float(0), count: 1600) + speech)
    }

    func testDisabledPipelinePreservesExactAudio() {
        let buffer = ThreadSafeAudioBuffer()
        let pipeline = self.pipeline(buffer: buffer)
        let samples = (0..<1600).map { Float($0) / 1600 }
        pipeline.setRecordingEnabled(true, sessionID: 1, startHostTime: self.hostTime(1))
        self.feed(pipeline, samples: samples, time: 1)
        XCTAssertEqual(buffer.getAll(), samples)
    }

    @MainActor
    func testSpaceMutesOnlyActiveDictationAndConsumesRepeatsAndRelease() throws {
        try self.withMuteSetting {
            let asr = ASRService()
            let manager = self.manager(asr: asr)
            XCTAssertNotNil(try self.send(manager, type: .keyDown))
            XCTAssertFalse(asr.isDictationMuted)
            _ = try self.send(manager, type: .keyUp)
            asr.isRunning = true
            XCTAssertNil(try self.send(manager, type: .keyDown))
            XCTAssertTrue(asr.isDictationMuted)
            XCTAssertTrue(NotchContentState.shared.isDictationMuted)
            XCTAssertNil(try self.send(manager, type: .keyDown, isRepeat: true))
            XCTAssertNil(try self.send(manager, type: .keyUp, modifiers: .maskShift))
            XCTAssertFalse(asr.isDictationMuted)
            XCTAssertFalse(NotchContentState.shared.isDictationMuted)
            asr.isRunning = false
        }
    }

    @MainActor
    func testExistingSpaceChordsAndOtherModesPassThrough() throws {
        try self.withMuteSetting {
            let asr = ASRService()
            asr.isRunning = true
            defer { asr.isRunning = false }
            let manager = self.manager(asr: asr)
            for modifier: CGEventFlags in [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn] {
                XCTAssertNotNil(try self.send(manager, type: .keyDown, modifiers: modifier))
                XCTAssertFalse(asr.isDictationMuted)
                XCTAssertNotNil(try self.send(manager, type: .keyUp, modifiers: modifier))
            }
            let otherMode = self.manager(asr: asr, isDictation: false)
            XCTAssertNotNil(try self.send(otherMode, type: .keyDown))
            XCTAssertFalse(asr.isDictationMuted)
        }
    }

    @MainActor
    func testStopDoesNotLeakHeldSpaceOrMuteNextSession() throws {
        try self.withMuteSetting {
            let asr = ASRService()
            let manager = self.manager(asr: asr)
            asr.isRunning = true
            _ = try self.send(manager, type: .keyDown)
            asr.isRunning = false
            XCTAssertFalse(asr.isDictationMuted)
            XCTAssertNil(try self.send(manager, type: .keyDown, isRepeat: true))
            asr.isRunning = true
            XCTAssertNil(try self.send(manager, type: .keyDown, isRepeat: true))
            XCTAssertFalse(asr.isDictationMuted)
            XCTAssertNil(try self.send(manager, type: .keyUp))
            asr.isRunning = false
        }
    }

    @MainActor
    func testDisablingSettingUnmutesImmediatelyAndPreservesKeyOwnership() throws {
        try self.withMuteSetting {
            let asr = ASRService()
            let manager = self.manager(asr: asr)
            asr.isRunning = true
            _ = try self.send(manager, type: .keyDown)
            SettingsStore.shared.holdSpaceToMute = false
            XCTAssertFalse(asr.isDictationMuted)
            XCTAssertNil(try self.send(manager, type: .keyDown, isRepeat: true))
            XCTAssertNil(try self.send(manager, type: .keyUp))
            XCTAssertNotNil(try self.send(manager, type: .keyDown))
            asr.isRunning = false
        }
    }

    @MainActor
    func testMissedReleaseRecoversWithoutUnmutingHeldKey() throws {
        try self.withMuteSetting {
            let asr = ASRService()
            let manager = self.manager(asr: asr)
            asr.isRunning = true
            _ = try self.send(manager, type: .keyDown)
            manager.reconcileHoldToMute(isPhysicallyDown: true)
            XCTAssertTrue(asr.isDictationMuted)
            manager.reconcileHoldToMute(isPhysicallyDown: false)
            XCTAssertFalse(asr.isDictationMuted)
            XCTAssertNotNil(try self.send(manager, type: .keyUp))
            asr.isRunning = false
        }
    }

    @MainActor
    func testConfiguredSpaceShortcutHasPriorityOverMute() throws {
        try self.withMuteSetting {
            let asr = ASRService()
            asr.isRunning = true
            let manager = self.manager(asr: asr)
            manager.updatePrimaryShortcuts([HotkeyShortcut(keyCode: 49, modifierFlags: [])])
            _ = try self.send(manager, type: .keyDown)
            XCTAssertFalse(asr.isDictationMuted)
            asr.isRunning = false
        }
    }

    @MainActor
    func testNewSettingDefaultsOffAndIsSearchable() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "HoldSpaceToMute")
        defer {
            if let previous {
                defaults.set(previous, forKey: "HoldSpaceToMute")
            } else {
                defaults.removeObject(forKey: "HoldSpaceToMute")
            }
        }
        defaults.removeObject(forKey: "HoldSpaceToMute")
        XCTAssertFalse(SettingsStore.shared.holdSpaceToMute)
        XCTAssertEqual(SettingsSearchTarget.holdSpaceToMute.section, .dictation)
    }

    @MainActor
    func testQuickTapMutesImmediatelyThenTypesExactlyOneSpaceOnRelease() throws {
        try self.withMuteSetting {
            let asr = ASRService()
            asr.isRunning = true
            defer { asr.isRunning = false }
            let manager = self.manager(asr: asr)
            let context = HoldToMuteSpaceTap.Context(pid: 100, leftClicks: 0, rightClicks: 0, otherClicks: 0)
            var captureCount = 0
            manager.holdToMuteSpaceTap.contextProvider = {
                if captureCount == 0 {
                    XCTAssertTrue(asr.isDictationMuted, "Mute must precede context capture")
                }
                captureCount += 1
                return context
            }
            var posted: [CGEvent] = []
            manager.holdToMuteSpaceTap.postEvent = { _, event in
                XCTAssertFalse(asr.isDictationMuted, "Resume must precede replay")
                posted.append(event)
            }
            XCTAssertNil(try self.send(manager, type: .keyDown, at: 1_000_000_000))
            XCTAssertTrue(asr.isDictationMuted)
            XCTAssertTrue(posted.isEmpty)
            XCTAssertNil(try self.send(manager, type: .keyUp, at: 1_100_000_000))
            XCTAssertFalse(asr.isDictationMuted)
            XCTAssertEqual(posted.map(\.type), [.keyDown, .keyUp])
            for event in posted {
                XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 49)
                XCTAssertEqual(event.getIntegerValueField(.keyboardEventAutorepeat), 0)
                XCTAssertEqual(event.timestamp, 1_100_000_000)
                var length = 0
                var character: UniChar = 0
                event.keyboardGetUnicodeString(maxStringLength: 1, actualStringLength: &length, unicodeString: &character)
                XCTAssertEqual(length, 1)
                XCTAssertEqual(character, 0x20)
            }
            _ = try self.send(manager, type: .keyUp, at: 1_110_000_000)
            XCTAssertEqual(posted.count, 2)
        }
    }

    @MainActor
    func testLongHoldAndAutorepeatNeverTypeSpaces() throws {
        try self.withMuteSetting {
            let asr = ASRService()
            asr.isRunning = true
            defer { asr.isRunning = false }
            let manager = self.manager(asr: asr)
            manager.holdToMuteSpaceTap.postEvent = { _, _ in XCTFail("A hold must not type") }
            for repeatKey in [false, true] {
                _ = try self.send(manager, type: .keyDown, at: 1_000_000_000)
                if repeatKey {
                    _ = try self.send(manager, type: .keyDown, isRepeat: true, at: 1_050_000_000)
                }
                XCTAssertTrue(asr.isDictationMuted)
                let release: UInt64 = repeatKey ? 1_100_000_000 : 1_250_000_001
                _ = try self.send(manager, type: .keyUp, at: release)
                XCTAssertFalse(asr.isDictationMuted)
            }
        }
    }

    @MainActor
    func testFastTypingFlushesSpaceBeforeNextLetterAndIgnoresPreviousLetterRelease() throws {
        try self.withMuteSetting {
            let asr = ASRService()
            asr.isRunning = true
            defer { asr.isRunning = false }
            let manager = self.manager(asr: asr)
            var posted: [CGEventType] = []
            manager.holdToMuteSpaceTap.postEvent = { _, event in posted.append(event.type) }
            _ = try self.send(manager, type: .keyDown, at: 1_000_000_000)
            XCTAssertNotNil(try self.send(manager, type: .keyUp, at: 1_020_000_000, keyCode: 0, text: "a"))
            XCTAssertTrue(posted.isEmpty)
            XCTAssertNotNil(try self.send(manager, type: .keyDown, at: 1_050_000_000, keyCode: 11, text: "b"))
            XCTAssertEqual(posted, [.keyDown, .keyUp], "Space must be posted before the next letter returns from the tap")
            XCTAssertTrue(asr.isDictationMuted, "Typing does not release the physical mute hold")
            _ = try self.send(manager, type: .keyDown, isRepeat: true, at: 1_060_000_000)
            _ = try self.send(manager, type: .keyUp, at: 1_090_000_000)
            XCTAssertEqual(posted.count, 2)
            XCTAssertFalse(asr.isDictationMuted)
        }
    }

    @MainActor
    func testAppSwitchOrMouseClickCancelsPendingSpace() throws {
        try self.withMuteSetting {
            let asr = ASRService()
            asr.isRunning = true
            defer { asr.isRunning = false }
            let manager = self.manager(asr: asr)
            let original = HoldToMuteSpaceTap.Context(pid: 100, leftClicks: 1, rightClicks: 2, otherClicks: 3)
            let changed = [
                HoldToMuteSpaceTap.Context(pid: 101, leftClicks: 1, rightClicks: 2, otherClicks: 3),
                HoldToMuteSpaceTap.Context(pid: 100, leftClicks: 2, rightClicks: 2, otherClicks: 3),
                HoldToMuteSpaceTap.Context(pid: 100, leftClicks: 1, rightClicks: 3, otherClicks: 3),
                HoldToMuteSpaceTap.Context(pid: 100, leftClicks: 1, rightClicks: 2, otherClicks: 4),
                nil,
            ]
            var context: HoldToMuteSpaceTap.Context? = original
            manager.holdToMuteSpaceTap.contextProvider = { context }
            manager.holdToMuteSpaceTap.postEvent = { _, _ in XCTFail("Destination changed") }
            for destination in changed {
                context = original
                _ = try self.send(manager, type: .keyDown, at: 1_000_000_000)
                context = destination
                _ = try self.send(manager, type: .keyUp, at: 1_100_000_000)
                XCTAssertFalse(asr.isDictationMuted)
            }
        }
    }

    @MainActor
    func testNavigationAndModifierChangesCancelTapWithoutEndingMute() throws {
        try self.withMuteSetting {
            let asr = ASRService()
            asr.isRunning = true
            defer { asr.isRunning = false }
            let manager = self.manager(asr: asr)
            manager.holdToMuteSpaceTap.postEvent = { _, _ in XCTFail("Interrupted gesture must not type") }
            for keyCode: CGKeyCode in [48, 51, 123] {
                _ = try self.send(manager, type: .keyDown, at: 1_000_000_000)
                _ = try self.send(manager, type: .keyDown, at: 1_050_000_000, keyCode: keyCode, text: "\t")
                XCTAssertTrue(asr.isDictationMuted)
                _ = try self.send(manager, type: .keyUp, at: 1_100_000_000)
            }
            _ = try self.send(manager, type: .keyDown, at: 2_000_000_000)
            _ = try self.send(manager, type: .flagsChanged, modifiers: .maskShift, at: 2_050_000_000, keyCode: 56, text: "")
            XCTAssertTrue(asr.isDictationMuted)
            _ = try self.send(manager, type: .keyUp, at: 2_100_000_000)
            XCTAssertFalse(asr.isDictationMuted)
        }
    }

    @MainActor
    func testStoppedSessionDisabledSettingAndLostReleaseCannotReplaySpace() throws {
        try self.withMuteSetting {
            let asr = ASRService()
            let manager = self.manager(asr: asr)
            manager.holdToMuteSpaceTap.postEvent = { _, _ in XCTFail("Cancelled tap must not type") }
            for reason in 0..<4 {
                SettingsStore.shared.holdSpaceToMute = true
                asr.isRunning = true
                _ = try self.send(manager, type: .keyDown, at: 1_000_000_000)
                switch reason {
                case 0: asr.isRunning = false
                case 1:
                    asr.isRunning = false
                    asr.isRunning = true
                case 2: SettingsStore.shared.holdSpaceToMute = false
                default: manager.reconcileHoldToMute(isPhysicallyDown: false)
                }
                _ = try self.send(manager, type: .keyUp, at: 1_100_000_000)
                XCTAssertFalse(asr.isDictationMuted)
                asr.isRunning = false
            }
        }
    }

    @MainActor
    func testRepeatedQuickTapsEachTypeOneSpace() throws {
        try self.withMuteSetting {
            let asr = ASRService()
            asr.isRunning = true
            defer { asr.isRunning = false }
            let manager = self.manager(asr: asr)
            var count = 0
            manager.holdToMuteSpaceTap.postEvent = { _, _ in count += 1 }
            for index in 0..<10 {
                let time = UInt64(index) * 200_000_000 + 1_000_000_000
                _ = try self.send(manager, type: .keyDown, at: time)
                _ = try self.send(manager, type: .keyUp, at: time + 100_000_000)
            }
            XCTAssertEqual(count, 20)
        }
    }

    private func hostTime(_ seconds: Double) -> UInt64 {
        AVAudioTime.hostTime(forSeconds: seconds)
    }

    private func pipeline(buffer: ThreadSafeAudioBuffer) -> AudioCapturePipeline {
        AudioCapturePipeline(audioBuffer: buffer, onFirstAudio: { _, _, _, _, _, _, _ in }, onLevel: { _ in }, onCaptureHealth: { _, _, _, _, _, _ in })
    }

    private func feed(_ pipeline: AudioCapturePipeline, samples: [Float], rate: Double = 16_000, time: Double, sampleTime: Int64 = -1) {
        samples.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            pipeline.handle(samples: base, frameCount: samples.count, sampleRate: rate, inputHostTime: self.hostTime(time), inputSampleTime: sampleTime)
        }
    }

    @MainActor
    private func withMuteSetting(_ body: () throws -> Void) rethrows {
        let previous = SettingsStore.shared.holdSpaceToMute
        defer { SettingsStore.shared.holdSpaceToMute = previous }
        SettingsStore.shared.holdSpaceToMute = true
        try body()
    }

    @MainActor
    private func manager(asr: ASRService, isDictation: Bool = true) -> GlobalHotkeyManager {
        let manager = GlobalHotkeyManager(
            asrService: asr,
            primaryShortcuts: [HotkeyShortcut(keyCode: 61, modifierFlags: [])],
            promptModeShortcut: HotkeyShortcut(keyCode: 60, modifierFlags: []),
            commandModeShortcut: nil,
            rewriteModeShortcut: HotkeyShortcut(keyCode: 15, modifierFlags: [.option]),
            promptModeShortcutEnabled: false,
            commandModeShortcutEnabled: false,
            rewriteModeShortcutEnabled: false,
            startRecordingCallback: {},
            stopAndProcessCallback: { _ in },
            isDictateRecordingProvider: { isDictation }
        )
        manager.setHotkeyMode(.toggle)
        manager.holdToMuteChecksPhysicalKeyState = false
        manager.holdToMuteSpaceTap.contextProvider = {
            HoldToMuteSpaceTap.Context(pid: 100, leftClicks: 0, rightClicks: 0, otherClicks: 0)
        }
        return manager
    }

    @MainActor
    private func send(_ manager: GlobalHotkeyManager, type: CGEventType, modifiers: CGEventFlags = [], isRepeat: Bool = false, at timestamp: UInt64? = nil, keyCode: CGKeyCode = 49, text: String = " ") throws -> CGEvent? {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: type == .keyDown))
        if let timestamp {
            event.timestamp = timestamp
        }
        let characters = Array(text.utf16)
        event.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
        event.flags = modifiers
        event.setIntegerValueField(.keyboardEventAutorepeat, value: isRepeat ? 1 : 0)
        return withExtendedLifetime(event) {
            manager.handleKeyEvent(type: type, event: event)?.takeUnretainedValue()
        }
    }
}
