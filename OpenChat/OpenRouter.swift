import Foundation

struct RouterError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct OpenRouter {
    private let session: URLSession
    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 3600
        self.session = session ?? URLSession(configuration: config)
    }
    func models() async throws -> [RouterModel] {
        let (data, response) = try await session.data(from: URL(string: "https://openrouter.ai/api/v1/models")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw RouterError(message: "Could not load the model catalog. You can enter a model ID manually.")
        }
        struct Catalog: Decodable { let data: [RouterModel] }
        return try JSONDecoder().decode(Catalog.self, from: data).data.sorted { $0.name < $1.name }
    }
    func stream(key: String, model: String, messages: [WireMessage], onMetadata: (@MainActor (ResponseMetadata) -> Void)? = nil, onText: @MainActor (String) -> Void) async throws {
        try await stream(key: key, model: model, messages: messages, reasoningEffort: nil, onMetadata: onMetadata, onText: onText)
    }
    func stream(key: String, model: String, messages: [WireMessage], reasoningEffort: ReasoningEffort?, onMetadata: (@MainActor (ResponseMetadata) -> Void)? = nil, onText: @MainActor (String) -> Void) async throws {
        struct Reasoning: Encodable { let effort: ReasoningEffort }
        struct Request: Encodable { let model: String; let messages: [WireMessage]; let reasoning: Reasoning?; let stream = true }
        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta
                let finish_reason: String?
            }
            struct Failure: Decodable { let message: String }
            let choices: [Choice]?
            let error: Failure?
        }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(Request(model: model, messages: messages, reasoning: reasoningEffort.map { Reasoning(effort: $0) }))
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw RouterError(message: "Invalid server response.") }
        guard (200..<300).contains(http.statusCode) else {
            // Do not echo server bodies, which may contain private prompt content.
            throw RouterError(message: "OpenRouter returned HTTP \(http.statusCode). Check your key, credit, and model access.")
        }
        var parser = SSEParser()
        var finished = false
        var observedMetadata = ResponseMetadata()
        // Frame raw UTF-8 lines ourselves to retain empty SSE event delimiters.
        var lineBytes = Data()
        for try await byte in bytes {
            guard byte == 10 else { lineBytes.append(byte); continue }
            try Task.checkCancellation()
            if lineBytes.last == 13 { lineBytes.removeLast() }
            let line = String(decoding: lineBytes, as: UTF8.self)
            lineBytes.removeAll(keepingCapacity: true)
            guard let event = parser.consume(line) else { continue }
            if event == "[DONE]" { finished = true; break }
            let data = Data(event.utf8)
            let chunk = try JSONDecoder().decode(Chunk.self, from: data)
            if chunk.error != nil { throw RouterError(message: "The provider reported a streaming error. Your partial response is saved.") }
            let metadata = ResponseMetadata.provider(data)
            let mergedMetadata = observedMetadata.merging(metadata)
            if mergedMetadata != observedMetadata {
                observedMetadata = mergedMetadata
                await onMetadata?(mergedMetadata)
            }
            if let choice = chunk.choices?.first {
                if let content = choice.delta.content { await onText(content) }
                if let reason = choice.finish_reason {
                    guard reason != "error" else { throw RouterError(message: "The provider interrupted this response.") }
                    finished = true
                }
            }
        }
        try Task.checkCancellation()
        guard finished else { throw RouterError(message: "The connection ended early. The partial response is saved; you can continue it.") }
    }
}
