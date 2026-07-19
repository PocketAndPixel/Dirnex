import Foundation
import Testing

@testable import DirnexCore

@Suite("SavedSearch")
struct SavedSearchTests {
    private func search(_ name: String, nameContains: String = "term") -> SavedSearch {
        SavedSearch(name: name, query: SpotlightQuery(nameContains: nameContains))
    }

    // MARK: - SavedSearch value

    @Test("identity is the name")
    func identityIsName() {
        #expect(search("Big Videos").id == "Big Videos")
    }

    @Test("a scoped search round-trips through Codable with its query and scope")
    func codableRoundTrip() throws {
        let original = SavedSearch(
            name: "Recent Images",
            query: SpotlightQuery(
                nameContains: "photo",
                kinds: [.image],
                minSizeBytes: 1_048_576,
                modifiedWithin: .week
            ),
            scope: .local("/Users/me/Pictures")
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SavedSearch.self, from: data)
        #expect(decoded == original)
        #expect(decoded.scope == .local("/Users/me/Pictures"))
        #expect(decoded.query.kinds == [.image])
    }

    @Test("an everywhere search encodes a nil scope")
    func everywhereScopeIsNil() throws {
        let original = SavedSearch(name: "All PDFs", query: SpotlightQuery(nameContains: "pdf"))
        let decoded = try JSONDecoder().decode(
            SavedSearch.self,
            from: try JSONEncoder().encode(original)
        )
        #expect(decoded.scope == nil)
    }

    // MARK: - Collection

    @Test("a fresh collection is empty")
    func startsEmpty() {
        #expect(SavedSearches().searches.isEmpty)
    }

    @Test("save appends a new name and reports it did not replace")
    func saveAppends() {
        var list = SavedSearches()
        let replacedA = list.save(search("A"))
        #expect(replacedA == false)
        let replacedB = list.save(search("B"))
        #expect(replacedB == false)
        #expect(list.searches.map(\.name) == ["A", "B"])
    }

    @Test("save overwrites an existing name in place, keeping its position")
    func saveReplacesInPlace() {
        var list = SavedSearches(searches: [search("A"), search("B"), search("C")])
        let replaced = list.save(search("B", nameContains: "updated"))
        #expect(replaced)
        #expect(list.searches.map(\.name) == ["A", "B", "C"])
        #expect(list.search(named: "B")?.query.nameContains == "updated")
    }

    @Test("the initializer collapses duplicate names, keeping the first")
    func dedupOnInit() {
        let list = SavedSearches(searches: [
            search("Dup", nameContains: "first"),
            search("Dup", nameContains: "second"),
            search("Other")
        ])
        #expect(list.searches.map(\.name) == ["Dup", "Other"])
        #expect(list.search(named: "Dup")?.query.nameContains == "first")
    }

    @Test("contains and lookup by name")
    func containsAndLookup() {
        let list = SavedSearches(searches: [search("A")])
        #expect(list.contains(name: "A"))
        #expect(!list.contains(name: "B"))
        #expect(list.search(named: "A")?.name == "A")
        #expect(list.search(named: "B") == nil)
    }

    @Test("remove by name reports whether one was removed")
    func removeByName() {
        var list = SavedSearches(searches: [search("A"), search("B")])
        let removed = list.remove(name: "A")
        #expect(removed)
        let removedAgain = list.remove(name: "A")
        #expect(!removedAgain)
        #expect(list.searches.map(\.name) == ["B"])
    }

    @Test("remove at index ignores out-of-range")
    func removeAtIndex() {
        var list = SavedSearches(searches: [search("A"), search("B")])
        list.remove(at: 5)
        #expect(list.searches.count == 2)
        list.remove(at: 0)
        #expect(list.searches.map(\.name) == ["B"])
    }

    @Test("rename rejects an empty name and a collision with a different entry")
    func renameRules() {
        var list = SavedSearches(searches: [search("A"), search("B")])
        // Hoist each mutating call into a `let` — the Testing `#expect` macro captures its
        // argument immutably, so calling a `mutating` method inline fails to compile.
        let emptyRejected = list.rename(name: "A", to: "")
        #expect(!emptyRejected)
        let collisionRejected = list.rename(name: "A", to: "B")
        #expect(!collisionRejected)
        #expect(list.searches.map(\.name) == ["A", "B"])
        let sameName = list.rename(name: "A", to: "A") // same-name is a no-op success
        #expect(sameName)
        let renamed = list.rename(name: "A", to: "A2")
        #expect(renamed)
        #expect(list.searches.map(\.name) == ["A2", "B"])
    }

    @Test("move reorders with array semantics")
    func moveReorders() {
        var list = SavedSearches(searches: [search("A"), search("B"), search("C")])
        list.move(from: 0, to: 2)
        #expect(list.searches.map(\.name) == ["B", "C", "A"])
    }

    @Test("the whole collection round-trips through Codable, sanitizing on decode")
    func collectionCodableRoundTrip() throws {
        let list = SavedSearches(searches: [search("A"), search("B")])
        let decoded = try JSONDecoder().decode(
            SavedSearches.self,
            from: try JSONEncoder().encode(list)
        )
        #expect(decoded == list)
    }
}
