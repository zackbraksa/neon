import SwiftUI

struct WelcomeChatView: View {
    let name: String
    let choosePrompt: (String) -> Void
    @State private var suggestions: [Suggestion]

    init(name: String, choosePrompt: @escaping (String) -> Void) {
        self.name = name
        self.choosePrompt = choosePrompt
        _suggestions = State(initialValue: Self.suggestionGroups.compactMap { $0.randomElement() })
    }

    private var greeting: String {
        let first = name.split(whereSeparator: \.isWhitespace).first.map(String.init)
        return first.map { "Hi \($0), let’s get into it." } ?? "Let’s get into it."
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 36)
                    VStack(spacing: 22) {
                        WelcomeBrandMark()
                        Text(greeting).font(ChatAppearance.greeting.weight(.regular)).multilineTextAlignment(.center)
                            .foregroundStyle(Color(white: 0.88)).fixedSize(horizontal: false, vertical: true)
                    }.padding(.horizontal, 24).accessibilityElement(children: .combine)
                    Spacer(minLength: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(suggestions) { suggestion in
                            suggestionButton(suggestion)
                        }
                    }.frame(maxWidth: 620).padding(.horizontal, 24).padding(.bottom, 12)
                }
                .frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height), alignment: .center)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
    }
    private func suggestionButton(_ suggestion: Suggestion) -> some View {
        Button { choosePrompt(suggestion.prompt) } label: {
            HStack(alignment: .center, spacing: 18) {
                Image(systemName: suggestion.icon).font(.system(size: 21, weight: .light)).frame(width: 26).accessibilityHidden(true)
                Text(suggestion.title).font(ChatAppearance.body).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }.foregroundStyle(Color(white: 0.82)).padding(.vertical, 13).frame(minHeight: 48).contentShape(.rect)
        }.buttonStyle(.plain).accessibilityHint("Adds a suggested prompt to the composer for you to edit")
    }

    private struct Suggestion: Identifiable {
        let title: String
        let icon: String
        let prompt: String
        var id: String { title }
    }

    private static let suggestionGroups: [[Suggestion]] = [
        [
            Suggestion(title: "Poke holes in an idea", icon: "scope",
                       prompt: "I have an idea I want to test. Ask me what it is and what I’m trying to achieve, then look for weak assumptions and ways it could fail."),
            Suggestion(title: "Make the case against my plan", icon: "arrow.triangle.branch",
                       prompt: "Help me examine a plan before I commit. Ask me for the plan, my goal and constraints, then make the strongest practical case against it."),
            Suggestion(title: "Test a belief I keep repeating", icon: "questionmark.bubble",
                       prompt: "I want to question a belief I keep repeating. Ask me what it is and why I believe it, then help me separate evidence from assumptions.")
        ],
        [
            Suggestion(title: "Find the smallest next move", icon: "arrow.right.circle",
                       prompt: "Help me find one small step I can take today. Ask what I want to move forward, what is blocking me and how much time I have, then suggest a concrete next move."),
            Suggestion(title: "Untangle a stuck project", icon: "wrench.and.screwdriver",
                       prompt: "A project is stuck. Ask what I’m making, where progress stopped and what I’ve already tried, then help me work out what to tackle next."),
            Suggestion(title: "Turn a rough note into a plan", icon: "list.bullet.clipboard",
                       prompt: "I have a rough note I want to act on. Ask me to share it and explain the outcome I want, then turn it into a short sequence of practical steps.")
        ],
        [
            Suggestion(title: "Take me down a rabbit hole", icon: "binoculars",
                       prompt: "Help me explore a topic I know little about. Ask what has caught my attention lately, then follow one surprising connection at a time."),
            Suggestion(title: "Invent a world with one odd rule", icon: "globe",
                       prompt: "Let’s invent a world built around one unusual rule. Ask me for a setting or mood, suggest three rules, then help me explore how one changes everyday life."),
            Suggestion(title: "Follow a question worth asking", icon: "magnifyingglass",
                       prompt: "I want a question worth exploring. Ask me about something I noticed or couldn’t explain recently, then help me investigate it from a few different angles.")
        ]
    ]

}
