@testable import FluidVoice_Debug
import XCTest

#if arch(arm64)
@MainActor
@available(macOS 14.0, *)
final class NemotronCacheRecoveryTests: XCTestCase {

    func testShouldRetryWithoutNeuralEngine_matchesNestedErrorCodeMinus14() {
        let underlying = NSError(domain: "CoreML", code: -14)
        let error = NSError(
            domain: "FluidVoiceTests",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )

        XCTAssertTrue(NemotronProvider.shouldRetryWithoutNeuralEngine(error))
    }

    func testShouldRetryWithoutNeuralEngine_matchesCoreMLExecutionPlanDescription() {
        let error = NSError(
            domain: "CoreML",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Failed to build the model execution plan with error code: -14.",
            ]
        )

        XCTAssertTrue(NemotronProvider.shouldRetryWithoutNeuralEngine(error))
    }

    func testShouldRetryWithoutNeuralEngine_ignoresUnrelatedErrors() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: -999,
            userInfo: [NSLocalizedDescriptionKey: "The operation was cancelled."]
        )

        XCTAssertFalse(NemotronProvider.shouldRetryWithoutNeuralEngine(error))
    }

    func testCompiledModelCacheDirectoryUsesFluidAudioCompiledNemotronCache() throws {
        let cachesDirectory = try XCTUnwrap(
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        ).standardizedFileURL
        let compiledCacheDirectory = try XCTUnwrap(NemotronProvider.compiledModelCacheDirectory)
            .standardizedFileURL

        XCTAssertTrue(compiledCacheDirectory.path.hasPrefix(cachesDirectory.path + "/"))
        XCTAssertEqual(
            Array(compiledCacheDirectory.pathComponents.suffix(2)),
            ["FluidAudio", "CompiledNemotronModels"]
        )
    }

    func testClearCompiledModelCacheRemovesDirectoryAndIgnoresMissingDirectory() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NemotronCacheRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        let compiledCacheDirectory = tempRoot
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("CompiledNemotronModels", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        try FileManager.default.createDirectory(at: compiledCacheDirectory, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: compiledCacheDirectory.appendingPathComponent("marker.txt"))

        NemotronProvider.clearCompiledModelCache(at: compiledCacheDirectory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: compiledCacheDirectory.path))
        NemotronProvider.clearCompiledModelCache(at: compiledCacheDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: compiledCacheDirectory.path))
    }
}
#endif
