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
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.7.4"),
        .package(url: "https://github.com/mxcl/PromiseKit", from: "6.0.0"),
        .package(url: "https://github.com/MrKai77/DynamicNotchKit", from: "1.0.0"),
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", branch: "master"),
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
            ]
        ),
    ]
)
