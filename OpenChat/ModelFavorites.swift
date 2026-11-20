import Foundation

struct ModelFavorites {
    private(set) var ids: [String]

    static let auto = RouterModel(id: "openrouter/auto", name: "Auto")

    init(ids: [String]) { self.ids = ids }

    init(encoded: String) {
        ids = (try? JSONDecoder().decode([String].self, from: Data(encoded.utf8))) ?? []
    }

    var encoded: String {
        String(decoding: (try? JSONEncoder().encode(ids)) ?? Data("[]".utf8), as: UTF8.self)
    }

    mutating func toggle(_ model: String) {
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        if ids.contains(id) { ids.removeAll { $0 == id } }
        else { ids.append(id) }
    }

    mutating func move(_ id: String, by offset: Int) {
        guard let index = ids.firstIndex(of: id) else { return }
        let destination = index + offset
        guard ids.indices.contains(destination) else { return }
        ids.swapAt(index, destination)
    }

    func models(in catalog: [RouterModel], search: String) -> [RouterModel] {
        ids.map { id in
            if id == Self.auto.id { return Self.auto }
            let name = catalog.first { $0.id == id }?.name
            return RouterModel(id: id, name: ChatAppearance.modelName(id, catalogName: name))
        }.filter { Self.matches($0, search: search) }
    }

    static func matches(_ model: RouterModel, search: String) -> Bool {
        search.isEmpty || model.name.localizedCaseInsensitiveContains(search) || model.id.localizedCaseInsensitiveContains(search)
    }
}
