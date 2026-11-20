import SwiftUI

struct ConversationDrawer: View {
    @Bindable var store: ChatStore
    @Binding var showArchived: Bool
    let isPresented: Bool
    let showsCloseButton: Bool
    let close: () -> Void
    let selected: () -> Void
    let newChat: () -> Void
    let openModels: () -> Void
    let openSettings: () -> Void
    @AppStorage("display-name") private var name = ""
    @State private var search = ""
    @State private var searching = false
    @State private var metadataBusy = false
    @State private var deleteTarget: UUID?
    @State private var renameTarget: UUID?
    @State private var renameTitle = ""
    @FocusState private var searchFocused: Bool
    private var chats: [Conversation] {
        (showArchived ? store.archivedConversations : store.conversations).filter {
            (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.messages.contains(where: { $0.content.localizedCaseInsensitiveContains(search) }))
        }.sorted { $0.updated > $1.updated }
    }
    var body: some View {
        let sections = ConversationRecency.sections(chats, includePinned: !showArchived)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("Neon").font(.title2.weight(.medium))
                Spacer(minLength: 0)
                if store.isRemote {
                    Button { Task { await store.refresh() } } label: {
                        Group {
                            if store.isSyncing { ProgressView().controlSize(.small) }
                            else { Image(systemName: "arrow.clockwise") }
                        }.frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain).foregroundStyle(ChatAppearance.muted)
                    .disabled(store.isSyncing)
                    .accessibilityLabel(store.isSyncing ? "Syncing conversations" : "Sync conversations")
                    .help("Sync conversations")
                }
                Button {
                    if searching { endSearch() } else { searching = true }
                } label: { Image(systemName: searching ? "magnifyingglass.circle.fill" : "magnifyingglass") }
                    .buttonStyle(ChatRoundButtonStyle()).accessibilityLabel(searching ? "Close search" : "Search conversations")
                if showsCloseButton {
                    Button { endSearch(); close() } label: { Image(systemName: "xmark") }
                        .buttonStyle(ChatRoundButtonStyle()).accessibilityLabel("Close conversations")
                }
            }.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 16)
            if searching {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(ChatAppearance.muted)
                    TextField(showArchived ? "Search archived" : "Search chats", text: $search).textFieldStyle(.plain).focused($searchFocused)
                        .task { await Task.yield(); if searching && isPresented { searchFocused = true } }
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44).contentShape(.rect) }
                            .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }
                .padding(.leading, 14).padding(.trailing, 8).frame(minHeight: 48)
                .background(ChatAppearance.surface, in: .rect(cornerRadius: 14))
                .padding(.horizontal, 18).padding(.bottom, 10)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if !searching {
                        VStack(spacing: 2) {
                            drawerAction("New chat", icon: "square.and.pencil") { endSearch(); newChat() }
                            drawerAction("Models", icon: "square.grid.2x2", action: openModels)
                                .disabled(store.selectedID.flatMap { store.chat($0) }?.isArchived == true)
                                .accessibilityHint("Start or restore a conversation to choose its model.")
                        }.padding(.horizontal, 18).padding(.bottom, 14)
                    }
                    HStack {
                        Text(searching ? (showArchived ? "Search archived" : "Search results") : (showArchived ? "Archived" : "Conversations"))
                            .font(ChatAppearance.subheadline).foregroundStyle(ChatAppearance.muted)
                        Spacer()
                        Menu {
                            Button { showArchived = false } label: {
                                if !showArchived { Label("Default", systemImage: "checkmark") } else { Text("Default") }
                            }
                            Button { showArchived = true } label: {
                                if showArchived { Label("Archived", systemImage: "checkmark") } else { Text("Archived") }
                            }
                        } label: { Image(systemName: showArchived ? "archivebox" : "line.3.horizontal.decrease").frame(width: 44, height: 44) }
                            .chatMenuStyle().foregroundStyle(ChatAppearance.muted).accessibilityLabel("Filter conversations")
                    }.padding(.leading, 24).padding(.trailing, 14)
                    if showArchived && !store.supportsArchiveBrowsing {
                        Text("Archived history isn’t available on this connection yet.")
                            .font(ChatAppearance.subheadline).foregroundStyle(ChatAppearance.muted).padding(24)
                    }
                    if chats.isEmpty {
                        if store.isSyncing && (!showArchived || store.supportsArchiveBrowsing) {
                            ProgressView(showArchived ? "Loading archived conversations…" : "Loading conversations…")
                                .font(ChatAppearance.subheadline).padding(24)
                        } else if !showArchived || store.supportsArchiveBrowsing {
                            Text(searching ? "No matching conversations." : (showArchived ? "No archived conversations are saved here." : "Your conversations will appear here."))
                                .font(ChatAppearance.subheadline).foregroundStyle(ChatAppearance.muted).padding(24)
                        }
                    }
                    ForEach(sections) { section in
                        Text(section.title).font(ChatAppearance.caption.weight(.medium)).foregroundStyle(ChatAppearance.muted)
                            .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 4)
                        ForEach(section.chats) { chat in conversationRow(chat) }
                    }
                }.padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .font(ChatAppearance.body)
        .background(ChatAppearance.canvas)
        .onChange(of: isPresented) { if !isPresented { endSearch() } }
        .alert("Delete conversation?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), presenting: deleteTarget) { id in
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete", role: .destructive) {
                deleteTarget = nil
                metadataBusy = true
                Task {
                    defer { metadataBusy = false }
                    do { try await store.delete(id) }
                    catch { store.error = "Deletion was not confirmed: \(error.localizedDescription)" }
                }
            }
        } message: { _ in
            Text("This permanently deletes the conversation and its messages, including queued responses. This cannot be undone.")
        }
        .alert("Rename conversation", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } }), presenting: renameTarget) { id in
            TextField("Conversation title", text: $renameTitle)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                updateMetadata(id, title: trimmedRename)
                renameTarget = nil
            }.disabled(trimmedRename.isEmpty || trimmedRename.utf16.count > 200)
        }
    }
    private var trimmedRename: String { renameTitle.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func updateMetadata(_ id: UUID, title: String? = nil, pinned: Bool? = nil) {
        guard !metadataBusy else { return }
        metadataBusy = true
        Task {
            defer { metadataBusy = false }
            do { try await store.setMetadata(id, title: title, pinned: pinned) }
            catch { store.error = "Couldn’t update the conversation. Please try again." }
        }
    }
    private func restore(_ chat: Conversation) {
        guard !metadataBusy else { return }
        metadataBusy = true
        Task {
            defer { metadataBusy = false }
            do {
                try await store.restore(chat.id)
                store.selectedID = chat.id
                showArchived = false
                endSearch()
            } catch { store.error = "Couldn’t restore the conversation. Please try again." }
        }
    }
    private func endSearch() {
        searchFocused = false
        searching = false
        search = ""
    }
    private func conversationRow(_ chat: Conversation) -> some View {
        Button {
            store.selectedID = chat.id
            endSearch()
            selected()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(chat.title).font(ChatAppearance.body).lineLimit(searching ? 2 : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if Ollama.isModel(chat.model) {
                        Text("Ollama · On this Mac").font(ChatAppearance.caption2).foregroundStyle(ChatAppearance.muted)
                    }
                    if searching {
                        Text(chat.updated.formatted(date: .abbreviated, time: .shortened))
                            .font(ChatAppearance.caption2).foregroundStyle(ChatAppearance.muted)
                    }
                }
                if store.active[chat.id] != nil { Circle().fill(ChatAppearance.accent).frame(width: 6, height: 6).accessibilityLabel("Generating") }
            }
            .foregroundStyle(Color(white: 0.86)).padding(.horizontal, 18).padding(.vertical, 14)
            .background(chat.id == store.selectedID ? ChatAppearance.selected : .clear, in: .rect(cornerRadius: 20))
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain).padding(.horizontal, 10)
        .accessibilityAddTraits(chat.id == store.selectedID ? .isSelected : [])
        .contextMenu {
            if chat.isArchived {
                Button("Restore", systemImage: "arrow.uturn.backward") { restore(chat) }
                    .disabled(metadataBusy || (chat.serverThread == true && !store.supportsRestore(chat.id)))
            } else {
                if store.supportsMetadata(chat.id) {
                    Button(chat.pinned == true ? "Unpin" : "Pin", systemImage: "pin") {
                        updateMetadata(chat.id, pinned: chat.pinned != true)
                    }.disabled(metadataBusy)
                    Button("Rename", systemImage: "pencil") {
                        renameTitle = chat.title
                        renameTarget = chat.id
                    }.disabled(metadataBusy)
                }
                Button("Archive", systemImage: "archivebox", role: .destructive) { store.archive(chat.id) }
                    .disabled(metadataBusy)
            }
            Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = chat.id }
                .disabled(metadataBusy || !store.supportsDeletion(chat.id))
            if !store.supportsDeletion(chat.id) { Text("A server update is required to delete conversations.") }
        }
    }
    private func drawerAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { Text(title).frame(maxWidth: .infinity, alignment: .leading) } icon: {
                Image(systemName: icon).font(.system(size: 21, weight: .light)).frame(width: 28)
            }
            .font(ChatAppearance.body).foregroundStyle(Color(white: 0.86)).padding(.vertical, 13).padding(.horizontal, 8).contentShape(.rect)
        }.buttonStyle(.plain)
    }
    private var footer: some View {
        Button(action: openSettings) {
            HStack(spacing: 12) {
                ChatProfileBadge(name: name)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Your workspace" : name).font(ChatAppearance.subheadline.weight(.medium)).foregroundStyle(.white).lineLimit(1)
                    Text(store.connectionStatus).font(ChatAppearance.caption2).foregroundStyle(ChatAppearance.muted).lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "gearshape").font(.system(size: 20, weight: .light)).foregroundStyle(Color(white: 0.8))
            }.padding(.horizontal, 22).padding(.vertical, 18).frame(maxWidth: .infinity).background(ChatAppearance.canvas)
        }.buttonStyle(.plain).accessibilityLabel("Profile, connection, and settings")
    }
}

extension View {
    @ViewBuilder func composerMenuStyle() -> some View {
        #if os(macOS)
        self.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        #else
        self
        #endif
    }
    @ViewBuilder func chatMenuStyle() -> some View {
        #if os(macOS)
        self.menuStyle(.borderlessButton).menuIndicator(.hidden)
        #else
        self
        #endif
    }
}
