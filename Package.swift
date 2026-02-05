// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FluidVoice",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/mxcl/AppUpdater.git", from: "1.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.7.9"),
        .package(url: "https://github.com/mxcl/PromiseKit", from: "6.0.0"),
        .package(url: "https://github.com/MrKai77/DynamicNotchKit", from: "1.0.0"),
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", branch: "master"),
        .package(url: "https://github.com/PostHog/posthog-ios.git", from: "3.0.0"),
        // Voxtral MLX for Apple Silicon speech-to-text
        .package(url: "https://github.com/VincentGourbin/mlx-voxtral-swift", branch: "main"),
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
                .product(name: "VoxtralCore", package: "mlx-voxtral-swift"),
            ]
        ),
    ]
)
