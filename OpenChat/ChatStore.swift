import Foundation
import Observation
import UniformTypeIdentifiers

/// The UI observes one facade while each transport keeps a separate history.
@MainActor @Observable
final class ChatStore {
    enum Bootstrap: Equatable {
        case needsKey
        case connecting
        case failed(String)
    }
    private let sessions: BackendSessionStorage
    private let createSession: (String, UUID) async throws -> BackendCredentials
    private let makeRemote: (BackendCredentials) throws -> RemoteChatStore
    private let push: PushCoordinator
    private let direct: DirectChatStore
    private let ollama: DirectChatStore?
    private let preferences: UserDefaults?
    private var localAccess = false
    private var localSelected = false
    private(set) var openRouterCatalogError: String?
    private(set) var ollamaCatalogError: String?
    var ollamaAvailable: Bool { ollama != nil }
    var isLocalConversation: Bool { localSelected }
    private var openRouterNeedsConnection: Bool { bootstrap != nil || authenticationRequired }
    private var remote: RemoteChatStore?
    private var ownError: String?
    private var connectionGeneration = UUID()
    private var imagePasteRequests: [UUID: UUID] = [:]
    private var foreground = false
    @ObservationIgnored private var startupCatalogLoad: Task<Void, Never>?
    private var sessionCreation: Task<BackendCredentials, Error>?
    private(set) var bootstrap: Bootstrap? = .needsKey
    var authenticationRequired: Bool { remote?.requiresAuthentication == true }
    var needsBackendConnection: Bool { !localAccess && openRouterNeedsConnection }
    var isConnecting: Bool { sessionCreation != nil }
    var isRemote: Bool { remote != nil }
    var serverAddress: String { NeonBackend.address }
    var connectionStatus: String { localSelected ? "Ollama · On this Mac" : remote?.connectionStatus ?? "Add your OpenRouter API key" }
    var isSyncing: Bool { remote?.isSyncing ?? false }
    var conversations: [Conversation] { ((remote?.conversations ?? []) + (localAccess ? ollama?.conversations ?? [] : [])).filter { !$0.isArchived } }
    var archivedConversations: [Conversation] { ((remote?.conversations ?? []) + (localAccess ? ollama?.conversations ?? [] : [])).filter(\.isArchived) }
    var supportsArchiveBrowsing: Bool { localAccess || remote?.supportsArchiveBrowsing == true }
    func supportsMetadata(_ id: UUID) -> Bool { localStore(id) != nil || remote?.supportsConversationMetadata == true }
    func supportsRestore(_ id: UUID) -> Bool { localStore(id) != nil || remote?.supportsArchiveBrowsing == true }
    func restore(_ id: UUID) async throws { if let local = localStore(id) { local.restore(id) } else { try await remote?.restore(id) } }
    var selectedID: UUID? {
        get { localSelected ? ollama?.selectedID : remote?.selectedID }
        set {
            localSelected = newValue.flatMap { localStore($0) } != nil
            if localSelected { ollama?.selectedID = newValue } else { remote?.select(newValue) }
        }
    }
    var active: [UUID: UUID] { (remote?.active ?? [:]).merging(ollama?.active ?? [:]) { first, _ in first } }
    var models: [RouterModel] { direct.models + (ollama?.models ?? []) }
    func reasoningEfforts(for id: UUID) -> [ReasoningEffort] {
        guard remote?.supportsReasoningEffort == true else { return [] }
        return catalogReasoningEfforts(for: id)
    }
    private func catalogReasoningEfforts(for id: UUID) -> [ReasoningEffort] {
        guard let chat = chat(id), localStore(id) == nil, openRouterCatalogError == nil else { return [] }
        return direct.models.first { $0.id == chat.model }?.reasoningEfforts ?? []
    }
    func chooseReasoningEffort(_ effort: ReasoningEffort?, for id: UUID) {
        guard effort == nil || reasoningEfforts(for: id).contains(effort!) else { return }
        update(id) { $0.reasoningEffort = effort }
    }
    private func validateReasoningEffort(_ id: UUID) -> Bool {
        guard let effort = chat(id)?.reasoningEffort else { return true }
        guard catalogReasoningEfforts(for: id).contains(effort) else {
            error = "Refresh the model catalog or choose Default reasoning effort before sending."
            return false
        }
        return true
    }
    var hasKey: Bool { remote?.hasKey ?? false }
    var supportsConversationMetadata: Bool { localSelected || remote?.supportsConversationMetadata == true }
    var pushAvailable: Bool { remote?.pushAvailable ?? false }
    var keyAllowance: KeyAllowanceState { remote?.keyAllowance ?? .idle }
    func refreshKeyAllowance() async { await remote?.refreshKeyAllowance() }
    var error: String? {
        get { ownError ?? ollama?.error ?? remote?.error }
        set { ownError = newValue; if newValue == nil { remote?.error = nil; ollama?.error = nil } }
    }
    init() {
        direct = DirectChatStore(readKey: { "" })
        preferences = .standard
        #if os(macOS)
        ollama = DirectChatStore(storageDirectory: URL.applicationSupportDirectory.appendingPathComponent("OpenChat/Ollama", isDirectory: true),
                                 readKey: { "" }, router: Ollama(), requiresKey: false, defaultModel: "")
        localAccess = UserDefaults.standard.bool(forKey: "ollama-enabled")
        #else
        ollama = nil
        #endif
        sessions = SystemBackendSessionStorage()
        let client = BackendSessionClient()
        createSession = { try await client.create(key: $0, deviceID: $1) }
        makeRemote = { try RemoteChatStore(client: BackendClient($0)) }
        push = .shared
        restoreConnection()
        localSelected = localAccess && remote == nil
    }
    init(direct: DirectChatStore, remote: RemoteChatStore? = nil, sessions: BackendSessionStorage,
         push: PushCoordinator, ollama: DirectChatStore? = nil, preferences: UserDefaults? = nil, makeRemote: ((BackendCredentials) throws -> RemoteChatStore)? = nil,
         createSession: ((String, UUID) async throws -> BackendCredentials)? = nil) {
        self.direct = direct
        self.ollama = ollama
        self.preferences = preferences
        self.localAccess = preferences?.bool(forKey: "ollama-enabled") == true
        self.remote = remote
        self.sessions = sessions
        self.push = push
        self.makeRemote = makeRemote ?? { try RemoteChatStore(client: BackendClient($0)) }
        let client = BackendSessionClient()
        self.createSession = createSession ?? { try await client.create(key: $0, deviceID: $1) }
        if remote != nil { bootstrap = nil }
        else { restoreConnection() }
        localSelected = localAccess && self.remote == nil
    }
    private func restoreConnection() {
        do {
            if let credentials = try sessions.connection(), NeonBackend.matches(credentials) {
                let restored = try makeRemote(credentials)
                direct.pauseAll()
                remote = restored
                bootstrap = nil
            }
        } catch {
            bootstrap = .failed("Neon cannot restore your saved connection. Unlock this device and allow Keychain access if prompted, then reopen Neon or enter your OpenRouter key.")
        }
    }
    private func localStore(_ id: UUID) -> DirectChatStore? { ollama?.chat(id) == nil ? nil : ollama }
    func useOllama() {
        guard let ollama else { return }
        localAccess = true
        preferences?.set(true, forKey: "ollama-enabled")
        if ollama.selectedID == nil { ollama.newChat() }
        localSelected = true
    }
    func chooseModel(_ model: String, for id: UUID) {
        guard let current = chat(id), !current.isArchived else { return }
        let localModel = Ollama.isModel(model)
        if localModel == (localStore(id) != nil) {
            update(id) { $0.model = model }
            return
        }
        if localModel && current.messages.isEmpty && !(current.draftImages ?? []).isEmpty {
            error = "Remove the draft images before switching to Ollama. Image input is available with OpenRouter."
            return
        }
        if localModel {
            let existing = ollama?.selectedID != nil
            useOllama()
            if existing { ollama?.newChat() }
        }
        else {
            guard !openRouterNeedsConnection, let remote else {
                error = "Connect OpenRouter in Settings before choosing an OpenRouter model."
                return
            }
            remote.newChat()
            localSelected = false
        }
        guard let target = selectedID else { return }
        // Provider changes start a separate conversation; carry an unsent draft only from an empty chat.
        let draft = current.messages.isEmpty ? current.draft : ""
        update(target) { $0.model = model; $0.draft = draft; $0.draftImages = current.messages.isEmpty ? current.draftImages : nil }
    }
    func chat(_ id: UUID) -> Conversation? { localStore(id)?.chat(id) ?? remote?.chat(id) }
    func update(_ id: UUID, _ change: (inout Conversation) -> Void, save: Bool = true) {
        if let local = localStore(id) {
            guard local.chat(id)?.isArchived == false else { return }
            local.update(id, change, save: save); return
        }
        guard let remote, remote.canMutate(id) else { return }
        remote.update(id, change, save: save)
    }
    func setMetadata(_ id: UUID, title: String? = nil, pinned: Bool? = nil) async throws {
        if let local = localStore(id) {
            guard local.chat(id)?.isArchived == false else { return }
            local.update(id) { if let title { $0.title = title }; if let pinned { $0.pinned = pinned } }
            return
        }
        guard let remote else { throw RouterError(message: "Connect to Neon before editing a conversation.") }
        try await remote.setMetadata(id, title: title, pinned: pinned)
    }
    func setDraft(_ id: UUID, text: String) { if let local = localStore(id) { if local.chat(id)?.isArchived == false { local.setDraft(id, text: text) } } else { remote?.setDraft(id, text: text) } }
    func supportsImages(_ id: UUID) -> Bool { localStore(id) == nil && remote?.supportsImageInputs == true }
    func pasteImages(_ providers: [NSItemProvider], to id: UUID) {
        guard supportsImages(id) else {
            error = "Image input requires an updated Neon server and an OpenRouter conversation."
            return
        }
        guard imagePasteRequests[id] == nil else {
            error = "Wait for the pasted image to finish loading before pasting another."
            return
        }
        let request = UUID()
        let generation = connectionGeneration
        imagePasteRequests[id] = request
        Task {
            do {
                var images: [String] = []
                guard providers.count + (chat(id)?.draftImages ?? []).count <= ImageAttachment.maximumCount else {
                    throw RouterError(message: "You can attach up to four images per message.")
                }
                for provider in providers {
                    let data: Data = try await withCheckedThrowingContinuation { continuation in
                        guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else {
                            continuation.resume(throwing: RouterError(message: "Copy a PNG or JPEG image and try again.")); return
                        }
                        provider.loadDataRepresentation(forTypeIdentifier: type) { data, failure in
                            if let data { continuation.resume(returning: data) }
                            else { continuation.resume(throwing: failure ?? RouterError(message: "The clipboard image could not be read.")) }
                        }
                    }
                    images.append(try await Task.detached(priority: .userInitiated) { try ImageAttachment.normalize(data) }.value)
                }
                guard connectionGeneration == generation, imagePasteRequests[id] == request else {
                    if imagePasteRequests[id] == request { imagePasteRequests[id] = nil }; return
                }
                appendImages(images, to: id)
            } catch {
                guard connectionGeneration == generation, imagePasteRequests[id] == request else {
                    if imagePasteRequests[id] == request { imagePasteRequests[id] = nil }; return
                }
                self.error = error.localizedDescription
            }
            if imagePasteRequests[id] == request { imagePasteRequests[id] = nil }
        }
    }
    func appendImages(_ images: [String], to id: UUID) {
        guard supportsImages(id), let chat = chat(id), !chat.isArchived else {
            error = "Image input requires an updated Neon server and an OpenRouter conversation."
            return
        }
        let combined = (chat.draftImages ?? []) + images
        do { try ImageAttachment.validate(combined) }
        catch { self.error = error.localizedDescription; return }
        update(id) { $0.draftImages = combined }
    }
    func removeDraftImage(_ id: UUID, at index: Int) {
        update(id) { chat in
            guard var images = chat.draftImages, images.indices.contains(index) else { return }
            images.remove(at: index)
            chat.draftImages = images.isEmpty ? nil : images
        }
    }
    func newChat() {
        guard !needsBackendConnection else { return }
        if localSelected || remote == nil { useOllama(); ollama?.newChat() }
        else { remote?.newChat() }
    }
    func archive(_ id: UUID) { if let local = localStore(id) { local.archive(id) } else { remote?.archive(id) } }
    func supportsDeletion(_ id: UUID) -> Bool { localStore(id) != nil || remote?.chat(id)?.serverThread != true || remote?.supportsConversationDeletion == true }
    func delete(_ id: UUID) async throws {
        if let local = localStore(id) { try local.delete(id) }
        else if let remote { try await remote.delete(id) }
    }
    func send(_ id: UUID, steer: Bool = false) {
        guard imagePasteRequests[id] == nil else { error = "Wait for the pasted image to finish loading before sending."; return }
        if let local = localStore(id) { local.send(id, steer: steer); return }
        guard !openRouterNeedsConnection, validateReasoningEffort(id) else { return }
        remote?.enqueue(id, steer: steer)
    }
    func summarize(_ id: UUID, messageID: UUID) {
        if let local = localStore(id) { local.summarize(id, messageID: messageID); return }
        guard !openRouterNeedsConnection, validateReasoningEffort(id) else { return }
        remote?.summarize(id, messageID: messageID)
    }
    func stop(_ id: UUID) { if let local = localStore(id) { local.stop(id) } else { remote?.stop(id) } }
    func resume(_ id: UUID) { if let local = localStore(id) { local.resume(id) } else if !openRouterNeedsConnection { remote?.resume(id) } }
    func removeQueued(_ id: UUID, messageID: UUID) { if let local = localStore(id) { if local.chat(id)?.isArchived == false { local.removeQueued(id, messageID: messageID) } } else { remote?.removeQueued(id, messageID: messageID) } }
    func edit(_ id: UUID, messageID: UUID, text: String) { if let local = localStore(id) { local.edit(id, messageID: messageID, text: text); localSelected = true } else { remote?.fork(id, messageID: messageID, text: text); localSelected = false } }
    func loadModels() async {
        async let openRouterModels: Void = loadOpenRouterModels()
        async let localModels: Void = loadOllamaModels()
        _ = await (openRouterModels, localModels)
    }
    private func loadOpenRouterModels() async {
        direct.error = nil
        await direct.loadModels()
        openRouterCatalogError = direct.error
        if direct.error == nil {
            for chat in remote?.conversations ?? [] where chat.reasoningEffort != nil {
                if !catalogReasoningEfforts(for: chat.id).contains(chat.reasoningEffort!) {
                    remote?.update(chat.id) { $0.reasoningEffort = nil }
                }
            }
        }
        if ollama == nil, let error = direct.error { ownError = error }
        direct.error = nil
    }
    private func loadOllamaModels() async {
        ollama?.error = nil
        await ollama?.loadModels()
        ollamaCatalogError = ollama?.error
        ollama?.error = nil
    }
    func saveProviderKey(_ key: String) async -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return await saveConnectedKey(key) }
        if remote != nil && !authenticationRequired { return await saveConnectedKey(key) }
        connectionGeneration = UUID()
        let generation = connectionGeneration
        sessionCreation?.cancel()
        bootstrap = .connecting
        ownError = nil
        remote?.error = nil
        let deviceID = sessions.deviceID
        let create = createSession
        let request = Task { try await create(key, deviceID) }
        sessionCreation = request
        defer { if connectionGeneration == generation { sessionCreation = nil } }
        do {
            let credentials = try await request.value
            guard connectionGeneration == generation, !request.isCancelled else { return false }
            guard NeonBackend.matches(credentials), credentials.serverID != nil else {
                throw RouterError(message: "Neon returned an invalid connection. Please retry.")
            }
            if let previous = remote, previous.client.credentials.serverID != credentials.serverID {
                throw RouterError(message: "This key opens a different workspace. Enter the key for your current chats.")
            }
            let replacement = try makeRemote(credentials)
            do { try sessions.saveConnection(credentials) }
            catch {
                throw RouterError(message: "Neon couldn’t save this device’s session in Keychain. Unlock Keychain or allow access if prompted, then try again.")
            }
            replacement.hasKey = true
            if remote == nil { localSelected = false }
            remote?.suspend()
            remote = replacement
            bootstrap = nil
            ownError = nil
            if foreground { replacement.start() }
            return true
        } catch {
            guard connectionGeneration == generation else { return false }
            let message = "Could not connect. \(error.localizedDescription)"
            bootstrap = .failed(message)
            if localAccess { ownError = message }
            return false
        }
    }
    private func saveConnectedKey(_ key: String) async -> Bool {
        guard let remote, !authenticationRequired else { return false }
        struct Body: Encodable { let key: String }
        let generation = connectionGeneration
        do {
            let state: KeyState = try await remote.client.send("v1/settings/openrouter-key", method: "PUT", body: Body(key: key))
            guard connectionGeneration == generation, self.remote === remote else { return false }
            remote.hasKey = state.configured
            remote.invalidateKeyAllowance()
            guard state.configured == !key.isEmpty else {
                ownError = key.isEmpty
                    ? "Neon couldn’t confirm that your API key was removed. Try again."
                    : "Neon couldn’t confirm that your API key was saved. Try again."
                return false
            }
            await remote.retryPending()
            return true
        } catch {
            guard connectionGeneration == generation, self.remote === remote else { return false }
            switch (error as? BackendFailure)?.status {
            case 400: ownError = "Enter a valid OpenRouter API key."
            case 401:
                remote.requireAuthentication()
                ownError = "Your Neon session expired. Enter your OpenRouter API key again to reconnect."
            case 409: ownError = "This key belongs to another workspace. Enter the key for your current chats."
            case 422: ownError = "OpenRouter rejected this API key. Check it and try again."
            case 429: ownError = "Too many attempts. Wait a moment and try again."
            case 503: ownError = "Neon couldn’t verify your key right now. Try again shortly."
            default:
                ownError = error is URLError
                    ? "Neon couldn’t reach the server. Check your connection and try again."
                    : "Neon couldn’t finish the request. Try again."
            }
            return false
        }
    }
    func disconnect(forgetConnection: (() throws -> Void)? = nil) async {
        do {
            if let forgetConnection { try forgetConnection() }
            else { try sessions.clearConnection() }
            let previous = remote
            connectionGeneration = UUID()
            let generation = connectionGeneration
            sessionCreation?.cancel(); sessionCreation = nil
            bootstrap = .needsKey
            previous?.suspend(); remote = nil
            if let previous {
                let deviceID = push.rotateRegistration()
                let coordinator = push
                Task { [weak self] in
                    do { try await coordinator.unregister(from: previous.client, deviceID: deviceID, updateState: false) }
                    catch {
                        guard let self, self.connectionGeneration == generation else { return }
                        self.ownError = "This device disconnected. Notification cleanup is pending on the previous connection."
                    }
                }
            }
        } catch { self.error = "Disconnect was not completed: \(error.localizedDescription)" }
    }
    func activate() {
        foreground = true
        remote?.start()
        if direct.models.isEmpty, startupCatalogLoad == nil {
            startupCatalogLoad = Task { [weak self] in
                guard let self else { return }
                await loadOpenRouterModels()
                startupCatalogLoad = nil
            }
        }
        Task { await registerNotifications(); await openPendingNotification() }
    }
    func background() {
        foreground = false
        if sessionCreation != nil {
            connectionGeneration = UUID()
            sessionCreation?.cancel(); sessionCreation = nil
            let message = "Saving was interrupted. Try again."
            bootstrap = .failed(message)
            if localAccess { ownError = message }
        }
        remote?.suspend()
        direct.pauseAll()
        ollama?.pauseAll()
    }
    func refresh() async { await remote?.retryPending(); await registerNotifications(); await openPendingNotification() }
    func registerNotifications() async {
        guard let remote else { return }
        await push.register(with: remote.client)
    }
    func enableNotifications() async {
        guard let remote else { return }
        await push.enable(with: remote.client)
    }
    func disableNotifications() async {
        guard let remote else { return }
        do { try await push.unregister(from: remote.client); push.enabled = false }
        catch { self.error = error.localizedDescription }
    }
    func openPendingNotification() async {
        guard let remote, let pending = push.pending else { return }
        let generation = connectionGeneration
        do {
            let capabilities: BackendCapabilities = try await remote.client.get("v1/capabilities")
            guard connectionGeneration == generation, self.remote === remote,
                  capabilities.serverId == pending.serverID else { return }
            if await remote.openJob(pending.jobID) {
                guard connectionGeneration == generation, self.remote === remote,
                      push.pending?.jobID == pending.jobID, push.pending?.serverID == pending.serverID else { return }
                localSelected = false
                push.clearPending()
            }
        } catch { /* Keep the tap durable until the server can be contacted. */ }
    }
}
