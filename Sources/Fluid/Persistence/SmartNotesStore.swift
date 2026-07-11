import Combine
import Foundation

struct SmartNote: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    var title: String
    var category: String?
    var tags: [String]
    var body: String
    var isAIEnhanced: Bool
    let fileURL: URL
}

struct SmartNoteEnhancement: Decodable, Equatable {
    let title: String
    let category: String
    let tags: [String]
    let body: String

    static func parseAIResponse(_ response: String) throws -> SmartNoteEnhancement {
        guard let openingBrace = response.firstIndex(of: "{"),
              let closingBrace = response.lastIndex(of: "}"),
              openingBrace <= closingBrace
        else {
            throw SmartNotesError.invalidAIResponse
        }

        let json = String(response[openingBrace...closingBrace])
        guard let data = json.data(using: .utf8) else {
            throw SmartNotesError.invalidAIResponse
        }

        do {
            let decoded = try JSONDecoder().decode(Self.self, from: data)
            let title = decoded.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = decoded.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !body.isEmpty else {
                throw SmartNotesError.invalidAIResponse
            }
            return Self(
                title: String(title.prefix(120)),
                category: String(decoded.category.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)),
                tags: Array(decoded.tags
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
                    .uniqued()
                    .prefix(8)),
                body: body
            )
        } catch let error as SmartNotesError {
            throw error
        } catch {
            throw SmartNotesError.invalidAIResponse
        }
    }
}

enum SmartNotesError: LocalizedError {
    case emptyTranscript
    case noteNotFound
    case invalidAIResponse

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "The note transcript was empty."
        case .noteNotFound:
            return "The note could not be found."
        case .invalidAIResponse:
            return "AI returned an invalid note structure."
        }
    }
}

@MainActor
final class SmartNotesStore: ObservableObject {
    static let shared = SmartNotesStore()

    @Published private(set) var notes: [SmartNote] = []

    let notesDirectoryURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.notesDirectoryURL = directoryURL ?? Self.defaultNotesDirectory(fileManager: fileManager)
        self.reload()
    }

    @discardableResult
    func capture(rawText: String, at date: Date = Date(), id: UUID = UUID()) throws -> SmartNote {
        let body = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw SmartNotesError.emptyTranscript }

        try self.ensureDirectoryExists()
        let note = SmartNote(
            id: id,
            createdAt: date,
            title: Self.defaultTitle(for: body),
            category: nil,
            tags: [],
            body: body,
            isAIEnhanced: false,
            fileURL: self.notesDirectoryURL.appendingPathComponent(Self.fileName(for: date, id: id))
        )
        try self.write(note)
        self.reload()
        return note
    }

    @discardableResult
    func apply(_ enhancement: SmartNoteEnhancement, to noteID: UUID) throws -> SmartNote {
        guard var note = self.notes.first(where: { $0.id == noteID }) else {
            throw SmartNotesError.noteNotFound
        }

        note.title = enhancement.title
        note.category = enhancement.category.isEmpty ? nil : enhancement.category
        note.tags = enhancement.tags
        note.body = enhancement.body
        note.isAIEnhanced = true
        try self.write(note)
        self.reload()
        return note
    }

    func delete(_ note: SmartNote) throws {
        try self.fileManager.removeItem(at: note.fileURL)
        self.reload()
    }

    func reload() {
        do {
            try self.ensureDirectoryExists()
            let urls = try self.fileManager.contentsOfDirectory(
                at: self.notesDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            self.notes = urls
                .filter { $0.pathExtension.lowercased() == "md" }
                .compactMap { try? self.read(from: $0) }
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            DebugLogger.shared.error(
                "Unable to load Smart Notes: \(error.localizedDescription)",
                source: "SmartNotesStore"
            )
            self.notes = []
        }
    }

    private static func defaultNotesDirectory(fileManager: FileManager) -> URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        return documents.appendingPathComponent("FluidVoice Notes", isDirectory: true)
    }

    private func ensureDirectoryExists() throws {
        try self.fileManager.createDirectory(
            at: self.notesDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private func write(_ note: SmartNote) throws {
        let contents = try Self.markdown(for: note)
        try contents.write(to: note.fileURL, atomically: true, encoding: .utf8)
    }

    private func read(from url: URL) throws -> SmartNote {
        let contents = try String(contentsOf: url, encoding: .utf8)
        guard contents.hasPrefix("---\n"),
              let closingRange = contents.range(of: "\n---\n", range: contents.index(contents.startIndex, offsetBy: 4)..<contents.endIndex)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let metadataStart = contents.index(contents.startIndex, offsetBy: 4)
        let metadata = Self.parseMetadata(String(contents[metadataStart..<closingRange.lowerBound]))
        guard let idText = metadata["id"],
              let id = UUID(uuidString: idText),
              let createdText = metadata["createdAt"],
              let createdAt = Self.iso8601.date(from: createdText),
              let title = metadata["title"]
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let content = String(contents[closingRange.upperBound...])
        let marker = "<!-- fluidvoice:body -->\n"
        let markedBody = content.components(separatedBy: marker).last ?? content
        let heading = "# \(title)\n\n"
        let body = markedBody.hasPrefix(heading) ? String(markedBody.dropFirst(heading.count)) : markedBody

        return SmartNote(
            id: id,
            createdAt: createdAt,
            title: title,
            category: metadata["category"].flatMap { $0.isEmpty ? nil : $0 },
            tags: Self.decodeTags(metadata["tags"]),
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            isAIEnhanced: metadata["enhanced"] == "true",
            fileURL: url
        )
    }

    private static func markdown(for note: SmartNote) throws -> String {
        let id = try self.json(note.id.uuidString)
        let createdAt = try self.json(self.iso8601.string(from: note.createdAt))
        let title = try self.json(note.title)
        let category = try self.json(note.category ?? "")
        let tags = try self.json(note.tags)
        return """
        ---
        id: \(id)
        createdAt: \(createdAt)
        title: \(title)
        category: \(category)
        tags: \(tags)
        enhanced: \(note.isAIEnhanced)
        ---
        <!-- fluidvoice:body -->
        # \(note.title)

        \(note.body)
        """
    }

    private static func parseMetadata(_ text: String) -> [String: String] {
        text.split(separator: "\n").reduce(into: [:]) { result, line in
            guard let separator = line.firstIndex(of: ":") else { return }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if let data = value.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(String.self, from: data)
            {
                result[key] = decoded
            } else {
                result[key] = value
            }
        }
    }

    private static func decodeTags(_ value: String?) -> [String] {
        guard let value, let data = value.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func defaultTitle(for text: String) -> String {
        let words = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
        let title = words.prefix(9).joined(separator: " ")
        if title.count <= 72 { return title }
        return String(title.prefix(69)) + "..."
    }

    private static func fileName(for date: Date, id: UUID) -> String {
        "\(self.fileNameDate.string(from: date))-\(id.uuidString.prefix(8).lowercased()).md"
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let fileNameDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return self.filter { seen.insert($0).inserted }
    }
}
