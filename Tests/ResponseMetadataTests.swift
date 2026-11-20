import XCTest
@testable import OpenChat

private final class MetadataURLProtocol: URLProtocol {
    static var handler: (@Sendable (URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor final class ResponseMetadataTests: XCTestCase {
    func testLegacyAndMalformedMetadataDecodeWithoutInventingUsage() throws {
        let legacy = """
        {"id":"\(UUID())","threadId":"\(UUID())","position":1,"prompt":"Hi","model":"openrouter/auto","status":"complete","content":"Answer","created":1,"updated":2}
        """
        let job = try JSONDecoder().decode(BackendJob.self, from: Data(legacy.utf8))
        XCTAssertNil(job.responseModel); XCTAssertNil(job.totalTokens); XCTAssertNil(job.costUSD)
        var body = try JSONSerialization.jsonObject(with: Data(legacy.utf8)) as! [String: Any]
        body["responseModel"] = ["invalid"]; body["inputTokens"] = -1; body["outputTokens"] = 4
        body["totalTokens"] = 9_007_199_254_740_992 as Int64; body["costUSD"] = "invalid"
        let malformed = try JSONDecoder().decode(BackendJob.self, from: JSONSerialization.data(withJSONObject: body))
        XCTAssertEqual(malformed.content, "Answer"); XCTAssertNil(malformed.responseModel); XCTAssertNil(malformed.inputTokens)
        XCTAssertEqual(malformed.outputTokens, 4); XCTAssertNil(malformed.totalTokens); XCTAssertNil(malformed.costUSD)
        XCTAssertNil(ResponseMetadata(costUSD: .infinity).costUSD)
        XCTAssertNil(ResponseMetadata(responseModel: String(repeating: "m", count: 201)).responseModel)
    }

    func testUsageFormattingAndCacheRoundTripPreserveRequestedAutoModel() throws {
        XCTAssertNil(ResponseMetadata().caption)
        XCTAssertEqual(ResponseMetadata(totalTokens: 12, costUSD: 0.0042).caption, "12 tokens · $0.0042")
        XCTAssertEqual(ResponseMetadata(costUSD: 0).caption, "$0.00")
        XCTAssertEqual(ResponseMetadata(costUSD: 0.0000000001).caption, "<$0.00000001")
        XCTAssertEqual(ResponseMetadata(inputTokens: 2).caption, "2 input tokens")
        XCTAssertEqual(ResponseMetadata(inputTokens: 120).breakdown, "120 input tokens")
        XCTAssertEqual(ResponseMetadata(inputTokens: 120, costUSD: 0.0042).breakdown, "120 input tokens · $0.0042 USD")
        var message = Message(role: .assistant, content: "Answer", model: "openrouter/auto")
        message.applyMetadata(ResponseMetadata(responseModel: "anthropic/claude", inputTokens: 10, outputTokens: 2, totalTokens: 12, costUSD: 0.0042))
        message.applyMetadata(ResponseMetadata())
        XCTAssertTrue(message.responseMetadata.breakdown.contains("10 input tokens"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = try ConversationDisk(directory: directory)
        var chat = Conversation(); chat.messages = [message]; try disk.save(chat)
        let restored = try XCTUnwrap(disk.load().first?.messages.first)
        XCTAssertEqual(restored, message); XCTAssertEqual(restored.model, "openrouter/auto")
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as! [String: Any]
        for key in ["responseModel", "inputTokens", "outputTokens", "totalTokens", "costUSD"] { old.removeValue(forKey: key) }
        XCTAssertNil(try JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: old)).responseMetadata.caption)
    }

    func testDirectStreamParsesMetadataIndependentlyOfResponseText() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MetadataURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { MetadataURLProtocol.handler = nil; session.invalidateAndCancel() }
        let events = """
        data: {"model":"anthropic/claude","choices":[{"delta":{"content":"Hello"}}]}

        data: {"model":"anthropic/claude","choices":[]}

        data: {"model":"anthropic/claude","choices":[]}

        data: {"model":[],"usage":{"prompt_tokens":-1,"completion_tokens":3,"total_tokens":"bad","cost":"bad"},"choices":[{"delta":{"content":" world"},"finish_reason":"stop"}]}

        data: {"usage":{"prompt_tokens":10,"completion_tokens":3,"total_tokens":13,"cost":0.0042},"choices":[]}

        data: [DONE]


        """
        MetadataURLProtocol.handler = { request in
            let stream = request.httpBodyStream
            var data = request.httpBody ?? Data()
            if let stream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 2048); while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) } }
            let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "openrouter/auto"); XCTAssertNil(body["usage"]); XCTAssertNil(body["stream_options"])
            return Data(events.utf8)
        }
        var text = ""; var metadata = Message(role: .assistant, content: ""); var metadataUpdates = 0
        try await OpenRouter(session: session).stream(key: "synthetic-test-key", model: "openrouter/auto", messages: [], onMetadata: { metadata.applyMetadata($0); metadataUpdates += 1 }) { text += $0 }
        XCTAssertEqual(text, "Hello world"); XCTAssertEqual(metadata.responseModel, "anthropic/claude")
        XCTAssertEqual(metadata.inputTokens, 10); XCTAssertEqual(metadata.outputTokens, 3)
        XCTAssertEqual(metadata.totalTokens, 13); XCTAssertEqual(metadata.costUSD, 0.0042)
        XCTAssertEqual(metadataUpdates, 3)
    }

    func testRemoteStatusMetadataUsesJobIdentityAndPersistsToCache() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MetadataURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { MetadataURLProtocol.handler = nil; session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let threadID = UUID(); let jobID = UUID()
        let job: [String: Any] = ["id": jobID.pathID, "threadId": threadID.pathID, "position": 0, "prompt": "Hi", "model": "openrouter/auto", "status": "running", "content": "Answer", "created": 1, "updated": 2]
        let thread: [String: Any] = ["id": threadID.pathID, "title": "Hi", "paused": 0, "created": 1, "revision": 1, "jobs": [job]]
        let snapshot = try JSONSerialization.data(withJSONObject: thread)
        let list = try JSONSerialization.data(withJSONObject: [thread])
        let caps = try JSONSerialization.data(withJSONObject: ["serverId": UUID().pathID, "push": false, "backgroundJobs": true])
        let events = """
        event: status
        data: {"jobId":"\(UUID())","status":"complete","responseModel":"wrong/model","totalTokens":999}

        event: status
        data: {"jobId":"\(jobID)","status":"complete","responseModel":"anthropic/claude","inputTokens":10,"outputTokens":3,"totalTokens":13,"costUSD":0.0042}


        """
        MetadataURLProtocol.handler = { request in
            switch request.url!.path {
            case "/v1/capabilities": return caps
            case "/v1/settings/openrouter-key": return Data("{\"configured\":true}".utf8)
            case "/v1/threads": return list
            case "/v1/threads/\(threadID.pathID)": return snapshot
            default: return Data(events.utf8)
            }
        }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        let store = try RemoteChatStore(client: BackendClient(credentials, session: session), directory: directory)
        store.start()
        for _ in 0..<200 {
            if store.chat(threadID)?.messages.last?.responseModel != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        store.suspend()
        let answer = try XCTUnwrap(store.chat(threadID)?.messages.last)
        XCTAssertEqual(answer.responseModel, "anthropic/claude"); XCTAssertEqual(answer.model, "openrouter/auto")
        XCTAssertEqual(answer.totalTokens, 13); XCTAssertEqual(answer.costUSD, 0.0042)
        XCTAssertEqual(try ConversationDisk(directory: directory, recoverStreaming: false).load().first?.messages.last, answer)
    }
}
