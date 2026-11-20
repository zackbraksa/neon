import Foundation
import Security

struct ConversationDisk {
    let directory: URL
    let recoverStreaming: Bool
    init(directory: URL? = nil, recoverStreaming: Bool = true) throws {
        self.recoverStreaming = recoverStreaming
        self.directory = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("OpenChat", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }
    func load() throws -> [Conversation] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { url in
                var chat = try JSONDecoder().decode(Conversation.self, from: Data(contentsOf: url))
                if recoverStreaming { chat.recover() }
                return chat
            }.sorted { $0.updated > $1.updated }
    }
    func save(_ chat: Conversation) throws {
        let data = try JSONEncoder().encode(chat)
        try data.write(to: directory.appendingPathComponent("\(chat.id).json"), options: .atomic)
    }
    func delete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
    }
}

enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "OpenChat.OpenRouter", kSecAttrAccount as String: account]
    }
    static func read(account: String = "api-key") throws -> String {
        var request = query(account)
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw RouterError(message: "Unable to read the API key from Keychain (\(status)).")
        }
        return key
    }
    static func save(_ key: String, account: String = "api-key") throws {
        let query = query(account)
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw RouterError(message: "Could not remove the key (\(status)).") }
            return
        }
        let values = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(values) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw RouterError(message: "Could not save the key (\(status)).") }
    }
}
