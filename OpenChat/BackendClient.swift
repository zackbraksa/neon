import Foundation

struct BackendCredentials: Codable, Equatable {
    let url: URL
    let token: String
    var serverID: UUID? = nil
    init(address: String, token: String) throws {
        guard token.trimmingCharacters(in: .whitespacesAndNewlines).count >= 32 else {
            throw RouterError(message: "Enter the server’s owner token (at least 32 characters).")
        }
        self.url = try Self.endpoint(address)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func endpoint(_ address: String) throws -> URL {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else {
            throw RouterError(message: "Use an HTTPS server address, or HTTP on localhost for development.")
        }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let url = parts.url else { throw RouterError(message: "Enter a valid server address.") }
        return url
    }
}
struct BackendFailure: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }

    init(status: Int, message: String? = nil) {
        self.status = status
        if let message {
            self.message = message
            return
        }
        self.message = switch status {
        case 300..<400: "The Neon server redirected the request. Check the server URL in Settings."
        case 401: "Your Neon session was rejected. Reconnect to your server in Settings."
        case 403: "The Neon server blocked access (403). If it requires a private network like Tailscale, connect to it and try again."
        case 408: "The Neon server took too long to respond. Try again."
        case 429: "The Neon server is receiving too many requests. Wait a moment and try again."
        case 500..<600: "The Neon server is having trouble responding. Try again in a moment."
        case 0: "Neon received an unexpected response. Check the server URL and try again."
        default: "Neon couldn’t complete the request (\(status)). Try again."
        }
    }
}
struct BackendCapabilities: Decodable { let push: Bool; let backgroundJobs: Bool; let serverId: UUID; let conversationMetadata: Bool?; let archiveBrowsing: Bool?; let conversationDeletion: Bool?; let reasoningEffort: Bool?; let imageInputs: Bool? }
struct KeyState: Decodable { let configured: Bool }
struct BackendThread: Decodable {
    let id: UUID
    let title: String
    let paused: Int
    let created: Double
    let revision: Int
    let jobs: [BackendJob]?
    let pinned: Int?
    let archived: Int?
}
struct BackendJob: Codable, Identifiable {
    enum Status: String, Codable { case queued, running, complete, stopped, failed }
    let id: UUID
    let threadId: UUID
    let position: Int
    let prompt: String
    let model: String
    var status: Status
    var content: String
    var error: String?
    let created: Double
    var updated: Double
    var responseModel: String? = nil
    var inputTokens: Int? = nil
    var outputTokens: Int? = nil
    var totalTokens: Int? = nil
    var costUSD: Double? = nil
    let reasoningEffort: ReasoningEffort?
    var images: [String]? = nil
    init(id: UUID, threadId: UUID, position: Int, prompt: String, model: String, status: Status, content: String, error: String? = nil, created: Double, updated: Double, responseModel: String? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil, totalTokens: Int? = nil, costUSD: Double? = nil, reasoningEffort: ReasoningEffort? = nil, images: [String]? = nil) {
        self.id = id; self.threadId = threadId; self.position = position; self.prompt = prompt; self.model = model
        self.status = status; self.content = content; self.error = error; self.created = created; self.updated = updated
        self.reasoningEffort = reasoningEffort
        self.images = images
        applyMetadata(ResponseMetadata(responseModel: responseModel, inputTokens: inputTokens, outputTokens: outputTokens, totalTokens: totalTokens, costUSD: costUSD))
    }
    private enum CodingKeys: String, CodingKey { case id, threadId, position, prompt, model, status, content, error, created, updated, responseModel, inputTokens, outputTokens, totalTokens, costUSD, reasoningEffort, images }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(UUID.self, forKey: .id), threadId: try values.decode(UUID.self, forKey: .threadId),
                  position: try values.decode(Int.self, forKey: .position), prompt: try values.decode(String.self, forKey: .prompt),
                  model: try values.decode(String.self, forKey: .model), status: try values.decode(Status.self, forKey: .status),
                  content: try values.decode(String.self, forKey: .content), error: try values.decodeIfPresent(String.self, forKey: .error),
                  created: try values.decode(Double.self, forKey: .created), updated: try values.decode(Double.self, forKey: .updated),
                  reasoningEffort: try values.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort),
                  images: try values.decodeIfPresent([String].self, forKey: .images))
        applyMetadata(try ResponseMetadata(from: decoder))
    }
    mutating func applyMetadata(_ value: ResponseMetadata) {
        if let value = value.responseModel { responseModel = value }
        if let value = value.inputTokens { inputTokens = value }
        if let value = value.outputTokens { outputTokens = value }
        if let value = value.totalTokens { totalTokens = value }
        if let value = value.costUSD { costUSD = value }
    }
    var unfinished: Bool { status == .queued || status == .running }
}
struct PendingSend: Codable, Identifiable {
    var id = UUID()
    let threadID: UUID
    let prompt: String
    let model: String
    let steer: Bool
    var reasoningEffort: ReasoningEffort? = nil
    // A fork is retried using the same two IDs; the server can be queried after 409.
    var sourceThreadID: UUID? = nil
    var targetJobID: UUID? = nil
    var lastError: String? = nil
    var images: [String]? = nil
}
struct NormalMessageBody: Encodable {
    let id: UUID
    let prompt: String
    let model: String
    let steer: Bool
    let reasoningEffort: ReasoningEffort?
    let images: [String]?
    init(_ pending: PendingSend) {
        id = pending.id; prompt = pending.prompt; model = pending.model; steer = pending.steer
        reasoningEffort = pending.reasoningEffort
        images = pending.images.flatMap { $0.isEmpty ? nil : $0 }
    }
}
struct BackendEvent {
    let name: String
    let data: String
}
struct BackendEventParser {
    private var name = "message"
    private var fields: [String] = []
    mutating func consume(_ line: String) -> BackendEvent? {
        if line.isEmpty {
            defer { name = "message"; fields.removeAll(keepingCapacity: true) }
            guard !fields.isEmpty else { return nil }
            return BackendEvent(name: name, data: fields.joined(separator: "\n"))
        }
        if line.hasPrefix("event:") { name = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        if line.hasPrefix("data:") { fields.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
struct BackendDelta: Decodable { let jobId: UUID; let offset: Int; let text: String }
struct BackendStatus: Decodable {
    let jobId: UUID
    let status: BackendJob.Status
    let error: String?
    let metadata: ResponseMetadata
    private enum CodingKeys: String, CodingKey { case jobId, status, error }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try values.decode(UUID.self, forKey: .jobId); status = try values.decode(BackendJob.Status.self, forKey: .status)
        error = try values.decodeIfPresent(String.self, forKey: .error)
        metadata = try ResponseMetadata(from: decoder)
    }
}

final class BackendClient {
    private struct Failure: Decodable { let error: String }
    let credentials: BackendCredentials
    private let session: URLSession
    init(_ credentials: BackendCredentials, session: URLSession? = nil) {
        self.credentials = credentials
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 40
        configuration.timeoutIntervalForResource = 3600
        self.session = session ?? URLSession(configuration: configuration)
    }
    func request(_ path: String, method: String = "GET", body: Data? = nil, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: credentials.url.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        if let server = credentials.serverID { request.setValue(server.pathID, forHTTPHeaderField: "X-OpenChat-Server-ID") }
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await execute(request(path, query: query))
    }
    func send<T: Decodable, Body: Encodable>(_ path: String, method: String = "POST", body: Body) async throws -> T {
        try await execute(request(path, method: method, body: JSONEncoder().encode(body)))
    }
    func command(_ path: String, method: String = "POST") async throws {
        let _: Empty = try await send(path, method: method, body: Empty())
    }
    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw BackendFailure(status: status, message: try? JSONDecoder().decode(Failure.self, from: data).error)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func createThread(_ chat: Conversation, supportsMetadata: Bool = false) async throws {
        struct Body: Encodable { let id: UUID; let title: String; let pinned: Bool? }
        let _: BackendThread = try await send("v1/threads", body: Body(id: chat.id, title: chat.title, pinned: supportsMetadata ? chat.isPinned : nil))
    }
    func submit(_ pending: PendingSend) async throws -> BackendJob {
        if let source = pending.sourceThreadID, let target = pending.targetJobID {
            struct Body: Encodable { let targetJobId: UUID; let threadId: UUID; let jobId: UUID; let prompt: String; let images: [String]? }
            do {
                return try await send("v1/threads/\(source.pathID)/fork", body: Body(targetJobId: target, threadId: pending.threadID, jobId: pending.id, prompt: pending.prompt, images: pending.images))
            } catch let error as BackendFailure where error.status == 409 {
                // Only accept a matching job: an unrelated 409 must not discard an edit.
                let job: BackendJob = try await get("v1/jobs/\(pending.id.pathID)")
                guard job.threadId == pending.threadID && job.prompt == pending.prompt,
                      pending.matchesConfiguration(job) else { throw error }
                return job
            }
        }
        return try await send("v1/threads/\(pending.threadID.pathID)/messages", body: NormalMessageBody(pending))
    }
    func events(job: BackendJob, onEvent: @MainActor (BackendEvent) throws -> Void) async throws {
        var request = request("v1/jobs/\(job.id.pathID)/events")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(String(job.content.utf16.count), forHTTPHeaderField: "Last-Event-ID")
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw BackendFailure(status: status) }
        var parser = BackendEventParser()
        var line = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard byte == 10 else {
                line.append(byte)
                if line.count > 12_000_000 { throw RouterError(message: "Server event exceeded the size limit.") }
                continue
            }
            if line.last == 13 { line.removeLast() }
            let string = String(decoding: line, as: UTF8.self)
            line.removeAll(keepingCapacity: true)
            if let event = parser.consume(string) { try await onEvent(event) }
        }
    }
    struct Empty: Codable {}
}
extension PendingSend {
    func matchesConfiguration(_ job: BackendJob) -> Bool {
        guard (images ?? []) == (job.images ?? []) else { return false }
        // The fork endpoint inherits the target configuration; it accepts no model or effort.
        if sourceThreadID != nil { return true }
        return job.model == model && job.reasoningEffort == reasoningEffort
    }
}
extension UUID { var pathID: String { uuidString.lowercased() } }
