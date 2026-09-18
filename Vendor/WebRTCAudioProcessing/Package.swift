// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "WebRTCAudioProcessing",
    platforms: [
        .macOS("15.0"),
    ],
    products: [
        .library(name: "FluidAEC3Bridge", targets: ["FluidAEC3Bridge"]),
    ],
    targets: [
        .binaryTarget(
            name: "FluidAEC3Binary",
            path: "Artifacts/FluidAEC3.xcframework"
        ),
        .target(
            name: "FluidAEC3Bridge",
            dependencies: ["FluidAEC3Binary"],
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
            ]
        ),
    ]
)
