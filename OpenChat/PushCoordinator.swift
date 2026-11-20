import Foundation
import Observation
import UserNotifications
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension Notification.Name {
    static let backendDidSync = Notification.Name("OpenChat.backendDidSync")
    static let pushTokenChanged = Notification.Name("OpenChat.pushTokenChanged")
    static let answerNotificationOpened = Notification.Name("OpenChat.answerNotificationOpened")
}
struct NotificationTarget: Codable {
    let jobID: UUID
    let serverID: UUID
}
@MainActor @Observable
final class PushCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushCoordinator()
    var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "push-enabled") }
    }
    var status = "Notifications are off"
    private(set) var pending: NotificationTarget?
    @ObservationIgnored private var registering = false
    @ObservationIgnored private var lastRegistration: String?
    @ObservationIgnored private var deviceUpdates: [String: (id: UUID, task: Task<Void, Error>)] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    private override convenience init() { self.init(defaults: .standard) }
    init(defaults: UserDefaults) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "push-enabled")
        if let data = defaults.data(forKey: "pending-notification") {
            pending = try? JSONDecoder().decode(NotificationTarget.self, from: data)
        }
        super.init()
        if enabled { status = "Waiting for device registration" }
    }
    private var deviceID: UUID {
        if let value = defaults.string(forKey: "push-device-id"), let id = UUID(uuidString: value) { return id }
        let id = UUID(); defaults.set(id.uuidString, forKey: "push-device-id"); return id
    }
    func installDelegate() { UNUserNotificationCenter.current().delegate = self }
    func enable(with client: BackendClient) async {
        do {
            let capabilities: BackendCapabilities = try await client.get("v1/capabilities")
            guard capabilities.push else { status = "Completion alerts are unavailable on this connection."; return }
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            guard allowed else { status = "Allow notifications in system settings to receive alerts"; return }
            enabled = true
            registerWithApple()
            await register(with: client)
        } catch { status = "Could not enable notifications: \(error.localizedDescription)" }
    }
    func registerWithApple() {
        #if os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #else
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }
    func receivedToken(_ data: Data) {
        do {
            try Keychain.save(data.map { String(format: "%02x", $0) }.joined(), account: "apns-device-token")
            lastRegistration = nil
            status = "Connecting device to server…"
            NotificationCenter.default.post(name: .pushTokenChanged, object: nil)
        } catch { status = "Could not save the notification token" }
    }
    func registrationFailed() { status = "Neon couldn’t register this device for alerts. Try again later." }
    func register(with client: BackendClient) async {
        guard enabled, !registering else { return }
        registering = true
        let id = deviceID
        defer { registering = false }
        do {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard deviceID == id else { return }
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                status = "Notifications are disabled in system settings"; return
            }
            let token = try Keychain.read(account: "apns-device-token")
            guard !token.isEmpty else { registerWithApple(); status = "Waiting for Apple device registration…"; return }
            guard deviceID == id, registrationSignature(token: token, client: client, id: id) != lastRegistration else { return }
            let capabilities: BackendCapabilities = try await client.get("v1/capabilities")
            guard deviceID == id else { return }
            guard capabilities.push else { status = "Completion alerts are unavailable on this connection."; return }
            try await registerDevice(token: token, with: client, expectedDeviceID: id)
        } catch { if deviceID == id { status = "Device registration is pending; retry when connected" } }
    }
    private func registrationSignature(token: String, client: BackendClient, id: UUID) -> String {
        client.credentials.url.absoluteString + (client.credentials.serverID?.pathID ?? "") + token + id.pathID
    }
    private func updateDevice(on client: BackendClient, action: @escaping @MainActor () async throws -> Void) async throws {
        let endpoint = client.credentials.url.absoluteString
        let previous = deviceUpdates[endpoint]?.task
        let operation = UUID()
        let task = Task {
            _ = try? await previous?.value
            try await action()
        }
        deviceUpdates[endpoint] = (operation, task)
        defer { if deviceUpdates[endpoint]?.id == operation { deviceUpdates[endpoint] = nil } }
        try await task.value
    }
    func registerDevice(token: String, with client: BackendClient, expectedDeviceID: UUID? = nil) async throws {
        let id = expectedDeviceID ?? deviceID
        guard deviceID == id else { return }
        let signature = registrationSignature(token: token, client: client, id: id)
        guard signature != lastRegistration else { return }
        struct Body: Encodable { let token: String }
        try await updateDevice(on: client) { [weak self] in
            guard self?.deviceID == id else { return }
            let _: BackendClient.Empty = try await client.send("v1/devices/\(id.pathID)", method: "PUT", body: Body(token: token))
        }
        guard deviceID == id else { return }
        lastRegistration = signature
        status = "Completion notifications enabled"
    }
    func rotateRegistration() -> UUID {
        let previous = deviceID
        defaults.set(UUID().uuidString, forKey: "push-device-id")
        resetRegistration()
        return previous
    }
    func resetRegistration() {
        lastRegistration = nil
        status = "Notifications are off"
    }
    func unregister(from client: BackendClient, deviceID: UUID? = nil, updateState: Bool = true) async throws {
        let id = deviceID ?? self.deviceID
        try await updateDevice(on: client) {
            try await client.command("v1/devices/\(id.pathID)", method: "DELETE")
        }
        if updateState, self.deviceID == id { resetRegistration() }
    }
    func clearPending() { pending = nil; defaults.removeObject(forKey: "pending-notification") }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // The active app already syncs responses; avoid banners over the conversation.
        completionHandler([])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let values = response.notification.request.content.userInfo
        let job = (values["jobId"] as? String).flatMap(UUID.init(uuidString:))
        let server = (values["serverId"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            if let job, let server {
                let target = NotificationTarget(jobID: job, serverID: server)
                self.pending = target
                if let data = try? JSONEncoder().encode(target) { self.defaults.set(data, forKey: "pending-notification") }
                NotificationCenter.default.post(name: .answerNotificationOpened, object: nil)
            }
            completionHandler()
        }
    }
}

#if os(macOS)
@MainActor final class OpenChatDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppRuntime.isTestHost else { return }
        PushCoordinator.shared.installDelegate()
        if PushCoordinator.shared.enabled { PushCoordinator.shared.registerWithApple() }
    }
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        guard !AppRuntime.isTestHost else { return }
        PushCoordinator.shared.receivedToken(deviceToken)
    }
    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        guard !AppRuntime.isTestHost else { return }
        PushCoordinator.shared.registrationFailed()
    }
}
#else
@MainActor final class OpenChatDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        guard !AppRuntime.isTestHost else { return true }
        PushCoordinator.shared.installDelegate()
        if PushCoordinator.shared.enabled { PushCoordinator.shared.registerWithApple() }
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        guard !AppRuntime.isTestHost else { return }
        PushCoordinator.shared.receivedToken(deviceToken)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        guard !AppRuntime.isTestHost else { return }
        PushCoordinator.shared.registrationFailed()
    }
}
#endif
