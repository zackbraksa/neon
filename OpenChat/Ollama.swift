import Foundation

protocol DirectChatTransport {
    func models() async throws -> [RouterModel]
    func stream(key: String, model: String, messages: [WireMessage], onMetadata: (@MainActor (ResponseMetadata) -> Void)?, onText: @MainActor (String) -> Void) async throws
    func stream(key: String, model: String, messages: [WireMessage], reasoningEffort: ReasoningEffort?, onMetadata: (@MainActor (ResponseMetadata) -> Void)?, onText: @MainActor (String) -> Void) async throws
}

extension DirectChatTransport {
    func stream(key: String, model: String, messages: [WireMessage], reasoningEffort: ReasoningEffort?, onMetadata: (@MainActor (ResponseMetadata) -> Void)?, onText: @MainActor (String) -> Void) async throws {
        guard reasoningEffort == nil else { throw RouterError(message: "This provider does not support reasoning effort.") }
        try await stream(key: key, model: model, messages: messages, onMetadata: onMetadata, onText: onText)
    }
}

extension OpenRouter: DirectChatTransport {}

struct Ollama: DirectChatTransport {
    static let modelPrefix = "ollama://"
    static func isModel(_ id: String) -> Bool { id.hasPrefix(modelPrefix) }
    private let session: URLSession
    private let endpoint = URL(string: "http://localhost:11434")!
    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3600
        self.session = session ?? URLSession(configuration: configuration)
    }
    func models() async throws -> [RouterModel] {
        do {
            let (data, response) = try await session.data(from: endpoint.appendingPathComponent("api/tags"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw RouterError(message: "Ollama could not list installed models. Check that Ollama is running on this Mac.")
            }
            struct Catalog: Decodable {
                struct Model: Decodable { let name: String }
                let models: [Model]
            }
            return try JSONDecoder().decode(Catalog.self, from: data).models
                .map { RouterModel(id: Self.modelPrefix + $0.name, name: $0.name) }.sorted { $0.name < $1.name }
        } catch is CancellationError { throw CancellationError() }
        catch { throw RouterError(message: "Could not connect to Ollama. Start Ollama on this Mac, then refresh models.") }
    }
    func stream(key: String, model: String, messages: [WireMessage], onMetadata: (@MainActor (ResponseMetadata) -> Void)? = nil, onText: @MainActor (String) -> Void) async throws {
        guard messages.allSatisfy({ ($0.images ?? []).isEmpty }) else {
            throw RouterError(message: "Image input is available with OpenRouter. Ollama image input is not supported.")
        }
        struct Body: Encodable { let model: String; let messages: [WireMessage]; let stream = true }
        var request = URLRequest(url: endpoint.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(Body(model: Self.isModel(model) ? String(model.dropFirst(Self.modelPrefix.count)) : model, messages: messages))
        let (bytes, response) = try await session.bytes(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw RouterError(message: "Ollama could not start this response. Check that your selected model is installed.")
        }
        var parser = OllamaStreamParser()
        var line = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            if byte != 10 { line.append(byte); continue }
            if let chunk = try parser.consume(line) {
                if !chunk.text.isEmpty { await onText(chunk.text) }
                if let metadata = chunk.metadata { await onMetadata?(metadata) }
            }
            line.removeAll(keepingCapacity: true)
            if parser.finished { break }
        }
        try Task.checkCancellation()
        if !parser.finished, !line.isEmpty, let chunk = try parser.consume(line) {
            if !chunk.text.isEmpty { await onText(chunk.text) }
            if let metadata = chunk.metadata { await onMetadata?(metadata) }
        }
        guard parser.finished else {
            throw RouterError(message: "Ollama’s connection ended early. Your partial response is saved.")
        }
    }
}

struct OllamaStreamParser {
    struct Output { let text: String; let metadata: ResponseMetadata? }
    private(set) var finished = false
    mutating func consume(_ data: Data) throws -> Output? {
        guard !data.isEmpty else { return nil }
        struct Chunk: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message?
            let done: Bool?
            let error: String?
            let model: String?
            let prompt_eval_count: Int?
            let eval_count: Int?
        }
        let chunk: Chunk
        do { chunk = try JSONDecoder().decode(Chunk.self, from: data) }
        catch { throw RouterError(message: "Ollama returned an invalid response. Your partial response is saved.") }
        guard chunk.error == nil else {
            throw RouterError(message: "Ollama reported a streaming error. Check your model and available memory. Your partial response is saved.")
        }
        finished = chunk.done == true
        let metadata = finished ? ResponseMetadata(responseModel: chunk.model, inputTokens: chunk.prompt_eval_count,
                                                   outputTokens: chunk.eval_count) : nil
        return Output(text: chunk.message?.content ?? "", metadata: metadata)
    }
}
