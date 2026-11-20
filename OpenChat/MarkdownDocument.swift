import Foundation

/// Stable block IDs are source line positions, preserved as a response grows.
struct MarkdownBlock: Identifiable, Equatable {
    enum Kind: Equatable { case paragraph, heading(Int), code(String), quote, list(String), table, rule }
    let id: Int
    let kind: Kind
    let text: String
    var rows: [MarkdownRow] = []
}
struct MarkdownRow: Identifiable, Equatable {
    let id: Int
    let cells: [MarkdownCell]
}
struct MarkdownCell: Identifiable, Equatable { let id: Int; let text: String }
struct MarkdownDocument {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: "\n")
        var result: [MarkdownBlock] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { index += 1; continue }
            let start = index
            if let fence = fence(line) {
                index += 1
                var content: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.count >= fence.count && candidate.allSatisfy({ $0 == fence.character }) { index += 1; break }
                    content.append(lines[index]); index += 1
                }
                result.append(MarkdownBlock(id: start, kind: .code(fence.language), text: content.joined(separator: "\n")))
            } else if let heading = match("^(#{1,6}) +(.+)$", line) {
                result.append(MarkdownBlock(id: start, kind: .heading(heading[0].count), text: heading[1])); index += 1
            } else if index + 1 < lines.count && line.contains("|") && isTableSeparator(lines[index + 1]) {
                var rows = [row(line, id: index)]
                index += 2
                while index < lines.count && lines[index].contains("|") && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(row(lines[index], id: index)); index += 1
                }
                result.append(MarkdownBlock(id: start, kind: .table, text: "", rows: rows))
            } else if line.hasPrefix(">") {
                var content: [String] = []
                while index < lines.count && lines[index].hasPrefix(">") {
                    content.append(String(lines[index].dropFirst()).trimmingCharacters(in: .whitespaces)); index += 1
                }
                result.append(MarkdownBlock(id: start, kind: .quote, text: content.joined(separator: "\n")))
            } else if let item = match("^\\s*([-+*]|[0-9]+[.)]) +(?:\\[([ xX])\\] +)?(.*)$", line) {
                let marker = item[1].isEmpty ? (item[0].count == 1 ? "•" : item[0]) : (item[1].lowercased() == "x" ? "☑" : "☐")
                result.append(MarkdownBlock(id: start, kind: .list(marker), text: item[2])); index += 1
            } else if ["---", "***", "___"].contains(line.trimmingCharacters(in: .whitespaces)) {
                result.append(MarkdownBlock(id: start, kind: .rule, text: "")); index += 1
            } else {
                var content = [line]; index += 1
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    let next = lines[index]
                    if fence(next) != nil || next.hasPrefix("#") || next.hasPrefix(">") || match("^\\s*([-+*]|[0-9]+[.)]) +(.+)$", next) != nil { break }
                    if index + 1 < lines.count && next.contains("|") && isTableSeparator(lines[index + 1]) { break }
                    content.append(next); index += 1
                }
                result.append(MarkdownBlock(id: start, kind: .paragraph, text: content.joined(separator: "\n")))
            }
        }
        return result
    }
    private static func fence(_ line: String) -> (character: Character, count: Int, language: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let count = trimmed.prefix(while: { $0 == first }).count
        guard count >= 3 else { return nil }
        return (first, count, String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces))
    }
    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
    }
    static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var result: [String] = []; var current = ""; var escaped = false
        for character in trimmed {
            if escaped { current.append(character); escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "|" { result.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
            else { current.append(character) }
        }
        if escaped { current.append("\\") }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }
    private static func isTableSeparator(_ line: String) -> Bool {
        let columns = cells(line)
        return !columns.isEmpty && columns.allSatisfy { $0.range(of: "^:?-{3,}:?$", options: .regularExpression) != nil }
    }
    private static func row(_ line: String, id: Int) -> MarkdownRow {
        MarkdownRow(id: id, cells: cells(line).enumerated().map { MarkdownCell(id: $0.offset, text: $0.element) })
    }
}
