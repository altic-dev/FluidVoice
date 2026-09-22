import Foundation

@main
struct CommandMarkdownParserTests {
    static func main() {
        let parsed = CommandMarkdownParser.parse("# Heading\n\nA **bold** sentence with `code`.\n\n- First\n  - Nested\n2. Second\n\n> Quote\n> continued\n\n---")
        precondition(parsed.count == 7, "Headings, paragraphs, lists, quotes and rules must remain separate blocks")
        guard case let .heading(heading, level) = parsed[0].content else { preconditionFailure("Missing heading") }
        precondition(level == 1 && String(heading.characters) == "Heading")
        guard case let .paragraph(paragraph) = parsed[1].content else { preconditionFailure("Missing paragraph") }
        precondition(String(paragraph.characters) == "A bold sentence with code.")
        precondition(paragraph.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        precondition(paragraph.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        guard case let .listItem(_, marker, depth) = parsed[3].content else { preconditionFailure("Missing nested item") }
        precondition(marker == "•" && depth == 1)
        guard case let .listItem(_, orderedMarker, _) = parsed[4].content else { preconditionFailure("Missing ordered item") }
        precondition(orderedMarker == "2.")
        guard case let .quote(quote) = parsed[5].content else { preconditionFailure("Missing quote") }
        precondition(String(quote.characters) == "Quote\ncontinued")

        let fenced = CommandMarkdownParser.parse("```swift\nlet value = 1\n# literal heading\n```\n\nAfter")
        precondition(fenced.count == 2)
        guard case let .code(code, language) = fenced[0].content else { preconditionFailure("Missing fenced code") }
        precondition(code == "let value = 1\n# literal heading" && language == "swift")
        let windowsFence = CommandMarkdownParser.parse("```text\r\none\r\ntwo\r\n```")
        guard case let .code(windowsCode, _) = windowsFence.first?.content else { preconditionFailure("Missing CRLF code") }
        precondition(windowsCode == "one\ntwo", "CRLF must not introduce empty code lines")
        let unfinished = CommandMarkdownParser.parse("~~~json\n{\"streaming\": true")
        guard case let .code(partial, _) = unfinished.first?.content else { preconditionFailure("Partial streaming fence disappeared") }
        precondition(partial == "{\"streaming\": true")

        let tables = CommandMarkdownParser.parse("| Name | Value |\n| :--- | ---: |\n| `a|b` | yes |\n| escaped\\|pipe | no |")
        guard case let .table(headers, rows) = tables.first?.content else { preconditionFailure("Missing table") }
        precondition(headers.count == 2 && rows.count == 2)
        precondition(String(rows[0][0].characters) == "a|b")
        precondition(String(rows[1][0].characters) == "escaped|pipe")
        let nestedCode = CommandMarkdownParser.parse("| Name | Value |\n| --- | --- |\n| ``a|`b`` | yes |")
        guard case let .table(_, codeRows) = nestedCode.first?.content else { preconditionFailure("Missing code span table") }
        precondition(codeRows.count == 1 && String(codeRows[0][0].characters) == "a|`b")
        let longTable = "| a | b |\n| --- | --- |\n" + Array(repeating: "| x | y |", count: 105).joined(separator: "\n")
        let bounded = CommandMarkdownParser.parse(longTable)
        guard case let .table(_, boundedRows) = bounded.first?.content else { preconditionFailure("Missing bounded table") }
        precondition(boundedRows.count == 100 && bounded.count > 1, "Overflow rows must remain visible below the bounded table")
        precondition(CommandMarkdownParser.parse("").isEmpty)
        let literal = CommandMarkdownParser.parse("#not-heading\n2.not-list\n日本語 👨‍👩‍👧‍👦")
        guard case let .paragraph(value) = literal.first?.content else { preconditionFailure("Literal text misclassified") }
        precondition(String(value.characters) == "#not-heading\n2.not-list\n日本語 👨‍👩‍👧‍👦")

        let terminal = CommandToolOutput.parse("{\"success\":true,\"output\":\"hello\",\"executionTimeMs\":32}")
        precondition(terminal.success == true && terminal.output == "hello" && terminal.executionTime == 32)
        let error = CommandToolOutput.parse("{\"success\":false,\"output\":\"\",\"error\":\"Permission denied\"}")
        precondition(error.success == false && error.error == "Permission denied")
        let unknown = "{\"new_tool_result\": [1, 2, 3]}"
        precondition(CommandToolOutput.parse(unknown).output == unknown, "Unknown result formats must remain inspectable")
        precondition(CommandToolOutput.parse("plain legacy output").output == "plain legacy output")
        print("PASS: markdown structure, inline styles, nested lists, partial code fences, escaped table cells, bounded tables, Unicode, empty input, and legacy/unknown tool results")
    }
}
