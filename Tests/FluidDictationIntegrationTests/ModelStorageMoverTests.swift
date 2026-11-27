@testable import FluidVoice_Debug
import Foundation
import XCTest

private final class HookRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var commits: [(ModelStorageConfiguration, ModelStorageConfiguration)] = []

    func record(_ from: ModelStorageConfiguration, _ to: ModelStorageConfiguration) {
        self.lock.withLock { self.commits.append((from, to)) }
    }

    var commitTargets: [String?] {
        self.lock.withLock { self.commits.map(\.1.rootPath) }
    }
}

final class ModelStorageMoverTests: XCTestCase {
    private var temp: URL!
    private var journal: ModelStorageMoveJournal!
    private let whisper = ModelStorageFolder(name: "Whisper", kind: .whisper)
    private let meeting = ModelStorageFolder(name: "Meeting", kind: .meeting)

    override func setUpWithError() throws {
        self.temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStorageMoverTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: self.temp, withIntermediateDirectories: true)
        self.journal = ModelStorageMoveJournal(url: self.temp.appendingPathComponent("journal.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: self.temp.path)
        try? FileManager.default.removeItem(at: self.temp)
    }

    private func root(_ name: String) throws -> ModelStorageConfiguration {
        let url = self.temp.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return ModelStorageConfiguration(rootPath: url.path)
    }

    @discardableResult
    private func seedWhisper(in config: ModelStorageConfiguration, bytes: Int = 64) throws -> URL {
        let directory = ModelStorageLocation.whisperModelsDirectory(in: config)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("pkg.mlpackage/Data"), withIntermediateDirectories: true)
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: directory.appendingPathComponent("model.gguf"))
        try Data("weights".utf8).write(to: directory.appendingPathComponent("pkg.mlpackage/Data/weight.bin"))
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("alias").path, withDestinationPath: "model.gguf")
        return directory
    }

    /// Forces the copy path, which a temporary folder on one volume would otherwise skip.
    private func crossVolume(_ plan: ModelStorageMovePlan, available: Int64? = 1 << 40) -> ModelStorageMovePlan {
        let items = plan.items.map {
            ModelStorageMoveItem(folder: $0.folder, source: $0.source, resolvedSource: $0.resolvedSource, destination: $0.destination, byteCount: $0.byteCount, sameVolume: false)
        }
        let copy = items.reduce(Int64(0)) { $0 + $1.byteCount }
        return ModelStorageMovePlan(
            from: plan.from,
            to: plan.to,
            items: items,
            alreadyAtDestination: plan.alreadyAtDestination,
            requiredBytes: copy + ModelStorageMover.headroomBytes,
            availableBytes: available
        )
    }

    private func hooks(_ recorder: HookRecorder, verify: Bool = true) -> ModelStorageMover.Hooks {
        ModelStorageMover.Hooks(
            beforeSwitch: {},
            commit: { from, to in recorder.record(from, to) },
            verifyAfterSwitch: { verify }
        )
    }

    private func stagingFolders(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix(ModelStorageMover.stagingPrefix) }
    }

    // MARK: - Planning

    func testPlanSkipsMissingSourcesAndDetectsSameVolume() throws {
        let from = try self.root("from")
        let to = try self.root("to")
        try self.seedWhisper(in: from)
        let plan = try ModelStorageMover.makePlan(folders: [self.whisper, self.meeting], from: from, to: to)
        XCTAssertEqual(plan.items.map(\.folder), [self.whisper])
        XCTAssertTrue(try XCTUnwrap(plan.items.first).sameVolume)
        XCTAssertEqual(plan.requiredBytes, 0)
        XCTAssertTrue(plan.hasEnoughSpace)
    }

    func testPlanUsesFoldersAlreadyAtDestination() throws {
        let from = try self.root("from")
        let to = try self.root("to")
        try self.seedWhisper(in: from)
        try self.seedWhisper(in: to)
        let plan = try ModelStorageMover.makePlan(folders: [self.whisper], from: from, to: to)
        XCTAssertTrue(plan.items.isEmpty)
        XCTAssertEqual(plan.alreadyAtDestination, [self.whisper])
        XCTAssertTrue(plan.destinationHasModels)
    }

    func testPlanRefusesDestinationInsideSource() throws {
        let from = try self.root("from")
        let source = try self.seedWhisper(in: from)
        let to = ModelStorageConfiguration(rootPath: source.appendingPathComponent("nested").path)
        try FileManager.default.createDirectory(atPath: XCTUnwrap(to.rootPath), withIntermediateDirectories: true)
        XCTAssertThrowsError(try ModelStorageMover.makePlan(folders: [self.whisper], from: from, to: to)) { error in
            guard case .nestedFolders = error as? ModelStorageMoveError else { return XCTFail("\(error)") }
        }
    }

    func testPlanRefusesBrokenLinkAtDestination() throws {
        let from = try self.root("from")
        let to = try self.root("to")
        try self.seedWhisper(in: from)
        let destination = ModelStorageLocation.whisperModelsDirectory(in: to)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: self.temp.appendingPathComponent("nowhere").path)
        XCTAssertThrowsError(try ModelStorageMover.makePlan(folders: [self.whisper], from: from, to: to)) { error in
            XCTAssertEqual(error as? ModelStorageError, .symlinkInTheWay(path: destination.path))
        }
    }

    // MARK: - Copy and verify

    func testCopyKeepsBytesTimesPermissionsAndInnerLinks() throws {
        let from = try self.root("from")
        let source = try self.seedWhisper(in: from)
        let past = Date(timeIntervalSince1970: 1_700_000_000.123)
        try FileManager.default.setAttributes([.modificationDate: past, .posixPermissions: 0o640], ofItemAtPath: source.appendingPathComponent("model.gguf").path)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: source.appendingPathComponent("pkg.mlpackage").path)
        let destination = self.temp.appendingPathComponent("copy", isDirectory: true)

        let hashes = try ModelStorageMover.copyTree(from: source, to: destination)
        try ModelStorageMover.verifyTree(at: destination, expected: hashes)

        let copied = try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("model.gguf").path)
        XCTAssertEqual((copied[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        for name in ["model.gguf", "pkg.mlpackage"] {
            let date = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent(name).path)[.modificationDate] as? Date)
            XCTAssertEqual(Int64(date.timeIntervalSince1970 * 1000), Int64(past.timeIntervalSince1970 * 1000), name)
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("alias").path), "model.gguf")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("model.gguf")), try Data(contentsOf: source.appendingPathComponent("model.gguf")))
    }

    func testVerificationDetectsChangedByte() throws {
        let source = try self.seedWhisper(in: self.root("from"))
        let destination = self.temp.appendingPathComponent("copy", isDirectory: true)
        let hashes = try ModelStorageMover.copyTree(from: source, to: destination)
        let file = destination.appendingPathComponent("model.gguf")
        var bytes = try Data(contentsOf: file)
        bytes[0] ^= 0xff
        try bytes.write(to: file)
        XCTAssertThrowsError(try ModelStorageMover.verifyTree(at: destination, expected: hashes)) { error in
            XCTAssertEqual(error as? ModelStorageMoveError, .verificationFailed(path: file.path))
        }
    }

    // MARK: - Running

    func testCrossVolumeMoveCopiesVerifiesSwitchesAndDeletesOriginals() async throws {
        let from = try self.root("from")
        let to = try self.root("to")
        let source = try self.seedWhisper(in: from)
        let original = try Data(contentsOf: source.appendingPathComponent("model.gguf"))
        let plan = try self.crossVolume(ModelStorageMover.makePlan(folders: [self.whisper], from: from, to: to))
        let recorder = HookRecorder()

        let summary = try await ModelStorageMover.run(plan, journal: self.journal, hooks: self.hooks(recorder))

        let destination = ModelStorageLocation.whisperModelsDirectory(in: to)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("model.gguf")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(recorder.commitTargets, [to.rootPath])
        XCTAssertEqual(summary.movedFolders, ["Whisper"])
        XCTAssertTrue(self.stagingFolders(in: destination.deletingLastPathComponent()).isEmpty)
        XCTAssertNil(self.journal.read())
        XCTAssertTrue(try FileManager.default.fileExists(atPath: XCTUnwrap(to.resolvedRootURL).appendingPathComponent(ModelStorageLocation.markerFileName).path))
    }

    func testSameVolumeMoveRenamesWithoutSpace() async throws {
        let from = try self.root("from")
        let to = try self.root("to")
        let source = try self.seedWhisper(in: from)
        let fileNumber = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: source.appendingPathComponent("model.gguf").path)[.systemFileNumber] as? Int)
        let plan = try ModelStorageMover.makePlan(folders: [self.whisper], from: from, to: to)
        let limited = ModelStorageMovePlan(from: plan.from, to: plan.to, items: plan.items, alreadyAtDestination: [], requiredBytes: 0, availableBytes: 0)
        _ = try await ModelStorageMover.run(limited, journal: self.journal, hooks: self.hooks(HookRecorder()))

        let moved = ModelStorageLocation.whisperModelsDirectory(in: to).appendingPathComponent("model.gguf")
        // The same file number proves a rename, not a copy.
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: moved.path)[.systemFileNumber] as? Int, fileNumber)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testOriginalThatChangedAfterTheCopyIsKept() async throws {
        let from = try self.root("from")
        let to = try self.root("to")
        let source = try self.seedWhisper(in: from)
        let plan = try self.crossVolume(ModelStorageMover.makePlan(folders: [self.whisper], from: from, to: to))
        let late = source.appendingPathComponent("downloaded-during-move.gguf")
        let hooks = ModelStorageMover.Hooks(
            beforeSwitch: { try Data([9]).write(to: late) },
            commit: { _, _ in },
            verifyAfterSwitch: { true }
        )

        let summary = try await ModelStorageMover.run(plan, journal: self.journal, hooks: hooks)

        XCTAssertEqual(summary.changedOriginals, [source.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: late.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ModelStorageLocation.whisperModelsDirectory(in: to).appendingPathComponent("model.gguf").path))
    }

    func testFluidAudioFolderMovesPerModelAndMergesIntoAPartlyFilledDestination() async throws {
        let from = try self.root("from")
        let to = try self.root("to")
        let fluidAudio = ModelStorageFolder(name: "FluidAudio", kind: .fluidAudio)
        let sourceModels = ModelStorageLocation.fluidAudioModelsDirectory(in: from)
        let destinationModels = ModelStorageLocation.fluidAudioModelsDirectory(in: to)
        for name in ["model-a", "model-b"] {
            try FileManager.default.createDirectory(at: sourceModels.appendingPathComponent(name), withIntermediateDirectories: true)
            try Data([1]).write(to: sourceModels.appendingPathComponent("\(name)/weights.bin"))
        }
        try FileManager.default.createDirectory(at: destinationModels.appendingPathComponent("model-a"), withIntermediateDirectories: true)
        try Data([2]).write(to: destinationModels.appendingPathComponent("model-a/weights.bin"))

        let plan = try ModelStorageMover.makePlan(folders: [fluidAudio], from: from, to: to)
        XCTAssertEqual(plan.items.map(\.folder.kind), [.fluidAudioModel(name: "model-b")])
        XCTAssertEqual(plan.alreadyAtDestination.map(\.kind), [.fluidAudioModel(name: "model-a")])

        _ = try await ModelStorageMover.run(plan, journal: self.journal, hooks: self.hooks(HookRecorder()))
        XCTAssertEqual(try Data(contentsOf: destinationModels.appendingPathComponent("model-a/weights.bin")), Data([2]))
        XCTAssertEqual(try Data(contentsOf: destinationModels.appendingPathComponent("model-b/weights.bin")), Data([1]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceModels.appendingPathComponent("model-a").path))
    }

    func testVerificationIgnoresSidecarFilesOnTheDestination() throws {
        let source = try self.seedWhisper(in: self.root("from"))
        let destination = self.temp.appendingPathComponent("copy", isDirectory: true)
        let hashes = try ModelStorageMover.copyTree(from: source, to: destination)
        try Data([0]).write(to: destination.appendingPathComponent("._model.gguf"))
        try Data([0]).write(to: destination.appendingPathComponent(".DS_Store"))
        XCTAssertNoThrow(try ModelStorageMover.verifyTree(at: destination, expected: hashes))
    }

    func testInsufficientSpaceStopsBeforeWritingAnything() async throws {
        let from = try self.root("from")
        let to = try self.root("to")
        let source = try self.seedWhisper(in: from)
        let plan = try self.crossVolume(ModelStorageMover.makePlan(folders: [self.whisper], from: from, to: to), available: 10)
        let recorder = HookRecorder()
        do {
            _ = try await ModelStorageMover.run(plan, journal: self.journal, hooks: self.hooks(recorder))
            XCTFail("expected insufficient space")
        } catch let error as ModelStorageMoveError {
            guard case .insufficientSpace = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("model.gguf").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: XCTUnwrap(to.rootPath)), [])
        XCTAssertTrue(recorder.commitTargets.isEmpty)
        XCTAssertNil(self.journal.read())
    }

    func testCancelDuringCopyLeavesOriginalsAndConfiguration() async throws {
        let from = try self.root("from")
        let to = try self.root("to")
        let source = try self.seedWhisper(in: from, bytes: 64)
        let plan = try self.crossVolume(ModelStorageMover.makePlan(folders: [self.whisper], from: from, to: to))
        let recorder = HookRecorder()
        let journal = try XCTUnwrap(self.journal)

        let task = Task {
            try await ModelStorageMover.run(plan, journal: journal, hooks: self.hooks(recorder)) { progress in
                if progress.phase == .copying, progress.completedBytes > 0 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("model.gguf").path))
        let destination = ModelStorageLocation.whisperModelsDirectory(in: to)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(self.stagingFolders(in: destination.deletingLastPathComponent()).isEmpty)
        XCTAssertTrue(recorder.commitTargets.isEmpty)
        XCTAssertNil(journal.read())
    }

    func testCopyFailureLeavesOriginalsAndNoStaging() async throws {
        let from = try self.root("from")
        let to = try self.root("to")
        let source = try self.seedWhisper(in: from)
        let unreadable = source.appendingPathComponent("model.gguf")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }
        let plan = try self.crossVolume(ModelStorageMover.makePlan(folders: [self.whisper], from: from, to: to))
        let recorder = HookRecorder()

        do {
            _ = try await ModelStorageMover.run(plan, journal: self.journal, hooks: self.hooks(recorder))
            XCTFail("expected a copy error")
        } catch {}

        XCTAssertTrue(FileManager.default.fileExists(atPath: unreadable.path))
        let destination = ModelStorageLocation.whisperModelsDirectory(in: to)
        XCTAssertTrue(self.stagingFolders(in: destination.deletingLastPathComponent()).isEmpty)
        XCTAssertTrue(recorder.commitTargets.isEmpty)
    }

    func testMissingModelsAfterSwitchRollsBack() async throws {
        let from = try self.root("from")
        let to = try self.root("to")
        let source = try self.seedWhisper(in: from)
        let plan = try self.crossVolume(ModelStorageMover.makePlan(folders: [self.whisper], from: from, to: to))
        let recorder = HookRecorder()

        do {
            _ = try await ModelStorageMover.run(plan, journal: self.journal, hooks: self.hooks(recorder, verify: false))
            XCTFail("expected rollback")
        } catch let error as ModelStorageMoveError {
            XCTAssertEqual(error, .modelsMissingAfterSwitch)
        }

        XCTAssertEqual(recorder.commitTargets, [to.rootPath, from.rootPath])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("model.gguf").path))
        let destination = ModelStorageLocation.whisperModelsDirectory(in: to)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(self.stagingFolders(in: destination.deletingLastPathComponent()).isEmpty)
    }

    func testSymlinkedSourceIsMovedAndLinkIsReported() async throws {
        let real = try self.root("real")
        let realWhisper = try self.seedWhisper(in: real)
        let from = try self.root("from")
        let linked = ModelStorageLocation.whisperModelsDirectory(in: from)
        try FileManager.default.createDirectory(at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: realWhisper)
        let to = try self.root("to")

        let plan = try ModelStorageMover.makePlan(folders: [self.whisper], from: from, to: to)
        XCTAssertEqual(plan.items.first?.resolvedSource.path, realWhisper.path)
        let summary = try await ModelStorageMover.run(self.crossVolume(plan), journal: self.journal, hooks: self.hooks(HookRecorder()))

        XCTAssertTrue(ModelStorageLocation.isSymbolicLink(linked))
        XCTAssertEqual(summary.leftoverLinks, [linked.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: realWhisper.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ModelStorageLocation.whisperModelsDirectory(in: to).appendingPathComponent("model.gguf").path))
    }

    func testJournalRecoveryRemovesStagingFolders() throws {
        let staging = self.temp.appendingPathComponent("\(ModelStorageMover.stagingPrefix)x-WhisperModels", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try self.journal.write(.init(id: "x", from: .defaultLocations, to: .defaultLocations, phase: .copying, stagingPaths: [staging.path]))

        let entry = self.journal.recoverInterruptedMove()

        XCTAssertEqual(entry?.phase, .copying)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertNil(self.journal.read())
    }

    func testJournalRecoveryNeverDeletesFoldersItDidNotCreate() throws {
        let unrelated = self.temp.appendingPathComponent("Documents", isDirectory: true)
        let otherMove = self.temp.appendingPathComponent("\(ModelStorageMover.stagingPrefix)other-WhisperModels", isDirectory: true)
        for folder in [unrelated, otherMove] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try self.journal.write(.init(id: "x", from: .defaultLocations, to: .defaultLocations, phase: .copying, stagingPaths: [unrelated.path, otherMove.path]))

        _ = self.journal.recoverInterruptedMove()

        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherMove.path))
    }

    func testMoveFlagBlocksModelChanges() {
        ModelStorageLocation.setMoveInProgress(true)
        defer { ModelStorageLocation.setMoveInProgress(false) }
        XCTAssertThrowsError(try ModelStorageLocation.requireAvailableForChanges()) { error in
            XCTAssertEqual(error as? ModelStorageError, .moveInProgress)
        }
    }
}
