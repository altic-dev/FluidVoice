import Combine
import Foundation
import SwiftUI

/// A small block parser keeps completed replies unchanged while a streaming reply updates.
struct CommandMarkdownBlock: Identifiable, Equatable, Sendable {
    let id: Int
    let content: Content

    enum Content: Equatable, Sendable {
        case paragraph(AttributedString)
        case heading(AttributedString, level: Int)
        case listItem(AttributedString, marker: String, depth: Int)
        case quote(AttributedString)
        case code(String, language: String)
        case table(headers: [AttributedString], rows: [[AttributedString]])
        case divider
    }
}

enum CommandMarkdownParser {
    static func parse(_ text: String) -> [CommandMarkdownBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var result: [CommandMarkdownBlock] = []
        var index = 0

        func append(_ content: CommandMarkdownBlock.Content) {
            result.append(CommandMarkdownBlock(id: result.count, content: content))
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }

            if let fence = fenceOpening(trimmed) {
                index += 1
                var content: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    let prefix = candidate.prefix(while: { $0 == fence.character })
                    if prefix.count >= fence.length, candidate.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces).isEmpty {
                        index += 1
                        break
                    }
                    content.append(lines[index])
                    index += 1
                }
                append(.code(content.joined(separator: "\n"), language: fence.language))
                continue
            }

            if let heading = heading(trimmed) {
                append(.heading(self.inline(heading.text), level: heading.level))
                index += 1
                continue
            }

            if self.isDivider(trimmed) {
                append(.divider)
                index += 1
                continue
            }

            if index + 1 < lines.count,
               let headers = tableCells(line), headers.count > 1, headers.count <= 8,
               let separators = tableCells(lines[index + 1]), separators.count == headers.count,
               separators.allSatisfy(isTableSeparator)
            {
                index += 2
                var rows: [[AttributedString]] = []
                // A table is bounded; any remaining lines are still rendered below it.
                while index < lines.count, rows.count < 100, let cells = tableCells(lines[index]), cells.count == headers.count {
                    rows.append(cells.map(self.inline))
                    index += 1
                }
                append(.table(headers: headers.map(self.inline), rows: rows))
                continue
            }

            if trimmed.hasPrefix(">") {
                var quote: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quote.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                append(.quote(self.inline(quote.joined(separator: "\n"))))
                continue
            }

            if let item = listItem(line) {
                index += 1
                var content = item.text
                while index < lines.count, lines[index].hasPrefix("  "),
                      !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                      self.listItem(lines[index]) == nil, self.fenceOpening(lines[index].trimmingCharacters(in: .whitespaces)) == nil
                {
                    content += "\n" + lines[index].trimmingCharacters(in: .whitespaces)
                    index += 1
                }
                append(.listItem(self.inline(content), marker: item.marker, depth: item.depth))
                continue
            }

            var paragraph = [line]
            index += 1
            while index < lines.count {
                let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                if candidate.isEmpty || heading(candidate) != nil || self.fenceOpening(candidate) != nil ||
                    self.isDivider(candidate) || candidate.hasPrefix(">") || self.listItem(lines[index]) != nil { break }
                if index + 1 < lines.count, let cells = tableCells(lines[index + 1]), cells.allSatisfy(isTableSeparator) { break }
                paragraph.append(lines[index])
                index += 1
            }
            append(.paragraph(self.inline(paragraph.joined(separator: "\n"))))
        }
        return result
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private static func heading(_ text: String) -> (text: String, level: Int)? {
        let prefix = text.prefix(while: { $0 == "#" })
        guard (1...6).contains(prefix.count), text.dropFirst(prefix.count).first?.isWhitespace == true else { return nil }
        return (String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces), prefix.count)
    }

    private static func fenceOpening(_ text: String) -> (character: Character, length: Int, language: String)? {
        guard let character = text.first, character == "`" || character == "~" else { return nil }
        let count = text.prefix(while: { $0 == character }).count
        guard count >= 3 else { return nil }
        let language = text.dropFirst(count).trimmingCharacters(in: .whitespaces)
        guard character != "`" || !language.contains("`") else { return nil }
        return (character, count, String(language.prefix(40)))
    }

    private static func isDivider(_ text: String) -> Bool {
        let characters = text.filter { !$0.isWhitespace }
        guard characters.count >= 3, let first = characters.first, ["-", "*", "_"].contains(first) else { return false }
        return characters.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> (text: String, marker: String, depth: Int)? {
        let indentation = line.prefix(while: \.isWhitespace).count
        let text = line.dropFirst(indentation)
        var marker: String
        var content: Substring
        if let first = text.first, ["-", "*", "+"].contains(first), text.dropFirst().first?.isWhitespace == true {
            marker = "•"
            content = text.dropFirst(2)
        } else {
            let digits = text.prefix(while: \.isNumber)
            let rest = text.dropFirst(digits.count)
            guard !digits.isEmpty, digits.count <= 9, rest.first == "." || rest.first == ")", rest.dropFirst().first?.isWhitespace == true else { return nil }
            marker = String(digits) + "."
            content = rest.dropFirst(2)
        }
        if content.hasPrefix("[ ] ") { marker = "☐"; content = content.dropFirst(4) }
        if content.hasPrefix("[x] ") || content.hasPrefix("[X] ") { marker = "☑"; content = content.dropFirst(4) }
        return (String(content), marker, min(4, indentation / 2))
    }

    // Nil distinguishes a non-table line from a row containing empty cells.
    // swiftlint:disable:next discouraged_optional_collection
    private static func tableCells(_ line: String) -> [String]? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.contains("|") else { return nil }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        var codeFenceLength = 0
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let character = text[cursor]
            text.formIndex(after: &cursor)
            if escaped { cell.append(character); escaped = false; continue }
            if character == "\\" { cell.append(character); escaped = true; continue }
            if character == "`" {
                var count = 1
                while cursor < text.endIndex, text[cursor] == "`" {
                    count += 1
                    text.formIndex(after: &cursor)
                }
                cell += String(repeating: "`", count: count)
                if codeFenceLength == 0 {
                    codeFenceLength = count
                } else if codeFenceLength == count {
                    codeFenceLength = 0
                }
                continue
            }
            if character == "|", codeFenceLength == 0 {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        if text.hasPrefix("|"), cells.first?.isEmpty == true { cells.removeFirst() }
        if text.hasSuffix("|"), cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }

    private static func isTableSeparator(_ text: String) -> Bool {
        let stripped = text.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return stripped.count >= 3 && stripped.allSatisfy { $0 == "-" }
    }
}

@MainActor
private final class CommandMarkdownModel: ObservableObject {
    @Published private(set) var blocks: [CommandMarkdownBlock] = []
    private var requestedText = ""
    private var renderedText: String?
    private var renderingTask: Task<Void, Never>?

    func update(_ text: String) {
        self.requestedText = text
        guard self.renderingTask == nil, self.renderedText != text else { return }
        self.renderingTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let snapshot = self.requestedText
                let parsed = await Task.detached(priority: .userInitiated) { CommandMarkdownParser.parse(snapshot) }.value
                guard !Task.isCancelled else { return }
                self.blocks = parsed
                self.renderedText = snapshot
                // Coalesce arriving tokens into one snapshot instead of reparsing per token.
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                if self.requestedText == snapshot { self.renderingTask = nil; return }
            }
        }
    }

    func stop() {
        self.renderingTask?.cancel()
        self.renderingTask = nil
    }
}

struct CommandMarkdownContent: View {
    let text: String
    @Environment(\.theme) private var theme
    @StateObject private var model = CommandMarkdownModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(self.model.blocks) { block in
                self.blockView(block.content)
            }
        }
        .font(self.theme.typography.body)
        .foregroundStyle(self.theme.palette.primaryText)
        .lineSpacing(5)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { self.model.update(self.text) }
        .onChange(of: self.text) { _, text in self.model.update(text) }
        .onDisappear { self.model.stop() }
    }

    @ViewBuilder
    private func blockView(_ block: CommandMarkdownBlock.Content) -> some View {
        switch block {
        case let .paragraph(text):
            Text(text).fixedSize(horizontal: false, vertical: true)
        case let .heading(text, level):
            Text(text)
                .font(level == 1 ? self.theme.typography.title : (level == 2 ? self.theme.typography.statement.weight(.semibold) : self.theme.typography.sectionTitle))
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
        case let .listItem(text, marker, depth):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(marker).foregroundStyle(self.theme.palette.secondaryText).frame(minWidth: 14, alignment: .trailing)
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 18)
        case let .quote(text):
            HStack(alignment: .top, spacing: 12) {
                Rectangle().fill(self.theme.palette.separator).frame(width: 3)
                Text(text).foregroundStyle(self.theme.palette.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .code(code, language):
            CommandCodeBlock(code: code, language: language)
        case let .table(headers, rows):
            self.table(headers: headers, rows: rows)
        case .divider:
            Divider().padding(.vertical, 4)
        }
    }

    private func table(headers: [AttributedString], rows: [[AttributedString]]) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(headers.indices, id: \.self) { index in
                        self.tableCell(headers[index], heading: true)
                    }
                }
                .background(self.theme.palette.cardBackground)
                ForEach(rows.indices, id: \.self) { index in
                    GridRow {
                        ForEach(rows[index].indices, id: \.self) { column in
                            self.tableCell(rows[index][column], heading: false)
                        }
                    }
                    .overlay(alignment: .top) { Rectangle().fill(self.theme.palette.separator).frame(height: 0.5) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(self.theme.palette.cardBorder, lineWidth: 1) }
        }
    }

    private func tableCell(_ text: AttributedString, heading: Bool) -> some View {
        Text(text)
            .font(heading ? self.theme.typography.bodySmallStrong : self.theme.typography.bodySmall)
            .frame(width: 172, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
    }
}

struct CommandCodeBlock: View {
    let code: String
    var language = ""
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(self.language.isEmpty ? "Code" : self.language)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                Spacer()
                CommandCopyButton(text: self.code, label: "Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Text(verbatim: self.code)
                    .font(.fluidSystem(size: 12, design: .monospaced))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: min(320, CGFloat(self.code.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }) * 19 + 24))
        }
        .background(self.theme.palette.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(self.theme.palette.cardBorder.opacity(0.6), lineWidth: 1) }
    }
}

struct CommandCopyButton: View {
    let text: String
    let label: String
    @State private var copied = false

    var body: some View {
        Button {
            self.copied = ClipboardService.copyToClipboard(self.text)
        } label: {
            Image(systemName: self.copied ? "checkmark" : "doc.on.doc")
                .font(.fluidSystem(size: 11))
                .foregroundStyle(.secondary)
        }
        .fluidGlassAction(circular: true)
        .help(self.copied ? "Copied" : self.label)
        .accessibilityLabel(self.copied ? "Copied" : self.label)
        .task(id: self.copied) {
            guard self.copied else { return }
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            self.copied = false
        }
    }
}
