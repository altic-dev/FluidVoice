// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FluidVoice",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(url: "https://github.com/mxcl/AppUpdater.git", from: "1.0.0"),
        .package(url: "https://github.com/altic-dev/FluidAudio.git", branch: "B/cohere-coreml-asr"),
        .package(url: "https://github.com/mxcl/PromiseKit", from: "6.0.0"),
        .package(url: "https://github.com/altic-dev/DynamicNotchKit.git", branch: "main"),
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", branch: "master"),
        .package(url: "https://github.com/PostHog/posthog-ios.git", from: "3.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "FluidVoice",
            dependencies: [
                "AppUpdater",
                "FluidAudio",
                "PromiseKit",
                "DynamicNotchKit",
                "SwiftWhisper",
                .product(name: "PostHog", package: "posthog-ios"),
            ]
        ),
    ]
)
