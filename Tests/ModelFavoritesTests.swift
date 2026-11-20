import XCTest
@testable import OpenChat

final class ModelFavoritesTests: XCTestCase {
    func testFavoriteOrderPersistsAfterMovingByIdentity() {
        var favorites = ModelFavorites(encoded: "[\"google/gemini\",\"anthropic/claude\",\"openrouter/auto\"]")
        favorites.move("openrouter/auto", by: -1)
        favorites.move("openrouter/auto", by: -1)
        let restored = ModelFavorites(encoded: favorites.encoded)
        XCTAssertEqual(restored.ids, ["openrouter/auto", "google/gemini", "anthropic/claude"])
        XCTAssertEqual(restored.models(in: [], search: "").map(\.id), restored.ids)
    }

    func testFavoriteReorderBoundariesKeepAllModels() {
        var favorites = ModelFavorites(encoded: "[\"vendor/one\",\"vendor/two\"]")
        favorites.move("vendor/one", by: -1)
        favorites.move("vendor/two", by: 1)
        favorites.move("missing/model", by: -1)
        XCTAssertEqual(favorites.ids, ["vendor/one", "vendor/two"])
        favorites.move("vendor/one", by: 1)
        XCTAssertEqual(favorites.ids, ["vendor/two", "vendor/one"])
    }

    func testConciseModelNamesPreserveIDsAndSearchTerms() {
        let model = RouterModel(id: "google/gemini-4-carbon", name: "Google: Gemini 4 Carbon")
        var favorites = ModelFavorites(encoded: "[]")
        favorites.toggle(model.id)
        let result = favorites.models(in: [model], search: "google")
        XCTAssertEqual(result.first?.name, "Gemini 4 Carbon")
        XCTAssertEqual(result.first?.id, model.id)
        XCTAssertEqual(ChatAppearance.modelName("anthropic/claude-opus-5.5", catalogName: "Anthropic: Claude Opus 5.5"), "Claude Opus 5.5")
        XCTAssertEqual(ChatAppearance.modelName("google/gemini-4-hydrogen"), "Gemini 4 Hydrogen")
        XCTAssertEqual(ChatAppearance.modelName("openrouter/auto", catalogName: "Auto · let OpenRouter choose"), "Auto")
    }

    func testFavoritesSurvivePreferenceReloadWithoutCatalog() throws {
        let suite = "OpenChat.ModelFavoritesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var favorites = ModelFavorites(encoded: "[]")
        favorites.toggle("openrouter/auto")
        favorites.toggle("private/custom-model")
        defaults.set(favorites.encoded, forKey: "favorite-model-ids")

        let reloadedDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let reloaded = ModelFavorites(encoded: try XCTUnwrap(reloadedDefaults.string(forKey: "favorite-model-ids")))
        XCTAssertEqual(reloaded.ids, ["openrouter/auto", "private/custom-model"])
        XCTAssertEqual(reloaded.models(in: [], search: "").map(\.id), reloaded.ids)
        XCTAssertEqual(reloaded.models(in: [], search: "").first?.name, ModelFavorites.auto.name)
    }

    func testRemoveFavoritePreservesOtherIDsAndOrder() {
        var favorites = ModelFavorites(encoded: "[]")
        favorites.toggle("vendor/one")
        favorites.toggle("vendor/two")
        favorites.toggle("vendor/three")
        favorites.toggle("vendor/two")
        XCTAssertEqual(ModelFavorites(encoded: favorites.encoded).ids, ["vendor/one", "vendor/three"])
    }

    func testSearchUsesCatalogNameOrIDAndKeepsMissingModels() {
        var favorites = ModelFavorites(encoded: "[]")
        favorites.toggle("vendor/one")
        favorites.toggle("private/offline-model")
        let catalog = [RouterModel(id: "vendor/one", name: "Friendly Model")]
        XCTAssertEqual(favorites.models(in: catalog, search: "FRIENDLY").map(\.id), ["vendor/one"])
        XCTAssertEqual(favorites.models(in: catalog, search: "OFFLINE").map(\.id), ["private/offline-model"])
        XCTAssertEqual(favorites.models(in: [], search: "vendor").map(\.id), ["vendor/one"])
        XCTAssertTrue(favorites.models(in: catalog, search: "unmatched").isEmpty)
    }

    func testManualIDsTrimWhitespaceAndEmptyInputDoesNotAddFavorite() {
        var favorites = ModelFavorites(encoded: "[]")
        favorites.toggle(" \n ")
        XCTAssertTrue(favorites.ids.isEmpty)
        favorites.toggle("  custom/model\n")
        XCTAssertEqual(favorites.ids, ["custom/model"])
        favorites.toggle("custom/model")
        XCTAssertTrue(favorites.ids.isEmpty)
    }
}
