@testable import FluidVoice_Debug
import XCTest

final class BuiltInMicrophoneCompatibilityCaptureTests: XCTestCase {
    func testCompatibilityCaptureIsLimitedToAppleSiliconBuiltInMicrophones() {
        XCTAssertTrue(BuiltInMicrophoneCompatibilityCapturePolicy.shouldUse(
            isAppleSilicon: true,
            isInternalMicrophone: true
        ))
        XCTAssertFalse(BuiltInMicrophoneCompatibilityCapturePolicy.shouldUse(
            isAppleSilicon: true,
            isInternalMicrophone: false
        ))
        XCTAssertFalse(BuiltInMicrophoneCompatibilityCapturePolicy.shouldUse(
            isAppleSilicon: false,
            isInternalMicrophone: true
        ))
    }

    func testCompatibilityCaptureHidesOnlyAVAudioEnginePrivateAggregates() {
        XCTAssertFalse(BuiltInMicrophoneCompatibilityCapturePolicy.shouldIncludeInputDevice(
            uid: "CADefaultDeviceAggregate-123",
            name: "CADefaultDeviceAggregate-123",
            isCompatibilityCapture: true
        ))
        XCTAssertFalse(BuiltInMicrophoneCompatibilityCapturePolicy.shouldIncludeInputDevice(
            uid: "private-aggregate",
            name: "CADefaultDeviceAggregate-123",
            isCompatibilityCapture: true
        ))
        XCTAssertTrue(BuiltInMicrophoneCompatibilityCapturePolicy.shouldIncludeInputDevice(
            uid: "BuiltInMicrophoneDevice",
            name: "MacBook Pro Microphone",
            isCompatibilityCapture: true
        ))
        XCTAssertTrue(BuiltInMicrophoneCompatibilityCapturePolicy.shouldIncludeInputDevice(
            uid: "CADefaultDeviceAggregate-123",
            name: "CADefaultDeviceAggregate-123",
            isCompatibilityCapture: false
        ))
    }
}
