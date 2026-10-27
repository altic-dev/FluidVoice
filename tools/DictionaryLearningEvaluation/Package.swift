// swift-tools-version: 6.2
import Foundation
import PackageDescription

let package = Package(
    name: "DictionaryLearningEvaluation",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            name: "FluidAudio",
            path: ProcessInfo.processInfo.environment["FLUIDAUDIO_SOURCE"]
                ?? "../../../FluidAudio_pronunciation_streaming"
        ),
    ],
    targets: [
        .executableTarget(
            name: "Evaluate", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .executableTarget(
            name: "PersonalProof", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
    ]
)
