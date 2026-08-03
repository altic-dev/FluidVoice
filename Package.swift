// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FluidVoice",
    platforms: [
        .macOS("14.0"),
    ],
    dependencies: [
        .package(url: "https://github.com/mxcl/AppUpdater.git", from: "1.0.0"),
        .package(url: "https://github.com/altic-dev/FluidAudio.git", branch: "B/cohere-coreml-asr"),
        .package(url: "https://github.com/mxcl/PromiseKit", from: "6.0.0"),
        .package(url: "https://github.com/altic-dev/DynamicNotchKit.git", branch: "main"),
        .package(url: "https://github.com/altic-dev/transcribe-cpp-swift.git", exact: "0.1.2"),
        .package(url: "https://github.com/PostHog/posthog-ios.git", from: "3.0.0"),
        .package(url: "https://github.com/ejbills/mediaremote-adapter", branch: "master"),
    ],
    targets: [
        .target(
            name: "CoreAudioCaptureSupport",
            path: "Sources/CoreAudioCaptureSupport",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
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
                .product(name: "TranscribeCpp", package: "transcribe-cpp-swift"),
                .product(name: "PostHog", package: "posthog-ios"),
                .product(name: "MediaRemoteAdapter", package: "mediaremote-adapter"),
            ],
            path: "Sources/Fluid",
            exclude: [
                "CoreAudioCaptureSupportBridge.c",
                "CoreAudioCaptureSupportBridge.h",
                "Fluid-Bridging-Header.h"
            ]
        ),
    ]
)
