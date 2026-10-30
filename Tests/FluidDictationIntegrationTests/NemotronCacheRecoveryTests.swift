import CoreML
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

    private func makeCompiledCache() throws -> (root: URL, cache: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NemotronCacheRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        let cache = root
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("CompiledNemotronModels", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: cache.appendingPathComponent("marker.txt"))
        return (root, cache)
    }

    func testLoadRecoveringCompiledCache_clearsCacheBeforeTheGPURetry() async throws {
        let (root, cache) = try self.makeCompiledCache()
        defer { try? FileManager.default.removeItem(at: root) }
        var attempts: [(MLComputeUnits, Bool)] = []

        let result = try await NemotronProvider.loadRecoveringCompiledCache(compiledCacheDirectory: cache) { units in
            attempts.append((units, FileManager.default.fileExists(atPath: cache.path)))
            if units == .cpuAndNeuralEngine {
                throw NSError(domain: "CoreML", code: -14)
            }
            return "loaded"
        }

        XCTAssertEqual(result, "loaded")
        XCTAssertEqual(attempts.map(\.0), [.cpuAndNeuralEngine, .cpuAndGPU])
        XCTAssertEqual(attempts.map(\.1), [true, false], "the cache must be gone before the retry")
    }

    func testLoadRecoveringCompiledCache_keepsCacheAndRethrowsUnrelatedErrors() async throws {
        let (root, cache) = try self.makeCompiledCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = NSError(domain: NSCocoaErrorDomain, code: -999)
        var attempts: [MLComputeUnits] = []

        do {
            _ = try await NemotronProvider.loadRecoveringCompiledCache(compiledCacheDirectory: cache) { units -> String in
                attempts.append(units)
                throw unrelated
            }
            XCTFail("expected the unrelated error to be rethrown")
        } catch {
            XCTAssertEqual(error as NSError, unrelated)
        }

        XCTAssertEqual(attempts, [.cpuAndNeuralEngine])
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
    }

    func testLoadRecoveringCompiledCache_wrapsTheRetryFailureWithItsUnderlyingError() async throws {
        let (root, cache) = try self.makeCompiledCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let retryFailure = NSError(domain: "CoreML", code: 7)

        do {
            _ = try await NemotronProvider.loadRecoveringCompiledCache(compiledCacheDirectory: cache) { units -> String in
                throw units == .cpuAndNeuralEngine ? NSError(domain: "CoreML", code: -14) : retryFailure
            }
            XCTFail("expected the retry failure to be thrown")
        } catch {
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            XCTAssertEqual(underlying, retryFailure)
            XCTAssertTrue((error as NSError).localizedDescription.contains(cache.path))
        }
    }
}
#endif
