import Foundation
import Observation

@MainActor @Observable
final class DirectChatStore {
    var conversations: [Conversation] = []
    var selectedID: UUID?
    var models: [RouterModel] = []
    var error: String?
    var hasKey = false
    private(set) var active: [UUID: UUID] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var tickers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pending: [UUID: String] = [:]
    @ObservationIgnored private var draftSaves: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var disk: ConversationDisk?
    @ObservationIgnored private let router: any DirectChatTransport
    @ObservationIgnored private let readKey: () throws -> String
    @ObservationIgnored private let writeKey: (String) throws -> Void
    private let requiresKey: Bool
    private let defaultModel: String

    init(storage: ConversationDisk? = nil, storageDirectory: URL? = nil,
         readKey: @escaping () throws -> String = { try Keychain.read() },
         writeKey: @escaping (String) throws -> Void = { try Keychain.save($0) },
         router: any DirectChatTransport = OpenRouter(), requiresKey: Bool = true,
         defaultModel: String = "openrouter/auto") {
        self.router = router
        self.readKey = readKey
        self.writeKey = writeKey
        self.requiresKey = requiresKey
        self.defaultModel = defaultModel
        do {
            let storage = try storage ?? ConversationDisk(directory: storageDirectory)
            let loaded = try storage.load()
            disk = storage
            conversations = loaded.map { value in
                var chat = value
                if chat.messages.contains(where: { $0.status == .queued }) { chat.paused = true }
                return chat
            }
            hasKey = try !requiresKey || !readKey().isEmpty
        } catch { self.error = error.localizedDescription }
        selectedID = conversations.first?.id
        if conversations.isEmpty && disk != nil { newChat() }
    }
    func chat(_ id: UUID) -> Conversation? { conversations.first { $0.id == id } }
    func update(_ id: UUID, _ change: (inout Conversation) -> Void, save: Bool = true) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let previousModel = conversations[index].model
        change(&conversations[index])
        if conversations[index].model != previousModel { conversations[index].reasoningEffort = nil }
        if save { persist(id) }
    }
    func setDraft(_ id: UUID, text: String) {
        update(id, { $0.draft = text }, save: false)
        draftSaves[id]?.cancel()
        draftSaves[id] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.persist(id)
            self?.draftSaves[id] = nil
        }
    }
    func persist(_ id: UUID) {
        guard let chat = chat(id), let disk else { return }
        do { try disk.save(chat) } catch { self.error = "Could not save your conversation: \(error.localizedDescription)" }
    }
    func newChat() {
        var chat = Conversation()
        chat.model = defaultModel
        conversations.insert(chat, at: 0)
        selectedID = chat.id
        persist(chat.id)
    }
    func archive(_ id: UUID) {
        stop(id)
        update(id) { $0.archived = true; $0.paused = true }
        if selectedID == id { selectedID = conversations.first { !$0.isArchived }?.id }
    }
    func restore(_ id: UUID) { update(id) { $0.archived = false } }
    func summarize(_ id: UUID, messageID: UUID) {
        guard let chat = chat(id), !chat.isArchived,
              let source = chat.messages.first(where: { $0.id == messageID }),
              source.role == .assistant, source.status == .complete,
              !source.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let prompt = SummaryPrompt.make(source.content)
        guard !SummaryPrompt.hasUnfinished(prompt, messages: chat.messages) else { return }
        send(id, text: prompt)
    }
    func delete(_ id: UUID) throws {
        stop(id)
        try disk?.delete(id)
        draftSaves.removeValue(forKey: id)?.cancel()
        conversations.removeAll { $0.id == id }
        if selectedID == id { selectedID = conversations.first(where: { !$0.isArchived })?.id }
    }
    func saveKey(_ key: String) -> Bool {
        do {
            let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
            try writeKey(key)
            hasKey = !key.isEmpty
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func loadModels() async {
        do { models = try await router.models() }
        catch { self.error = error.localizedDescription }
    }
    func send(_ id: UUID, steer: Bool = false, text override: String? = nil) {
        guard let chat = chat(id), !chat.isArchived else { return }
        let text = (override ?? chat.draft).trimmingCharacters(in: .whitespacesAndNewlines)
        let images = override == nil ? chat.draftImages ?? [] : []
        guard !text.isEmpty || !images.isEmpty else { return }
        guard requiresKey || images.isEmpty else { error = "Image input is available with OpenRouter. Remove the images before sending to Ollama."; return }
        do { try ImageAttachment.validate(images) } catch { self.error = error.localizedDescription; return }
        guard hasKey else { error = "Add your OpenRouter API key in Settings first."; return }
        guard !chat.model.isEmpty else { error = "Choose an installed Ollama model before sending."; return }
        if requiresKey, let effort = chat.reasoningEffort,
           models.first(where: { $0.id == chat.model })?.reasoningEfforts.contains(effort) != true {
            error = "Refresh the model catalog or choose Default reasoning effort before sending."
            return
        }
        if steer { stop(id) }
        let busy = active[id] != nil
        update(id) {
            $0.enqueue(text, prioritize: steer, model: requiresKey ? chat.model : nil, reasoningEffort: requiresKey ? chat.reasoningEffort : nil, images: images.isEmpty ? nil : images)
            if override == nil { $0.draft = ""; $0.draftImages = nil }
            $0.updated = Date()
            if $0.title == "New conversation", !text.isEmpty { $0.title = String(text.prefix(60)) }
        }
        if !busy { startNext(id) }
    }
    func startNext(_ id: UUID) {
        guard active[id] == nil, let chat = chat(id), !chat.isArchived, !chat.model.isEmpty, let next = chat.messages.first(where: { $0.status == .queued }) else { return }
        guard requiresKey || chat.requestMessages.allSatisfy({ ($0.images ?? []).isEmpty }) && (next.images ?? []).isEmpty else {
            error = "Image input is available with OpenRouter. This Ollama queue has been kept without sending."
            return
        }
        var key: String
        do { key = requiresKey ? try readKey() : "" } catch { self.error = error.localizedDescription; return }
        guard !requiresKey || !key.isEmpty else { error = "Add your API key in Settings."; return }
        update(id) { c in
            if let i = c.messages.firstIndex(where: { $0.id == next.id }) { c.messages[i].status = .complete }
        }
        begin(id, key: key, model: requiresKey ? next.model ?? chat.model : chat.model,
              reasoningEffort: requiresKey ? next.reasoningEffort : nil)
    }
    private func begin(_ id: UUID, key: String, model: String, reasoningEffort: ReasoningEffort?) {
        guard let chat = chat(id) else { return }
        let run = UUID()
        let response = Message(role: .assistant, content: "", status: .streaming, model: model, reasoningEffort: reasoningEffort)
        let history = chat.requestMessages
        active[id] = run
        update(id) { $0.insertResponse(response); $0.paused = false }
        pending[id] = ""
        tickers[id] = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self, self.active[id] == run else { return }
                self.flush(id, responseID: response.id)
                ticks += 1
                if ticks % 20 == 0 { self.persist(id) }
            }
        }
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            var succeeded = false
            do {
                try await self.router.stream(key: key, model: model, messages: history, reasoningEffort: reasoningEffort, onMetadata: { [weak self] metadata in
                    guard let self, self.active[id] == run else { return }
                    self.update(id) { conversation in
                        guard let index = conversation.messages.firstIndex(where: { $0.id == response.id }) else { return }
                        conversation.messages[index].applyMetadata(metadata)
                    }
                }) { [weak self] text in
                    guard let self, self.active[id] == run else { return }
                    self.pending[id, default: ""] += text
                }
                succeeded = true
            } catch {
                guard self.active[id] == run else { return }
                self.error = error.localizedDescription
            }
            guard self.active[id] == run else { return }
            self.flush(id, responseID: response.id)
            self.update(id) { c in
                if let i = c.messages.firstIndex(where: { $0.id == response.id }) {
                    c.messages[i].status = succeeded ? .complete : .failed
                    if !succeeded { c.paused = true }
                }
            }
            self.finish(id)
            if succeeded { self.startNext(id) }
        }
    }
    private func flush(_ id: UUID, responseID: UUID) {
        guard let text = pending[id], !text.isEmpty else { return }
        pending[id] = ""
        update(id, { c in
            if let i = c.messages.firstIndex(where: { $0.id == responseID }) { c.messages[i].content += text }
        }, save: false)
    }
    private func finish(_ id: UUID) {
        active[id] = nil
        tickers.removeValue(forKey: id)?.cancel()
        tasks[id] = nil
        pending[id] = nil
    }
    func stop(_ id: UUID) {
        guard active[id] != nil else { return }
        if let response = chat(id)?.messages.last(where: { $0.status == .streaming }) {
            flush(id, responseID: response.id)
            update(id) { c in
                if let i = c.messages.firstIndex(where: { $0.id == response.id }) { c.messages[i].status = .stopped
                    c.paused = true }
            }
        }
        tasks[id]?.cancel()
        finish(id)
    }
    func pauseAll() {
        for id in Array(active.keys) { stop(id) }
        for id in Array(draftSaves.keys) {
            draftSaves.removeValue(forKey: id)?.cancel()
            persist(id)
        }
    }
    func resume(_ id: UUID) {
        guard active[id] == nil, chat(id)?.isArchived == false else { return }
        if chat(id)?.messages.contains(where: { $0.status == .queued }) == true { startNext(id); return }
        update(id) { $0.messages.append(Message(role: .user, content: "Continue from where you stopped without repeating what you already wrote.", status: .queued, model: requiresKey ? $0.model : nil, reasoningEffort: requiresKey ? $0.reasoningEffort : nil)) }
        startNext(id)
    }
    func removeQueued(_ id: UUID, messageID: UUID) {
        update(id) { $0.messages.removeAll { $0.id == messageID && $0.status == .queued } }
    }
    /// Editing forks history, keeping the original and its responses intact.
    func edit(_ id: UUID, messageID: UUID, text: String) {
        guard let original = chat(id), !original.isArchived, let i = original.messages.firstIndex(where: { $0.id == messageID }), (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(original.messages[i].images ?? []).isEmpty) else { return }
        var fork = Conversation()
        fork.title = original.title + " · edited"
        fork.model = original.model
        fork.reasoningEffort = original.reasoningEffort
        fork.messages = Array(original.messages.prefix(i)).filter { $0.status != .queued }
        fork.recover()
        fork.messages.append(Message(role: .user, content: text, status: .queued, model: requiresKey ? fork.model : nil, reasoningEffort: requiresKey ? fork.reasoningEffort : nil, images: original.messages[i].images))
        conversations.insert(fork, at: 0)
        selectedID = fork.id
        persist(fork.id)
        startNext(fork.id)
    }
}
