import XCTest
@testable import OpenChat

final class OpenChatTests: XCTestCase {
    func testSSEFraming() {
        var parser = SSEParser()
        XCTAssertNil(parser.consume(": heartbeat"))
        XCTAssertNil(parser.consume(""))
        XCTAssertNil(parser.consume("data: first"))
        XCTAssertNil(parser.consume("data: second"))
        XCTAssertEqual(parser.consume(""), "first\nsecond")
        XCTAssertNil(parser.consume(""))
        XCTAssertNil(parser.consume("data: [DONE]"))
        XCTAssertEqual(parser.consume(""), "[DONE]")
    }
    func testQueuedMessagesCannotLeakIntoCurrentRequestAndMaintainTurnOrder() {
        var chat = Conversation()
        chat.messages = [Message(role: .user, content: "First")]
        chat.enqueue("Second")
        chat.enqueue("Third")
        XCTAssertEqual(chat.requestMessages.map(\.content), ["First"])
        chat.insertResponse(Message(role: .assistant, content: "Answer one"))
        let next = chat.messages.firstIndex { $0.status == .queued }!
        chat.messages[next].status = .complete
        XCTAssertEqual(chat.requestMessages.map(\.content), ["First", "Answer one", "Second"])
        chat.insertResponse(Message(role: .assistant, content: "Answer two"))
        XCTAssertEqual(chat.messages.map(\.content), ["First", "Answer one", "Second", "Answer two", "Third"])
    }
    func testSteeringPrioritizesInstructionWithoutDroppingQueue() {
        var chat = Conversation()
        chat.enqueue("Later")
        chat.enqueue("Steer now", prioritize: true)
        XCTAssertEqual(chat.messages.map(\.content), ["Steer now", "Later"])
    }
    func testRecoveryKeepsPartialAndQueue() throws {
        var chat = Conversation()
        chat.messages = [Message(role: .assistant, content: "Partial", status: .streaming)]
        chat.enqueue("Next")
        var recovered = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(chat))
        recovered.recover()
        XCTAssertEqual(recovered.messages[0].status, .stopped)
        XCTAssertEqual(recovered.messages[0].content, "Partial")
        XCTAssertEqual(recovered.messages[1].status, .queued)
    }
    func testAtomicConversationRoundTripAndDelete() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = try ConversationDisk(directory: directory)
        var first = Conversation()
        first.draft = "Unsent draft"
        first.enqueue("Queued")
        let second = Conversation()
        try disk.save(first)
        try disk.save(second)
        first.title = "Updated"
        try disk.save(first)
        let loaded = try disk.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first { $0.id == first.id }?.draft, "Unsent draft")
        XCTAssertEqual(loaded.first { $0.id == first.id }?.title, "Updated")
        try disk.delete(first.id)
        XCTAssertEqual(try disk.load().map(\.id), [second.id])
    }
}
