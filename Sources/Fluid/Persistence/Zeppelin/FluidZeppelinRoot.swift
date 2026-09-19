import Foundation
import ZeppelinEmbed

/// The Zeppelin database at `~/Library/Application Support/FluidVoice/zeppelin/`.
///
/// Each namespace is one directory under the root, created on demand and independent
/// of the others. Every namespace here is a derived copy of a store the app already
/// keeps, so the library's default `derived` durability applies and one that cannot
/// be read is reset and rebuilt from its source.
actor FluidZeppelinRoot {
    static let shared = FluidZeppelinRoot()

    /// Errors that mean the bytes on disk cannot be interpreted. `.io` is absent: a
    /// full disk or a lost volume is not a reason to throw the index away.
    private static let unreadable: Set<ZeppelinError> = [.corrupt, .epochMismatch, .schemaMismatch]

    private let root: URL
    private var namespaces: [String: Task<ZeppelinStore, Error>] = [:]

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidVoice/zeppelin", isDirectory: true)
    }

    /// Opens a namespace, or returns the handle already open for it.
    ///
    /// A second open of the same directory fails on its writer lock, so the open is
    /// cached as a task: concurrent first callers share one open instead of racing.
    func namespace(_ name: String, spec: NamespaceSpec) async throws -> ZeppelinStore {
        if let open = self.namespaces[name] {
            return try await open.value
        }
        let open = Task { try await self.open(name, spec: spec) }
        self.namespaces[name] = open
        do {
            return try await open.value
        } catch {
            self.namespaces[name] = nil
            throw error
        }
    }

    private func open(_ name: String, spec: NamespaceSpec) async throws -> ZeppelinStore {
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        do {
            return try await ZeppelinStore.openNamespace(root: self.root, name: name, spec: spec, options: OpenOptions())
        } catch let error as ZeppelinError where Self.unreadable.contains(error) {
            await DebugLogger.shared.error(
                "Zeppelin namespace \(name) could not be read (\(error)); resetting it",
                source: "FluidZeppelinRoot"
            )
            try FileManager.default.removeItem(at: self.root.appendingPathComponent(name, isDirectory: true))
            return try await ZeppelinStore.openNamespace(root: self.root, name: name, spec: spec, options: OpenOptions())
        }
    }

    /// Closes every open namespace so their logs are checkpointed rather than
    /// replayed on the next launch. Called from `applicationWillTerminate`.
    func closeAll() async {
        for (name, open) in self.namespaces {
            do {
                try await open.value.close()
            } catch {
                await DebugLogger.shared.warning(
                    "Zeppelin namespace \(name) did not close cleanly: \(error)",
                    source: "FluidZeppelinRoot"
                )
            }
        }
        self.namespaces.removeAll()
    }
}
