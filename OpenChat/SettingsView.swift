import SwiftUI

struct SettingsView: View {
    private enum Topic: Hashable { case openRouter, personalization, notifications, privacy }
    @Bindable var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("display-name") private var displayName = ""
    @State private var key = ""
    @State private var busy = false
    @State private var allowanceRefresh = 0
    @State private var path: [Topic] = []
    @State private var confirmKeyRemoval = false

    private var keyActionsLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 16))
    }
    private var navigationPath: Binding<[Topic]> {
        Binding(get: { path }, set: { if !busy { path = $0 } })
    }
    private var notificationStatus: String {
        guard store.pushAvailable else { return "Unavailable" }
        return PushCoordinator.shared.enabled ? "Enabled on device" : "Off"
    }
    var body: some View {
        NavigationStack(path: navigationPath) {
            Form {
                Section("Connection") {
                    #if os(macOS)
                    if store.ollamaAvailable {
                        LabeledContent("Ollama", value: "On this Mac")
                        Text("Installed Ollama models appear beside OpenRouter models in the model picker. Ollama chats stay on this Mac and use localhost:11434.")
                            .font(ChatAppearance.caption).foregroundStyle(.secondary)
                    }
                    #endif
                    if store.hasKey {
                        NavigationLink(value: Topic.openRouter) {
                            settingsRow("OpenRouter", icon: "key.fill", status: "Connected")
                        }
                    } else {
                        keyEditor
                    }
                }
                Section("Preferences") {
                    NavigationLink(value: Topic.personalization) {
                        settingsRow("Personalization", icon: "person.crop.circle", status: displayName.isEmpty ? "Optional" : displayName)
                    }
                    NavigationLink(value: Topic.notifications) {
                        settingsRow("Notifications", icon: "bell", status: notificationStatus)
                    }
                }
                Section {
                    NavigationLink(value: Topic.privacy) {
                        settingsRow("Privacy", icon: "hand.raised")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar { if path.isEmpty { doneToolbar } }
            .navigationDestination(for: Topic.self) { topic in
                topicView(topic).navigationBarBackButtonHidden(busy)
                    .toolbar { doneToolbar }
            }
        }
        .font(ChatAppearance.body).tint(ChatAppearance.accent)
        .disabled(busy)
        .interactiveDismissDisabled(busy)
        .overlay { if busy { ProgressView("Saving…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) } }
        .alert("Neon", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .confirmationDialog("Remove API key for all devices?", isPresented: $confirmKeyRemoval, titleVisibility: .visible) {
            Button("Remove API key", role: .destructive) {
                run { if await store.saveProviderKey("") { allowanceRefresh += 1 } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the shared workspace’s OpenRouter key on every device. Your chats are kept. Add a key again to resume sending.")
        }
        .frame(minWidth: 320, idealWidth: 560, minHeight: 520)
    }
    @ToolbarContentBuilder private var doneToolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }.disabled(busy)
        }
    }
    @ViewBuilder private func topicView(_ topic: Topic) -> some View {
        switch topic {
        case .openRouter:
            openRouterSettings
        case .personalization:
            Form {
                Section {
                    TextField("Your name (optional)", text: $displayName).frame(minHeight: 44)
                } footer: {
                    Text("Used for your welcome greeting on this device.")
                }
            }.formStyle(.grouped).navigationTitle("Personalization")
        case .notifications:
            Form {
                Section {
                    Text(PushCoordinator.shared.status).foregroundStyle(.secondary)
                    if PushCoordinator.shared.enabled {
                        Button("Turn off notifications on this device") { run { await store.disableNotifications() } }
                            .frame(minHeight: 44)
                    } else {
                        Button("Enable completion notifications") { run { await store.enableNotifications() } }
                            .frame(minHeight: 44).disabled(!store.pushAvailable)
                    }
                } footer: {
                    if !store.pushAvailable { Text("Completion alerts aren’t available on this connection.") }
                }
            }.formStyle(.grouped).navigationTitle("Notifications")
        case .privacy:
            Form {
                Section("Provider sharing") {
                    Text("OpenRouter conversations send prompts and chat history to OpenRouter and its selected provider. Provider charges and retention policies apply.")
                    #if os(macOS)
                    Text("Ollama conversations send prompts and history directly to Ollama on this Mac. They are never uploaded to Neon. Installed cloud models may send data to Ollama’s cloud service; choose a local model for on-device processing.")
                    #endif
                }
                Section("Storage") {
                    Text("Neon stores OpenRouter chats on its backend and keeps a local cache on this device. Your OpenRouter key is stored encrypted on Neon’s backend and used with OpenRouter.")
                    #if os(macOS)
                    Text("Ollama chats, drafts and queued messages are saved separately on this Mac. They do not sync to other devices. Switching conversations preserves each provider’s history.")
                    #endif
                }
            }.formStyle(.grouped).navigationTitle("Privacy")
        }
    }
    private var openRouterSettings: some View {
        Form {
            Section {
                keyEditor
            }
            Section {
                allowanceRow
                Link("OpenRouter account balance", destination: URL(string: "https://openrouter.ai/settings/credits")!)
                    .foregroundStyle(ChatAppearance.accent).frame(minHeight: 44)
            } header: {
                Text("Key allowance")
            } footer: {
                Text("Your API key’s spending allowance. View your account balance on OpenRouter.")
            }
            if store.hasKey {
                Section {
                    Button(role: .destructive) { confirmKeyRemoval = true } label: {
                        Label("Remove API key…", systemImage: "trash").frame(minHeight: 44)
                    }
                } footer: {
                    Text("Affects the shared workspace on every device. Chats are retained.")
                }
            }
        }
        .formStyle(.grouped).navigationTitle("OpenRouter")
        .task(id: allowanceRefresh) { await store.refreshKeyAllowance() }
    }
    private var keyEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(store.hasKey ? "Update API key" : "OpenRouter API key", systemImage: "key.fill")
                .font(ChatAppearance.headline)
            SecureField(text: $key, prompt: Text("Paste your OpenRouter API key")) { Text("OpenRouter API key") }
                .labelsHidden().textFieldStyle(.roundedBorder).autocorrectionDisabled()
                .controlSize(.large).frame(minHeight: 44)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityLabel("OpenRouter API key")
            Text("Saving sends this key to your configured Neon server for encrypted storage and OpenRouter access. Updating it keeps your chats.")
                .font(ChatAppearance.caption).foregroundStyle(.secondary)
            keyActionsLayout {
                Button("Save API key") {
                    run { if await store.saveProviderKey(key) { key = ""; allowanceRefresh += 1 } }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .foregroundStyle(busy || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ChatAppearance.muted : ChatAppearance.canvas)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Link("Get API key", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                    .foregroundStyle(ChatAppearance.accent).frame(minHeight: 44)
            }
        }.padding(.vertical, 4)
    }
    private func settingsRow(_ title: String, icon: String, status: String? = nil) -> some View {
        keyActionsLayout {
            Label(title, systemImage: icon)
            if let status {
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 12) }
                Text(status).foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
        }.frame(minHeight: 44)
    }
    private var allowanceRow: some View {
        keyActionsLayout {
            Label("Remaining allowance", systemImage: "creditcard")
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            switch store.keyAllowance {
            case .loading:
                ProgressView().controlSize(.small).accessibilityLabel("Loading key allowance")
            case .loaded(let allowance):
                if !allowance.configured { Text("No API key").foregroundStyle(.secondary) }
                else if allowance.limit == nil { Text("No key limit").foregroundStyle(.secondary) }
                else if let remaining = allowance.remaining {
                    Text(remaining, format: .currency(code: "USD").precision(.fractionLength(2...4))).monospacedDigit()
                } else { Text("Unavailable").foregroundStyle(.secondary) }
            case .idle:
                Text("Refresh to view").foregroundStyle(.secondary)
            case .unavailable:
                Text("Unavailable").foregroundStyle(.secondary)
            }
            Button { allowanceRefresh += 1 } label: {
                Image(systemName: "arrow.clockwise").frame(width: 44, height: 44).contentShape(.rect)
            }
            .buttonStyle(.plain).accessibilityLabel("Refresh key allowance").help("Refresh key allowance")
            .disabled(store.keyAllowance == .loading)
        }.frame(minHeight: 44)
    }
    private func run(_ work: @escaping @MainActor () async -> Void) {
        guard !busy else { return }
        busy = true
        Task { await work(); busy = false }
    }
}

struct EditView: View {
    @State private var text: String
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    init(text: String, save: @escaping (String) -> Void) {
        _text = State(initialValue: text) // Intentional editable snapshot.
        self.save = save
    }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Your original conversation will be kept. Sending this edit starts a new branch from this message.").foregroundStyle(.secondary)
                TextEditor(text: $text).font(ChatAppearance.body)
            }.padding(20).navigationTitle("Edit message")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Send edit") { save(text); dismiss() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
        }.frame(minWidth: 320, idealWidth: 600, minHeight: 400)
    }
}
