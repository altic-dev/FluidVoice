@testable import FluidVoice_Debug
import Foundation
import XCTest
import ZeppelinEmbed

/// `FluidZeppelinRoot`: namespaces are independent, one handle is shared per
/// namespace, and a namespace that cannot be read is reset rather than left broken.
final class ZeppelinDataLayerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZeppelinDataLayerTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.root)
        self.root = nil
    }

    // MARK: - Fixtures

    private static let spec = NamespaceSpec(
        attributes: [AttributeDefinition(id: 1, name: "kind", type: .u64, nullable: false)],
        vectorSpace: nil
    )

    private func seed(_ store: ZeppelinStore, ids: ClosedRange<UInt64>) async throws {
        _ = try await store.upsert(ids.map { id in
            IngestDocument(
                id: DocumentID(high: 0, low: id),
                revision: 1,
                timestamp: Int64(id),
                vector: [],
                text: "row \(id)",
                attributes: [1: .u64(1)]
            )
        })
        try await store.seal()
    }

    private func corruptManifest(of name: String) throws {
        let manifest = self.root
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("manifest.ze")
        let original = try Data(contentsOf: manifest)
        try original.prefix(original.count / 2).write(to: manifest)
    }

    private func directories() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: self.root.path).sorted()
    }

    // MARK: - Namespaces

    func testANamespaceAddedLaterLeavesExistingOnesUntouched() async throws {
        let database = FluidZeppelinRoot(root: self.root)
        let first = try await database.namespace("first", spec: Self.spec)
        try await self.seed(first, ids: 1...5)

        let second = try await database.namespace("second", spec: NamespaceSpec(attributes: [], vectorSpace: nil))
        _ = try await second.upsert([
            IngestDocument(id: DocumentID(high: 0, low: 1), revision: 1, timestamp: 0, vector: [], text: "hello"),
        ])
        try await second.seal()

        let count = try await first.count().count
        XCTAssertEqual(count, 5, "adding a namespace disturbed an existing one")
        let names = try await ZeppelinStore.listNamespaces(root: self.root)
        XCTAssertEqual(names, ["first", "second"])
        await database.closeAll()
    }

    func testTheSameNamespaceReturnsOneSharedHandle() async throws {
        let database = FluidZeppelinRoot(root: self.root)
        let first = try await database.namespace("first", spec: Self.spec)
        let second = try await database.namespace("first", spec: Self.spec)
        XCTAssertTrue(first === second)
        await database.closeAll()
    }

    /// Two callers asking for the same namespace before either open has finished
    /// must share one open rather than the second failing on the writer lock.
    func testConcurrentFirstOpensShareOneHandle() async throws {
        let database = FluidZeppelinRoot(root: self.root)
        async let first = database.namespace("first", spec: Self.spec)
        async let second = database.namespace("first", spec: Self.spec)
        let (a, b) = try await (first, second)
        XCTAssertTrue(a === b)
        await database.closeAll()
    }

    // MARK: - Unreadable namespaces are reset

    func testACorruptNamespaceIsResetAndReopenedEmpty() async throws {
        let first = FluidZeppelinRoot(root: self.root)
        try await self.seed(first.namespace("first", spec: Self.spec), ids: 1...4)
        await first.closeAll()
        try self.corruptManifest(of: "first")

        let second = FluidZeppelinRoot(root: self.root)
        let reopened = try await second.namespace("first", spec: Self.spec)
        let count = try await reopened.count().count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(try self.directories(), ["first"], "nothing but the live namespace should remain")
        await second.closeAll()
    }

    func testASchemaMismatchIsResetToo() async throws {
        let first = FluidZeppelinRoot(root: self.root)
        try await self.seed(first.namespace("first", spec: Self.spec), ids: 1...2)
        await first.closeAll()

        let widened = NamespaceSpec(
            attributes: Self.spec.attributes + [
                AttributeDefinition(id: 2, name: "app", type: .dictionaryString, nullable: true),
            ],
            vectorSpace: nil
        )
        let second = FluidZeppelinRoot(root: self.root)
        let reopened = try await second.namespace("first", spec: widened)
        let count = try await reopened.count().count
        XCTAssertEqual(count, 0)
        await second.closeAll()
    }

    func testAHealthyNamespaceKeepsItsRowsAcrossLaunches() async throws {
        let first = FluidZeppelinRoot(root: self.root)
        try await self.seed(first.namespace("first", spec: Self.spec), ids: 1...3)
        await first.closeAll()
        try self.corruptManifest(of: "first")

        let second = FluidZeppelinRoot(root: self.root)
        try await self.seed(second.namespace("first", spec: Self.spec), ids: 10...12)
        await second.closeAll()

        let third = FluidZeppelinRoot(root: self.root)
        let count = try await third.namespace("first", spec: Self.spec).count().count
        XCTAssertEqual(count, 3, "the rebuilt namespace should have kept its rows")
        await third.closeAll()
    }
}
