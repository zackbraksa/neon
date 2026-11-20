import Foundation

enum SummaryPrompt {
    static func make(_ answer: String) -> String {
        """
        TL;DR of this answer:

        “\(answer)”

        Use up to 3 short bullets in the same language. Keep the key conclusions and important caveats, and add no new information.
        """
    }

    static func validate(_ pending: PendingSend, jobs: [BackendJob]) throws {
        guard pending.prompt.utf16.count <= 100_000,
              try JSONEncoder().encode(NormalMessageBody(pending)).count <= 150_000 else {
            throw RouterError(message: "This answer is too long to summarize. Try a shorter answer.")
        }
        let context = jobs.filter { $0.status == .complete || !$0.content.isEmpty }
            .reduce(0) { $0 + $1.prompt.utf16.count + $1.content.utf16.count }
        guard context + pending.prompt.utf16.count <= 400_000 else {
            throw RouterError(message: "This conversation is too long to summarize. Start a new conversation.")
        }
    }

    static func hasUnfinished(_ prompt: String, messages: [Message]) -> Bool {
        for (index, message) in messages.enumerated() where message.role == .user && message.content == prompt {
            if message.status == .queued || message.status == .sending { return true }
            for response in messages.dropFirst(index + 1) {
                if response.role == .user { break }
                if response.status == .streaming { return true }
            }
        }
        return false
    }
}
