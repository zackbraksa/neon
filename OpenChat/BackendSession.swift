import CryptoKit
import Foundation

protocol BackendSessionStorage: AnyObject {
    var deviceID: UUID { get }
    func connection() throws -> BackendCredentials?
    func saveConnection(_ credentials: BackendCredentials) throws
    func clearConnection() throws
}

enum NeonBackend {
    static let address = Bundle.main.object(forInfoDictionaryKey: "NeonBackendURL") as? String
        ?? "http://localhost:8080"
    static func matches(_ credentials: BackendCredentials) -> Bool { (try? BackendCredentials.endpoint(address)) == credentials.url }
    static func decode(_ data: Data) throws -> BackendCredentials {
        let decoded = try JSONDecoder().decode(BackendCredentials.self, from: data)
        var result = try BackendCredentials(address: decoded.url.absoluteString, token: decoded.token)
        result.serverID = decoded.serverID
        return result
    }
}

final class SystemBackendSessionStorage: BackendSessionStorage {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var deviceID: UUID {
        if let value = defaults.string(forKey: "backend-session-device-id"), let id = UUID(uuidString: value) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: "backend-session-device-id")
        return id
    }
    func connection() throws -> BackendCredentials? {
        let value = try Keychain.read(account: "backend-connection")
        return value.isEmpty ? nil : try NeonBackend.decode(Data(value.utf8))
    }
    func saveConnection(_ credentials: BackendCredentials) throws {
        let existing = try Keychain.read(account: "backend-connection")
        let previous = try? NeonBackend.decode(Data(existing.utf8))
        if !existing.isEmpty, previous.map({ !NeonBackend.matches($0) }) ?? true {
            let identity = previous.map { $0.url.absoluteString + ($0.serverID?.pathID ?? "") } ?? UUID().uuidString
            let suffix = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            try Keychain.save(existing, account: "backend-legacy-\(suffix)")
        }
        try Keychain.save(String(decoding: JSONEncoder().encode(credentials), as: UTF8.self), account: "backend-connection")
    }
    func clearConnection() throws { try Keychain.save("", account: "backend-connection") }
}

struct BackendSessionClient {
    private let session: URLSession
    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 40
        configuration.timeoutIntervalForResource = 60
        self.session = session ?? URLSession(configuration: configuration)
    }
    func create(key: String, deviceID: UUID) async throws -> BackendCredentials {
        struct Body: Encodable { let key: String; let deviceId: String }
        struct Response: Decodable { let token: String; let serverId: UUID }
        let endpoint = try BackendCredentials.endpoint(NeonBackend.address)
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/sessions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(key: key.trimmingCharacters(in: .whitespacesAndNewlines), deviceId: deviceID.pathID))
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message: String
            switch status {
            case 400: message = "Enter a valid OpenRouter API key."
            case 401: message = "OpenRouter rejected this API key. Check it and try again."
            case 429: message = "Too many connection attempts. Please try again shortly."
            case 503: message = "Neon could not verify your key right now. Please retry."
            default: message = "Neon could not connect (\(status)). Please retry."
            }
            throw BackendFailure(status: status, message: message)
        }
        let issued = try JSONDecoder().decode(Response.self, from: data)
        var credentials = try BackendCredentials(address: NeonBackend.address, token: issued.token)
        credentials.serverID = issued.serverId
        return credentials
    }
}
