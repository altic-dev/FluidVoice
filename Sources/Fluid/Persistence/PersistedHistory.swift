//
//  PersistedHistory.swift
//  Fluid
//
//  Loading for history saved as one JSON array in UserDefaults.
//

import Foundation

enum PersistedHistory {
    /// Decodes each saved element on its own, so one element this build cannot read is
    /// skipped instead of emptying the whole list. Returns nil when the data is not a JSON array.
    static func decode<Entry: Decodable>(_: Entry.Type, from data: Data) -> (entries: [Entry], skipped: Int)? {
        guard let elements = try? JSONDecoder().decode([DecodedElement<Entry>].self, from: data) else {
            return nil
        }
        let entries = elements.compactMap(\.value)
        return (entries, elements.count - entries.count)
    }

    /// One array element, or nil when that element alone fails to decode.
    private struct DecodedElement<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            self.value = try? decoder.singleValueContainer().decode(Value.self)
        }
    }
}
