@testable import FluidVoice_Debug
import XCTest

final class BuiltInMicCompatibilityCaptureTests: XCTestCase {
    func testCompatibilityCaptureIsLimitedToTheDefaultAppleSiliconBuiltInMicrophone() {
        XCTAssertTrue(BuiltInMicCompatibilityCapturePolicy.shouldUse(
            isAppleSilicon: true,
            isInternalMicrophone: true,
            selectedInputUID: "BuiltInMicrophoneDevice",
            defaultInputUID: "BuiltInMicrophoneDevice"
        ))
        XCTAssertFalse(BuiltInMicCompatibilityCapturePolicy.shouldUse(
            isAppleSilicon: true,
            isInternalMicrophone: true,
            selectedInputUID: "BuiltInMicrophoneDevice",
            defaultInputUID: "ExternalMicrophoneDevice"
        ))
        XCTAssertFalse(BuiltInMicCompatibilityCapturePolicy.shouldUse(
            isAppleSilicon: true,
            isInternalMicrophone: false,
            selectedInputUID: "ExternalMicrophoneDevice",
            defaultInputUID: "ExternalMicrophoneDevice"
        ))
        XCTAssertFalse(BuiltInMicCompatibilityCapturePolicy.shouldUse(
            isAppleSilicon: false,
            isInternalMicrophone: true,
            selectedInputUID: "BuiltInMicrophoneDevice",
            defaultInputUID: "BuiltInMicrophoneDevice"
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
