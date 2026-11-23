import XCTest
@testable import OpenChat

private final class OllamaURLProtocol: URLProtocol {
    static var respond: ((URLRequest) throws -> (Int, [Data], Bool))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var observed = request
            if observed.httpBody == nil, let stream = observed.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var bytes = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    data.append(contentsOf: bytes.prefix(count))
                }
                observed.httpBody = data
            }
            let (status, chunks, finishes) = try Self.respond!(observed)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/x-ndjson"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for data in chunks { client?.urlProtocol(self, didLoad: data) }
            if finishes { client?.urlProtocolDidFinishLoading(self) }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor private final class ControlledChatTransport: DirectChatTransport {
    struct Call {
        let model: String
        let messages: [WireMessage]
        let continuation: CheckedContinuation<String, Error>
    }
    var calls: [Call] = []
    func models() async throws -> [RouterModel] { [RouterModel(id: "ollama://test:latest", name: "test:latest")] }
    func stream(key: String, model: String, messages: [WireMessage], onMetadata: (@MainActor (ResponseMetadata) -> Void)?, onText: @MainActor (String) -> Void) async throws {
        await onText("Partial ")
        let text = try await withCheckedThrowingContinuation { continuation in
            calls.append(Call(model: model, messages: messages, continuation: continuation))
        }
        await onText(text)
        await onMetadata?(ResponseMetadata(inputTokens: 2, outputTokens: 3))
    }
}

@MainActor private final class BlockedCatalogTransport: DirectChatTransport {
    var pending: CheckedContinuation<[RouterModel], Error>?
    func models() async throws -> [RouterModel] {
        try await withCheckedThrowingContinuation { pending = $0 }
    }
    func stream(key: String, model: String, messages: [WireMessage], onMetadata: (@MainActor (ResponseMetadata) -> Void)?, onText: @MainActor (String) -> Void) async throws {
        throw RouterError(message: "No generation in catalog test")
    }
}

@MainActor final class OllamaTests: XCTestCase {
    private var directory: URL!
    private var session: URLSession!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaURLProtocol.self]
        session = URLSession(configuration: configuration)
    }
    override func tearDown() async throws {
        session.invalidateAndCancel()
        OllamaURLProtocol.respond = nil
        try? FileManager.default.removeItem(at: directory)
    }
    private func eventually(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected local chat state")
    }
    private func local(_ transport: any DirectChatTransport = Ollama()) throws -> DirectChatStore {
        DirectChatStore(storage: try ConversationDisk(directory: directory.appendingPathComponent("ollama")),
                        readKey: { XCTFail("Ollama must not read Keychain"); return "" },
                        router: transport, requiresKey: false, defaultModel: "")
    }
    func testCatalogNamesAreQualifiedAndCannotCollideWithOpenRouterIDs() async throws {
        OllamaURLProtocol.respond = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/api/tags")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, [Data("{\"models\":[{\"name\":\"test:latest\"},{\"name\":\"another:small\"}]}".utf8)], true)
        }
        let models = try await Ollama(session: session).models()
        XCTAssertEqual(models.map(\.id), ["ollama://another:small", "ollama://test:latest"])
        XCTAssertEqual(models.map(\.name), ["another:small", "test:latest"])
        XCTAssertFalse(Ollama.isModel("test:latest"))
        XCTAssertFalse(Ollama.isModel("ollama/test:latest"))
    }
    func testStreamHandlesFragmentedUnicodeAndFinalUsageWithoutCost() async throws {
        let stream = "{\"message\":{\"content\":\"Hello 🌍\"},\"done\":false}\n{\"message\":{\"content\":\"!\"},\"done\":true,\"model\":\"test:latest\",\"prompt_eval_count\":4,\"eval_count\":7}"
        let data = Data(stream.utf8)
        OllamaURLProtocol.respond = { request in
            XCTAssertEqual(request.url?.path, "/api/chat")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, "test:latest")
            XCTAssertEqual(body["stream"] as? Bool, true)
            XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["content"], "Hello")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, data.map { Data([$0]) }, true)
        }
        var text = ""
        var metadata: ResponseMetadata?
        try await Ollama(session: session).stream(key: "", model: "ollama://test:latest", messages: [WireMessage(role: "user", content: "Hello")], onMetadata: { metadata = $0 }) { text += $0 }
        XCTAssertEqual(text, "Hello 🌍!")
        XCTAssertEqual(metadata?.inputTokens, 4)
        XCTAssertEqual(metadata?.outputTokens, 7)
        XCTAssertNil(metadata?.costUSD)
    }
    func testEOFAndStreamErrorPreservePartialWithoutEchoingProviderError() async throws {
        for ending in ["", "{\"error\":\"private provider detail\"}\n", "invalid json\n"] {
            OllamaURLProtocol.respond = { _ in
                (200, [Data(("{\"message\":{\"content\":\"Partial\"},\"done\":false}\n" + ending).utf8)], true)
            }
            var text = ""
            do {
                try await Ollama(session: session).stream(key: "", model: "test", messages: []) { text += $0 }
                XCTFail("Incomplete or invalid stream must fail")
            } catch {
                XCTAssertEqual(text, "Partial")
                XCTAssertFalse(error.localizedDescription.contains("private provider detail"))
            }
        }
    }
    func testHTTPFailureDoesNotEchoResponseBody() async throws {
        OllamaURLProtocol.respond = { _ in (404, [Data("private model prompt".utf8)], true) }
        do {
            try await Ollama(session: session).stream(key: "", model: "test", messages: []) { _ in XCTFail("No text expected") }
            XCTFail("HTTP failure must fail")
        } catch { XCTAssertFalse(error.localizedDescription.contains("private model prompt")) }
    }
    func testCancelDoesNotTreatPartialAsCompleted() async throws {
        OllamaURLProtocol.respond = { _ in (200, [Data("{\"message\":{\"content\":\"Partial\"},\"done\":false}\n".utf8)], false) }
        var text = ""
        let task = Task { try await Ollama(session: session).stream(key: "", model: "test", messages: []) { text += $0 } }
        await eventually { text == "Partial" }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled stream must fail") } catch {}
        XCTAssertEqual(text, "Partial")
    }
    func testDirectQueueOrderStaleCallbacksAndPersistence() async throws {
        let transport = ControlledChatTransport()
        let store = try local(transport)
        let id = try XCTUnwrap(store.selectedID)
        XCTAssertEqual(store.chat(id)?.model, "")
        store.setDraft(id, text: "First")
        store.send(id)
        XCTAssertEqual(store.chat(id)?.draft, "First")
        XCTAssertTrue(transport.calls.isEmpty)
        store.error = nil
        store.update(id) { $0.model = "ollama://test:latest" }
        store.send(id)
        await eventually { transport.calls.count == 1 }
        store.setDraft(id, text: "Second"); store.send(id)
        store.setDraft(id, text: "Third"); store.send(id)
        XCTAssertEqual(transport.calls[0].messages.map(\.content), ["First"])
        transport.calls[0].continuation.resume(returning: "one")
        await eventually { transport.calls.count == 2 }
        XCTAssertEqual(transport.calls[1].messages.map(\.content), ["First", "Partial one", "Second"])
        store.stop(id)
        store.resume(id)
        await eventually { transport.calls.count == 3 }
        transport.calls[1].continuation.resume(returning: "stale")
        transport.calls[2].continuation.resume(returning: "three")
        await eventually { store.active.isEmpty }
        XCTAssertFalse(store.chat(id)!.messages.contains { $0.content.contains("stale") })
        XCTAssertEqual(store.chat(id)?.messages.map(\.role), [.user, .assistant, .user, .assistant, .user, .assistant])
        store.setDraft(id, text: "Saved draft")
        store.pauseAll()
        let restored = try local(transport)
        XCTAssertEqual(restored.chat(id)?.draft, "Saved draft")
        XCTAssertEqual(restored.chat(id)?.messages.last?.status, .complete)
        XCTAssertEqual(restored.chat(id)?.messages.last?.outputTokens, 3)
    }
    func testLocalPermanentDeletionStopsGenerationAndDoesNotReturnOnDisk() async throws {
        let transport = ControlledChatTransport()
        let store = try local(transport)
        let id = try XCTUnwrap(store.selectedID)
        store.update(id) { $0.model = "ollama://test:latest"; $0.draft = "Delete me" }
        store.send(id)
        await eventually { transport.calls.count == 1 }
        store.setDraft(id, text: "Delete queued"); store.send(id)
        store.setDraft(id, text: "Delete draft")
        try store.delete(id)
        transport.calls[0].continuation.resume(returning: "Late response")
        await Task.yield()
        store.pauseAll()
        XCTAssertNil(store.chat(id)); XCTAssertNil(store.active[id])
        XCTAssertTrue(try ConversationDisk(directory: directory.appendingPathComponent("ollama")).load().isEmpty)
    }
    func testLocalArchiveRestorePreservesDraftQueueAndPausedState() async throws {
        let store = try local()
        let id = try XCTUnwrap(store.selectedID)
        store.update(id) { $0.draft = "Keep draft"; $0.enqueue("Keep queue") }
        store.archive(id)
        store.restore(id)
        XCTAssertEqual(store.chat(id)?.draft, "Keep draft")
        XCTAssertEqual(store.chat(id)?.messages.first?.status, .queued)
        XCTAssertEqual(store.chat(id)?.paused, true)
        XCTAssertTrue(store.active.isEmpty)
        XCTAssertEqual(try ConversationDisk(directory: directory.appendingPathComponent("ollama")).load().count, 1)
    }
    func testSharedFacadeKeepsProviderHistoryAndBackendOutboxIsolated() async throws {
        let storage = FakeBackendSessionStorage()
        var credentials = try BackendCredentials(address: NeonBackend.address, token: String(repeating: "synthetic", count: 5))
        credentials.serverID = UUID()
        let remoteRoot = directory.appendingPathComponent("remote")
        let remote = try RemoteChatStore(client: BackendClient(credentials, session: session), directory: remoteRoot)
        remote.newChat()
        let remoteID = try XCTUnwrap(remote.selectedID)
        remote.setDraft(remoteID, text: "Backend pending"); remote.enqueue(remoteID)
        remote.setDraft(remoteID, text: "Backend draft")
        let outbox = try Data(contentsOf: remoteRoot.appendingPathComponent("outbox.data"))
        let local = try local()
        let direct = DirectChatStore(storage: try ConversationDisk(directory: directory.appendingPathComponent("legacy")), readKey: { "" })
        let facade = ChatStore(direct: direct, remote: remote, sessions: storage, push: storage.pushCoordinator(), ollama: local)
        facade.chooseModel("ollama://test:latest", for: remoteID)
        let localID = try XCTUnwrap(facade.selectedID)
        XCTAssertNotEqual(localID, remoteID)
        XCTAssertTrue(facade.isLocalConversation)
        XCTAssertEqual(facade.chat(remoteID)?.draft, "Backend draft")
        XCTAssertEqual(facade.chat(localID)?.draft, "")
        XCTAssertTrue(facade.conversations.contains { $0.id == remoteID })
        XCTAssertEqual(try Data(contentsOf: remoteRoot.appendingPathComponent("outbox.data")), outbox)
        facade.setDraft(localID, text: "Local draft")
        try await facade.setMetadata(localID, title: "Local title", pinned: true)
        facade.archive(localID)
        XCTAssertTrue(facade.archivedConversations.contains { $0.id == localID })
        try await facade.restore(localID)
        facade.selectedID = remoteID
        XCTAssertFalse(facade.isLocalConversation)
        XCTAssertEqual(facade.chat(localID)?.draft, "Local draft")
        XCTAssertEqual(facade.chat(localID)?.title, "Local title")
        XCTAssertTrue(facade.chat(localID)?.isPinned == true)
        facade.background()
        XCTAssertEqual(try Data(contentsOf: remoteRoot.appendingPathComponent("outbox.data")), outbox)
        XCTAssertEqual(storage.clears, 0)
    }
    func testLocalEntryBypassesKeySetupAndRetainsPreference() throws {
        let suite = "Neon.OllamaTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = FakeBackendSessionStorage()
        let local = try local()
        let direct = DirectChatStore(storage: try ConversationDisk(directory: directory.appendingPathComponent("legacy")), readKey: { "" })
        let facade = ChatStore(direct: direct, sessions: storage, push: storage.pushCoordinator(), ollama: local, preferences: defaults)
        XCTAssertTrue(facade.needsBackendConnection)
        facade.useOllama()
        XCTAssertFalse(facade.needsBackendConnection)
        XCTAssertTrue(facade.isLocalConversation)
        let id = try XCTUnwrap(facade.selectedID)
        facade.setDraft(id, text: "Local only"); facade.background()
        let restored = ChatStore(direct: direct, sessions: storage, push: storage.pushCoordinator(), ollama: try self.local(), preferences: defaults)
        XCTAssertFalse(restored.needsBackendConnection)
        XCTAssertEqual(restored.chat(id)?.draft, "Local only")
        XCTAssertEqual(storage.saves, 0)
        XCTAssertNil(storage.saved)
    }
    func testFirstOpenRouterConnectionFromOllamaDefaultsToAuto() async throws {
        let storage = FakeBackendSessionStorage()
        var credentials = try BackendCredentials(address: NeonBackend.address, token: String(repeating: "synthetic", count: 5))
        credentials.serverID = UUID()
        let remote = try RemoteChatStore(client: BackendClient(credentials, session: session),
                                         directory: directory.appendingPathComponent("remote"))
        let direct = DirectChatStore(storage: try ConversationDisk(directory: directory.appendingPathComponent("legacy")), readKey: { "" })
        let facade = ChatStore(direct: direct, sessions: storage, push: storage.pushCoordinator(), ollama: try local(),
                               makeRemote: { _ in remote }, createSession: { _, _ in credentials })
        facade.useOllama()
        let localID = try XCTUnwrap(facade.selectedID)
        facade.chooseModel("ollama://test:latest", for: localID)
        facade.setDraft(localID, text: "Local draft")

        let connected = await facade.saveProviderKey("synthetic-openrouter-key")
        XCTAssertTrue(connected)
        XCTAssertFalse(facade.isLocalConversation)
        if facade.selectedID == nil { facade.newChat() }

        let activeID = try XCTUnwrap(facade.selectedID)
        XCTAssertEqual(facade.chat(activeID)?.model, "openrouter/auto")
        XCTAssertEqual(facade.chat(localID)?.model, "ollama://test:latest")
        XCTAssertEqual(facade.chat(localID)?.draft, "Local draft")
    }
    func testRemoteNotificationNavigatesAwayFromSelectedOllamaChat() async throws {
        let suite = "Neon.OllamaNotificationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let serverID = UUID(), threadID = UUID(), jobID = UUID()
        let job = BackendJob(id: jobID, threadId: threadID, position: 0, prompt: "Question", model: "openrouter/auto", status: .complete, content: "Answer", created: 1, updated: 2)
        defaults.set(try JSONEncoder().encode(NotificationTarget(jobID: jobID, serverID: serverID)), forKey: "pending-notification")
        let push = PushCoordinator(defaults: defaults)
        var credentials = try BackendCredentials(address: NeonBackend.address, token: String(repeating: "synthetic", count: 5))
        credentials.serverID = serverID
        let remote = try RemoteChatStore(client: BackendClient(credentials, session: session), directory: directory.appendingPathComponent("notification-remote"))
        let direct = DirectChatStore(storage: try ConversationDisk(directory: directory.appendingPathComponent("legacy")), readKey: { "" })
        let storage = FakeBackendSessionStorage()
        let facade = ChatStore(direct: direct, remote: remote, sessions: storage, push: push, ollama: try local())
        facade.useOllama()
        XCTAssertTrue(facade.isLocalConversation)
        let jobObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job))
        OllamaURLProtocol.respond = { request in
            let body: Any
            if request.url?.path == "/v1/capabilities" {
                body = ["push": true, "backgroundJobs": true, "serverId": serverID.uuidString]
            } else if request.url?.path == "/v1/jobs/" + jobID.pathID {
                body = jobObject
            } else {
                XCTAssertEqual(request.url?.path, "/v1/threads/" + threadID.pathID)
                body = ["id": threadID.uuidString, "title": "Remote answer", "paused": 0, "created": 1, "revision": 1, "jobs": [jobObject]] as [String: Any]
            }
            return (200, [try JSONSerialization.data(withJSONObject: body)], true)
        }
        await facade.openPendingNotification()
        XCTAssertFalse(facade.isLocalConversation)
        XCTAssertEqual(facade.selectedID, threadID)
        XCTAssertNil(push.pending)
        facade.background()
    }

    func testLocalDiscoveryDoesNotWaitForOpenRouterAndCatalogIDsStayDistinct() async throws {
        let storage = FakeBackendSessionStorage()
        let slow = BlockedCatalogTransport()
        let direct = DirectChatStore(storage: try ConversationDisk(directory: directory.appendingPathComponent("catalog")), readKey: { "" }, router: slow)
        let facade = ChatStore(direct: direct, sessions: storage, push: storage.pushCoordinator(), ollama: try local(ControlledChatTransport()))
        let load = Task { await facade.loadModels() }
        await eventually { slow.pending != nil && facade.models.contains { $0.id == "ollama://test:latest" } }
        XCTAssertEqual(facade.models.count, 1)
        XCTAssertNil(facade.error)
        slow.pending?.resume(returning: [RouterModel(id: "test:latest", name: "test:latest")])
        await load.value
        XCTAssertEqual(Set(facade.models.map(\.id)), Set(["test:latest", "ollama://test:latest"]))
    }

}
