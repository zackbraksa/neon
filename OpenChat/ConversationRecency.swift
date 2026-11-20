import Foundation

enum ConversationRecency {
    struct Section: Identifiable {
        let id: Int
        let title: String
        let chats: [Conversation]
    }

    static func sections(_ chats: [Conversation], includePinned: Bool = true, now: Date = Date(), calendar: Calendar = .current) -> [Section] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let week = calendar.date(byAdding: .day, value: -7, to: today)!
        let month = calendar.date(byAdding: .day, value: -30, to: today)!
        let titles = ["Today", "Yesterday", "Previous 7 days", "Previous 30 days", "Older"]
        let ordered = chats.sorted { $0.updated > $1.updated }
        let pinned = includePinned ? ordered.filter { $0.pinned == true } : []
        let grouped = Dictionary(grouping: ordered.filter { !includePinned || $0.pinned != true }) { chat in
            if chat.updated >= today { return 0 }
            if chat.updated >= yesterday { return 1 }
            if chat.updated >= week { return 2 }
            if chat.updated >= month { return 3 }
            return 4
        }
        let recent = titles.indices.compactMap { index in
            grouped[index].map { Section(id: index, title: titles[index], chats: $0) }
        }
        return (pinned.isEmpty ? [] : [Section(id: -1, title: "Pinned", chats: pinned)]) + recent
    }
}
