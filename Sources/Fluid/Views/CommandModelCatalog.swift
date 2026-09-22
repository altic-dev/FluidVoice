import Foundation

struct CommandModelOption: Identifiable, Hashable {
    let providerID: String
    let providerName: String
    let modelID: String
    let displayName: String

    // Length-prefix the provider so model IDs containing separators cannot collide.
    var id: String { "\(self.providerID.utf8.count):\(self.providerID)\(self.modelID)" }
}

enum CommandModelCatalog {
    static func filtered(_ options: [CommandModelOption], query: String) -> [CommandModelOption] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return options }
        return options.filter { option in
            let fields = [option.providerID, option.providerName, option.modelID, option.displayName]
            return terms.allSatisfy { term in fields.contains { $0.localizedCaseInsensitiveContains(term) } }
        }
    }
}
