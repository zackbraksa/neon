import XCTest
@testable import OpenChat

private final class StubURLProtocol: URLProtocol {
    static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    static var deferResponse: ((URLRequest, @escaping () -> Void) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            let finish = { [self] in
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
            if let deferResponse = Self.deferResponse { deferResponse(request, finish) }
            else { finish() }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private struct ReasoningCatalogTransport: DirectChatTransport {
    let catalog: [RouterModel]?
    func models() async throws -> [RouterModel] {
        guard let catalog else { throw RouterError(message: "Catalog unavailable") }
        return catalog
    }
    func stream(key: String, model: String, messages: [WireMessage], onMetadata: (@MainActor (ResponseMetadata) -> Void)?, onText: @MainActor (String) -> Void) async throws {
        throw RouterError(message: "No generation expected")
    }
}

@MainActor private final class StartupCatalogTransport: DirectChatTransport {
    var requests = 0
    var failuresRemaining = 0
    let catalog = [RouterModel(id: "anthropic/claude-opus-5.5", name: "Claude Opus 5.5", reasoningEfforts: [.low, .high, .max])]
    func models() async throws -> [RouterModel] {
        requests += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw RouterError(message: "Catalog unavailable")
        }
        return catalog
    }
    func stream(key: String, model: String, messages: [WireMessage], onMetadata: (@MainActor (ResponseMetadata) -> Void)?, onText: @MainActor (String) -> Void) async throws {
        throw RouterError(message: "No generation expected")
    }
}

@MainActor final class BackendClientTests: XCTestCase {
    func testActivationLoadsEffortsForSavedModelWithoutOpeningPicker() async throws {
        let (facade, remote, transport, directory, session) = try startupCatalogFixture()
        defer { facade.background(); session.invalidateAndCancel(); StubURLProtocol.handler = nil; try? FileManager.default.removeItem(at: directory) }
        let id = try XCTUnwrap(facade.selectedID)
        XCTAssertTrue(facade.models.isEmpty)
        facade.activate()
        facade.activate()
        await eventually { facade.reasoningEfforts(for: id) == [.low, .high, .max] }
        XCTAssertEqual(transport.requests, 1)
        XCTAssertEqual(remote.chat(id)?.model, "anthropic/claude-opus-5.5")
        facade.background(); facade.activate()
        await eventually { remote.connectionStatus == "Synced" }
        XCTAssertEqual(transport.requests, 1)
    }

    func testActivationRetriesCatalogAfterInitialFailure() async throws {
        let (facade, _, transport, directory, session) = try startupCatalogFixture()
        defer { facade.background(); session.invalidateAndCancel(); StubURLProtocol.handler = nil; try? FileManager.default.removeItem(at: directory) }
        let id = try XCTUnwrap(facade.selectedID)
        transport.failuresRemaining = 1
        facade.activate()
        await eventually { facade.openRouterCatalogError != nil }
        XCTAssertTrue(facade.reasoningEfforts(for: id).isEmpty)
        facade.background(); facade.activate()
        await eventually { facade.reasoningEfforts(for: id) == [.low, .high, .max] }
        XCTAssertEqual(transport.requests, 2)
        XCTAssertNil(facade.openRouterCatalogError)
    }

    private func startupCatalogFixture() throws -> (ChatStore, RemoteChatStore, StartupCatalogTransport, URL, URLSession) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let caps = try JSONSerialization.data(withJSONObject: ["serverId": UUID().pathID, "push": false, "backgroundJobs": true, "reasoningEffort": true])
        StubURLProtocol.handler = { request in
            switch request.url!.path {
            case "/v1/capabilities": return (200, caps)
            case "/v1/settings/openrouter-key": return (200, Data("{\"configured\":true}".utf8))
            default: return (200, Data("[]".utf8))
            }
        }
        let transport = StartupCatalogTransport()
        let direct = DirectChatStore(storage: try ConversationDisk(directory: directory.appendingPathComponent("catalog")), readKey: { "" }, router: transport)
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        let remote = try RemoteChatStore(client: BackendClient(credentials, session: session), directory: directory.appendingPathComponent("remote"))
        remote.newChat(); let id = try XCTUnwrap(remote.selectedID)
        remote.update(id) { $0.model = "anthropic/claude-opus-5.5" }
        let sessions = FakeBackendSessionStorage()
        let facade = ChatStore(direct: direct, remote: remote, sessions: sessions, push: sessions.pushCoordinator())
        return (facade, remote, transport, directory, session)
    }

    func testCatalogFailurePreservesChoiceAndPreventsStaleSubmissionUntilDefaultIsChosen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let direct = DirectChatStore(storage: try ConversationDisk(directory: directory.appendingPathComponent("catalog")), readKey: { "" }, router: ReasoningCatalogTransport(catalog: nil))
        direct.models = [RouterModel(id: "model", name: "Model", reasoningEfforts: [.low, .high])]
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        let remote = try RemoteChatStore(client: BackendClient(credentials), directory: directory.appendingPathComponent("remote"))
        remote.supportsReasoningEffort = true
        remote.newChat(); let id = try XCTUnwrap(remote.selectedID)
        remote.update(id) { $0.model = "model" }
        let sessions = FakeBackendSessionStorage()
        let facade = ChatStore(direct: direct, remote: remote, sessions: sessions, push: sessions.pushCoordinator())
        XCTAssertEqual(facade.reasoningEfforts(for: id), [.low, .high])
        facade.chooseReasoningEffort(.high, for: id)
        facade.setDraft(id, text: "Keep my prompt")
        await facade.loadModels()
        XCTAssertEqual(remote.chat(id)?.reasoningEffort, .high)
        XCTAssertTrue(facade.reasoningEfforts(for: id).isEmpty)
        facade.send(id)
        XCTAssertEqual(remote.chat(id)?.draft, "Keep my prompt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("remote/outbox.data").path))
        facade.chooseReasoningEffort(nil, for: id)
        facade.send(id)
        let pending = try JSONDecoder().decode([PendingSend].self, from: Data(contentsOf: directory.appendingPathComponent("remote/outbox.data")))
        XCTAssertNil(pending.first?.reasoningEffort); XCTAssertEqual(pending.first?.prompt, "Keep my prompt")
        remote.suspend()
    }

    func testSuccessfulCatalogRefreshClearsInvalidChoiceWithoutCapabilityDependency() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = [RouterModel(id: "model", name: "Model", reasoningEfforts: [.low])]
        let direct = DirectChatStore(storage: try ConversationDisk(directory: directory.appendingPathComponent("catalog")), readKey: { "" }, router: ReasoningCatalogTransport(catalog: catalog))
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        let remote = try RemoteChatStore(client: BackendClient(credentials), directory: directory.appendingPathComponent("remote"))
        remote.newChat(); let id = try XCTUnwrap(remote.selectedID)
        remote.update(id) { $0.model = "model" }
        remote.update(id) { $0.reasoningEffort = .high }
        let sessions = FakeBackendSessionStorage()
        let facade = ChatStore(direct: direct, remote: remote, sessions: sessions, push: sessions.pushCoordinator())
        await facade.loadModels()
        XCTAssertNil(remote.chat(id)?.reasoningEffort)
        XCTAssertTrue(facade.reasoningEfforts(for: id).isEmpty)
        remote.supportsReasoningEffort = true
        XCTAssertEqual(facade.reasoningEfforts(for: id), [.low])
        facade.chooseReasoningEffort(.low, for: id)
        remote.supportsReasoningEffort = false
        XCTAssertTrue(facade.reasoningEfforts(for: id).isEmpty)
        XCTAssertEqual(remote.chat(id)?.reasoningEffort, .low)
        facade.chooseReasoningEffort(nil, for: id)
        XCTAssertNil(remote.chat(id)?.reasoningEffort)
        remote.suspend()
    }

    func testCatalogReasoningOptionsRequireDeclaredMetadata() throws {
        func options(_ reasoning: String?) throws -> [ReasoningEffort] {
            let field = reasoning.map { ",\"reasoning\":\($0)" } ?? ""
            let json = "{\"id\":\"provider/model\",\"name\":\"Model\"\(field)}"
            return try JSONDecoder().decode(RouterModel.self, from: Data(json.utf8)).reasoningEfforts
        }
        XCTAssertEqual(try options(nil), [])
        XCTAssertEqual(try options("null"), [])
        XCTAssertEqual(try options("{}"), [])
        XCTAssertEqual(try options("{\"supported_efforts\":null}"), ReasoningEffort.allCases)
        XCTAssertEqual(try options("{\"supported_efforts\":[\"high\",\"low\",\"future\",\"low\"]}"), [.low, .high])
        XCTAssertEqual(try options("{\"supported_efforts\":[\"none\",\"high\"],\"mandatory\":true}"), [.high])
        XCTAssertEqual(try options("{\"supported_efforts\":null,\"mandatory\":true}"), ReasoningEffort.allCases.filter { $0 != .none })
    }

    func testLegacyStoredAndServerObjectsDecodeWithoutEffort() throws {
        let chat = Conversation()
        XCTAssertNil(try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(chat)).reasoningEffort)
        let pending = PendingSend(threadID: chat.id, prompt: "Old send", model: "old", steer: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(pending)) as? [String: Any])
        let decoded = try JSONDecoder().decode(PendingSend.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.reasoningEffort)
        let job = BackendJob(id: pending.id, threadId: chat.id, position: 0, prompt: pending.prompt, model: "old", status: .queued, content: "", created: 1, updated: 1)
        XCTAssertNil(try JSONDecoder().decode(BackendJob.self, from: JSONEncoder().encode(job)).reasoningEffort)
        let caps = "{\"serverId\":\"\(UUID().uuidString)\",\"push\":false,\"backgroundJobs\":true}"
        XCTAssertNil(try JSONDecoder().decode(BackendCapabilities.self, from: Data(caps.utf8)).reasoningEffort)
    }

    func testNormalMessageBodyOmitsDefaultAndSerializesExplicitEffort() throws {
        var pending = PendingSend(threadID: UUID(), prompt: "Question", model: "model", steer: true)
        func body() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(NormalMessageBody(pending))) as? [String: Any])
        }
        XCTAssertNil(try body()["reasoningEffort"])
        pending.reasoningEffort = ReasoningEffort.none
        XCTAssertEqual(try body()["reasoningEffort"] as? String, "none")
        pending.reasoningEffort = .max
        XCTAssertEqual(try body()["reasoningEffort"] as? String, "max")
        XCTAssertEqual(try body().count, 5)
    }

    func testPendingEffortSurvivesModelChangeAndRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        let store = try RemoteChatStore(client: BackendClient(credentials), directory: directory)
        store.newChat(); let id = try XCTUnwrap(store.selectedID)
        store.update(id) { $0.model = "first" }
        store.update(id) { $0.reasoningEffort = .high; $0.draft = "Immutable request" }
        store.enqueue(id)
        store.update(id) { $0.model = "second" }
        XCTAssertNil(store.chat(id)?.reasoningEffort)
        let url = directory.appendingPathComponent("outbox.data")
        let pending = try XCTUnwrap(JSONDecoder().decode([PendingSend].self, from: Data(contentsOf: url)).first)
        XCTAssertEqual(pending.model, "first"); XCTAssertEqual(pending.reasoningEffort, .high)
        store.suspend()
        let restored = try RemoteChatStore(client: BackendClient(credentials), directory: directory)
        await restored.retryPending()
        XCTAssertEqual(restored.chat(id)?.messages.first?.model, "first")
        XCTAssertEqual(restored.chat(id)?.messages.first?.reasoningEffort, .high)
        XCTAssertEqual(try JSONDecoder().decode([PendingSend].self, from: Data(contentsOf: url)).first?.id, pending.id)
        restored.suspend()
    }

    func testOldBackendRejectsDurableExplicitEffortBeforeAnyPost() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { StubURLProtocol.handler = nil; try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        let store = try RemoteChatStore(client: BackendClient(credentials, session: session), directory: directory)
        store.newChat(); let id = try XCTUnwrap(store.selectedID)
        store.update(id) { $0.reasoningEffort = .high; $0.draft = "Keep effort" }
        store.enqueue(id)
        let caps = try JSONSerialization.data(withJSONObject: ["serverId": UUID().pathID, "push": false, "backgroundJobs": true])
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET", "No thread creation or generation on an incompatible backend")
            switch request.url!.path {
            case "/v1/capabilities": return (200, caps)
            case "/v1/settings/openrouter-key": return (200, Data("{\"configured\":true}".utf8))
            case "/v1/threads": return (200, Data("[]".utf8))
            default: XCTFail("Unexpected request"); return (500, Data())
            }
        }
        store.start(); await eventually { store.chat(id)?.messages.first?.status == .failed }; store.suspend()
        let saved = try XCTUnwrap(JSONDecoder().decode([PendingSend].self, from: Data(contentsOf: directory.appendingPathComponent("outbox.data"))).first)
        XCTAssertEqual(saved.reasoningEffort, .high); XCTAssertTrue(saved.lastError?.contains("does not support") == true)
        store.update(id) { $0.draft = "New draft" }
        store.enqueue(id)
        XCTAssertEqual(store.chat(id)?.draft, "New draft")
        XCTAssertEqual(try JSONDecoder().decode([PendingSend].self, from: Data(contentsOf: directory.appendingPathComponent("outbox.data"))).count, 1)
    }

    func testForkCapturesTargetModelAndEffortFromSavedMessages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var chat = Conversation(); chat.model = "current"; chat.reasoningEffort = .low
        let target = UUID()
        chat.messages = [Message(id: target, role: .user, content: "Original", model: "target", jobID: target, reasoningEffort: .max)]
        try ConversationDisk(directory: directory, recoverStreaming: false).save(chat)
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        let store = try RemoteChatStore(client: BackendClient(credentials), directory: directory)
        store.fork(chat.id, messageID: target, text: "Edited")
        let fork = try XCTUnwrap(store.selectedID); XCTAssertNotEqual(fork, chat.id)
        let pending = try XCTUnwrap(JSONDecoder().decode([PendingSend].self, from: Data(contentsOf: directory.appendingPathComponent("outbox.data"))).first)
        XCTAssertEqual(pending.model, "target"); XCTAssertEqual(pending.reasoningEffort, .max)
        XCTAssertEqual(store.chat(fork)?.model, "target"); XCTAssertEqual(store.chat(fork)?.reasoningEffort, .max)
        XCTAssertEqual(store.chat(chat.id)?.model, "current"); XCTAssertEqual(store.chat(chat.id)?.reasoningEffort, .low)
        store.suspend()
    }

    func testLegacyForkAcknowledgementUsesAuthoritativeTargetConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { StubURLProtocol.handler = nil; try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        let chat = Conversation()
        try ConversationDisk(directory: directory, recoverStreaming: false).save(chat)
        let legacy = PendingSend(threadID: chat.id, prompt: "Legacy edit", model: "picker-model", steer: false, sourceThreadID: UUID(), targetJobID: UUID())
        try JSONEncoder().encode([legacy]).write(to: directory.appendingPathComponent("outbox.data"))
        let accepted = BackendJob(id: legacy.id, threadId: chat.id, position: 0, prompt: legacy.prompt, model: "target-model", status: .queued, content: "", created: 1, updated: 1)
        let job = try JSONEncoder().encode(accepted)
        let caps = try JSONSerialization.data(withJSONObject: ["serverId": UUID().pathID, "push": false, "backgroundJobs": true, "reasoningEffort": true])
        StubURLProtocol.handler = { request in
            switch request.url!.path {
            case "/v1/capabilities": return (200, caps)
            case "/v1/settings/openrouter-key": return (200, Data("{\"configured\":true}".utf8))
            case "/v1/threads": return (200, Data("[]".utf8))
            default: return (200, job)
            }
        }
        let store = try RemoteChatStore(client: BackendClient(credentials, session: session), directory: directory)
        store.start(); await eventually { store.connectionStatus == "Synced" }; store.suspend()
        XCTAssertTrue(try JSONDecoder().decode([PendingSend].self, from: Data(contentsOf: directory.appendingPathComponent("outbox.data"))).isEmpty)
        XCTAssertEqual(store.chat(chat.id)?.messages.first?.model, "target-model")
        let normal = PendingSend(threadID: chat.id, prompt: legacy.prompt, model: legacy.model, steer: false)
        XCTAssertFalse(normal.matchesConfiguration(accepted))
    }

    func testPermanentDeletionRemovesArchivedCacheAndKeepsOtherChats() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { StubURLProtocol.handler = nil; try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        var chat = Conversation(); chat.serverThread = true; chat.archived = true; chat.draft = "Delete draft"
        chat.messages = [Message(role: .assistant, content: "Delete history")]
        let other = Conversation()
        let disk = try ConversationDisk(directory: directory, recoverStreaming: false)
        try disk.save(chat); try disk.save(other)
        let id = chat.id
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/v1/threads/\(id.pathID)")
            return (200, Data("{\"deleted\":true}".utf8))
        }
        let store = try RemoteChatStore(client: BackendClient(credentials, session: session), directory: directory)
        store.supportsConversationDeletion = true
        store.select(id)
        try await store.delete(id)
        XCTAssertNil(store.chat(id)); XCTAssertFalse(store.canMutate(id))
        XCTAssertEqual(store.selectedID, other.id)
        XCTAssertEqual(try disk.load().map(\.id), [other.id])
        XCTAssertNotNil(store.chat(other.id))
    }
    func testUnsupportedAndUnconfirmedDeletionKeepHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { StubURLProtocol.handler = nil; try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        var chat = Conversation(); chat.serverThread = true; chat.draft = "Keep draft"
        let disk = try ConversationDisk(directory: directory, recoverStreaming: false); try disk.save(chat)
        StubURLProtocol.handler = { _ in XCTFail("Unsupported server must not receive deletion"); return (500, Data()) }
        let store = try RemoteChatStore(client: BackendClient(credentials, session: session), directory: directory)
        do { try await store.delete(chat.id); XCTFail("Unsupported deletion accepted") } catch { }
        XCTAssertEqual(store.chat(chat.id)?.draft, "Keep draft")
        store.supportsConversationDeletion = true
        StubURLProtocol.handler = { _ in (503, Data("{\"error\":\"Unavailable\"}".utf8)) }
        do { try await store.delete(chat.id); XCTFail("Unconfirmed deletion accepted") } catch { }
        XCTAssertEqual(store.chat(chat.id)?.draft, "Keep draft")
        XCTAssertEqual(try disk.load().first?.id, chat.id)
        store.enqueue(chat.id)
        do { try await store.delete(chat.id); XCTFail("Pending send discarded") } catch { }
        XCTAssertEqual(try JSONDecoder().decode([PendingSend].self, from: Data(contentsOf: directory.appendingPathComponent("outbox.data"))).count, 1)
    }
    func testDeletionOnAnotherDeviceRemovesSavedDraftAndCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { StubURLProtocol.handler = nil; try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        var chat = Conversation(); chat.serverThread = true; chat.archived = true; chat.draft = "Deleted elsewhere"
        let disk = try ConversationDisk(directory: directory, recoverStreaming: false); try disk.save(chat)
        let caps = try JSONSerialization.data(withJSONObject: ["serverId": UUID().pathID, "push": false, "backgroundJobs": true, "archiveBrowsing": true, "conversationDeletion": true])
        StubURLProtocol.handler = { request in
            switch request.url!.path {
            case "/v1/capabilities": return (200, caps)
            case "/v1/settings/openrouter-key": return (200, Data("{\"configured\":true}".utf8))
            case "/v1/threads": return (200, Data("[]".utf8))
            default: return (404, Data("{\"error\":\"Not found\"}".utf8))
            }
        }
        let store = try RemoteChatStore(client: BackendClient(credentials, session: session), directory: directory)
        store.start(); await eventually { store.chat(chat.id) == nil }; store.suspend()
        XCTAssertNil(store.chat(chat.id)); XCTAssertTrue(try disk.load().isEmpty)
    }
    func testLegacyServerGoneResponseMarksCacheArchivedWithoutArchiveQueries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { StubURLProtocol.handler = nil; try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        var chat = Conversation(); chat.serverThread = true; chat.draft = "Keep my draft"
        chat.messages = [Message(role: .assistant, content: "Keep my history")]
        try ConversationDisk(directory: directory, recoverStreaming: false).save(chat)
        let pending = PendingSend(threadID: chat.id, prompt: "Unconfirmed", model: "test", steer: false, lastError: "Needs confirmation")
        let outboxURL = directory.appendingPathComponent("outbox.data")
        try JSONEncoder().encode([pending]).write(to: outboxURL)
        let caps = try JSONSerialization.data(withJSONObject: ["serverId": UUID().pathID, "push": false, "backgroundJobs": true])
        StubURLProtocol.handler = { request in
            XCTAssertNil(request.url?.query)
            switch request.url!.path {
            case "/v1/capabilities": return (200, caps)
            case "/v1/settings/openrouter-key": return (200, Data("{\"configured\":true}".utf8))
            case "/v1/threads": return (200, Data("[]".utf8))
            default: return (410, Data("{\"error\":\"Conversation archived\"}".utf8))
            }
        }
        let store = try RemoteChatStore(client: BackendClient(credentials, session: session), directory: directory)
        store.start(); await eventually { store.chat(chat.id)?.isArchived == true }; store.suspend()
        XCTAssertFalse(store.supportsArchiveBrowsing); XCTAssertFalse(store.canMutate(chat.id))
        XCTAssertEqual(store.chat(chat.id)?.draft, chat.draft); XCTAssertEqual(store.chat(chat.id)?.messages, chat.messages)
        let saved = try JSONDecoder().decode([PendingSend].self, from: Data(contentsOf: outboxURL))
        XCTAssertEqual(saved.first?.id, pending.id); XCTAssertTrue(saved.first?.lastError?.contains("explicitly retry") == true)
        XCTAssertNil(store.selectedID)
    }

    func testSplitListsMissingRestoredThreadUseCanonicalCacheWithoutLosingDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { StubURLProtocol.handler = nil; try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        var chat = Conversation(); chat.serverThread = true; chat.archived = true; chat.draft = "Unsaved thought"
        chat.messages = [Message(role: .assistant, content: "Preserved history")]
        try ConversationDisk(directory: directory, recoverStreaming: false).save(chat)
        let id = chat.id.pathID
        let caps = try JSONSerialization.data(withJSONObject: ["serverId": UUID().pathID, "push": false, "backgroundJobs": true, "archiveBrowsing": true])
        let job: [String: Any] = ["id": UUID().pathID, "threadId": id, "position": 0, "prompt": "Question", "model": "test", "status": "complete", "content": "Preserved history", "created": 1, "updated": 1]
        let snapshot = try JSONSerialization.data(withJSONObject: ["id": id, "title": "Restored elsewhere", "archived": 0, "paused": 0, "created": 1, "revision": 3, "jobs": [job]])
        StubURLProtocol.handler = { request in
            switch request.url!.path {
            case "/v1/capabilities": return (200, caps)
            case "/v1/settings/openrouter-key": return (200, Data("{\"configured\":true}".utf8))
            case "/v1/threads": return (200, Data("[]".utf8))
            default: XCTAssertEqual(request.url?.query, "includeArchived=true"); return (200, snapshot)
            }
        }
        let store = try RemoteChatStore(client: BackendClient(credentials, session: session), directory: directory)
        store.start(); await eventually { store.connectionStatus == "Synced" }; store.suspend()
        XCTAssertEqual(store.chat(chat.id)?.isArchived, false); XCTAssertEqual(store.chat(chat.id)?.draft, "Unsaved thought")
        XCTAssertTrue(store.chat(chat.id)?.messages.contains(where: { $0.content == "Preserved history" }) == true)
    }

    func testArchiveHonorsConcurrentRestoreInCanonicalResponse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { StubURLProtocol.handler = nil; try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        var chat = Conversation(); chat.serverThread = true; chat.draft = "Keep draft"
        try ConversationDisk(directory: directory, recoverStreaming: false).save(chat)
        let id = chat.id.pathID
        let restored = try JSONSerialization.data(withJSONObject: ["id": id, "title": "Restored", "archived": 0, "paused": 0, "created": 1, "revision": 3, "jobs": []])
        StubURLProtocol.handler = { request in request.httpMethod == "POST" ? (200, Data("{}".utf8)) : (200, restored) }
        let store = try RemoteChatStore(client: BackendClient(credentials, session: session), directory: directory)
        store.supportsArchiveBrowsing = true
        store.archive(chat.id)
        XCTAssertFalse(store.canMutate(chat.id))
        store.setDraft(chat.id, text: "Must not replace draft")
        await eventually { store.canMutate(chat.id) }
        XCTAssertEqual(store.chat(chat.id)?.serverRevision, 3); XCTAssertEqual(store.chat(chat.id)?.isArchived, false)
        XCTAssertEqual(store.chat(chat.id)?.draft, "Keep draft"); XCTAssertEqual(store.selectedID, chat.id)
        store.suspend()
    }

    func testOfflineRetryDoesNotRebuildArchivedColdCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        var chat = Conversation(); chat.serverThread = true; chat.archived = true; chat.draft = "Saved draft"
        chat.messages = [Message(role: .assistant, content: "Cached answer")]
        try ConversationDisk(directory: directory, recoverStreaming: false).save(chat)
        let pending = PendingSend(threadID: chat.id, prompt: "Pending", model: "test", steer: false, lastError: "Archived")
        let url = directory.appendingPathComponent("outbox.data"); let payload = try JSONEncoder().encode([pending]); try payload.write(to: url)
        let store = try RemoteChatStore(client: BackendClient(credentials), directory: directory)
        await store.retryPending()
        XCTAssertEqual(store.chat(chat.id)?.messages, chat.messages); XCTAssertEqual(store.chat(chat.id)?.draft, chat.draft)
        XCTAssertEqual(try JSONDecoder().decode([PendingSend].self, from: Data(contentsOf: url)).first?.id, pending.id)
        XCTAssertEqual(try JSONDecoder().decode([PendingSend].self, from: Data(contentsOf: url)).first?.lastError, "Archived")
        store.suspend()
    }

    func testRemoteArchiveMarksPendingSendForExplicitRetryAfterRestore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { StubURLProtocol.handler = nil; try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        var chat = Conversation(); chat.serverThread = true; chat.draft = "Still writing"
        try ConversationDisk(directory: directory, recoverStreaming: false).save(chat)
        let pending = PendingSend(threadID: chat.id, prompt: "Unconfirmed send", model: "test", steer: false, lastError: "Needs confirmation")
        let url = directory.appendingPathComponent("outbox.data")
        try JSONEncoder().encode([pending]).write(to: url)
        let id = chat.id.pathID
        let caps = try JSONSerialization.data(withJSONObject: ["serverId": UUID().pathID, "push": false, "backgroundJobs": true, "archiveBrowsing": true])
        let archived: [String: Any] = ["id": id, "title": "Archived elsewhere", "archived": 1, "paused": 1, "created": 1, "revision": 2, "jobs": []]
        let list = try JSONSerialization.data(withJSONObject: [archived])
        let snapshot = try JSONSerialization.data(withJSONObject: archived)
        let restored = try JSONSerialization.data(withJSONObject: archived.merging(["archived": 0, "revision": 3]) { _, new in new })
        StubURLProtocol.handler = { request in
            switch request.url!.path {
            case "/v1/capabilities": return (200, caps)
            case "/v1/settings/openrouter-key": return (200, Data("{\"configured\":true}".utf8))
            case "/v1/threads": return (200, request.url?.query == "archived=true" ? list : Data("[]".utf8))
            case "/v1/threads/\(id)":
                XCTAssertEqual(request.url?.query, "includeArchived=true"); return (200, snapshot)
            case "/v1/threads/\(id)/restore": return (200, restored)
            default: XCTFail("No provider-producing request is allowed"); return (500, Data())
            }
        }
        let store = try RemoteChatStore(client: BackendClient(credentials, session: session), directory: directory)
        store.start(); await eventually { store.chat(chat.id)?.isArchived == true }
        let marked = try JSONDecoder().decode([PendingSend].self, from: Data(contentsOf: url))
        XCTAssertEqual(marked.first?.id, pending.id); XCTAssertTrue(marked.first?.lastError?.contains("explicitly retry") == true)
        try await store.restore(chat.id)
        store.suspend()
        let saved = try JSONDecoder().decode([PendingSend].self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.first?.id, pending.id); XCTAssertEqual(saved.first?.lastError, marked.first?.lastError)
        XCTAssertEqual(store.chat(chat.id)?.draft, "Still writing")
    }

    func testLocalArchiveSurvivesReloadAndRestoresWithoutNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { StubURLProtocol.handler = nil; try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        StubURLProtocol.handler = { _ in XCTFail("Local archive must not use HTTP"); return (500, Data()) }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        let store = try RemoteChatStore(client: BackendClient(credentials, session: session), directory: directory)
        store.newChat(); let id = try XCTUnwrap(store.selectedID)
        store.setDraft(id, text: "Keep draft")
        store.archive(id)
        await eventually { store.chat(id)?.isArchived == true }
        XCTAssertNil(store.selectedID)
        let restored = try RemoteChatStore(client: BackendClient(credentials, session: session), directory: directory)
        XCTAssertTrue(try XCTUnwrap(restored.chat(id)).isArchived); XCTAssertNil(restored.selectedID)
        restored.setDraft(id, text: "Must not change")
        let sessions = FakeBackendSessionStorage()
        let direct = DirectChatStore(storage: try ConversationDisk(directory: directory.appendingPathComponent("direct")), readKey: { "" })
        let facade = ChatStore(direct: direct, remote: restored, sessions: sessions, push: sessions.pushCoordinator())
        facade.update(id, { $0.model = "Must not change" })
        XCTAssertEqual(restored.chat(id)?.model, "openrouter/auto"); XCTAssertEqual(restored.chat(id)?.draft, "Keep draft")
        restored.enqueue(id, text: "No send"); restored.resume(id); restored.stop(id)
        do { try await restored.setMetadata(id, title: "No rename"); XCTFail("Archived rename accepted") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("outbox.data").path))
        try await restored.restore(id)
        XCTAssertFalse(try XCTUnwrap(restored.chat(id)).isArchived)
        XCTAssertEqual(restored.chat(id)?.draft, "Keep draft"); XCTAssertNil(restored.selectedID)
        store.suspend(); restored.suspend()
    }

    func testFailedArchivedListPreservesBothCachedLists() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { StubURLProtocol.handler = nil; try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        var active = Conversation(); active.serverThread = true
        var archived = Conversation(); archived.serverThread = true; archived.archived = true
        let disk = try ConversationDisk(directory: directory, recoverStreaming: false)
        try disk.save(active); try disk.save(archived)
        let caps = try JSONSerialization.data(withJSONObject: ["serverId": UUID().pathID, "push": false, "backgroundJobs": true, "archiveBrowsing": true])
        StubURLProtocol.handler = { request in
            switch request.url!.path {
            case "/v1/capabilities": return (200, caps)
            case "/v1/settings/openrouter-key": return (200, Data("{\"configured\":true}".utf8))
            case "/v1/threads": return request.url?.query == "archived=true" ? (503, Data("{\"error\":\"Offline\"}".utf8)) : (200, Data("[]".utf8))
            default: XCTFail("Unexpected request"); return (500, Data())
            }
        }
        let store = try RemoteChatStore(client: BackendClient(credentials, session: session), directory: directory)
        store.start(); await eventually { store.connectionStatus.contains("Offline") }; store.suspend()
        XCTAssertNotNil(store.chat(active.id)); XCTAssertEqual(store.chat(archived.id)?.isArchived, true)
    }

    func testRestoreUsesCanonicalSnapshotAndDoesNotRetryArchivedPendingSend() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { StubURLProtocol.handler = nil; try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        var chat = Conversation(); chat.serverThread = true; chat.archived = true; chat.draft = "Saved draft"; chat.pinned = true
        try ConversationDisk(directory: directory, recoverStreaming: false).save(chat)
        let pending = PendingSend(threadID: chat.id, prompt: "Keep immutable payload", model: "test", steer: false, lastError: "Archived")
        let outboxURL = directory.appendingPathComponent("outbox.data")
        try JSONEncoder().encode([pending]).write(to: outboxURL)
        let id = chat.id.pathID
        let response = try JSONSerialization.data(withJSONObject: ["id": id, "title": "Original name", "pinned": 1, "archived": 0, "paused": 1, "created": 1, "revision": 4, "jobs": []])
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.url?.path, "/v1/threads/\(id)/restore")
            return (200, response)
        }
        let store = try RemoteChatStore(client: BackendClient(credentials, session: session), directory: directory)
        store.supportsArchiveBrowsing = true
        try await store.restore(chat.id)
        XCTAssertEqual(store.chat(chat.id)?.title, "Original name"); XCTAssertEqual(store.chat(chat.id)?.isPinned, true)
        XCTAssertEqual(store.chat(chat.id)?.paused, true); XCTAssertEqual(store.chat(chat.id)?.isArchived, false)
        XCTAssertEqual(store.chat(chat.id)?.draft, "Saved draft"); XCTAssertNil(store.selectedID)
        let saved = try JSONDecoder().decode([PendingSend].self, from: Data(contentsOf: outboxURL))
        XCTAssertEqual(saved.first?.id, pending.id); XCTAssertEqual(saved.first?.lastError, "Archived")
        store.suspend()
    }

    func testMissingArchiveCapabilityNeverQueriesArchiveAndKeepsKnownArchive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { StubURLProtocol.handler = nil; try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        var chat = Conversation(); chat.serverThread = true; chat.archived = true
        try ConversationDisk(directory: directory, recoverStreaming: false).save(chat)
        let caps = try JSONSerialization.data(withJSONObject: ["serverId": UUID().pathID, "push": false, "backgroundJobs": true])
        StubURLProtocol.handler = { request in
            XCTAssertNil(request.url?.query)
            switch request.url!.path {
            case "/v1/capabilities": return (200, caps)
            case "/v1/settings/openrouter-key": return (200, Data("{\"configured\":true}".utf8))
            default: return (200, Data("[]".utf8))
            }
        }
        let store = try RemoteChatStore(client: BackendClient(credentials, session: session), directory: directory)
        store.start(); await eventually { store.connectionStatus == "Synced" }; store.suspend()
        XCTAssertFalse(store.supportsArchiveBrowsing); XCTAssertEqual(store.chat(chat.id)?.isArchived, true)
    }

    func testSummaryQuotesSelectedOlderAnswerAndPersistsDraftAndPendingID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { StubURLProtocol.handler = nil; try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        var chat = Conversation()
        let answer = "  Première conclusion 🙂\nCaveat: \"quoted\"\nالسطر الثاني  "
        let source = Message(role: .assistant, content: answer)
        chat.messages = [source, Message(role: .assistant, content: "A newer answer")]
        chat.draft = "Keep my unfinished draft"; chat.model = "chosen/current-model"
        try ConversationDisk(directory: directory, recoverStreaming: false).save(chat)
        let client = BackendClient(credentials, session: session)
        let backend = StubBackend()
        StubURLProtocol.handler = { try backend.reply($0) }
        let store = try RemoteChatStore(client: client, directory: directory)
        store.summarize(chat.id, messageID: source.id)
        let url = directory.appendingPathComponent("outbox.data")
        let first = try JSONDecoder().decode([PendingSend].self, from: Data(contentsOf: url))
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(first[0].prompt.contains("“" + answer + "”"))
        XCTAssertFalse(first[0].prompt.contains("A newer answer"))
        XCTAssertEqual(first[0].model, chat.model); XCTAssertFalse(first[0].steer)
        // Restore the source while the same durable send remains unacknowledged.
        store.update(chat.id, { $0.messages.insert(source, at: 0) })
        store.summarize(chat.id, messageID: source.id)
        let retry = try JSONDecoder().decode([PendingSend].self, from: Data(contentsOf: url))
        XCTAssertEqual(retry.map(\.id), first.map(\.id))
        let restored = try RemoteChatStore(client: client, directory: directory)
        restored.summarize(chat.id, messageID: source.id)
        XCTAssertEqual(restored.chat(chat.id)?.draft, "Keep my unfinished draft")
        XCTAssertEqual(try JSONDecoder().decode([PendingSend].self, from: Data(contentsOf: url)).map(\.id), first.map(\.id))
        restored.suspend()
        store.start()
        await eventually { store.connectionStatus.contains("awaiting confirmation") }
        store.suspend()
        let afterLostReply = try RemoteChatStore(client: client, directory: directory)
        afterLostReply.start()
        await eventually { afterLostReply.chat(chat.id)?.messages.contains(where: { $0.content == "Saved answer" }) == true }
        afterLostReply.suspend()
        XCTAssertEqual(backend.sentIDs.count, 2)
        XCTAssertEqual(Set(backend.sentIDs).count, 1)
        XCTAssertEqual(afterLostReply.chat(chat.id)?.draft, "Keep my unfinished draft")
    }

    func testSummaryRejectsWrongSourcesAndCachedUnfinishedDuplicate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        var chat = Conversation()
        let source = Message(role: .assistant, content: "Answer")
        chat.messages = [Message(role: .user, content: "Question"), Message(role: .assistant, content: "Partial", status: .streaming), Message(role: .assistant, content: "Stopped", status: .stopped), Message(role: .assistant, content: " \n "), source, Message(role: .user, content: SummaryPrompt.make(source.content)), Message(role: .assistant, content: "", status: .streaming)]
        try ConversationDisk(directory: directory, recoverStreaming: false).save(chat)
        let store = try RemoteChatStore(client: BackendClient(credentials), directory: directory)
        for message in chat.messages { store.summarize(chat.id, messageID: message.id) }
        for status in [Message.Status.queued, .sending] {
            XCTAssertTrue(SummaryPrompt.hasUnfinished(SummaryPrompt.make(source.content), messages: [Message(role: .user, content: SummaryPrompt.make(source.content), status: status)]))
        }
        for content in [String(repeating: "🙂", count: 50_000), String(repeating: "\u{0001}", count: 30_000)] {
            let oversized = Message(role: .assistant, content: content)
            store.update(chat.id, { $0.messages = [oversized] })
            store.summarize(chat.id, messageID: oversized.id)
            XCTAssertNotNil(store.error)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("outbox.data").path))
        store.suspend()
    }

    func testSummaryPreflightsPromptEncodedJSONAndKnownContext() throws {
        func pending(_ text: String) -> PendingSend { PendingSend(threadID: UUID(), prompt: SummaryPrompt.make(text), model: "test", steer: false) }
        XCTAssertThrowsError(try SummaryPrompt.validate(pending(String(repeating: "🙂", count: 50_000)), jobs: []))
        XCTAssertThrowsError(try SummaryPrompt.validate(pending(String(repeating: "\u{0001}", count: 30_000)), jobs: []))
        let job = BackendJob(id: UUID(), threadId: UUID(), position: 0, prompt: String(repeating: "a", count: 200_000), model: "test", status: .complete, content: String(repeating: "b", count: 199_500), error: nil, created: 1, updated: 1)
        XCTAssertThrowsError(try SummaryPrompt.validate(pending(String(repeating: "c", count: 500)), jobs: [job]))
        var skipped = job; skipped.status = .stopped; skipped.content = ""
        XCTAssertNoThrow(try SummaryPrompt.validate(pending("Small answer"), jobs: [skipped]))
    }

    func testThreadCreationOmitsMetadataUnlessServerSupportsIt() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { StubURLProtocol.handler = nil; session.invalidateAndCancel() }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        let client = BackendClient(credentials, session: session)
        var chat = Conversation()
        chat.pinned = true
        let threadID = chat.id.pathID
        let response = try JSONSerialization.data(withJSONObject: ["id": threadID, "title": chat.title, "paused": 0, "created": 1, "revision": 1])
        StubURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: StubBackend.body(request)) as! [String: Any]
            guard Set(body.keys) == ["id", "title"] else {
                return (400, Data("{\"error\":\"Unexpected field\"}".utf8))
            }
            XCTAssertEqual((body["id"] as? String).flatMap(UUID.init(uuidString:)), chat.id)
            return (200, response)
        }
        try await client.createThread(chat)
        for pinned in [true, false] {
            chat.pinned = pinned
            StubURLProtocol.handler = { request in
                let body = try JSONSerialization.jsonObject(with: StubBackend.body(request)) as! [String: Any]
                XCTAssertEqual(body["pinned"] as? Bool, pinned)
                return (200, response)
            }
            try await client.createThread(chat, supportsMetadata: true)
        }
    }

    func testOlderCapabilitiesDoNotEnableConversationMetadata() throws {
        let data = try JSONSerialization.data(withJSONObject: ["serverId": UUID().pathID, "push": false, "backgroundJobs": true])
        let capabilities = try JSONDecoder().decode(BackendCapabilities.self, from: data)
        XCTAssertFalse(capabilities.conversationMetadata == true)
    }

    func testLocalMetadataPersistsAndOlderCachesDefaultToUnpinned() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        let store = try RemoteChatStore(client: BackendClient(credentials), directory: directory)
        store.newChat()
        let id = try XCTUnwrap(store.selectedID)
        XCTAssertFalse(try XCTUnwrap(store.chat(id)).isPinned)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try XCTUnwrap(store.chat(id)))) as! [String: Any]
        legacy.removeValue(forKey: "pinned")
        legacy.removeValue(forKey: "archived")
        XCTAssertFalse(try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: legacy)).isPinned)
        XCTAssertFalse(try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: legacy)).isArchived)
        try await store.setMetadata(id, title: "  My ideas  ", pinned: true)
        let restored = try RemoteChatStore(client: BackendClient(credentials), directory: directory)
        XCTAssertEqual(restored.chat(id)?.title, "My ideas")
        XCTAssertEqual(restored.chat(id)?.isPinned, true)
        do { try await store.setMetadata(id, title: " \n "); XCTFail("Empty title accepted") } catch { }
        do { try await store.setMetadata(id, title: String(repeating: "a", count: 201)); XCTFail("Long title accepted") } catch { }
        do { try await store.setMetadata(id, title: String(repeating: "🙂", count: 101)); XCTFail("UTF-16 limit ignored") } catch { }
        XCTAssertEqual(store.chat(id)?.title, "My ideas")
        store.suspend(); restored.suspend()
    }

    func testConfirmedMetadataPreservesJobsDraftAndSnapshotRevision() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { StubURLProtocol.handler = nil; try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        var cached = Conversation()
        cached.serverThread = true; cached.serverRevision = 1; cached.draft = "Unsent thought"
        cached.messages = [Message(role: .assistant, content: "Keep this answer")]
        try ConversationDisk(directory: directory, recoverStreaming: false).save(cached)
        let store = try RemoteChatStore(client: BackendClient(credentials, session: session), directory: directory)
        let threadID = cached.id
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.url?.path, "/v1/threads/\(threadID.pathID)")
            let body = try JSONSerialization.jsonObject(with: StubBackend.body(request)) as! [String: Any]
            XCTAssertEqual(body["title"] as? String, "Renamed")
            XCTAssertEqual(body["pinned"] as? Bool, true)
            return (200, try JSONSerialization.data(withJSONObject: ["id": threadID.pathID, "title": "Renamed", "pinned": 1, "paused": 0, "created": 1, "revision": 3]))
        }
        try await store.setMetadata(threadID, title: "Renamed", pinned: true)
        XCTAssertEqual(store.chat(threadID)?.title, "Renamed")
        XCTAssertEqual(store.chat(threadID)?.isPinned, true)
        XCTAssertEqual(store.chat(threadID)?.serverRevision, 1)
        XCTAssertEqual(store.chat(threadID)?.draft, "Unsent thought")
        XCTAssertEqual(store.chat(threadID)?.messages.map(\.content), ["Keep this answer"])
        StubURLProtocol.handler = { _ in (503, Data("{\"error\":\"Unavailable\"}".utf8)) }
        do { try await store.setMetadata(threadID, title: "Rejected", pinned: false); XCTFail("Failure accepted") } catch { }
        XCTAssertEqual(store.chat(threadID)?.title, "Renamed")
        XCTAssertEqual(store.chat(threadID)?.isPinned, true)
        StubURLProtocol.handler = { _ in (401, Data("{\"error\":\"Reconnect\"}".utf8)) }
        do { try await store.setMetadata(threadID, pinned: false); XCTFail("Authentication failure accepted") } catch { }
        XCTAssertTrue(store.requiresAuthentication)
        XCTAssertEqual(store.chat(threadID)?.title, "Renamed")
        XCTAssertEqual(store.chat(threadID)?.draft, "Unsent thought")
        store.suspend()
    }

    func testInflightOldSnapshotCannotOverwriteConfirmedMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let gate = ResponseGate()
        defer { gate.release(); StubURLProtocol.handler = nil; StubURLProtocol.deferResponse = nil; try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        var cached = Conversation()
        cached.serverThread = true; cached.serverRevision = 1; cached.draft = "Unsent thought"
        try ConversationDisk(directory: directory, recoverStreaming: false).save(cached)
        let store = try RemoteChatStore(client: BackendClient(credentials, session: session), directory: directory)
        let threadID = cached.id.pathID
        let old = try JSONSerialization.data(withJSONObject: ["id": threadID, "title": "Old", "paused": 0, "created": 1, "revision": 1, "jobs": []])
        let list = try JSONSerialization.data(withJSONObject: [["id": threadID, "title": "Old", "paused": 0, "created": 1, "revision": 1]])
        let updated = try JSONSerialization.data(withJSONObject: ["id": threadID, "title": "New", "pinned": 1, "paused": 0, "created": 1, "revision": 2])
        let caps = try JSONSerialization.data(withJSONObject: ["serverId": UUID().pathID, "push": false, "backgroundJobs": true])
        StubURLProtocol.handler = { request in
            switch request.url!.path {
            case "/v1/capabilities": return (200, caps)
            case "/v1/settings/openrouter-key": return (200, Data("{\"configured\":true}".utf8))
            case "/v1/threads": return (200, list)
            default: return (200, request.httpMethod == "PATCH" ? updated : old)
            }
        }
        StubURLProtocol.deferResponse = { request, finish in
            if request.url?.path == "/v1/threads/\(threadID)" && request.httpMethod == "GET" { gate.holdFirst(finish) }
            else { finish() }
        }
        store.start()
        await eventually { gate.isHolding }
        try await store.setMetadata(cached.id, title: "New", pinned: true)
        gate.release()
        await eventually { !store.isSyncing }
        XCTAssertEqual(store.chat(cached.id)?.title, "New")
        XCTAssertEqual(store.chat(cached.id)?.isPinned, true)
        XCTAssertEqual(store.chat(cached.id)?.draft, "Unsent thought")
        store.suspend()
    }

    func testCredentialsRequireTLSAndKeepSecretsOutOfTheURL() throws {
        let token = String(repeating: "a", count: 32)
        XCTAssertThrowsError(try BackendCredentials(address: "http://public.example", token: token))
        XCTAssertThrowsError(try BackendCredentials(address: "https://user:secret@example.test", token: token))
        XCTAssertThrowsError(try BackendCredentials(address: "https://example.test?token=secret", token: token))
        XCTAssertThrowsError(try BackendCredentials(address: "https://example.test", token: "short"))
        XCTAssertEqual(try BackendCredentials(address: "https://example.test/", token: token).url.absoluteString, "https://example.test")
        XCTAssertNoThrow(try BackendCredentials(address: "http://127.0.0.1:8080", token: token))
    }
    func testBackendEventFramingAndUTF16Cursor() throws {
        var parser = BackendEventParser()
        XCTAssertNil(parser.consume(": heartbeat"))
        XCTAssertNil(parser.consume("event: delta"))
        XCTAssertNil(parser.consume("data: {\"text\":\"🙂\"}"))
        let event = parser.consume("")
        XCTAssertEqual(event?.name, "delta")
        XCTAssertEqual(event?.data, "{\"text\":\"🙂\"}")
        XCTAssertNil(parser.consume(""))
        XCTAssertEqual("First 🙂".utf16.count, 8)
    }
    func testHistoriesAreNamespacedByEndpointAndServerIdentity() throws {
        let url = URL(string: "https://example.test")!
        let one = UUID(); let two = UUID()
        XCTAssertNotEqual(RemoteChatStore.namespace(url, serverID: one), RemoteChatStore.namespace(url, serverID: two))
        XCTAssertNotEqual(RemoteChatStore.namespace(url), RemoteChatStore.namespace(URL(string: "https://other.test")!))
        XCTAssertEqual(RemoteChatStore.assistantID(one), RemoteChatStore.assistantID(one))
        XCTAssertNotEqual(RemoteChatStore.assistantID(one), one)
    }
    func testRemoteCacheDoesNotTreatSubscriberDisconnectionAsStoppedGeneration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let remoteDisk = try ConversationDisk(directory: directory, recoverStreaming: false)
        var chat = Conversation()
        chat.messages = [Message(role: .assistant, content: "Server is still working", status: .streaming)]
        try remoteDisk.save(chat)
        XCTAssertEqual(try remoteDisk.load().first?.messages.first?.status, .streaming)
        XCTAssertEqual(try ConversationDisk(directory: directory).load().first?.messages.first?.status, .stopped)
    }
    func testLostAcknowledgementSurvivesRelaunchAndRetriesTheSameJobID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { StubURLProtocol.handler = nil; try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        let client = BackendClient(credentials, session: session)
        let backend = StubBackend()
        StubURLProtocol.handler = { try backend.reply($0) }
        let first = try RemoteChatStore(client: client, directory: directory)
        first.newChat()
        let id = first.selectedID!
        first.start(); first.setDraft(id, text: "Do not duplicate this request"); first.enqueue(id)
        await eventually { first.connectionStatus.contains("awaiting confirmation") }
        first.suspend()
        XCTAssertEqual(backend.sentIDs.count, 1)
        let second = try RemoteChatStore(client: client, directory: directory)
        second.start()
        await eventually { second.chat(id)?.messages.contains(where: { $0.content == "Saved answer" }) == true }
        second.suspend()
        XCTAssertEqual(backend.sentIDs.count, 2)
        XCTAssertEqual(Set(backend.sentIDs).count, 1)
        XCTAssertEqual(second.chat(id)?.messages.filter { $0.role == .user }.count, 1)
        let saved = try JSONDecoder().decode([PendingSend].self, from: Data(contentsOf: directory.appendingPathComponent("outbox.data")))
        XCTAssertTrue(saved.isEmpty)
    }
    func testContinuePreservesUnsentDraftAcrossRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        let client = BackendClient(credentials)
        let store = try RemoteChatStore(client: client, directory: directory)
        store.newChat()
        let id = store.selectedID!
        store.setDraft(id, text: "Keep this unfinished thought")
        store.resume(id)
        XCTAssertEqual(store.chat(id)?.draft, "Keep this unfinished thought")
        let reloaded = try RemoteChatStore(client: client, directory: directory)
        XCTAssertEqual(reloaded.chat(id)?.draft, "Keep this unfinished thought")
        let pending = try JSONDecoder().decode([PendingSend].self, from: Data(contentsOf: directory.appendingPathComponent("outbox.data")))
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.prompt, "Continue from where you stopped without repeating what you already wrote.")
        store.suspend()
    }
    func testResumeUsesCachedQueueAfterRelaunchWithoutEnqueuingContinuation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { StubURLProtocol.handler = nil; try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        var cached = Conversation()
        cached.serverThread = true
        cached.paused = true
        cached.draft = "Keep this unfinished thought"
        cached.messages = [Message(role: .user, content: "Already queued", status: .queued, jobID: UUID())]
        try ConversationDisk(directory: directory, recoverStreaming: false).save(cached)
        let store = try RemoteChatStore(client: BackendClient(credentials, session: session), directory: directory)
        let resumed = expectation(description: "Resume the existing server queue")
        let path = "/v1/threads/\(cached.id.pathID)/resume"
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, path)
            resumed.fulfill()
            throw URLError(.notConnectedToInternet)
        }

        store.resume(cached.id)
        await fulfillment(of: [resumed], timeout: 2)
        await eventually { store.error != nil }
        XCTAssertEqual(store.chat(cached.id)?.draft, cached.draft)
        XCTAssertEqual(store.chat(cached.id)?.messages.map(\.content), ["Already queued"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("outbox.data").path))
        store.suspend()
    }
    func testDisconnectDoesNotWaitForOfflineNotificationCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { StubURLProtocol.handler = nil; try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        let client = BackendClient(credentials, session: session)
        let remote = try RemoteChatStore(client: client, directory: directory.appendingPathComponent("remote"))
        remote.newChat(); let remoteID = remote.selectedID!
        remote.setDraft(remoteID, text: "Remote draft stays cached")
        let disk = try ConversationDisk(directory: directory.appendingPathComponent("direct"))
        let direct = DirectChatStore(storage: disk, readKey: { "" })
        let connections = FakeBackendSessionStorage()
        let store = ChatStore(direct: direct, remote: remote, sessions: connections, push: connections.pushCoordinator())
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        var removedConnection = false
        await store.disconnect { removedConnection = true }
        XCTAssertTrue(removedConnection)
        XCTAssertFalse(store.isRemote)
        XCTAssertNil(store.selectedID)
        XCTAssertTrue(store.needsBackendConnection)
        XCTAssertEqual(try ConversationDisk(directory: directory.appendingPathComponent("remote")).load().first?.draft, "Remote draft stays cached")
        await eventually { store.error?.contains("Notification cleanup") == true }
        XCTAssertFalse(store.isRemote)
    }
    func testFailedCredentialRemovalKeepsRemoteConnection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        let remote = try RemoteChatStore(client: BackendClient(credentials), directory: directory.appendingPathComponent("remote"))
        let direct = DirectChatStore(storage: try ConversationDisk(directory: directory.appendingPathComponent("direct")), readKey: { "" })
        let connections = FakeBackendSessionStorage()
        let store = ChatStore(direct: direct, remote: remote, sessions: connections, push: connections.pushCoordinator())
        await store.disconnect { throw RouterError(message: "Test credential removal failed") }
        XCTAssertTrue(store.isRemote)
        XCTAssertTrue(store.error?.contains("Disconnect was not completed") == true)
    }
    func testLateNotificationCleanupCannotDeleteReconnectedRegistration() async throws {
        let suite = "OpenChatTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); StubURLProtocol.handler = nil; StubURLProtocol.deferResponse = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        let client = BackendClient(credentials, session: session)
        let backend = NotificationBackend()
        StubURLProtocol.handler = { backend.reply($0) }
        let gate = ResponseGate()
        StubURLProtocol.deferResponse = { _, finish in gate.holdFirst(finish) }
        let coordinator = PushCoordinator(defaults: defaults)
        let original = Task { try await coordinator.registerDevice(token: "synthetic-token", with: client) }
        await eventually { backend.registeredIDs.count == 1 && gate.isHolding }
        let previousID = coordinator.rotateRegistration()
        var cleanupStarted = false
        let cleanup = Task {
            cleanupStarted = true
            try await coordinator.unregister(from: client, deviceID: previousID, updateState: false)
        }
        var reconnectStarted = false
        let reconnect = Task {
            reconnectStarted = true
            try await coordinator.registerDevice(token: "synthetic-token", with: client)
        }
        await eventually { cleanupStarted && reconnectStarted }
        XCTAssertEqual(backend.operations.count, 1, "New device writes must wait for the old PUT response")
        gate.release()
        try await original.value; try await cleanup.value; try await reconnect.value
        XCTAssertEqual(backend.registeredIDs.count, 2)
        XCTAssertEqual(backend.registeredIDs.first, previousID.pathID)
        XCTAssertNotEqual(backend.registeredIDs.first, backend.registeredIDs.last)
        XCTAssertEqual(backend.remainingIDs, Set(backend.registeredIDs.suffix(1)))
        XCTAssertEqual(backend.operations, ["PUT \(previousID.pathID)", "DELETE \(previousID.pathID)", "PUT \(backend.registeredIDs.last!)"])
        XCTAssertEqual(coordinator.status, "Completion notifications enabled")
    }
    func testRejectedSendDoesNotBlockOtherThreadsOrReorderItsOwnThread() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { StubURLProtocol.handler = nil; try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let credentials = try BackendCredentials(address: "https://example.test", token: String(repeating: "t", count: 32))
        let client = BackendClient(credentials, session: session)
        let backend = OutboxBackend()
        StubURLProtocol.handler = { try backend.reply($0) }
        let store = try RemoteChatStore(client: client, directory: directory)
        store.newChat(); let blockedID = store.selectedID!
        store.setDraft(blockedID, text: "Reject this"); store.enqueue(blockedID)
        store.setDraft(blockedID, text: "Must wait"); store.enqueue(blockedID)
        store.newChat(); let otherID = store.selectedID!
        store.setDraft(otherID, text: "Independent"); store.enqueue(otherID)
        let savedURL = directory.appendingPathComponent("outbox.data")
        let original = try JSONDecoder().decode([PendingSend].self, from: Data(contentsOf: savedURL))
        store.start()
        await eventually { store.chat(otherID)?.messages.contains(where: { $0.content == "Accepted Independent" }) == true }
        store.suspend()
        XCTAssertEqual(backend.prompts, ["Reject this", "Independent"])
        let remaining = try JSONDecoder().decode([PendingSend].self, from: Data(contentsOf: savedURL))
        XCTAssertEqual(remaining.map(\.id), original.prefix(2).map(\.id))
        XCTAssertNotNil(remaining.first?.lastError)
        backend.allowRejected = true
        store.start()
        await store.retryPending()
        await eventually { store.chat(blockedID)?.messages.contains(where: { $0.content == "Accepted Must wait" }) == true }
        store.suspend()
        XCTAssertEqual(backend.prompts, ["Reject this", "Independent", "Reject this", "Must wait"])
        XCTAssertEqual(backend.requestIDs.map { $0.lowercased() }, [original[0].id, original[2].id, original[0].id, original[1].id].map(\.pathID))
    }
    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<300 { if condition() { return }; try? await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out waiting for client state")
    }
}

private final class NotificationBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var registrations: [String] = []
    private var rows: Set<String> = []
    private var requests: [String] = []
    var registeredIDs: [String] { lock.lock(); defer { lock.unlock() }; return registrations }
    var remainingIDs: Set<String> { lock.lock(); defer { lock.unlock() }; return rows }
    var operations: [String] { lock.lock(); defer { lock.unlock() }; return requests }
    func reply(_ request: URLRequest) -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        let id = request.url!.lastPathComponent
        requests.append("\(request.httpMethod!) \(id)")
        if request.httpMethod == "DELETE" {
            rows.remove(id)
        } else if request.httpMethod == "PUT" {
            registrations.append(id)
            // Match the backend's replacement of older rows for the same token.
            rows = [id]
        }
        return (200, Data("{}".utf8))
    }
}

private final class ResponseGate {
    private let lock = NSLock()
    private var finish: (() -> Void)?
    private var used = false
    var isHolding: Bool { lock.lock(); defer { lock.unlock() }; return finish != nil }
    func holdFirst(_ completion: @escaping () -> Void) {
        lock.lock()
        if !used { used = true; finish = completion; lock.unlock() }
        else { lock.unlock(); completion() }
    }
    func release() {
        lock.lock(); let completion = finish; finish = nil; lock.unlock()
        completion?()
    }
}

private final class OutboxBackend: @unchecked Sendable {
    private let lock = NSLock()
    private let serverID = UUID().pathID
    private var threads: [String: [String: Any]] = [:]
    private var jobs: [String: [[String: Any]]] = [:]
    private var attempts: [(String, String)] = []
    private var allowed = false
    var allowRejected: Bool {
        get { lock.lock(); defer { lock.unlock() }; return allowed }
        set { lock.lock(); defer { lock.unlock() }; allowed = newValue }
    }
    var prompts: [String] { lock.lock(); defer { lock.unlock() }; return attempts.map(\.0) }
    var requestIDs: [String] { lock.lock(); defer { lock.unlock() }; return attempts.map(\.1) }
    func reply(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        let path = request.url!.path
        if path.hasSuffix("capabilities") { return (200, try data(["serverId": serverID, "push": false, "backgroundJobs": true])) }
        if path.hasSuffix("openrouter-key") { return (200, try data(["configured": true])) }
        if path == "/v1/threads", request.httpMethod == "POST" {
            let body = try JSONSerialization.jsonObject(with: StubBackend.body(request)) as! [String: Any]
            let id = body["id"] as! String
            threads[id] = threads[id] ?? ["id": id, "title": "Test", "paused": 0, "created": 1, "revision": 1]
            return (200, try data(threads[id]!))
        }
        if path.hasSuffix("messages") {
            let body = try JSONSerialization.jsonObject(with: StubBackend.body(request)) as! [String: Any]
            let id = body["id"] as! String; let prompt = body["prompt"] as! String
            attempts.append((prompt, id))
            if prompt == "Reject this", !allowed { return (400, try data(["error": "Rejected test send"])) }
            let threadID = path.components(separatedBy: "/")[3]
            let job: [String: Any] = ["id": id, "threadId": threadID, "position": (jobs[threadID]?.count ?? 0) + 1, "prompt": prompt, "model": body["model"]!, "status": "complete", "content": "Accepted \(prompt)", "created": 1, "updated": 2]
            jobs[threadID, default: []].append(job)
            threads[threadID]?["revision"] = jobs[threadID]!.count + 1
            return (200, try data(job))
        }
        if path == "/v1/threads" { return (200, try data(Array(threads.values))) }
        if path.hasPrefix("/v1/threads/"), let id = path.components(separatedBy: "/").last, let thread = threads[id] {
            return (200, try data(thread.merging(["jobs": jobs[id] ?? []]) { _, new in new }))
        }
        return (404, try data(["error": "Unexpected route"]))
    }
}

/// URLProtocol callbacks execute off the main actor. Keep fake server state behind
/// a lock rather than capture XCTest's actor-isolated local variables.
private final class StubBackend: @unchecked Sendable {
    private let lock = NSLock()
    private let serverID = UUID().pathID
    private var threadID = ""
    private var postedIDs: [String] = []
    private var accepted: [String: Any]?
    var sentIDs: [String] { lock.lock(); defer { lock.unlock() }; return postedIDs }
    func reply(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        let path = request.url!.path
        if path.hasSuffix("capabilities") { return (200, try data(["serverId": serverID, "push": false, "backgroundJobs": true])) }
        if path.hasSuffix("openrouter-key") { return (200, try data(["configured": true])) }
        if path == "/v1/threads", request.httpMethod == "POST" {
            let body = try JSONSerialization.jsonObject(with: Self.body(request)) as! [String: Any]
            threadID = body["id"] as! String
            return (200, try data(["id": threadID, "title": "Test", "paused": 0, "created": 1, "revision": 1]))
        }
        if path.hasSuffix("messages") {
            let body = try JSONSerialization.jsonObject(with: Self.body(request)) as! [String: Any]
            let id = body["id"] as! String; postedIDs.append(id)
            accepted = accepted ?? ["id": id, "threadId": threadID, "position": 1, "prompt": body["prompt"]!, "model": body["model"]!, "status": "complete", "content": "Saved answer", "created": 1, "updated": 2]
            if postedIDs.count == 1 { return (503, try data(["error": "Reply lost"])) }
            return (200, try data(accepted!))
        }
        let metadata: [String: Any] = ["id": threadID, "title": "Test", "paused": 0, "created": 1, "revision": 2]
        if path == "/v1/threads" { return (200, try data(threadID.isEmpty ? [] : [metadata])) }
        if path.hasPrefix("/v1/threads/") { return (200, try data(metadata.merging(["jobs": accepted.map { [$0] } ?? []]) { _, new in new })) }
        return (404, try data(["error": "Unexpected route"]))
    }
    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; result.append(contentsOf: buffer.prefix(count)) }
        return result
    }
}
