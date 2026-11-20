import SwiftUI

struct ModelPicker: View {
    @Bindable var store: ChatStore
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var search = ""
    @State private var custom = ""
    @State private var showCustom = false
    @State private var reordering = false
    @AppStorage("favorite-model-ids") private var savedFavorites = "[]"
    @AppStorage("ollama-favorite-model-ids") private var savedLocalFavorites = "[]"

    private var favorites: ModelFavorites { ModelFavorites(ids: ModelFavorites(encoded: savedFavorites).ids + ModelFavorites(encoded: savedLocalFavorites).ids) }
    private var customID: String { custom.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var favoriteModels: [RouterModel] { favorites.models(in: store.models, search: search) }
    private var catalogModels: [RouterModel] {
        let favoriteIDs = Set(favorites.ids)
        let catalog = [ModelFavorites.auto] + store.models.filter { $0.id != ModelFavorites.auto.id }
        return catalog.filter { !favoriteIDs.contains($0.id) && ModelFavorites.matches($0, search: search) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Models").font(.title2.weight(.semibold))
                Spacer()
                Button { Task { await store.loadModels() } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 44, height: 44).contentShape(.rect)
                }.buttonStyle(.plain).accessibilityLabel("Refresh models").help("Refresh models")
                Button { dismiss() } label: {
                    Text("Done").frame(minWidth: 44, minHeight: 44).contentShape(.rect)
                }
                    .buttonStyle(.plain).font(ChatAppearance.headline)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search models", text: $search)
                    .textFieldStyle(.plain).autocorrectionDisabled()
                    .frame(minHeight: 44)
                    .accessibilityLabel("Search models")
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }.buttonStyle(.plain).accessibilityLabel("Clear model search")
                }
            }
            .padding(.leading, 14).padding(.trailing, search.isEmpty ? 14 : 0)
            .frame(minHeight: 44)
            .background(ChatAppearance.surface, in: .rect(cornerRadius: 12))
            .padding(.horizontal, 20).padding(.bottom, 12)
            List {
                if !favoriteModels.isEmpty {
                    Section {
                        ForEach(favoriteModels) { model in modelRow(model, favorite: true) }
                    } header: {
                        HStack {
                            sectionHeading("Favorites")
                            Spacer()
                            if favorites.ids.count > 1 && search.isEmpty {
                                Button(reordering ? "Done" : "Reorder") { reordering.toggle() }
                                    .font(ChatAppearance.caption).textCase(nil)
                                    .frame(minHeight: 44)
                                    .accessibilityLabel(reordering ? "Finish reordering favorites" : "Reorder favorite models")
                            }
                        }
                    }
                }
                Section {
                    ForEach(catalogModels.filter { !Ollama.isModel($0.id) }) { model in modelRow(model) }
                    if let error = store.openRouterCatalogError { Text(error).font(ChatAppearance.caption).foregroundStyle(.secondary) }
                } header: {
                    sectionHeading("OpenRouter")
                }
                if store.ollamaAvailable {
                    Section {
                        ForEach(catalogModels.filter { Ollama.isModel($0.id) }) { model in modelRow(model) }
                        if store.models.filter({ Ollama.isModel($0.id) }).isEmpty && search.isEmpty {
                            Text(store.ollamaCatalogError ?? "No installed models found. Install a model in Ollama, then refresh.")
                                .font(ChatAppearance.caption).foregroundStyle(.secondary)
                        }
                    } header: { sectionHeading("Ollama · On this Mac") }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .overlay {
                if favoriteModels.isEmpty && catalogModels.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            if store.ollamaAvailable {
                Text("OpenRouter and Ollama keep separate conversations. Choosing the other provider starts a new chat and carries an unsent draft from an empty chat.")
                    .font(ChatAppearance.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 8)
            }
            Divider().overlay(.white.opacity(0.06))
            DisclosureGroup(isExpanded: $showCustom) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("provider/model-name", text: $custom)
                            .textFieldStyle(.plain).autocorrectionDisabled()
                            .padding(.horizontal, 12).frame(minHeight: 44)
                            .background(ChatAppearance.surface, in: .rect(cornerRadius: 10))
                        ModelFavoriteButton(name: customID.isEmpty ? "custom model" : customID,
                                            isFavorite: favorites.ids.contains(customID)) {
                            toggleFavorite(customID)
                        }.disabled(customID.isEmpty)
                    }
                    Button("Use model ID") { choose(customID) }
                        .buttonStyle(.bordered).frame(minHeight: 44).disabled(customID.isEmpty)
                }.padding(.bottom, 12)
            } label: {
                Text("Use an OpenRouter model ID").font(ChatAppearance.subheadline)
                    .foregroundStyle(.secondary).frame(minHeight: 44)
            }
            .padding(.horizontal, 20).padding(.bottom, 8)
        }
        .font(ChatAppearance.body)
        .background(ChatAppearance.canvas)
        .alert("Neon", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .task { if store.models.isEmpty { await store.loadModels() } }
        .frame(minWidth: 320, idealWidth: 560, minHeight: 500)
    }
    private func sectionHeading(_ title: String) -> some View {
        Text(title).font(ChatAppearance.caption.weight(.semibold))
            .foregroundStyle(ChatAppearance.muted).textCase(nil)
    }
    private func modelRow(_ model: RouterModel, favorite: Bool = false) -> some View {
        let selected = model.id == store.chat(id)?.model
        let name = ChatAppearance.modelName(model.id, catalogName: model.name)
        let arranging = favorite && reordering && search.isEmpty
        return HStack(spacing: 8) {
            Button { choose(model.id) } label: {
                HStack(spacing: 10) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? ChatAppearance.accent : ChatAppearance.muted.opacity(0.4))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name).foregroundStyle(.primary).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            .fixedSize(horizontal: false, vertical: true)
                            .fontWeight(selected ? .semibold : .regular)
                        Text(Ollama.isModel(model.id) ? "Ollama · " + String(model.id.dropFirst(Ollama.modelPrefix.count)) : "OpenRouter · " + model.id).font(ChatAppearance.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            if arranging {
                Button { moveFavorite(model.id, by: -1) } label: {
                    Image(systemName: "arrow.up").frame(width: 44, height: 44)
                }
                .disabled(providerFavorites(model.id).first == model.id)
                .accessibilityLabel("Move \(name) up")
                Button { moveFavorite(model.id, by: 1) } label: {
                    Image(systemName: "arrow.down").frame(width: 44, height: 44)
                }
                .disabled(providerFavorites(model.id).last == model.id)
                .accessibilityLabel("Move \(name) down")
            } else {
                ModelFavoriteButton(name: name, isFavorite: favorites.ids.contains(model.id)) {
                    toggleFavorite(model.id)
                }
            }
        }
        .buttonStyle(.borderless)
        .listRowBackground(selected ? ChatAppearance.accent.opacity(0.07) : Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 3, leading: 20, bottom: 3, trailing: 12))
    }
    private func providerFavorites(_ id: String) -> [String] { ModelFavorites(encoded: Ollama.isModel(id) ? savedLocalFavorites : savedFavorites).ids }
    private func moveFavorite(_ id: String, by offset: Int) {
        var updated = ModelFavorites(encoded: Ollama.isModel(id) ? savedLocalFavorites : savedFavorites)
        updated.move(id, by: offset)
        if Ollama.isModel(id) { savedLocalFavorites = updated.encoded } else { savedFavorites = updated.encoded }
    }
    private func toggleFavorite(_ model: String) {
        var updated = ModelFavorites(encoded: Ollama.isModel(model) ? savedLocalFavorites : savedFavorites)
        updated.toggle(model)
        if Ollama.isModel(model) { savedLocalFavorites = updated.encoded } else { savedFavorites = updated.encoded }
    }
    private func choose(_ model: String) {
        store.chooseModel(model, for: id)
        dismiss()
    }
}

private struct ModelFavoriteButton: View {
    let name: String
    let isFavorite: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundStyle(isFavorite ? ChatAppearance.accent : ChatAppearance.muted)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isFavorite ? "Remove \(name) from favorites" : "Add \(name) to favorites")
        .help(isFavorite ? "Remove from favorites" : "Add to favorites")
    }
}
