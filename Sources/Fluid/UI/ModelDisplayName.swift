import Foundation

/// Presentation only. Picker tags, history records and API requests keep their original IDs.
enum ModelDisplayName {
    /// A registry lookup reads the process environment and settings on every call, which is far
    /// too slow for History rows that are drawn while scrolling. A name only changes when settings
    /// do, so names are remembered until the next settings change.
    private static let cache = DisplayNameCache()

    static func forID(_ modelID: String) -> String {
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name = self.cache.name(for: id) { return name }
        let name = self.lookUp(id)
        self.cache.store(name, for: id)
        return name
    }

    private static func lookUp(_ id: String) -> String {
        let canonical = PrivateAIModelRegistry.canonicalModelID(for: id) ?? id
        guard let model = PrivateAIModelRegistry.model(id: canonical), !model.displayName.isEmpty else { return id }
        return model.displayName.replacingOccurrences(of: "Fluid-1", with: "Fluid 1")
    }
}

/// Display names by model ID, emptied whenever settings change. Holds at most a few dozen IDs.
private final class DisplayNameCache: @unchecked Sendable {
    private static let limit = 64

    private let lock = NSLock()
    private var names: [String: String] = [:]
    private var observer: NSObjectProtocol?

    init() {
        self.observer = NotificationCenter.default.addObserver(
            forName: Foundation.UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.removeAll()
        }
    }

    func name(for id: String) -> String? {
        self.lock.withLock { self.names[id] }
    }

    func store(_ name: String, for id: String) {
        self.lock.withLock {
            if self.names.count >= Self.limit { self.names.removeAll() }
            self.names[id] = name
        }
    }

    private func removeAll() {
        self.lock.withLock { self.names.removeAll() }
    }
}
