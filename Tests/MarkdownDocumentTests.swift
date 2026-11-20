import XCTest
@testable import OpenChat

final class MarkdownDocumentTests: XCTestCase {
    func testStreamingFencePreservesItsIdentityAsCodeArrives() {
        let partial = MarkdownDocument.parse("# Heading\n\n```swift\nlet a")
        let complete = MarkdownDocument.parse("# Heading\n\n```swift\nlet answer = 42\n```\n\nAfter")
        XCTAssertEqual(partial[1].id, complete[1].id)
        XCTAssertEqual(complete[1].kind, .code("swift"))
        XCTAssertEqual(complete[1].text, "let answer = 42")
        XCTAssertEqual(complete.last?.text, "After")
    }
    func testTablesKeepEscapedPipesInsideCells() {
        let blocks = MarkdownDocument.parse("| Name | Value |\n| --- | --- |\n| A\\|B | **bold** |")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .table)
        XCTAssertEqual(blocks[0].rows[1].cells.map(\.text), ["A|B", "**bold**"])
    }
    func testListsQuotesAndHeadingsBecomeDistinctBlocks() {
        let blocks = MarkdownDocument.parse("## Title\n\n- [x] Done\n1. Next\n\n> Quoted\n> more")
        XCTAssertEqual(blocks.map(\.kind), [.heading(2), .list("☑"), .list("1."), .quote])
        XCTAssertEqual(blocks.last?.text, "Quoted\nmore")
    }
    func testFenceCanContainShorterBacktickRuns() {
        let blocks = MarkdownDocument.parse("````text\n```\ninside\n````")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].text, "```\ninside")
    }
}
