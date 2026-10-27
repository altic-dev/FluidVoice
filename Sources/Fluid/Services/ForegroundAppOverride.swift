import Foundation

/// A manual choice belongs to one visit to an app, never to its saved rules.
struct ForegroundAppOverride<Value> {
    private(set) var appID: String?
    private var choices: [String: Value] = [:]

    @discardableResult
    mutating func activate(_ appID: String?) -> Bool {
        guard let appID, !appID.isEmpty, appID != self.appID else { return false }
        self.appID = appID
        self.choices.removeAll(keepingCapacity: true)
        return true
    }

    mutating func select(_ value: Value, slot: String, appID: String) {
        guard appID == self.appID else { return }
        self.choices[slot] = value
    }

    func choice(slot: String, appID: String?) -> Value? {
        guard let appID, appID == self.appID else { return nil }
        return self.choices[slot]
    }
}
