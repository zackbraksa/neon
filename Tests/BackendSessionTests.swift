import XCTest
@testable import OpenChat

final class FakeBackendSessionStorage: BackendSessionStorage {
    let deviceID = UUID()
    var saved: BackendCredentials?
    var archived: [BackendCredentials] = []
    var saves = 0
    var clears = 0
    private let suite = "Neon.BackendSessionTests.\(UUID().uuidString)"
    private let defaults: UserDefaults
    init() { defaults = UserDefaults(suiteName: suite)! }
    deinit { defaults.removePersistentDomain(forName: suite) }
    func connection() throws -> BackendCredentials? { saved }
    func saveConnection(_ credentials: BackendCredentials) throws {
        if let saved, !NeonBackend.matches(saved) { archived.append(saved) }
        saved = credentials; saves += 1
    }
    func clearConnection() throws { saved = nil; clears += 1 }
    @MainActor func pushCoordinator() -> PushCoordinator { PushCoordinator(defaults: defaults) }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return values }
    func append(_ request: URLRequest) {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
            request.httpBody = data
        }
        lock.lock(); defer { lock.unlock() }; values.append(request)
    }
}
private final class SessionURLProtocol: URLProtocol {
    static var respond: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let respond = Self.respond else { throw URLError(.notConnectedToInternet) }
            let (status, data) = try respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor final class BackendSessionTests: XCTestCase {
    private var directory: URL!
    private var session: URLSession!
    private var stores: [ChatStore] = []
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionURLProtocol.self]
        session = URLSession(configuration: configuration)
    }
    override func tearDown() async throws {
        stores.forEach { $0.background() }; stores.removeAll()
        await Task.yield()
        session.invalidateAndCancel()
        SessionURLProtocol.respond = nil
        try? FileManager.default.removeItem(at: directory)
    }
    private func credentials(address: String = NeonBackend.address, pin: UUID = UUID()) throws -> BackendCredentials {
        var result = try BackendCredentials(address: address, token: String(repeating: "issued-session-", count: 4))
        result.serverID = pin
        return result
    }
    private func makeStore(_ storage: FakeBackendSessionStorage,
                           create: ((String, UUID) async throws -> BackendCredentials)? = nil,
                           restored: ((BackendCredentials) -> Void)? = nil) throws -> ChatStore {
        let direct = DirectChatStore(storage: try ConversationDisk(directory: directory.appendingPathComponent("direct")), readKey: { "" }, router: OpenRouter(session: session))
        let session = session!
        let root = directory!
        let client = BackendSessionClient(session: session)
        let store = ChatStore(direct: direct, sessions: storage, push: storage.pushCoordinator(), makeRemote: { credentials in
            restored?(credentials)
            let namespace = RemoteChatStore.namespace(credentials.url, serverID: credentials.serverID)
            return try RemoteChatStore(client: BackendClient(credentials, session: session), directory: root.appendingPathComponent(namespace))
        }, createSession: create ?? { try await client.create(key: $0, deviceID: $1) })
        stores.append(store)
        return store
    }
    private func response(_ credentials: BackendCredentials) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["token": credentials.token, "serverId": credentials.serverID!.uuidString])
    }
    private func eventually(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected session state did not arrive")
    }
    func testCatalogFailureReachesFacadeWithoutLiveRequests() async throws {
        let store = try makeStore(FakeBackendSessionStorage())
        SessionURLProtocol.respond = { _ in throw URLError(.notConnectedToInternet) }
        await store.loadModels()
        XCTAssertNotNil(store.error)
    }
    func testHostedTestsUseInertAppEntry() { XCTAssertTrue(AppRuntime.isTestHost) }

    func testFreshInstallHasNoDirectComposerOrConfiguredProviderKey() throws {
        let storage = FakeBackendSessionStorage()
        let store = try makeStore(storage)
        XCTAssertTrue(store.needsBackendConnection)
        XCTAssertFalse(store.hasKey)
        XCTAssertFalse(store.isRemote)
        XCTAssertNil(store.selectedID)
        store.newChat()
        XCTAssertTrue(store.conversations.isEmpty)
        XCTAssertEqual(storage.saves, 0)
    }
    func testExplicitKeyCreatesPinnedSessionWithoutOldAuthAndRestoresAfterRelaunch() async throws {
        let storage = FakeBackendSessionStorage()
        let issued = try credentials()
        let data = try response(issued)
        let log = RequestLog()
        SessionURLProtocol.respond = { request in log.append(request); return (200, data) }
        let store = try makeStore(storage)
        let connected = await store.saveProviderKey("synthetic-openrouter-key")
        XCTAssertTrue(connected)
        XCTAssertEqual(storage.saved, issued)
        XCTAssertNotEqual(storage.saved?.token, "synthetic-openrouter-key")
        let request = try XCTUnwrap(log.requests.first)
        XCTAssertEqual(request.url?.absoluteString, NeonBackend.address + "/v1/sessions")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-OpenChat-Server-ID"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["key": "synthetic-openrouter-key", "deviceId": storage.deviceID.pathID])
        store.newChat(); let id = try XCTUnwrap(store.selectedID)
        store.setDraft(id, text: "Keep my unfinished thought")
        store.background()
        let restored = try makeStore(storage)
        XCTAssertTrue(restored.isRemote)
        XCTAssertFalse(restored.needsBackendConnection)
        XCTAssertEqual(restored.chat(id)?.draft, "Keep my unfinished thought")
        XCTAssertEqual(log.requests.count, 1)
    }
    func testUncertainSessionRetryKeepsStableDeviceID() async throws {
        let storage = FakeBackendSessionStorage()
        let log = RequestLog()
        SessionURLProtocol.respond = { request in log.append(request); throw URLError(.networkConnectionLost) }
        let store = try makeStore(storage)
        let first = await store.saveProviderKey("synthetic-openrouter-key")
        XCTAssertFalse(first)
        XCTAssertNil(storage.saved)
        let data = try response(credentials())
        SessionURLProtocol.respond = { request in log.append(request); return (200, data) }
        let second = await store.saveProviderKey("synthetic-openrouter-key")
        XCTAssertTrue(second)
        XCTAssertEqual(log.requests.count, 2)
        let expected = ["key": "synthetic-openrouter-key", "deviceId": storage.deviceID.pathID]
        for request in log.requests {
            let body = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(request.httpBody))
            XCTAssertEqual(body, expected)
        }
    }
    func testRejectedKeyDoesNotPersistOrEchoProviderKey() async throws {
        let storage = FakeBackendSessionStorage()
        let key = "synthetic-private-input"
        let data = try JSONSerialization.data(withJSONObject: ["error": key])
        SessionURLProtocol.respond = { _ in (401, data) }
        let store = try makeStore(storage)
        let connected = await store.saveProviderKey(key)
        XCTAssertFalse(connected)
        XCTAssertNil(storage.saved)
        guard case .failed(let message) = store.bootstrap else { return XCTFail("Expected key error") }
        XCTAssertFalse(message.contains(key))
        XCTAssertTrue(message.contains("rejected"))
    }
    func testLegacyNeonOwnerConnectionRestoresOriginalPin() throws {
        let storage = FakeBackendSessionStorage()
        let legacy = try credentials()
        storage.saved = legacy
        var restored: BackendCredentials?
        let store = try makeStore(storage, restored: { restored = $0 })
        XCTAssertTrue(store.isRemote)
        XCTAssertFalse(store.needsBackendConnection)
        XCTAssertEqual(storage.saves, 0)
        XCTAssertEqual(restored?.serverID, legacy.serverID)
        XCTAssertEqual(restored?.token, legacy.token)
    }
    func testCustomLegacyConnectionIsNotContactedOrSilentlyMerged() async throws {
        let storage = FakeBackendSessionStorage()
        let legacy = try credentials(address: "https://old.example.test")
        storage.saved = legacy
        let store = try makeStore(storage)
        XCTAssertTrue(store.needsBackendConnection)
        XCTAssertFalse(store.isRemote)
        XCTAssertEqual(storage.saved, legacy)
        let issued = try credentials()
        let data = try response(issued)
        SessionURLProtocol.respond = { _ in (200, data) }
        let connected = await store.saveProviderKey("synthetic-new-key")
        XCTAssertTrue(connected)
        XCTAssertEqual(storage.archived, [legacy])
        XCTAssertTrue(store.conversations.isEmpty)
    }
    func testKeyRotationUsesPUTAnd409KeepsSessionHistoryAndDraft() async throws {
        let storage = FakeBackendSessionStorage()
        let issued = try credentials()
        storage.saved = issued
        let store = try makeStore(storage)
        store.newChat(); let id = try XCTUnwrap(store.selectedID)
        store.setDraft(id, text: "Keep this draft")
        let log = RequestLog()
        SessionURLProtocol.respond = { request in log.append(request); return (409, Data("{\"error\":\"This key belongs to another workspace\"}".utf8)) }
        let changed = await store.saveProviderKey("synthetic-conflicting-key")
        XCTAssertFalse(changed)
        XCTAssertEqual(storage.saved, issued)
        XCTAssertEqual(store.selectedID, id)
        XCTAssertEqual(store.chat(id)?.draft, "Keep this draft")
        XCTAssertEqual(log.requests.first?.httpMethod, "PUT")
        XCTAssertEqual(log.requests.first?.url?.path, "/v1/settings/openrouter-key")
        XCTAssertEqual(log.requests.first?.value(forHTTPHeaderField: "X-OpenChat-Server-ID"), issued.serverID?.pathID)
        SessionURLProtocol.respond = { request in log.append(request); return (422, Data("{\"error\":\"OpenRouter rejected this key\"}".utf8)) }
        let rejected = await store.saveProviderKey("synthetic-invalid-provider-key")
        XCTAssertFalse(rejected)
        XCTAssertFalse(store.needsBackendConnection)
        XCTAssertFalse(store.authenticationRequired)
        XCTAssertEqual(store.chat(id)?.draft, "Keep this draft")
        XCTAssertEqual(storage.saved, issued)
        SessionURLProtocol.respond = { request in log.append(request); return (200, Data("{\"configured\":true}".utf8)) }
        let updated = await store.saveProviderKey("synthetic-replacement-key")
        XCTAssertTrue(updated)
        XCTAssertEqual(storage.saved, issued)
        XCTAssertEqual(store.chat(id)?.draft, "Keep this draft")
        XCTAssertEqual(storage.saves, 0)
    }
    func testDeletingProviderKeyKeepsAuthenticatedHistory() async throws {
        let storage = FakeBackendSessionStorage()
        storage.saved = try credentials()
        let store = try makeStore(storage)
        store.newChat(); let id = try XCTUnwrap(store.selectedID)
        SessionURLProtocol.respond = { _ in (200, Data("{\"configured\":false}".utf8)) }
        let removed = await store.saveProviderKey("")
        XCTAssertTrue(removed)
        XCTAssertTrue(store.isRemote)
        XCTAssertNotNil(store.chat(id))
        XCTAssertNotNil(storage.saved)
        XCTAssertEqual(storage.clears, 0)
    }
    func testLateBootstrapCannotAdoptAfterBackgroundCancellation() async throws {
        let storage = FakeBackendSessionStorage()
        var pending: CheckedContinuation<BackendCredentials, Error>?
        let store = try makeStore(storage, create: { _, _ in try await withCheckedThrowingContinuation { pending = $0 } })
        let task = Task { await store.saveProviderKey("synthetic-key") }
        await eventually { pending != nil }
        store.background()
        pending?.resume(returning: try credentials())
        let connected = await task.value
        XCTAssertFalse(connected)
        XCTAssertNil(storage.saved)
        XCTAssertTrue(store.needsBackendConnection)
    }
    func testUnauthorizedSessionPreservesOutboxAndDraftForReauthentication() async throws {
        let issued = try credentials()
        let root = directory.appendingPathComponent("expired")
        let remote = try RemoteChatStore(client: BackendClient(issued, session: session), directory: root)
        remote.newChat(); let id = try XCTUnwrap(remote.selectedID)
        remote.setDraft(id, text: "Queued message"); remote.enqueue(id)
        remote.setDraft(id, text: "Next unsent draft")
        let before = try Data(contentsOf: root.appendingPathComponent("outbox.data"))
        SessionURLProtocol.respond = { _ in (401, Data("{\"error\":\"Unauthorized\"}".utf8)) }
        remote.start()
        await eventually { remote.requiresAuthentication }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("outbox.data")), before)
        XCTAssertEqual(remote.chat(id)?.draft, "Next unsent draft")
        XCTAssertTrue(remote.connectionStatus.contains("Reconnect"))
        remote.suspend()
    }
    func testReauthenticationCannotReplaceCurrentWorkspaceWithAnotherKey() async throws {
        let storage = FakeBackendSessionStorage()
        let previous = try credentials()
        storage.saved = previous
        let store = try makeStore(storage)
        store.newChat(); let id = try XCTUnwrap(store.selectedID)
        store.setDraft(id, text: "Keep my existing workspace draft")
        SessionURLProtocol.respond = { _ in (401, Data("{\"error\":\"Unauthorized\"}".utf8)) }
        let expired = await store.saveProviderKey("synthetic-key")
        XCTAssertFalse(expired)
        XCTAssertTrue(store.authenticationRequired)
        let other = try credentials()
        let data = try response(other)
        SessionURLProtocol.respond = { _ in (200, data) }
        let switched = await store.saveProviderKey("synthetic-other-workspace-key")
        XCTAssertFalse(switched)
        XCTAssertEqual(storage.saved, previous)
        XCTAssertEqual(store.chat(id)?.draft, "Keep my existing workspace draft")
        XCTAssertTrue(store.needsBackendConnection)
        guard case .failed(let message) = store.bootstrap else { return XCTFail("Expected workspace mismatch") }
        XCTAssertTrue(message.contains("different workspace"))
    }
    func testSessionDeviceIDPersistsAndIsIndependentOfPushRotation() throws {
        let suite = "Neon.SessionIdentityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = SystemBackendSessionStorage(defaults: defaults).deviceID
        _ = PushCoordinator(defaults: defaults).rotateRegistration()
        XCTAssertEqual(SystemBackendSessionStorage(defaults: defaults).deviceID, first)
    }
    func testPushRegistrationDoesNotReuseAnotherWorkspaceSignature() async throws {
        let storage = FakeBackendSessionStorage()
        let push = storage.pushCoordinator()
        let one = try credentials(), two = try credentials()
        let log = RequestLog()
        SessionURLProtocol.respond = { request in
            log.append(request)
            if request.value(forHTTPHeaderField: "X-OpenChat-Server-ID") == one.serverID?.pathID { return (200, Data("{}".utf8)) }
            return (409, Data("{\"error\":\"Device token belongs to another workspace\"}".utf8))
        }
        try await push.registerDevice(token: "synthetic-apns-token", with: BackendClient(one, session: session))
        do {
            try await push.registerDevice(token: "synthetic-apns-token", with: BackendClient(two, session: session))
            XCTFail("A different workspace must not reuse the previous registration signature")
        } catch let failure as BackendFailure { XCTAssertEqual(failure.status, 409) }
        XCTAssertEqual(log.requests.count, 2)
        XCTAssertEqual(log.requests.map { $0.value(forHTTPHeaderField: "X-OpenChat-Server-ID") }, [one.serverID?.pathID, two.serverID?.pathID])
    }
}
