@testable import FluidVoice_Debug
import XCTest

final class BuiltInMicCompatibilityCaptureTests: XCTestCase {
    func testCompatibilityCaptureIsLimitedToAppleSiliconBuiltInMicrophones() {
        XCTAssertTrue(BuiltInMicCompatibilityCapturePolicy.shouldUse(
            isAppleSilicon: true,
            isInternalMicrophone: true
        ))
        XCTAssertFalse(BuiltInMicCompatibilityCapturePolicy.shouldUse(
            isAppleSilicon: true,
            isInternalMicrophone: false
        ))
        XCTAssertFalse(BuiltInMicCompatibilityCapturePolicy.shouldUse(
            isAppleSilicon: false,
            isInternalMicrophone: true
        ))
    }

    func testCompatibilityCaptureHidesOnlyAVAudioEnginePrivateAggregates() {
        XCTAssertFalse(BuiltInMicCompatibilityCapturePolicy.shouldIncludeInputDevice(
            uid: "CADefaultDeviceAggregate-123",
            name: "CADefaultDeviceAggregate-123",
            isCompatibilityCapture: true
        ))
        XCTAssertFalse(BuiltInMicCompatibilityCapturePolicy.shouldIncludeInputDevice(
            uid: "private-aggregate",
            name: "CADefaultDeviceAggregate-123",
            isCompatibilityCapture: true
        ))
        XCTAssertTrue(BuiltInMicCompatibilityCapturePolicy.shouldIncludeInputDevice(
            uid: "BuiltInMicrophoneDevice",
            name: "MacBook Pro Microphone",
            isCompatibilityCapture: true
        ))
        XCTAssertTrue(BuiltInMicCompatibilityCapturePolicy.shouldIncludeInputDevice(
            uid: "CADefaultDeviceAggregate-123",
            name: "CADefaultDeviceAggregate-123",
            isCompatibilityCapture: false
        ))
    }
}
