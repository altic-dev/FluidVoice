import Foundation

/// Catalog-driven carousel math. Empty and single-model builds never wrap or invent neighbors.
enum PrivateAIModelCarouselNavigation {
    static func next(in ids: [String], current: String, forward: Bool) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let index = ids.firstIndex(of: current) else { return ids.first }
        return ids[(index + (forward ? 1 : ids.count - 1)) % ids.count]
    }

    static func position(of id: String, in ids: [String], current: String) -> Int {
        guard let index = ids.firstIndex(of: id), !ids.isEmpty else { return 0 }
        let center = ids.firstIndex(of: current) ?? 0
        if ids.count == 2 { return index - center }
        let distance = (index - center + ids.count) % ids.count
        return distance > ids.count / 2 ? distance - ids.count : distance
    }
}

/// Presentation-only choice and a single bounded mutation slot. Browsing never invokes an action.
struct PrivateAISettingsSession {
    private(set) var selectedModelID: String
    private(set) var previewModelID: String
    private(set) var revision = UUID()
    private(set) var operationID: UUID?

    var isBusy: Bool { self.operationID != nil }

    init(selectedModelID: String) {
        self.selectedModelID = selectedModelID
        self.previewModelID = selectedModelID
    }

    mutating func preview(_ modelID: String) {
        self.previewModelID = modelID
    }

    /// Explicit activation only. The caller validates IDs against the current model catalog.
    @discardableResult
    mutating func select(_ modelID: String) -> Bool {
        guard !self.isBusy else { return false }
        self.selectedModelID = modelID
        self.previewModelID = modelID
        self.revision = UUID()
        return true
    }

    mutating func begin() -> UUID? {
        guard !self.isBusy else { return nil }
        let token = UUID()
        self.operationID = token
        self.revision = UUID()
        return token
    }

    mutating func finish(_ token: UUID) {
        guard self.operationID == token else { return }
        self.operationID = nil
        self.revision = UUID()
    }

    func acceptsRead(_ revision: UUID) -> Bool {
        !self.isBusy && self.revision == revision
    }
}

/// Injectable transaction boundary used by the real update button and deterministic tests.
/// Keep the mutation slot occupied until commit/rollback has finished, not just verification.
enum PrivateAISettingsUpdateTransaction {
    @MainActor
    static func run<Token>(
        update: () async throws -> Token,
        verify: () async -> Bool,
        commit: (Token) async -> Void,
        rollback: (Token) async -> Void
    ) async throws -> Bool {
        let token = try await update()
        do {
            try Task.checkCancellation()
            let verified = await verify()
            try Task.checkCancellation()
            if verified {
                await commit(token)
            } else {
                await rollback(token)
            }
            return verified
        } catch {
            await rollback(token)
            throw error
        }
    }
}
