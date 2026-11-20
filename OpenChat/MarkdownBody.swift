import SwiftUI

struct MarkdownBody: View {
    let content: String
    let streaming: Bool
    @State private var blocks: [MarkdownBlock] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(blocks) { block in MarkdownBlockView(block: block).equatable() }
        }
        .font(ChatAppearance.body)
        .onChange(of: content, initial: true) { blocks = MarkdownDocument.parse(content) }
        .environment(\.openURL, OpenURLAction { url in
            ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
    }
}
private struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    var body: some View {
        switch block.kind {
        case .paragraph:
            SelectableText(text: inline(block.text))
        case .heading(let level):
            Text(inline(block.text)).font(level == 1 ? .title2.bold() : ChatAppearance.headline).textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
        case .code(let language):
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(language.isEmpty ? "Code" : language).font(ChatAppearance.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy code", systemImage: "doc.on.doc") { Clipboard.copy(block.text) }.font(ChatAppearance.caption)
                }
                ScrollView(.horizontal) {
                    Text(CodeHighlighter.highlight(block.text, language: language))
                        .font(ChatAppearance.code).textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
                }
            }.padding(14).background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
        case .quote:
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(.indigo.opacity(0.5)).frame(width: 3)
                SelectableText(text: inline(block.text))
            }.fixedSize(horizontal: false, vertical: true)
        case .list(let marker):
            HStack(alignment: .top, spacing: 10) {
                Text(marker).foregroundStyle(.secondary).frame(minWidth: 18, alignment: .trailing)
                SelectableText(text: inline(block.text))
            }
        case .rule:
            Divider()
        case .table:
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 12) {
                    ForEach(block.rows) { row in
                        GridRow {
                            ForEach(row.cells) { cell in
                                Text(inline(cell.text)).fontWeight(row.id == block.rows.first?.id ? .semibold : .regular)
                                    .textSelection(.enabled).frame(maxWidth: 320, alignment: .leading)
                            }
                        }
                    }
                }.padding(14)
            }.background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 10))
        }
    }
    private func inline(_ text: String) -> AttributedString {
        var value = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in value.runs {
            if let link = run.link, !["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") { value[run.range].link = nil }
        }
        return value
    }
}

enum CodeHighlighter {
    /// Small, bounded lexical highlighting. Unknown languages remain plain text.
    static func highlight(_ source: String, language: String) -> AttributedString {
        var value = AttributedString(source)
        let known = ["swift", "javascript", "js", "typescript", "ts", "jsx", "tsx", "python", "py", "json", "bash", "sh", "c", "cpp", "java", "rust", "go", "sql"]
        guard known.contains(language.lowercased()), source.utf16.count < 100_000 else { return value }
        let patterns: [(String, Color)] = [
            (#"\b(?:let|var|const|func|function|class|struct|enum|import|from|def|return|if|else|for|while|try|catch|throw|throws|async|await|public|private|static|final|true|false|null|nil|None|True|False|SELECT|FROM|WHERE|INSERT|UPDATE|DELETE)\b"#, .purple),
            (#"\b\d+(?:\.\d+)?\b"#, .orange),
            (#"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, .green),
            (#"//[^\n]*|(?m)^\s*#[^\n]*"#, .secondary),
        ]
        for (pattern, color) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                guard let range = Range(match.range, in: source),
                      let lower = AttributedString.Index(range.lowerBound, within: value),
                      let upper = AttributedString.Index(range.upperBound, within: value) else { continue }
                value[lower..<upper].foregroundColor = color
            }
        }
        return value
    }
}
