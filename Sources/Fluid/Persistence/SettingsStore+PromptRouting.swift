import Combine
import Foundation

extension SettingsStore {
    enum PromptRoutingScope: String, Codable, CaseIterable, Identifiable {
        case allApps
        case selectedAppsOnly

        var id: String { self.rawValue }
    }

    var dictationPromptRoutingScope: PromptRoutingScope {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: PromptRoutingKeys.dictation),
                  let scope = PromptRoutingScope(rawValue: rawValue)
            else {
                return .allApps
            }
            return scope
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: PromptRoutingKeys.dictation)
        }
    }

    var editPromptRoutingScope: PromptRoutingScope {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: PromptRoutingKeys.edit),
                  let scope = PromptRoutingScope(rawValue: rawValue)
            else {
                return .allApps
            }
            return scope
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: PromptRoutingKeys.edit)
        }
    }

    func promptRoutingScope(for mode: PromptMode) -> PromptRoutingScope {
        switch mode.normalized {
        case .dictate:
            return self.dictationPromptRoutingScope
        case .edit, .write, .rewrite:
            return self.editPromptRoutingScope
        }
    }

    func setPromptRoutingScope(_ scope: PromptRoutingScope, for mode: PromptMode) {
        switch mode.normalized {
        case .dictate:
            self.dictationPromptRoutingScope = scope
        case .edit, .write, .rewrite:
            self.editPromptRoutingScope = scope
        }
    }
}

private enum PromptRoutingKeys {
    static let dictation = "DictationPromptRoutingScope"
    static let edit = "EditPromptRoutingScope"
}
