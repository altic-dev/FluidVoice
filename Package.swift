// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FluidVoice",
    platforms: [
        .macOS("15.0"),
    ],
    dependencies: [
        .package(path: "Vendor/WebRTCAudioProcessing"),
        .package(url: "https://github.com/mxcl/AppUpdater.git", from: "1.0.0"),
        .package(url: "https://github.com/altic-dev/FluidAudio.git", revision: "eb1e6628998e47022799d305b52c2680d3576801"),
        .package(url: "https://github.com/mxcl/PromiseKit", from: "6.0.0"),
        .package(url: "https://github.com/altic-dev/DynamicNotchKit.git", revision: "50dc8565469cc80bbbe3c0d5dd902585a2d67986"),
        .package(url: "https://github.com/altic-dev/transcribe-cpp-swift.git", exact: "0.1.2"),
        .package(url: "https://github.com/zepdb/zeppelin-embed.git", exact: "0.4.1"),
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
                .product(name: "FluidAEC3Bridge", package: "WebRTCAudioProcessing"),
                .product(name: "TranscribeCpp", package: "transcribe-cpp-swift"),
                .product(name: "ZeppelinEmbed", package: "zeppelin-embed"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
