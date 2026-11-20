import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ContentView: View {
    @Bindable var store: ChatStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settings = false
    @State private var models = false
    @State private var drawer = false
    @State private var sidebar = true
    @State private var showArchived = false
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 900
            let drawerWidth = min(390, geometry.size.width - 36)
            ZStack(alignment: .leading) {
                if !wide && !store.needsBackendConnection {
                    conversationDrawer(showsCloseButton: true, close: { drawer = false })
                        .frame(width: drawerWidth)
                        .accessibilityHidden(!drawer)
                        .allowsHitTesting(drawer)
                        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { value in
                            if DrawerSwipe.closes(value.translation) { drawer = false }
                        })
                }
                HStack(spacing: 0) {
                    if wide && sidebar && !store.needsBackendConnection {
                        conversationDrawer(showsCloseButton: false, close: { sidebar = false }).frame(width: 290)
                        Rectangle().fill(.white.opacity(0.06)).frame(width: 1)
                    }
                    Group {
                        if store.needsBackendConnection {
                            BackendConnectionView(store: store)
                        } else if let id = store.selectedID, store.chat(id) != nil {
                            ChatView(store: store, id: id,
                                     drawerPresented: drawer && !wide,
                                     openDrawer: { if wide { sidebar.toggle() } else { drawer = true } },
                                     openModels: { models = true },
                                     newChat: newChat, restored: { showArchived = false })
                                .id(id)
                        } else {
                            VStack(spacing: 24) {
                                WelcomeBrandMark()
                                Text("A little space to think").font(.title2)
                                Button("Start a conversation", action: newChat).buttonStyle(.borderedProminent).foregroundStyle(ChatAppearance.canvas)
                            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(ChatBackdrop())
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(ChatAppearance.canvas)
                .offset(x: !wide && drawer ? drawerWidth : 0)
                .accessibilityHidden(drawer && !wide)
                .allowsHitTesting(wide || !drawer)
                if !wide && !store.needsBackendConnection {
                    if drawer {
                        Button { drawer = false } label: {
                            Color.black.opacity(0.35)
                        }
                        .buttonStyle(.plain)
                        .frame(width: geometry.size.width - drawerWidth)
                        .frame(maxHeight: .infinity)
                        .offset(x: drawerWidth)
                        .accessibilityLabel("Close conversation drawer")
                        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { value in
                            if DrawerSwipe.closes(value.translation) { drawer = false }
                        })
                    } else {
                        Color.clear
                            .frame(width: 24)
                            .contentShape(.rect)
                            .gesture(DragGesture(minimumDistance: 24).onEnded { value in
                                if DrawerSwipe.opens(value.translation) { drawer = true }
                            })
                            .accessibilityHidden(true)
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: drawer)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: sidebar)
            .onChange(of: wide) { if wide { drawer = false } }
            .onChange(of: store.needsBackendConnection) { if store.needsBackendConnection { drawer = false } }
        }
        .background(ChatAppearance.canvas)
        .preferredColorScheme(.dark)
        .tint(ChatAppearance.accent)
        .task(id: store.isRemote) { if store.selectedID == nil { newChat() } }
        .onChange(of: store.selectedID.flatMap { store.chat($0) }?.isArchived) {
            if store.selectedID.flatMap({ store.chat($0) })?.isArchived == true { models = false }
        }
        .sheet(isPresented: $settings) { SettingsView(store: store) }
        .sheet(isPresented: $models) {
            if let id = store.selectedID { ModelPicker(store: store, id: id) }
        }
        .alert("Neon", isPresented: Binding(get: { store.error != nil && !settings && !models }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
    private func newChat() {
        showArchived = false
        store.newChat()
    }
    private func conversationDrawer(showsCloseButton: Bool, close: @escaping () -> Void) -> some View {
        ConversationDrawer(store: store, showArchived: $showArchived, isPresented: !showsCloseButton || drawer, showsCloseButton: showsCloseButton, close: close, selected: { drawer = false },
                           newChat: { newChat(); drawer = false },
                           openModels: { if store.selectedID == nil { newChat() }; models = true },
                           openSettings: { settings = true })
    }
}

struct ChatView: View {
    @Bindable var store: ChatStore
    let id: UUID
    let drawerPresented: Bool
    let openDrawer: () -> Void
    let openModels: () -> Void
    let newChat: () -> Void
    let restored: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var metadataBusy = false
    @State private var renameTitle = ""
    @State private var showingRename = false
    @State private var showingDelete = false
    @State private var editing: Message?
    @State private var queue = false
    @State private var bottomRequest = 0
    @State private var composerFocused = false
    @AppStorage("display-name") private var name = ""
    @AppStorage("favorite-model-ids") private var savedFavorites = "[]"
    @AppStorage("ollama-favorite-model-ids") private var savedLocalFavorites = "[]"
    private var chat: Conversation { store.chat(id) ?? Conversation() }
    private var readOnly: Bool { chat.isArchived }
    private var canRestore: Bool { chat.serverThread != true || store.supportsRestore(id) }
    private var busy: Bool { store.active[id] != nil }
    private var hasText: Bool { !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(chat.draftImages ?? []).isEmpty }
    private var pending: [Message] { chat.messages.filter { $0.role == .user && [.sending, .queued, .failed].contains($0.status) } }
    var body: some View {
        VStack(spacing: 0) {
            header
            if readOnly {
                transcript
            } else if chat.messages.isEmpty {
                WelcomeChatView(name: name) { prompt in store.setDraft(id, text: prompt); composerFocused = true }
                    .id(id)
            } else {
                transcript
            }
            #if os(iOS)
            if !readOnly { composer }
            #endif
        }
        #if os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) { if !readOnly { composer } }
        #endif
        .background(ChatBackdrop(response: ResponseGlowInput(conversationID: id, activeJobID: store.active[id], messages: chat.messages)))
        .onChange(of: drawerPresented) { if drawerPresented { composerFocused = false } }
        .onChange(of: readOnly) {
            if readOnly { composerFocused = false; editing = nil; queue = false; showingRename = false }
        }
        .sheet(item: $editing) { message in
            EditView(text: message.content) { text in store.edit(id, messageID: message.id, text: text) }
        }
        .sheet(isPresented: $queue) { queueSheet }
        .alert("Delete conversation?", isPresented: $showingDelete) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                metadataBusy = true
                Task {
                    defer { metadataBusy = false }
                    do { try await store.delete(id) }
                    catch { store.error = "Deletion was not confirmed: \(error.localizedDescription)" }
                }
            }
        } message: {
            Text("This permanently deletes the conversation and its messages, including queued responses. This cannot be undone.")
        }
        .alert("Rename conversation", isPresented: $showingRename) {
            TextField("Conversation title", text: $renameTitle)
            Button("Cancel", role: .cancel) { }
            Button("Save") { updateMetadata(title: trimmedRename) }.disabled(trimmedRename.isEmpty || trimmedRename.utf16.count > 200)
        }
    }
    private var trimmedRename: String { renameTitle.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func updateMetadata(title: String? = nil, pinned: Bool? = nil) {
        guard !metadataBusy else { return }
        metadataBusy = true
        Task {
            defer { metadataBusy = false }
            do { try await store.setMetadata(id, title: title, pinned: pinned) }
            catch { store.error = "Couldn’t update the conversation. Please try again." }
        }
    }
    private var header: some View {
        HStack(spacing: 10) {
            Button { composerFocused = false; openDrawer() } label: { Image(systemName: "line.3.horizontal") }
                .buttonStyle(ChatRoundButtonStyle()).accessibilityLabel("Open conversations")
                .keyboardShortcut("s", modifiers: [.command, .shift])
            if readOnly {
                Text("Archived").font(ChatAppearance.body).foregroundStyle(ChatAppearance.muted).lineLimit(1)
            } else {
            Menu {
                let favorites = ModelFavorites(ids: ModelFavorites(encoded: savedFavorites).ids + ModelFavorites(encoded: savedLocalFavorites).ids).models(in: store.models, search: "")
                if favorites.isEmpty {
                    Text("No favorite models yet")
                } else {
                    Section("Favorites") {
                        ForEach(favorites) { model in
                            Button { store.chooseModel(model.id, for: id) } label: {
                                if model.id == chat.model {
                                    Label(model.name, systemImage: "checkmark")
                                } else {
                                    Text(model.name)
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Browse all models…", systemImage: "magnifyingglass", action: openModels)
            } label: {
                HStack(spacing: 6) {
                    Text(ChatAppearance.modelName(chat.model)).lineLimit(1)
                    Image(systemName: "chevron.down").font(ChatAppearance.caption)
                }.font(ChatAppearance.body).foregroundStyle(Color(white: 0.85)).frame(minHeight: 44)
            }.chatMenuStyle().accessibilityLabel("Choose model, current model \(ChatAppearance.modelName(chat.model))")
            if !Ollama.isModel(chat.model), !store.reasoningEfforts(for: id).isEmpty || chat.reasoningEffort != nil {
                Menu {
                    Picker(selection: Binding(get: { chat.reasoningEffort }, set: { store.chooseReasoningEffort($0, for: id) })) {
                        Text("Default").tag(ReasoningEffort?.none)
                        ForEach(store.reasoningEfforts(for: id)) { effort in
                            Text(effort.title).tag(Optional(effort))
                        }
                    } label: { Text("Reasoning effort") }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "brain")
                        Text(chat.reasoningEffort?.title ?? "Default").lineLimit(1)
                    }.font(ChatAppearance.caption).foregroundStyle(Color(white: 0.85)).frame(minHeight: 44)
                }.chatMenuStyle()
                    .accessibilityLabel("Reasoning effort")
                    .accessibilityValue(chat.reasoningEffort?.title ?? "Default")
            }
            }
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                Button(action: newChat) { Image(systemName: "square.and.pencil").frame(width: 44, height: 44) }
                    .accessibilityLabel("New chat").keyboardShortcut("n")
                if readOnly {
                    Button(action: restore) {
                        Group {
                            if metadataBusy { ProgressView().controlSize(.small) }
                            else { Text("Restore").font(ChatAppearance.subheadline).fixedSize(horizontal: true, vertical: false) }
                        }.frame(minWidth: 44, minHeight: 44).padding(.horizontal, 8)
                    }.disabled(metadataBusy || !canRestore)
                        .accessibilityLabel("Restore conversation")
                }
                Menu {
                    if !readOnly && store.supportsMetadata(id) {
                        Button(chat.pinned == true ? "Unpin" : "Pin", systemImage: "pin") {
                            updateMetadata(pinned: chat.pinned != true)
                        }
                        Button("Rename", systemImage: "pencil") {
                            renameTitle = chat.title
                            showingRename = true
                        }
                    }
                    if !readOnly {
                        Button("Archive", systemImage: "archivebox") { store.archive(id) }
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) { showingDelete = true }
                        .disabled(!store.supportsDeletion(id))
                    if !store.supportsDeletion(id) { Text("A server update is required to delete conversations.") }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                    .chatMenuStyle().accessibilityLabel("Conversation actions").disabled(metadataBusy)
            }
            .buttonStyle(.plain).font(.system(size: 20)).foregroundStyle(Color(white: 0.85))
            .background(.white.opacity(0.075), in: .capsule)
            .overlay { Capsule().strokeBorder(.white.opacity(0.06), lineWidth: 1) }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
    }
    private func restore() {
        guard !metadataBusy && canRestore else { return }
        metadataBusy = true
        Task {
            defer { metadataBusy = false }
            do {
                try await store.restore(id)
                restored()
            } catch { store.error = "Couldn’t restore the conversation. Please try again." }
        }
    }
    private var transcript: some View {
        TranscriptScrollView(bottomRequest: bottomRequest) {
            if readOnly && !canRestore {
                Text("Restoring archived conversations isn’t available on this connection yet.")
                    .font(ChatAppearance.subheadline).foregroundStyle(ChatAppearance.muted)
            }
            ForEach(chat.messages) { message in
                MessageView(message: message, edit: { editing = message }, remove: { store.removeQueued(id, messageID: message.id) }, summarize: readOnly ? nil : {
                    store.summarize(id, messageID: message.id)
                    bottomRequest += 1
                }, readOnly: readOnly)
            }
        }
    }
    private var queueActionsLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
    }
    private var composer: some View {
        VStack(spacing: 10) {
            if !pending.isEmpty || (busy && hasText) {
                queueActionsLayout {
                    if !pending.isEmpty {
                        Button { queue = true } label: {
                            Text("\(pending.count) pending").frame(minHeight: 44).contentShape(.rect)
                        }.foregroundStyle(ChatAppearance.accent)
                    }
                    if !busy && chat.paused == true && chat.messages.contains(where: { $0.status == .queued }) {
                        Button { store.resume(id); bottomRequest += 1 } label: {
                            Label("Resume queued messages", systemImage: "play").frame(minHeight: 44).contentShape(.rect)
                        }.foregroundStyle(ChatAppearance.accent)
                    }
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    if busy && hasText {
                        Button { store.send(id, steer: true); bottomRequest += 1 } label: {
                            Text("Stop & steer").frame(minHeight: 44).contentShape(.rect)
                        }.foregroundStyle(ChatAppearance.accent)
                    }
                }.font(ChatAppearance.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
            }
            if let images = chat.draftImages, !images.isEmpty {
                AttachedImages(images: images) { store.removeDraftImage(id, at: $0) }
                    .padding(.horizontal, 14)
                Text("Choose an image-capable OpenRouter model.")
                    .font(ChatAppearance.caption).foregroundStyle(ChatAppearance.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button("Choose model", systemImage: "cpu", action: openModels)
                    Button("New chat", systemImage: "square.and.pencil", action: newChat)
                    if busy { Button("Stop response", systemImage: "stop") { store.stop(id) } }
                } label: {
                    Image(systemName: "plus").font(.system(size: 23, weight: .light)).frame(width: 44, height: 44)
                }
                .composerMenuStyle()
                .frame(width: 44, height: 44)
                .contentShape(.rect)
                .foregroundStyle(Color(white: 0.8)).accessibilityLabel("Chat options")
                ComposerTextInput(text: Binding(get: { chat.draft }, set: { store.setDraft(id, text: $0) }),
                                  focused: Binding(get: { composerFocused }, set: { composerFocused = $0 }),
                                  hasContent: hasText, pasteImages: { store.pasteImages($0, to: id) }) {
                    store.send(id)
                    bottomRequest += 1
                }
                .overlay(alignment: .topLeading) {
                    if chat.draft.isEmpty {
                        Text("Ask Neon").font(ChatAppearance.body).foregroundStyle(ChatAppearance.muted)
                            .padding(.top, 12).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                Button {
                    if busy && !hasText { store.stop(id) }
                    else { store.send(id); bottomRequest += 1 }
                } label: {
                    Image(systemName: busy && !hasText ? "stop" : "arrow.up").font(.system(size: 19, weight: .medium))
                }
                .buttonStyle(ChatRoundButtonStyle(prominent: hasText))
                .disabled(!hasText && !busy).opacity(hasText || busy ? 1 : 0.45)
                .accessibilityLabel(busy && !hasText ? "Stop response" : (busy ? "Queue message" : "Send message"))
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(9).padding(.leading, 5)
            .background(LinearGradient(colors: [Color(white: 0.115), Color(white: 0.09)], startPoint: .top, endPoint: .bottom), in: .rect(cornerRadius: 32))
            .overlay { RoundedRectangle(cornerRadius: 32).strokeBorder(.white.opacity(0.08), lineWidth: 1) }
            .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        }
        .frame(maxWidth: 780).padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 14).frame(maxWidth: .infinity)
    }
    private var queueSheet: some View {
        NavigationStack {
            List {
                if pending.isEmpty { Text("Your queue is empty.").foregroundStyle(.secondary) }
                ForEach(pending) { message in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(message.content).lineLimit(5)
                        if let images = message.images, !images.isEmpty { AttachedImages(images: images) }
                        HStack {
                            Text(message.status.rawValue.capitalized).font(ChatAppearance.caption).foregroundStyle(.secondary)
                            Spacer()
                            if message.status != .sending {
                                Button(message.status == .failed ? "Restore draft" : "Remove") { store.removeQueued(id, messageID: message.id) }
                            }
                        }
                        if let failure = message.failure { Text(failure).font(ChatAppearance.caption).foregroundStyle(.red) }
                    }.padding(.vertical, 6)
                }
            }.navigationTitle("Pending messages")
                .font(ChatAppearance.body)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { queue = false } } }
        }.frame(minWidth: 320, idealWidth: 520, minHeight: 400)
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}


enum DrawerSwipe {
    static func opens(_ translation: CGSize) -> Bool {
        translation.width > 60 && translation.width > abs(translation.height) * 1.5
    }
    static func closes(_ translation: CGSize) -> Bool {
        translation.width < -60 && -translation.width > abs(translation.height) * 1.5
    }
}
