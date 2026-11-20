import XCTest
@testable import OpenChat

private final class AllowanceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held: (() -> Void)?
    var isHolding: Bool { lock.lock(); defer { lock.unlock() }; return held != nil }
    func hold(_ work: @escaping () -> Void) { lock.lock(); defer { lock.unlock() }; held = work }
    func release() { lock.lock(); let work = held; held = nil; lock.unlock(); work?() }
}
private final class AllowanceProtocol: URLProtocol {
    static var respond: ((URLRequest, @escaping (Int, Data) -> Void) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.respond?(request) { [self] status, data in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@MainActor final class KeyAllowanceTests: XCTestCase {
    private var directory: URL!
    private var session: URLSession!
    private var remote: RemoteChatStore!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AllowanceProtocol.self]
        session = URLSession(configuration: config)
        var credentials = try BackendCredentials(address: NeonBackend.address, token: String(repeating: "synthetic-session", count: 4))
        credentials.serverID = UUID()
        remote = try RemoteChatStore(client: BackendClient(credentials, session: session), directory: directory)
    }
    override func tearDown() async throws {
        remote.suspend()
        session.invalidateAndCancel()
        AllowanceProtocol.respond = nil
        try? FileManager.default.removeItem(at: directory)
    }
    private func eventually(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected allowance request did not arrive")
    }
    func testAllowanceUsesAuthenticatedWorkspaceRequestAndHandlesUnlimitedKey() async {
        let pin = remote.client.credentials.serverID!.pathID
        AllowanceProtocol.respond = { request, finish in
            XCTAssertEqual(request.url?.path, "/v1/settings/openrouter-allowance")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-OpenChat-Server-ID"), pin)
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
            finish(200, Data("{\"configured\":true,\"limit\":null,\"remaining\":null}".utf8))
        }
        await remote.refreshKeyAllowance()
        XCTAssertEqual(remote.keyAllowance, .loaded(KeyAllowance(configured: true, limit: nil, remaining: nil)))
    }
    func testOldAllowanceResponseCannotReplaceNewKeyAllowance() async {
        let gate = AllowanceGate()
        AllowanceProtocol.respond = { _, finish in gate.hold { finish(200, Data("{\"configured\":true,\"limit\":20,\"remaining\":2}".utf8)) } }
        let original = Task { await remote.refreshKeyAllowance() }
        await eventually { gate.isHolding }
        remote.invalidateKeyAllowance()
        AllowanceProtocol.respond = { _, finish in finish(200, Data("{\"configured\":true,\"limit\":100,\"remaining\":90}".utf8)) }
        await remote.refreshKeyAllowance()
        gate.release(); await original.value
        XCTAssertEqual(remote.keyAllowance, .loaded(KeyAllowance(configured: true, limit: 100, remaining: 90)))
    }
    func testSuspensionDiscardsInFlightAllowance() async {
        let gate = AllowanceGate()
        AllowanceProtocol.respond = { _, finish in gate.hold { finish(200, Data("{\"configured\":true,\"limit\":20,\"remaining\":2}".utf8)) } }
        let request = Task { await remote.refreshKeyAllowance() }
        await eventually { gate.isHolding }
        remote.suspend()
        gate.release(); await request.value
        XCTAssertEqual(remote.keyAllowance, .idle)
    }
    func testProviderFailureStaysInlineWithoutExposingResponseDetails() async {
        AllowanceProtocol.respond = { _, finish in finish(503, Data("{\"error\":\"synthetic-private-upstream-body\"}".utf8)) }
        await remote.refreshKeyAllowance()
        XCTAssertEqual(remote.keyAllowance, .unavailable)
        XCTAssertNil(remote.error)
        XCTAssertFalse(remote.requiresAuthentication)
    }
}
