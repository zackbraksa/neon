import XCTest
@testable import OpenChat

final class ConversationDrawerTests: XCTestCase {
    func testPinnedConversationsStayAboveRecencyWithoutDuplication() {
        var oldPinned = Conversation()
        oldPinned.pinned = true
        oldPinned.updated = Date(timeIntervalSince1970: 100)
        var newerPinned = Conversation()
        newerPinned.pinned = true
        newerPinned.updated = Date(timeIntervalSince1970: 200)
        var regular = Conversation()
        regular.updated = Date()
        let sections = ConversationRecency.sections([oldPinned, regular, newerPinned])
        XCTAssertEqual(sections.first?.title, "Pinned")
        XCTAssertEqual(sections.first?.chats.map(\.id), [newerPinned.id, oldPinned.id])
        XCTAssertEqual(sections.flatMap(\.chats).count, 3)
        XCTAssertEqual(sections.dropFirst().flatMap(\.chats).map(\.id), [regular.id])
    }

    func testArchivedGroupingKeepsPinnedChatsInTheirRecencyGroups() {
        var archived = Conversation()
        archived.pinned = true
        archived.updated = Date()
        let sections = ConversationRecency.sections([archived], includePinned: false)
        XCTAssertEqual(sections.map(\.title), ["Today"])
        XCTAssertEqual(sections.flatMap(\.chats).map(\.id), [archived.id])
        XCTAssertEqual(archived.pinned, true)
    }

    func testRecencyUsesLocalCalendarBoundariesAndKeepsNewestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 3600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 10))!
        let start = calendar.startOfDay(for: now)
        var recent = Conversation()
        recent.updated = start.addingTimeInterval(60)
        var midnight = Conversation()
        midnight.updated = start
        var previous = Conversation()
        previous.updated = start.addingTimeInterval(-1)
        var older = Conversation()
        older.updated = calendar.date(byAdding: .day, value: -40, to: start)!
        let sections = ConversationRecency.sections([older, previous, midnight, recent], now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.title), ["Today", "Yesterday", "Older"])
        XCTAssertEqual(sections[0].chats.map(\.id), [recent.id, midnight.id])
        XCTAssertEqual(sections[1].chats.map(\.id), [previous.id])
        XCTAssertTrue(ConversationRecency.sections([], now: now, calendar: calendar).isEmpty)
    }

    func testDrawerSwipesRequireHorizontalIntentAndDistance() {
        XCTAssertTrue(DrawerSwipe.opens(CGSize(width: 100, height: 10)))
        XCTAssertTrue(DrawerSwipe.closes(CGSize(width: -100, height: 10)))
        XCTAssertFalse(DrawerSwipe.opens(CGSize(width: 100, height: 200)))
        XCTAssertFalse(DrawerSwipe.closes(CGSize(width: -100, height: 200)))
        XCTAssertFalse(DrawerSwipe.opens(CGSize(width: 30, height: 0)))
        XCTAssertFalse(DrawerSwipe.closes(CGSize(width: 100, height: 0)))
    }
}
