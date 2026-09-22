import Foundation

/// Unsaved text belongs to its session, including when another surface changes selection.
struct CommandSessionDrafts {
    private var values: [String: String] = [:]

    func text(for sessionID: String?) -> String {
        guard let sessionID else { return "" }
        return self.values[sessionID] ?? ""
    }

    mutating func set(_ text: String, for sessionID: String?) {
        guard let sessionID else { return }
        self.values[sessionID] = text.isEmpty ? nil : text
    }

    mutating func retain(sessionIDs: [String]) {
        let retained = Set(sessionIDs)
        self.values = self.values.filter { retained.contains($0.key) }
    }
}

enum CommandWorkspaceLayout {
    static let sidebarWidth: CGFloat = 272
    static let dockedHistoryMinimumWidth: CGFloat = 900
    static let conversationMaximumWidth: CGFloat = 1040

    static func showsDockedHistory(width: CGFloat, preferred: Bool) -> Bool {
        preferred && width >= self.dockedHistoryMinimumWidth
    }
}
