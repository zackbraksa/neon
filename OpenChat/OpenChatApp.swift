import SwiftUI

enum AppRuntime {
    static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
}

@main
struct OpenChatApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(OpenChatDelegate.self) private var delegate
    #else
    @UIApplicationDelegateAdaptor(OpenChatDelegate.self) private var delegate
    #endif
    @State private var store: ChatStore?
    init() {
        _store = State(initialValue: AppRuntime.isTestHost ? nil : ChatStore())
    }
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup("Neon") {
            if let store {
                ContentView(store: store)
                .frame(minWidth: 320, minHeight: 480)
                .tint(ChatAppearance.accent)
                .task { store.activate() }
                .onReceive(NotificationCenter.default.publisher(for: .backendDidSync)) { _ in
                    Task { await store.registerNotifications(); await store.openPendingNotification() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .pushTokenChanged)) { _ in
                    Task { await store.registerNotifications() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .answerNotificationOpened)) { _ in
                    Task { await store.openPendingNotification() }
                }
                .onChange(of: phase) { _, phase in
                    if phase == .background { store.background() }
                    if phase == .active { store.activate() }
                }
            } else {
                Color.clear
            }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 780)
        #endif
    }
}
