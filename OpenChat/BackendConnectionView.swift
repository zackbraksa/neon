import SwiftUI

struct BackendConnectionView: View {
    @Bindable var store: ChatStore
    let onKeySaved: () -> Void
    @State private var key = ""

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                form
                    .padding(28).frame(maxWidth: 520)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .font(ChatAppearance.body)
        .background(ChatBackdrop())
    }
    private var form: some View {
        VStack(alignment: .leading, spacing: 20) {
            WelcomeBrandMark().frame(maxWidth: .infinity)
            Text("Your chats, on every device").font(.title2.weight(.semibold))
            Text("Use the same OpenRouter key on Mac and iPhone to share your chats. Your key is sent to your configured Neon server and stored encrypted for background generation.")
                .foregroundStyle(.secondary)
            Text(store.serverAddress).font(ChatAppearance.caption).textSelection(.enabled)
            SecureField(text: $key, prompt: Text("Paste your OpenRouter API key")) { Text("OpenRouter API key") }
                .labelsHidden().textFieldStyle(.roundedBorder).autocorrectionDisabled()
                .controlSize(.large).frame(minHeight: 44)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityLabel("OpenRouter API key")
                .disabled(store.isConnecting)
            if case .failed(let message) = store.bootstrap {
                Text(message).foregroundStyle(.secondary)
            } else if store.authenticationRequired {
                Text("Reconnect with your OpenRouter key. Your saved chats and unsent messages stay on this device.")
                    .foregroundStyle(.secondary)
            }
            #if os(macOS)
            Button("Use Ollama on this Mac") { store.useOllama() }
                .buttonStyle(.bordered).disabled(store.isConnecting)
            Text("Ollama chats stay on this Mac. Start Ollama and install a model before sending. You can connect OpenRouter later in Settings.")
                .font(ChatAppearance.caption).foregroundStyle(.secondary)
            #endif
            HStack(spacing: 16) {
                Button(store.isConnecting ? "Saving API key…" : "Save API key") {
                    Task {
                        if await store.saveProviderKey(key) {
                            key = ""
                            onKeySaved()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isConnecting ? ChatAppearance.muted : ChatAppearance.canvas)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isConnecting)
                if store.isConnecting { ProgressView().controlSize(.small) }
                Link("Get API key", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                    .foregroundStyle(ChatAppearance.accent)
            }
        }
    }
}
