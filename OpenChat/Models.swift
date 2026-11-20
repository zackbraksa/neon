import Foundation

struct Message: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant }
    enum Status: String, Codable { case sending, queued, complete, streaming, stopped, failed }
    var id = UUID()
    var role: Role
    var content: String
    var status: Status = .complete
    var model: String? = nil
    var jobID: UUID? = nil
    var failure: String? = nil
    var responseModel: String? = nil
    var inputTokens: Int? = nil
    var outputTokens: Int? = nil
    var totalTokens: Int? = nil
    var costUSD: Double? = nil
    var reasoningEffort: ReasoningEffort? = nil
    var images: [String]? = nil
    var responseMetadata: ResponseMetadata {
        ResponseMetadata(responseModel: responseModel, inputTokens: inputTokens, outputTokens: outputTokens, totalTokens: totalTokens, costUSD: costUSD)
    }
    mutating func applyMetadata(_ value: ResponseMetadata) {
        if let model = value.responseModel { responseModel = model }
        if let value = value.inputTokens { inputTokens = value }
        if let value = value.outputTokens { outputTokens = value }
        if let value = value.totalTokens { totalTokens = value }
        if let value = value.costUSD { costUSD = value }
    }
}

struct Conversation: Codable, Identifiable {
    var id = UUID()
    var title = "New conversation"
    var model = "openrouter/auto"
    var reasoningEffort: ReasoningEffort? = nil
    var messages: [Message] = []
    var draft = ""
    var draftImages: [String]? = nil
    var updated = Date()
    var serverThread: Bool? = nil
    var serverRevision: Int? = nil
    var paused: Bool? = nil
    var pinned: Bool? = nil
    var isPinned: Bool { pinned ?? false }
    var archived: Bool? = nil
    var isArchived: Bool { archived ?? false }

    var requestMessages: [WireMessage] {
        messages.filter { $0.status != .queued && (!$0.content.isEmpty || !($0.images ?? []).isEmpty) }
            .map { WireMessage(role: $0.role.rawValue, content: $0.content, images: $0.images) }
    }
    mutating func enqueue(_ text: String, prioritize: Bool = false, model: String? = nil, reasoningEffort: ReasoningEffort? = nil, images: [String]? = nil) {
        let message = Message(role: .user, content: text, status: .queued, model: model, reasoningEffort: reasoningEffort, images: images)
        if prioritize, let i = messages.firstIndex(where: { $0.status == .queued }) {
            messages.insert(message, at: i)
        } else { messages.append(message) }
    }
    mutating func insertResponse(_ response: Message) {
        // Pending follow-ups must stay AFTER the current response in history.
        let index = messages.firstIndex(where: { $0.status == .queued }) ?? messages.endIndex
        messages.insert(response, at: index)
    }
    mutating func recover() {
        for i in messages.indices where messages[i].status == .streaming {
            messages[i].status = .stopped
        }
    }
}

struct WireMessage: Codable, Equatable {
    let role: String
    let content: String
    var images: [String]? = nil
    private enum CodingKeys: String, CodingKey { case role, content }
    private struct Part: Encodable {
        let type: String
        var text: String? = nil
        var image_url: ImageURL? = nil
        struct ImageURL: Encodable { let url: String }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(role, forKey: .role)
        guard let images, !images.isEmpty else {
            try values.encode(content, forKey: .content)
            return
        }
        var parts = content.isEmpty ? [] : [Part(type: "text", text: content)]
        parts += images.map { Part(type: "image_url", image_url: .init(url: $0)) }
        try values.encode(parts, forKey: .content)
    }
}
enum ReasoningEffort: String, Codable, CaseIterable, Identifiable {
    case none, minimal, low, medium, high, xhigh, max
    var id: String { rawValue }
    var title: String {
        switch self {
        case .xhigh: "Extra high"
        default: rawValue.capitalized
        }
    }
}
struct RouterModel: Decodable, Identifiable {
    let id: String
    let name: String
    var reasoningEfforts: [ReasoningEffort] = []
    init(id: String, name: String, reasoningEfforts: [ReasoningEffort] = []) {
        self.id = id; self.name = name; self.reasoningEfforts = reasoningEfforts
    }
    private enum CodingKeys: String, CodingKey { case id, name, reasoning }
    private struct Reasoning: Decodable {
        let efforts: [ReasoningEffort]
        private enum CodingKeys: String, CodingKey { case supportedEfforts = "supported_efforts", mandatory }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let supported: [ReasoningEffort]
            if !values.contains(.supportedEfforts) { supported = [] }
            else if try values.decodeNil(forKey: .supportedEfforts) { supported = ReasoningEffort.allCases }
            else {
                let names = try values.decode([String].self, forKey: .supportedEfforts)
                supported = ReasoningEffort.allCases.filter { names.contains($0.rawValue) }
            }
            let mandatory = try values.decodeIfPresent(Bool.self, forKey: .mandatory) == true
            efforts = supported.filter { !mandatory || $0 != .none }
        }
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        reasoningEfforts = try values.decodeIfPresent(Reasoning.self, forKey: .reasoning)?.efforts ?? []
    }
}

/// Event framing is independent from network chunk boundaries; comments are ignored.
struct SSEParser {
    private var data: [String] = []
    mutating func consume(_ line: String) -> String? {
        if line.isEmpty {
            guard !data.isEmpty else { return nil }
            defer { data.removeAll(keepingCapacity: true) }
            return data.joined(separator: "\n")
        }
        if line.hasPrefix("data:") {
            let value = String(line.dropFirst(5))
            data.append(value.hasPrefix(" ") ? String(value.dropFirst()) : value)
        }
        return nil
    }
}
