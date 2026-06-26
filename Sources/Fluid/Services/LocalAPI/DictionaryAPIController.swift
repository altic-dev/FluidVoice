import Foundation

struct DictionaryAPIController: LocalAPIRouteHandler {
    struct ReplacementEntry: Codable {
        let id: UUID?
        let triggers: [String]
        let replacement: String
    }

    struct ReplacementListResponse: Encodable {
        let count: Int
        let items: [ReplacementEntry]
    }

    struct ReplacementWriteRequest: Decodable {
        let mode: WriteMode
        let entries: [ReplacementEntry]
        let hasEntries: Bool
        let singleEntry: ReplacementEntry?

        enum CodingKeys: String, CodingKey {
            case mode
            case entries
            case triggers
            case replacement
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.mode = try container.decodeIfPresent(WriteMode.self, forKey: .mode) ?? .append
            self.entries = try container.decodeIfPresent([ReplacementEntry].self, forKey: .entries) ?? []
            self.hasEntries = container.contains(.entries)

            let triggers = try container.decodeIfPresent([String].self, forKey: .triggers) ?? []
            let replacement = try container.decodeIfPresent(String.self, forKey: .replacement)
            if let replacement, !triggers.isEmpty {
                self.singleEntry = ReplacementEntry(id: nil, triggers: triggers, replacement: replacement)
            } else {
                self.singleEntry = nil
            }
        }
    }

    struct CustomWordEntry: Codable {
        let text: String
        let weight: Float?
        let aliases: [String]

        enum CodingKeys: String, CodingKey {
            case text
            case weight
            case aliases
        }

        init(text: String, weight: Float?, aliases: [String] = []) {
            self.text = text
            self.weight = weight
            self.aliases = aliases
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.text = try container.decode(String.self, forKey: .text)
            self.weight = try container.decodeIfPresent(Float.self, forKey: .weight)
            self.aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        }
    }

    struct CustomWordsResponse: Encodable {
        let count: Int
        let items: [CustomWordEntry]
    }

    struct CustomWordsWriteRequest: Decodable {
        let mode: WriteMode
        let entries: [CustomWordEntry]
        let hasEntries: Bool
        let singleEntry: CustomWordEntry?

        enum CodingKeys: String, CodingKey {
            case mode
            case entries
            case text
            case weight
            case aliases
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.mode = try container.decodeIfPresent(WriteMode.self, forKey: .mode) ?? .append
            self.entries = try container.decodeIfPresent([CustomWordEntry].self, forKey: .entries) ?? []
            self.hasEntries = container.contains(.entries)

            if let text = try container.decodeIfPresent(String.self, forKey: .text) {
                let weight = try container.decodeIfPresent(Float.self, forKey: .weight)
                let aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
                self.singleEntry = CustomWordEntry(text: text, weight: weight, aliases: aliases)
            } else {
                self.singleEntry = nil
            }
        }
    }

    enum WriteMode: String, Decodable {
        case append
        case replace
    }

    func handle(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        switch (request.method, request.path) {
        case ("GET", "/v1/dictionary/replacements"):
            return self.getReplacements()
        case ("POST", "/v1/dictionary/replacements"):
            return self.writeReplacements(request)
        case ("GET", "/v1/dictionary/custom-words"):
            return self.getCustomWords()
        case ("POST", "/v1/dictionary/custom-words"):
            return self.writeCustomWords(request)
        default:
            return LocalAPI.error("Route not found.", status: 404)
        }
    }

    private func getReplacements() -> LocalAPI.Response {
        let entries = SettingsStore.shared.customDictionaryEntries.map(Self.apiEntry(from:))
        return LocalAPI.json(ReplacementListResponse(count: entries.count, items: entries))
    }

    private func writeReplacements(_ request: LocalAPI.Request) -> LocalAPI.Response {
        do {
            let payload = try LocalAPI.decoder.decode(ReplacementWriteRequest.self, from: request.body)
            let incoming = try self.replacementEntries(from: payload)

            var stored = payload.mode == .replace ? [] : SettingsStore.shared.customDictionaryEntries
            for entry in incoming {
                let normalized = Self.storeEntry(from: entry)
                guard !normalized.triggers.isEmpty,
                      !normalized.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    continue
                }

                stored.removeAll { existing in
                    if let id = entry.id, existing.id == id { return true }
                    return existing.replacement.caseInsensitiveCompare(normalized.replacement) == .orderedSame
                }
                stored.append(normalized)
            }

            SettingsStore.shared.customDictionaryEntries = stored
            ASRService.invalidateDictionaryCache()
            NotificationCenter.default.post(name: .parakeetVocabularyDidChange, object: nil)
            return self.getReplacements()
        } catch {
            return LocalAPI.error("Invalid replacement payload: \(error.localizedDescription)", status: 400)
        }
    }

    private func getCustomWords() -> LocalAPI.Response {
        do {
            let entries = try ParakeetVocabularyStore.shared.loadUserBoostTerms().map(Self.apiEntry(from:))
            return LocalAPI.json(CustomWordsResponse(count: entries.count, items: entries))
        } catch {
            return LocalAPI.error("Failed to load custom words: \(error.localizedDescription)", status: 500)
        }
    }

    private func writeCustomWords(_ request: LocalAPI.Request) -> LocalAPI.Response {
        do {
            let payload = try LocalAPI.decoder.decode(CustomWordsWriteRequest.self, from: request.body)
            let incoming = try self.customWordEntries(from: payload)

            var stored = payload.mode == .replace ? [] : try ParakeetVocabularyStore.shared.loadUserBoostTerms()
            for entry in incoming {
                let normalized = Self.storeEntry(from: entry)
                guard !normalized.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                stored.removeAll { $0.text.caseInsensitiveCompare(normalized.text) == .orderedSame }
                stored.append(normalized)
            }

            try ParakeetVocabularyStore.shared.saveUserBoostTerms(stored)
            NotificationCenter.default.post(name: .parakeetVocabularyDidChange, object: nil)
            return self.getCustomWords()
        } catch {
            return LocalAPI.error("Invalid custom words payload: \(error.localizedDescription)", status: 400)
        }
    }

    private func replacementEntries(from payload: ReplacementWriteRequest) throws -> [ReplacementEntry] {
        if payload.hasEntries {
            return payload.entries
        }
        if let singleEntry = payload.singleEntry {
            return [singleEntry]
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "Expected entries or triggers/replacement.")
        )
    }

    private func customWordEntries(from payload: CustomWordsWriteRequest) throws -> [CustomWordEntry] {
        if payload.hasEntries {
            return payload.entries
        }
        if let singleEntry = payload.singleEntry {
            return [singleEntry]
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "Expected entries or text.")
        )
    }

    private static func apiEntry(from entry: SettingsStore.CustomDictionaryEntry) -> ReplacementEntry {
        ReplacementEntry(id: entry.id, triggers: entry.triggers, replacement: entry.replacement)
    }

    private static func storeEntry(from entry: ReplacementEntry) -> SettingsStore.CustomDictionaryEntry {
        if let id = entry.id {
            return SettingsStore.CustomDictionaryEntry(id: id, triggers: entry.triggers, replacement: entry.replacement)
        }
        return SettingsStore.CustomDictionaryEntry(triggers: entry.triggers, replacement: entry.replacement)
    }

    private static func apiEntry(from term: ParakeetVocabularyStore.VocabularyConfig.Term) -> CustomWordEntry {
        CustomWordEntry(text: term.text, weight: term.weight, aliases: term.aliases)
    }

    private static func storeEntry(from entry: CustomWordEntry) -> ParakeetVocabularyStore.VocabularyConfig.Term {
        ParakeetVocabularyStore.VocabularyConfig.Term(
            text: entry.text,
            weight: entry.weight,
            aliases: entry.aliases
        )
    }
}
