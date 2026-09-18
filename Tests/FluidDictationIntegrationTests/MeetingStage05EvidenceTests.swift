#if DEBUG

@testable import FluidVoice_Debug
import CoreAudio
import Foundation
import XCTest

final class MeetingStage05EvidenceTests: XCTestCase {
    private func window(_ id: UInt32 = 1, bundle: String? = "com.google.Chrome",
                        pid: Int32 = 42, title: String? = MeetingStage05StimulusHandshake.readyTitle
    ) -> MeetingExternalReferenceTrialAWindowCandidate {
        .init(windowID: id, owningBundleIdentifier: bundle, owningProcessID: pid, title: title)
    }

    func testReadySelectionRequiresExactlyOneOwnedExactReadyWindow() {
        let ready = window()
        XCTAssertEqual(
            MeetingStage05StimulusHandshake.selectReadyWindow(
                from: [ready, window(2, title: "Unrelated")], targetBundleIdentifier: "com.google.Chrome"),
            ready)
        XCTAssertNil(MeetingStage05StimulusHandshake.selectReadyWindow(
            from: [ready, window(2)], targetBundleIdentifier: "com.google.Chrome"))
        XCTAssertNil(MeetingStage05StimulusHandshake.selectReadyWindow(
            from: [window(bundle: "com.apple.Safari")], targetBundleIdentifier: "com.google.Chrome"))
        XCTAssertNil(MeetingStage05StimulusHandshake.selectReadyWindow(
            from: [window(0)], targetBundleIdentifier: "com.google.Chrome"))
    }

    func testReadyToPlayingTransitionSucceedsForSameWindowOwnerAndPID() {
        let ready = window()
        let playing = window(title: "FluidVoice C2 Diagnostic Stimulus — PLAYING — 24s")
        let decision = MeetingStage05StimulusHandshake.decision(
            for: ready, current: [playing], targetBundleIdentifier: "com.google.Chrome",
            now: 0.5, deadline: 2)
        XCTAssertEqual(decision, .success(playing))
    }

    func testPlayingTransitionRejectsAmbiguityAndIdentityChanges() {
        let ready = window()
        let playing = window(title: "FluidVoice C2 Diagnostic Stimulus — PLAYING — 24s")
        XCTAssertEqual(MeetingStage05StimulusHandshake.decision(
            for: ready, current: [playing, window(2, title: "FluidVoice C2 Diagnostic Stimulus — PLAYING — 11s")],
            targetBundleIdentifier: "com.google.Chrome", now: 0.5, deadline: 2), .failure(.ambiguous))
        XCTAssertEqual(MeetingStage05StimulusHandshake.decision(
            for: ready, current: [window(bundle: "com.apple.Safari", title: "FluidVoice C2 Diagnostic Stimulus — PLAYING — 24s")],
            targetBundleIdentifier: "com.google.Chrome", now: 0.5, deadline: 2), .failure(.ownerChanged))
        XCTAssertEqual(MeetingStage05StimulusHandshake.decision(
            for: ready, current: [window(pid: 43, title: "FluidVoice C2 Diagnostic Stimulus — PLAYING — 24s")],
            targetBundleIdentifier: "com.google.Chrome", now: 0.5, deadline: 2), .failure(.processChanged))
        XCTAssertEqual(MeetingStage05StimulusHandshake.decision(
            for: ready, current: [window(2, title: "FluidVoice C2 Diagnostic Stimulus — PLAYING — 24s")],
            targetBundleIdentifier: "com.google.Chrome", now: 0.5, deadline: 2), .failure(.windowChanged))
    }

    func testPlayingTransitionRejectsTimeoutMalformedAndInsufficientRemainingTime() {
        let ready = window()
        XCTAssertEqual(MeetingStage05StimulusHandshake.decision(
            for: ready, current: [ready], targetBundleIdentifier: "com.google.Chrome",
            now: 2, deadline: 2), .failure(.timeout))
        XCTAssertEqual(MeetingStage05StimulusHandshake.decision(
            for: ready, current: [window(title: "FluidVoice C2 Diagnostic Stimulus — COMPLETE")],
            targetBundleIdentifier: "com.google.Chrome", now: 0.5, deadline: 2), .failure(.malformedState))
        XCTAssertEqual(MeetingStage05StimulusHandshake.decision(
            for: ready, current: [window(title: "FluidVoice C2 Diagnostic Stimulus — PLAYING — 21s")],
            targetBundleIdentifier: "com.google.Chrome", now: 0.5, deadline: 2), .failure(.remainingInsufficient))
    }

    func testHandshakeDecisionMayWaitBeforePlaybackWithoutStartingCapture() {
        let ready = window()
        XCTAssertEqual(MeetingStage05StimulusHandshake.decision(
            for: ready, current: [ready], targetBundleIdentifier: "com.google.Chrome",
            now: 7.99, deadline: 8), .waiting)
        XCTAssertEqual(MeetingStage05StimulusHandshake.decision(
            for: ready, current: [ready], targetBundleIdentifier: "com.google.Chrome",
            now: 8, deadline: 8), .failure(.timeout))
    }

    func testPlayingCountdownParserRequiresTheExactBoundedTitle() {
        XCTAssertEqual(MeetingStage05StimulusHandshake.playingRemainingSeconds(
            "FluidVoice C2 Diagnostic Stimulus — PLAYING — 24s"), 24)
        for malformed in [
            "FluidVoice C2 Diagnostic Stimulus — PLAYING — 25s",
            "FluidVoice C2 Diagnostic Stimulus — PLAYING — 24ss",
            "FluidVoice C2 Diagnostic Stimulus — PLAYING — 24.0s",
            "FluidVoice C2 Diagnostic Stimulus — PLAYING — -1s",
            "FluidVoice C2 Diagnostic Stimulus — PLAYINGISH — 12s",
            "FluidVoice C2 Diagnostic Stimulus — PLAYING — 24s - Google Chrome",
        ] {
            XCTAssertNil(MeetingStage05StimulusHandshake.playingRemainingSeconds(malformed))
        }
    }

    func testTimeoutDoesNotWaitForANoncooperativeOperation() async {
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await MeetingStage05EvidenceAutorun.withTimeout(seconds: 0.02) {
                // The timeout helper intentionally cannot cancel or await this operation.
                try? await Task.sleep(nanoseconds: 250_000_000)
                return true
            }
            XCTFail("expected timeout")
        } catch is MeetingStage05EvidenceAutorun.TimeoutError {
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.15)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testEmergencyCleanupRootIsNarrowlyScoped() {
        let exactRoot = URL(fileURLWithPath: "/private/tmp/fv-stage05-evidence.unit-test", isDirectory: true)
        XCTAssertTrue(MeetingStage05EvidenceAutorun.evidenceRootIsSafe(exactRoot))
        // The runtime retains the exact input URL; the explicit /tmp alias below remains rejected.
        for path in [
            "/private/tmp/fv-stage05-evidence.",
            "/private/tmp/stage05",
            "/tmp/fv-stage05-evidence.unit-test",
            "/Users/example/fv-stage05-evidence.unit-test",
        ] {
            XCTAssertFalse(MeetingStage05EvidenceAutorun.evidenceRootIsSafe(
                URL(fileURLWithPath: path, isDirectory: true)))
        }
    }

    func testNativeMonoFloat32FormatIsAcceptedWithoutConversion() {
        let asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        XCTAssertEqual(MeetingStage05NativePCMFormat.from(asbd)?.codec, "pcm_f32le")
        XCTAssertEqual(MeetingStage05NativePCMFormat.from(asbd)?.bytesPerFrame, 4)
    }

    func testNonfiniteFloat32PayloadIsRejected() {
        var data = Data()
        data.append(contentsOf: [0, 0, 128, 127]) // +infinity, little-endian IEEE-754
        XCTAssertFalse(MeetingStage05NativePCMFormat.containsOnlyFiniteFloat32(data))
        data = Data()
        var value = Float32(0.25).bitPattern.littleEndian
        Swift.withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        XCTAssertTrue(MeetingStage05NativePCMFormat.containsOnlyFiniteFloat32(data))
    }

    func testStereoAndIntegerFormatsFailClosed() {
        let stereo = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        let integer = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        XCTAssertNil(MeetingStage05NativePCMFormat.from(stereo))
        XCTAssertNil(MeetingStage05NativePCMFormat.from(integer))
    }

    func testConsentAndCaptureAreExplicitlyOptIn() {
        XCTAssertFalse(MeetingStage05EvidenceAutorun.requested(environment: [:]))
        XCTAssertFalse(MeetingStage05EvidenceAutorun.consentConfirmed(environment: [
            MeetingStage05EvidenceAutorun.consentEnvironmentKey: "1"
        ]))
        XCTAssertTrue(MeetingStage05EvidenceAutorun.consentConfirmed(environment: [
            MeetingStage05EvidenceAutorun.consentEnvironmentKey:
                MeetingStage05EvidenceAutorun.consentToken
        ]))
        let complete = [
            MeetingStage05EvidenceAutorun.environmentKey: "1",
            MeetingStage05EvidenceAutorun.autorunEnvironmentKey: "1",
            MeetingStage05EvidenceAutorun.targetBundleIDEnvironmentKey:
                MeetingStage05EvidenceAutorun.requiredTargetBundleID,
            MeetingStage05EvidenceAutorun.consentEnvironmentKey:
                MeetingStage05EvidenceAutorun.consentToken,
            MeetingStage05EvidenceAutorun.rootEnvironmentKey: "/private/tmp/stage05",
            MeetingStage05EvidenceAutorun.fixturePathEnvironmentKey: "/private/tmp/fixture.html",
        ]
        XCTAssertTrue(MeetingStage05EvidenceAutorun.requested(environment: complete))
        XCTAssertFalse(MeetingStage05EvidenceAutorun.requested(environment: complete.merging([
            MeetingStage05EvidenceAutorun.consentEnvironmentKey: "1"
        ]) { _, new in new }))
        let operatorMedia = complete.merging([
            MeetingStage05EvidenceAutorun.operatorMediaConsentEnvironmentKey:
                MeetingStage05EvidenceAutorun.operatorMediaConsentToken,
        ]) { _, new in new }
        XCTAssertTrue(MeetingStage05EvidenceAutorun.requested(environment: operatorMedia))
        XCTAssertTrue(MeetingStage05EvidenceAutorun.operatorMediaRequested(environment: operatorMedia))
        XCTAssertFalse(MeetingStage05EvidenceAutorun.requested(environment: operatorMedia.merging([
            MeetingStage05EvidenceAutorun.operatorMediaConsentEnvironmentKey: "1"
        ]) { _, new in new }))
        XCTAssertEqual(MeetingStage05EvidenceAutorun.remainingStimulusSeconds(
            "FluidVoice C2 Diagnostic Stimulus — PLAYING — 24s"), 24)
        XCTAssertNil(MeetingStage05EvidenceAutorun.remainingStimulusSeconds(
            "FluidVoice C2 Diagnostic Stimulus — PLAYING — 21s"))
        XCTAssertNil(MeetingStage05EvidenceAutorun.remainingStimulusSeconds(
            "FluidVoice C2 Diagnostic Stimulus — PLAYING"))
    }

    func testOperatorMediaWindowRequiresChromeOwnershipAndStableIdentity() {
        func eligible(
            id: CGWindowID = 1,
            bundle: String = "com.google.Chrome",
            pid: Int32 = 42,
            width: CGFloat = 1280,
            height: CGFloat = 720
        ) -> Bool {
            MeetingStage05EvidenceAutorun.operatorMediaWindowIsEligible(
                windowID: id, owningBundleIdentifier: bundle, owningProcessID: pid,
                frameWidth: width, frameHeight: height,
                targetBundleIdentifier: "com.google.Chrome")
        }
        XCTAssertTrue(eligible())
        XCTAssertFalse(eligible(id: 0))
        XCTAssertFalse(eligible(bundle: "com.apple.Safari"))
        XCTAssertFalse(eligible(pid: 0))
        XCTAssertFalse(eligible(width: 639))
        XCTAssertFalse(eligible(height: 359))
        XCTAssertFalse(eligible(width: .nan))
    }

    func testFinalizeDiagnosticsAreFixedPrivacySafeCategories() {
        let values = MeetingStage05FinalizeFailure.allCases.map(\.rawValue)
        XCTAssertEqual(values.count, 18)
        XCTAssertEqual(Set(values).count, values.count)
        XCTAssertTrue(values.allSatisfy {
            !$0.isEmpty && $0.unicodeScalars.allSatisfy {
                CharacterSet.letters.contains($0)
            }
        })
    }

    func testCaptureTargetLeavesHeadroomBelowTheFrameCeiling() {
        XCTAssertEqual(MeetingStage05EvidenceAutorun.captureSeconds, 14)
        XCTAssertGreaterThan(MeetingStage05EvidenceAutorun.captureSeconds, 10)
        XCTAssertEqual(MeetingStage05EvidenceAutorun.operatorResponseSeconds, 30)
        XCTAssertGreaterThanOrEqual(
            MeetingStage05EvidenceAutorun.hardWatchdogSeconds,
            MeetingStage05EvidenceAutorun.operatorResponseSeconds
                + MeetingStage05EvidenceAutorun.captureSeconds + 4
        )
    }
}

#endif
