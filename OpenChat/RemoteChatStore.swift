import Foundation
import Observation
import CryptoKit

@MainActor @Observable
final class RemoteChatStore {
    let client: BackendClient
    var conversations: [Conversation]
    var selectedID: UUID?
    var error: String?
    var hasKey = false
    var supportsConversationMetadata = false
    var supportsArchiveBrowsing = false
    var supportsReasoningEffort: Bool? = nil
    var supportsConversationDeletion = false
    var supportsImageInputs = false
    @ObservationIgnored private var deletedIDs = Set<UUID>()
    @ObservationIgnored private var archiveMutations = Set<UUID>()
    @ObservationIgnored private var archiveEpochs: [UUID: UUID] = [:]
    var pushAvailable = false
    private(set) var keyAllowance: KeyAllowanceState = .idle
    @ObservationIgnored private var allowanceRequest = UUID()
    private(set) var requiresAuthentication = false
    var connectionStatus = "Connecting…"
    private(set) var isSyncing = false
    private var jobs: [UUID: BackendJob] = [:]
    @ObservationIgnored private var metadataTasks: [UUID: (id: UUID, task: Task<Void, Error>)] = [:]
    @ObservationIgnored private var metadataRevisions: [UUID: Int] = [:]
    private var outbox: [PendingSend]
    @ObservationIgnored private let disk: ConversationDisk
    @ObservationIgnored private let outboxURL: URL
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var stream: Task<Void, Never>?
    @ObservationIgnored private var streamJob: UUID?
    @ObservationIgnored private var streamEpoch = UUID()
    @ObservationIgnored private var foreground = false
    @ObservationIgnored private var lifecycle = UUID()
    @ObservationIgnored private var draftSaves: [UUID: Task<Void, Never>] = [:]

    init(client: BackendClient, directory: URL? = nil) throws {
        self.client = client
        let root = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("OpenChat/Servers/\(Self.namespace(client.credentials.url, serverID: client.credentials.serverID))", isDirectory: true)
        let storage = try ConversationDisk(directory: root, recoverStreaming: false)
        let loaded = try storage.load()
        let queueURL = root.appendingPathComponent("outbox.data")
        let pending = FileManager.default.fileExists(atPath: queueURL.path)
            ? try JSONDecoder().decode([PendingSend].self, from: Data(contentsOf: queueURL)) : []
        disk = storage
        outboxURL = queueURL
        conversations = loaded
        selectedID = loaded.first(where: { !$0.isArchived })?.id
        outbox = pending
    }
    static func namespace(_ url: URL, serverID: UUID? = nil) -> String {
        SHA256.hash(data: Data((url.absoluteString + (serverID?.pathID ?? "")).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var active: [UUID: UUID] {
        var result = Dictionary(jobs.values.filter { $0.status == .running && chat($0.threadId)?.isArchived != true }.map { ($0.threadId, $0.id) }, uniquingKeysWith: { first, _ in first })
        for chat in conversations where !chat.isArchived && !jobs.values.contains(where: { $0.threadId == chat.id }) {
            if let response = chat.messages.first(where: { $0.status == .streaming }), let id = response.jobID { result[chat.id] = id }
        }
        return result
    }
    func chat(_ id: UUID) -> Conversation? { conversations.first { $0.id == id } }
    func update(_ id: UUID, _ change: (inout Conversation) -> Void, save: Bool = true) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        let previousModel = conversations[i].model
        change(&conversations[i])
        if conversations[i].model != previousModel { conversations[i].reasoningEffort = nil }
        if save { persist(id) }
    }
    func persist(_ id: UUID) {
        guard let chat = chat(id) else { return }
        do { try disk.save(chat) } catch { self.error = "Could not save the local cache: \(error.localizedDescription)" }
    }
    func setMetadata(_ id: UUID, title: String? = nil, pinned: Bool? = nil) async throws {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, trimmed.isEmpty || trimmed.utf16.count > 200 {
            throw RouterError(message: "Use a conversation name between 1 and 200 characters.")
        }
        let previous = metadataTasks[id]?.task
        let requestID = UUID()
        let expectedLifecycle = lifecycle
        let task = Task { @MainActor in
            _ = try? await previous?.value
            try Task.checkCancellation()
            guard self.lifecycle == expectedLifecycle else { throw CancellationError() }
            do {
                try await self.updateMetadata(id, title: trimmed, pinned: pinned, expectedLifecycle: expectedLifecycle)
            } catch {
                if let failure = error as? BackendFailure, failure.status == 401, self.lifecycle == expectedLifecycle {
                    self.requireAuthentication()
                }
                throw error
            }
        }
        metadataTasks[id] = (requestID, task)
        defer { if metadataTasks[id]?.id == requestID { metadataTasks[id] = nil } }
        try await task.value
    }
    private func updateMetadata(_ id: UUID, title: String?, pinned: Bool?, expectedLifecycle: UUID) async throws {
        guard canMutate(id) else { throw RouterError(message: "Restore this conversation before editing it.") }
        guard var current = chat(id) else { throw RouterError(message: "This conversation is no longer available.") }
        if current.serverThread != true && outbox.contains(where: { $0.threadID == id && $0.sourceThreadID != nil }) {
            throw RouterError(message: "Wait for this edited conversation to sync before changing its name or pin.")
        }
        if current.serverThread != true && !outbox.contains(where: { $0.threadID == id }) {
            if let title { current.title = title }
            if let pinned { current.pinned = pinned }
            try disk.save(current)
            update(id, { $0.title = current.title; $0.pinned = current.pinned }, save: false)
            return
        }
        if current.serverThread != true { try await client.createThread(current, supportsMetadata: supportsConversationMetadata) }
        try Task.checkCancellation()
        guard lifecycle == expectedLifecycle else { throw CancellationError() }
        struct Body: Encodable { let title: String?; let pinned: Bool? }
        let confirmed: BackendThread = try await client.send("v1/threads/\(id.pathID)", method: "PATCH", body: Body(title: title, pinned: pinned))
        try Task.checkCancellation()
        guard lifecycle == expectedLifecycle, confirmed.id == id, let latest = chat(id) else { throw CancellationError() }
        guard confirmed.revision >= max(latest.serverRevision ?? 0, metadataRevisions[id] ?? 0) else { return }
        metadataRevisions[id] = max(metadataRevisions[id] ?? 0, confirmed.revision)
        update(id, {
            $0.title = confirmed.title; $0.pinned = (confirmed.pinned ?? 0) != 0; $0.serverThread = true
        })
    }
    func setDraft(_ id: UUID, text: String) {
        guard canMutate(id) else { return }
        update(id, { $0.draft = text }, save: false)
        draftSaves[id]?.cancel()
        draftSaves[id] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.persist(id)
            self?.draftSaves[id] = nil
        }
    }
    func newChat() {
        let chat = Conversation()
        do { try disk.save(chat) } catch { self.error = error.localizedDescription; return }
        conversations.insert(chat, at: 0)
        select(chat.id)
    }
    func select(_ id: UUID?) {
        selectedID = id
        cancelStream()
        ensureStream()
    }
    func start() {
        guard !foreground, !requiresAuthentication else { return }
        foreground = true
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sync()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
    func suspend() {
        allowanceRequest = UUID()
        if keyAllowance == .loading { keyAllowance = .idle }
        foreground = false; lifecycle = UUID()
        loop?.cancel(); loop = nil
        cancelStream()
        for task in draftSaves.values { task.cancel() }
        draftSaves.removeAll()
        for chat in conversations { persist(chat.id) }
        // This disconnects subscribers only. Never send /stop on background.
    }
    func invalidateKeyAllowance() {
        allowanceRequest = UUID()
        keyAllowance = .idle
    }
    func refreshKeyAllowance() async {
        let request = UUID()
        allowanceRequest = request
        keyAllowance = .loading
        do {
            let allowance: KeyAllowance = try await client.get("v1/settings/openrouter-allowance")
            guard allowanceRequest == request else { return }
            guard !Task.isCancelled else { keyAllowance = .idle; return }
            keyAllowance = .loaded(allowance)
            hasKey = allowance.configured
        } catch {
            guard allowanceRequest == request else { return }
            if Task.isCancelled { keyAllowance = .idle; return }
            if let failure = error as? BackendFailure, failure.status == 401 { requireAuthentication() }
            keyAllowance = .unavailable
        }
    }
    private func saveOutbox(_ value: [PendingSend]) throws {
        try JSONEncoder().encode(value).write(to: outboxURL, options: .atomic)
        outbox = value
    }
    func summarize(_ id: UUID, messageID: UUID) {
        guard canMutate(id) else { return }
        guard let chat = chat(id), let source = chat.messages.first(where: { $0.id == messageID }),
              source.role == .assistant, source.status == .complete,
              !source.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Choose a completed answer to summarize."
            return
        }
        let prompt = SummaryPrompt.make(source.content)
        guard !outbox.contains(where: { $0.threadID == id && $0.prompt == prompt }),
              !jobs.values.contains(where: { $0.threadId == id && $0.prompt == prompt && $0.unfinished }),
              !SummaryPrompt.hasUnfinished(prompt, messages: chat.messages) else { return }
        do {
            try SummaryPrompt.validate(PendingSend(threadID: id, prompt: prompt, model: chat.model, steer: false, reasoningEffort: chat.reasoningEffort),
                                       jobs: jobs.values.filter { $0.threadId == id })
        } catch { self.error = error.localizedDescription; return }
        enqueue(id, text: prompt)
    }
    func enqueue(_ id: UUID, steer: Bool = false, text override: String? = nil) {
        guard canMutate(id) else { return }
        guard let chat = chat(id) else { return }
        let text = (override ?? chat.draft).trimmingCharacters(in: .whitespacesAndNewlines)
        let images = override == nil ? chat.draftImages ?? [] : []
        guard !text.isEmpty || !images.isEmpty else { return }
        guard images.isEmpty || supportsImageInputs else {
            error = "This server does not support image input yet. Update the server or remove the images before sending."
            return
        }
        do { try ImageAttachment.validate(images) } catch { self.error = error.localizedDescription; return }
        guard chat.reasoningEffort == nil || supportsReasoningEffort != false else {
            error = "This server does not support reasoning effort yet. Choose Default or update the server before sending."
            return
        }
        let pending = PendingSend(threadID: id, prompt: text, model: chat.model, steer: steer, reasoningEffort: chat.reasoningEffort, images: images.isEmpty ? nil : images)
        do { try saveOutbox(outbox + [pending]) } catch { self.error = "Could not save your message. Your draft has been kept."; return }
        update(id) {
            if override == nil { $0.draft = ""; $0.draftImages = nil }
            $0.updated = Date()
            if $0.title == "New conversation", !text.isEmpty { $0.title = String(text.prefix(60)) }
        }
        rebuild(id)
        Task { await sync() }
    }
    func fork(_ id: UUID, messageID: UUID, text: String) {
        guard canMutate(id) else { return }
        guard let original = chat(id), let message = original.messages.first(where: { $0.id == messageID }), let target = message.jobID else { return }
        guard (message.images ?? []).isEmpty || supportsImageInputs else {
            error = "Update the server before editing a message with images."
            return
        }
        var chat = Conversation()
        chat.title = original.title + " · edited"
        let cachedTarget = original.messages.first { $0.jobID == target && $0.model != nil }
        guard let targetModel = jobs[target]?.model ?? cachedTarget?.model else {
            error = "Sync this conversation before editing so its original model and reasoning effort can be preserved."
            return
        }
        chat.model = targetModel
        chat.reasoningEffort = jobs[target].map(\.reasoningEffort) ?? cachedTarget?.reasoningEffort
        let pending = PendingSend(threadID: chat.id, prompt: text, model: chat.model, steer: false, reasoningEffort: chat.reasoningEffort, sourceThreadID: id, targetJobID: target, images: message.images)
        do {
            try disk.save(chat)
            try saveOutbox(outbox + [pending])
        } catch { self.error = "Could not save the edited branch: \(error.localizedDescription)"; return }
        conversations.insert(chat, at: 0)
        rebuild(chat.id); select(chat.id)
        Task { await sync() }
    }
    func sync() async {
        guard foreground, !isSyncing else { return }
        isSyncing = true
        let lifecycle = self.lifecycle
        defer { isSyncing = false }
        do {
            let capabilities: BackendCapabilities = try await client.get("v1/capabilities")
            if let expected = client.credentials.serverID, capabilities.serverId != expected {
                throw BackendFailure(status: 409, message: "This address now identifies a different server. Reconnect in Settings before sending.")
            }
            let key: KeyState = try await client.get("v1/settings/openrouter-key")
            try checkLifecycle(lifecycle)
            supportsConversationMetadata = capabilities.conversationMetadata == true
            supportsArchiveBrowsing = capabilities.archiveBrowsing == true
            supportsReasoningEffort = capabilities.reasoningEffort == true
            supportsConversationDeletion = capabilities.conversationDeletion == true
            supportsImageInputs = capabilities.imageInputs == true
            hasKey = key.configured; pushAvailable = capabilities.push
            // Retry the exact saved payload, including steer/fork IDs. Never generate
            // a second ID just because a POST response may have been lost.
            var blockedThreads = Set(outbox.filter { $0.lastError != nil }.map(\.threadID))
            while let pending = outbox.first(where: { !blockedThreads.contains($0.threadID) }) {
                if chat(pending.threadID)?.isArchived == true || archiveMutations.contains(pending.threadID) {
                    blockedThreads.insert(pending.threadID)
                    continue
                }
              do {
                guard pending.reasoningEffort == nil || capabilities.reasoningEffort == true else {
                    throw BackendFailure(status: 409, message: "This server does not support reasoning effort yet. Your original send is kept until the server is updated, or restore its draft and choose Default.")
                }
                guard (pending.images ?? []).isEmpty || capabilities.imageInputs == true else {
                    throw BackendFailure(status: 409, message: "This server does not support image input yet. Your original send is kept until the server is updated, or restore its draft and remove the images.")
                }
                if pending.sourceThreadID == nil, let chat = chat(pending.threadID) { try await client.createThread(chat, supportsMetadata: supportsConversationMetadata) }
                let accepted = try await client.submit(pending)
                try checkLifecycle(lifecycle)
                guard accepted.id == pending.id, accepted.threadId == pending.threadID, accepted.prompt == pending.prompt,
                      pending.matchesConfiguration(accepted) else {
                    throw BackendFailure(status: 409, message: "The server acknowledged a different message. Your original send is kept.")
                }
                jobs[accepted.id] = accepted
                update(accepted.threadId, { $0.serverThread = true }, save: false)
                rebuild(accepted.threadId)
                // The outbox remains durable until a matching server acknowledgement.
                try saveOutbox(outbox.filter { $0.id != pending.id })
              } catch let failure as BackendFailure where (400..<500).contains(failure.status) && failure.status != 401 && failure.status != 408 && failure.status != 429 {
                var saved = outbox
                if let index = saved.firstIndex(where: { $0.id == pending.id }) { saved[index].lastError = failure.localizedDescription }
                try saveOutbox(saved)
                rebuild(pending.threadID)
                self.error = "Send needs attention: \(failure.localizedDescription)"
                blockedThreads.insert(pending.threadID)
              }
            }
            var metadata: [BackendThread] = try await client.get("v1/threads")
            if supportsArchiveBrowsing {
                let archived: [BackendThread] = try await client.get("v1/threads", query: [URLQueryItem(name: "archived", value: "true")])
                metadata += archived
            }
            try checkLifecycle(lifecycle)
            let serverIDs = Set(metadata.map(\.id))
            let removed = conversations.filter { $0.serverThread == true && !serverIDs.contains($0.id) && (supportsArchiveBrowsing || !$0.isArchived) && !archiveMutations.contains($0.id) }
            for chat in removed {
                let epoch = archiveEpochs[chat.id]
                do {
                    let snapshot: BackendThread = try await client.get("v1/threads/\(chat.id.pathID)", query: supportsArchiveBrowsing ? [URLQueryItem(name: "includeArchived", value: "true")] : [])
                    try checkLifecycle(lifecycle)
                    if epoch == archiveEpochs[chat.id], !archiveMutations.contains(chat.id) { apply(snapshot) }
                } catch let failure as BackendFailure where failure.status == 410 {
                    try checkLifecycle(lifecycle)
                    if epoch == archiveEpochs[chat.id], !archiveMutations.contains(chat.id) {
                        var saved = outbox
                        for index in saved.indices where saved[index].threadID == chat.id {
                            saved[index].lastError = "Conversation is archived. Restore it, then explicitly retry this send."
                        }
                        try saveOutbox(saved)
                        update(chat.id, { $0.archived = true })
                        if selectedID == chat.id { cancelStream(); select(conversations.first(where: { !$0.isArchived })?.id) }
                    }
                } catch let failure as BackendFailure where failure.status == 404 {
                    try checkLifecycle(lifecycle)
                    if epoch == archiveEpochs[chat.id], !archiveMutations.contains(chat.id),
                       supportsConversationDeletion || (self.chat(chat.id)?.draft.isEmpty == true && (self.chat(chat.id)?.draftImages ?? []).isEmpty &&
                       !outbox.contains(where: { $0.threadID == chat.id || $0.sourceThreadID == chat.id })) {
                        try removeDeletedConversation(chat.id)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch let failure as BackendFailure where failure.status == 401 { throw failure }
                catch { /* Keep the cache until absence can be confirmed. */ }
            }
            for thread in metadata {
                if chat(thread.id)?.serverRevision != thread.revision || !jobs.values.contains(where: { $0.threadId == thread.id }) {
                    // Invalidate callbacks before fetching a canonical snapshot, so
                    // an older in-flight subscriber cannot overwrite newer state.
                    if thread.id == selectedID { cancelStream() }
                    let epoch = archiveEpochs[thread.id]
                    let snapshot: BackendThread = try await client.get("v1/threads/\(thread.id.pathID)", query: supportsArchiveBrowsing ? [URLQueryItem(name: "includeArchived", value: "true")] : [])
                    try checkLifecycle(lifecycle)
                    if epoch == archiveEpochs[thread.id], !archiveMutations.contains(thread.id) { apply(snapshot) }
                }
            }
            if let selectedID, chat(selectedID) == nil { select(conversations.first(where: { !$0.isArchived })?.id) }
            if selectedID == nil { select(conversations.first(where: { !$0.isArchived })?.id) }
            conversations.sort { $0.updated > $1.updated }
            connectionStatus = outbox.isEmpty ? "Synced" : "A send needs attention · sync to retry"
            ensureStream()
            NotificationCenter.default.post(name: .backendDidSync, object: nil)
        } catch is CancellationError { }
        catch {
            if let failure = error as? BackendFailure, failure.status == 401 {
                requireAuthentication()
                return
            }
            if !Task.isCancelled { connectionStatus = outbox.isEmpty ? "Offline · showing saved chats" : "Send awaiting confirmation · retry with the same ID" }
            // Surface actionable server errors; network reconnects remain quiet.
            if let failure = error as? BackendFailure { self.error = failure.localizedDescription }
        }
    }
    func requireAuthentication() {
        requiresAuthentication = true
        suspend()
        connectionStatus = "Reconnect with your OpenRouter key"
    }
    private func checkLifecycle(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard foreground, lifecycle == expected else { throw CancellationError() }
    }
    private func apply(_ snapshot: BackendThread) {
        guard !deletedIDs.contains(snapshot.id) else { return }
        guard snapshot.revision >= max(metadataRevisions[snapshot.id] ?? 0, chat(snapshot.id)?.serverRevision ?? 0) else { return }
        guard snapshot.archived != nil || chat(snapshot.id)?.isArchived != true else { return }
        let wasArchived = chat(snapshot.id)?.isArchived == true
        if chat(snapshot.id) == nil {
            var chat = Conversation(); chat.id = snapshot.id; chat.title = snapshot.title
            chat.updated = Date(timeIntervalSince1970: snapshot.created / 1000)
            conversations.insert(chat, at: 0)
        }
        jobs = jobs.filter { $0.value.threadId != snapshot.id }
        for job in snapshot.jobs ?? [] { jobs[job.id] = job }
        update(snapshot.id, {
            $0.title = snapshot.title; $0.pinned = (snapshot.pinned ?? 0) != 0; $0.serverThread = true; $0.serverRevision = snapshot.revision; $0.paused = snapshot.paused != 0
            $0.archived = (snapshot.archived ?? 0) != 0
        }, save: false)
        if chat(snapshot.id)?.isArchived == true {
            var saved = outbox
            for index in saved.indices where saved[index].threadID == snapshot.id {
                saved[index].lastError = "Conversation is archived. Restore it, then explicitly retry this send."
            }
            do { try saveOutbox(saved) } catch { self.error = error.localizedDescription }
            if selectedID == snapshot.id {
                cancelStream()
                if !wasArchived { select(conversations.first(where: { !$0.isArchived })?.id) }
            }
        }
        rebuild(snapshot.id)
    }
    private func rebuild(_ id: UUID, save: Bool = true) {
        let ordered = jobs.values.filter { $0.threadId == id }.sorted { $0.position < $1.position }
        var messages: [Message] = []
        for job in ordered {
            messages.append(Message(id: job.id, role: .user, content: job.prompt, status: job.status == .queued ? .queued : .complete, model: job.model, jobID: job.id, reasoningEffort: job.reasoningEffort, images: job.images))
            if job.status != .queued {
                let status: Message.Status
                switch job.status {
                case .running: status = .streaming
                case .complete: status = .complete
                case .stopped: status = .stopped
                case .failed: status = .failed
                case .queued: status = .queued
                }
                if !job.content.isEmpty || status != .stopped {
                    messages.append(Message(id: Self.assistantID(job.id), role: .assistant, content: job.content, status: status, model: job.model, jobID: job.id, failure: job.error, responseModel: job.responseModel, inputTokens: job.inputTokens, outputTokens: job.outputTokens, totalTokens: job.totalTokens, costUSD: job.costUSD, reasoningEffort: job.reasoningEffort))
                }
            }
        }
        for pending in outbox where pending.threadID == id && jobs[pending.id] == nil {
            messages.append(Message(id: pending.id, role: .user, content: pending.prompt, status: pending.lastError == nil ? .sending : .failed, model: pending.model, jobID: pending.id, failure: pending.lastError, reasoningEffort: pending.reasoningEffort, images: pending.images))
        }
        update(id, {
            $0.messages = messages
            if let latest = ordered.map(\.updated).max() { $0.updated = Date(timeIntervalSince1970: latest / 1000) }
        }, save: save)
    }
    static func assistantID(_ job: UUID) -> UUID {
        let hex = SHA256.hash(data: Data("\(job.pathID)/assistant".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let chars = Array(hex)
        let value = [String(chars[0..<8]), String(chars[8..<12]), String(chars[12..<16]), String(chars[16..<20]), String(chars[20..<32])].joined(separator: "-")
        return UUID(uuidString: value)!
    }
    private func cancelStream() {
        streamEpoch = UUID(); stream?.cancel(); stream = nil; streamJob = nil
    }
    private func ensureStream() {
        guard foreground, let selectedID, canMutate(selectedID) else { return }
        let candidate = jobs.values.filter { $0.threadId == selectedID && $0.unfinished }.sorted { $0.position < $1.position }.first
        guard let candidate, candidate.status == .running || chat(selectedID)?.paused != true else { cancelStream(); return }
        guard streamJob != candidate.id else { return }
        cancelStream(); streamJob = candidate.id
        let epoch = streamEpoch
        stream = Task { [weak self] in
            guard let self else { return }
            do {
                try await client.events(job: candidate) { [weak self] event in
                    guard let self, self.streamEpoch == epoch else { return }
                    if event.name == "delta" {
                        let delta = try JSONDecoder().decode(BackendDelta.self, from: Data(event.data.utf8))
                        guard delta.jobId == candidate.id, var job = self.jobs[candidate.id], job.content.utf16.count == delta.offset else {
                            throw RouterError(message: "Response cursor changed. Refreshing the saved response.")
                        }
                        job.content += delta.text; self.jobs[job.id] = job
                        self.rebuild(job.threadId, save: false)
                    } else if event.name == "status" {
                        let status = try JSONDecoder().decode(BackendStatus.self, from: Data(event.data.utf8))
                        guard status.jobId == candidate.id, var job = self.jobs[candidate.id] else { return }
                        job.status = status.status; job.error = status.error; job.applyMetadata(status.metadata); self.jobs[job.id] = job
                        self.rebuild(job.threadId, save: !job.unfinished || status.metadata.hasValues)
                    }
                }
            } catch { /* Snapshot polling repairs gaps and resumes from durable state. */ }
            guard self.streamEpoch == epoch else { return }
            if self.jobs[candidate.id]?.unfinished == true {
                self.update(candidate.threadId, { $0.serverRevision = nil }, save: false)
            }
            self.stream = nil; self.streamJob = nil
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            await self.sync()
        }
    }
    func stop(_ id: UUID) {
        guard canMutate(id) else { return }
        guard let job = active[id] else { return }
        struct Body: Encodable { let expectedJobId: UUID }
        Task {
            do {
                let _: BackendClient.Empty = try await client.send("v1/threads/\(id.pathID)/stop", body: Body(expectedJobId: job))
                await sync()
            } catch { self.error = "Stop was not confirmed: \(error.localizedDescription)" }
        }
    }
    func resume(_ id: UUID) {
        guard canMutate(id) else { return }
        let cachedQueue = chat(id)?.messages.contains(where: { $0.status == .queued }) == true
        if cachedQueue || jobs.values.contains(where: { $0.threadId == id && $0.status == .queued }) {
            Task { do { try await client.command("v1/threads/\(id.pathID)/resume"); await sync() } catch { self.error = error.localizedDescription } }
        } else { enqueue(id, text: "Continue from where you stopped without repeating what you already wrote.") }
    }
    func retryPending() async {
        do {
            var saved = outbox
            for index in saved.indices where chat(saved[index].threadID)?.isArchived != true && !archiveMutations.contains(saved[index].threadID) { saved[index].lastError = nil }
            try saveOutbox(saved)
            for id in Set(saved.map(\.threadID)) where canMutate(id) { rebuild(id) }
            await sync()
        } catch { self.error = error.localizedDescription }
    }
    func removeQueued(_ id: UUID, messageID: UUID) {
        guard canMutate(id) else { return }
        if let pending = outbox.first(where: { $0.id == messageID && $0.lastError != nil }), var chat = chat(id) {
            guard (chat.draftImages ?? []).count + (pending.images ?? []).count <= ImageAttachment.maximumCount else {
                error = "Remove draft images before restoring this message. A draft can contain up to four images."
                return
            }
            chat.draft += (chat.draft.isEmpty ? "" : "\n\n") + pending.prompt
            chat.draftImages = (chat.draftImages ?? []) + (pending.images ?? [])
            do {
                try disk.save(chat)
                update(id, { $0.draft = chat.draft; $0.draftImages = chat.draftImages }, save: false)
                try saveOutbox(outbox.filter { $0.id != pending.id })
                rebuild(id)
            } catch { self.error = error.localizedDescription }
            return
        }
        Task {
            do { try await client.command("v1/jobs/\(messageID.pathID)", method: "DELETE"); await sync() }
            catch { self.error = "Removal was not confirmed: \(error.localizedDescription)" }
        }
    }
    func archive(_ id: UUID) {
        guard let current = chat(id), !current.isArchived, !archiveMutations.contains(id), metadataTasks[id] == nil else { return }
        // Unconfirmed sends must be reconciled before archiving; never drop them.
        guard !outbox.contains(where: { $0.threadID == id || $0.sourceThreadID == id }) else { error = "Confirm pending sends before archiving this conversation."; return }
        archiveMutations.insert(id); archiveEpochs[id] = UUID()
        if selectedID == id { cancelStream() }
        let expectedLifecycle = lifecycle
        Task {
            defer { archiveMutations.remove(id) }
            do {
                if current.serverThread == true {
                    try await client.command("v1/threads/\(id.pathID)/archive")
                    if supportsArchiveBrowsing {
                        let snapshot: BackendThread = try await client.get("v1/threads/\(id.pathID)", query: [URLQueryItem(name: "includeArchived", value: "true")])
                        guard lifecycle == expectedLifecycle else { throw CancellationError() }
                        apply(snapshot)
                    }
                }
                guard lifecycle == expectedLifecycle else { throw CancellationError() }
                if current.serverThread != true || !supportsArchiveBrowsing { update(id, { $0.archived = true }) }
                if selectedID == id, chat(id)?.isArchived == true { select(conversations.first(where: { !$0.isArchived })?.id) }
            } catch { self.error = "Archive was not confirmed: \(error.localizedDescription)" }
        }
    }
    func delete(_ id: UUID) async throws {
        guard let current = chat(id) else { return }
        guard !archiveMutations.contains(id), metadataTasks[id] == nil else {
            throw RouterError(message: "Wait for the conversation update to finish, then try again.")
        }
        guard !outbox.contains(where: { $0.threadID == id || $0.sourceThreadID == id }) else {
            throw RouterError(message: "Confirm pending sends before deleting this conversation.")
        }
        guard current.serverThread != true || supportsConversationDeletion else {
            throw RouterError(message: "This server does not support deleting conversations yet.")
        }
        archiveMutations.insert(id); archiveEpochs[id] = UUID()
        if selectedID == id { cancelStream() }
        defer { archiveMutations.remove(id); ensureStream() }
        if current.serverThread == true {
            try await client.command("v1/threads/\(id.pathID)", method: "DELETE")
        }
        try removeDeletedConversation(id)
    }
    private func removeDeletedConversation(_ id: UUID) throws {
        try saveOutbox(outbox.filter { $0.threadID != id })
        try disk.delete(id)
        deletedIDs.insert(id)
        archiveEpochs[id] = UUID()
        draftSaves.removeValue(forKey: id)?.cancel()
        conversations.removeAll { $0.id == id }
        jobs = jobs.filter { $0.value.threadId != id }
        metadataRevisions[id] = nil
        if selectedID == id { select(conversations.first(where: { !$0.isArchived })?.id) }
    }
    func canMutate(_ id: UUID) -> Bool {
        !deletedIDs.contains(id) && chat(id)?.isArchived != true && !archiveMutations.contains(id)
    }
    func restore(_ id: UUID) async throws {
        guard let current = chat(id), current.isArchived, !archiveMutations.contains(id) else { return }
        archiveMutations.insert(id); archiveEpochs[id] = UUID()
        defer { archiveMutations.remove(id) }
        if current.serverThread != true {
            var restored = current; restored.archived = false
            try disk.save(restored)
            update(id, { $0.archived = false }, save: false)
            return
        }
        guard supportsArchiveBrowsing else { throw RouterError(message: "This server does not support restoring archived conversations yet.") }
        let expectedLifecycle = lifecycle
        let snapshot: BackendThread = try await client.send("v1/threads/\(id.pathID)/restore", body: BackendClient.Empty())
        try Task.checkCancellation()
        guard lifecycle == expectedLifecycle, snapshot.id == id else { throw CancellationError() }
        apply(snapshot)
    }
    func openJob(_ id: UUID) async -> Bool {
        do {
            let job: BackendJob = try await client.get("v1/jobs/\(id.pathID)")
            guard canMutate(job.threadId) else { return false }
            let epoch = archiveEpochs[job.threadId]
            cancelStream()
            let snapshot: BackendThread = try await client.get("v1/threads/\(job.threadId.pathID)", query: supportsArchiveBrowsing ? [URLQueryItem(name: "includeArchived", value: "true")] : [])
            guard epoch == archiveEpochs[job.threadId], canMutate(job.threadId) else { return false }
            apply(snapshot); select(snapshot.id)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
