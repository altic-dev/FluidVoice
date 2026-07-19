// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FluidVoice",
    platforms: [
        .macOS("15.0"),
    ],
    dependencies: [
        .package(url: "https://github.com/mxcl/AppUpdater.git", from: "1.0.0"),
        .package(url: "https://github.com/altic-dev/FluidAudio.git", branch: "B/cohere-coreml-asr"),
        .package(url: "https://github.com/mxcl/PromiseKit", from: "6.0.0"),
        .package(url: "https://github.com/altic-dev/DynamicNotchKit.git", branch: "main"),
        .package(url: "https://github.com/altic-dev/transcribe-cpp-swift.git", exact: "0.1.2"),
        .package(url: "https://github.com/PostHog/posthog-ios.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "CoreAudioCaptureSupport",
            path: "Sources/CoreAudioCaptureSupport",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
            ]
        ),
        // Exposes Picovoice's Porcupine wake-word C API (vendored header + prebuilt
        // libpv_porcupine.dylib, arm64 macOS - no official SPM/macOS Swift package exists
        // upstream, only their CocoaPods iOS binding) as the CPorcupine module.
        .target(
            name: "PorcupineSupport",
            path: "Sources/PorcupineSupport",
            linkerSettings: [
                .unsafeFlags(["-LSources/PorcupineSupport/lib"]),
            ]
        ),
        .executableTarget(
            name: "FluidVoice",
            dependencies: [
                "AppUpdater",
                "CoreAudioCaptureSupport",
                "FluidAudio",
                "PromiseKit",
                "DynamicNotchKit",
                "PorcupineSupport",
                .product(name: "TranscribeCpp", package: "transcribe-cpp-swift"),
                .product(name: "PostHog", package: "posthog-ios"),
            ],
            resources: [
                .copy("Resources/porcupine_params.pv"),
            ]
        ),
    ]
)
