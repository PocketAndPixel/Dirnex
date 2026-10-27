import Foundation
import Testing

@testable import DirnexCore

/// Where the pane was left in each folder of the trail, so ⌘[ and ⌘] come back to the row the cursor
/// was on and the tree folders that were open. What is asserted is that a spot stays with its own
/// entry through everything that reshapes the trail — a branch, a gone folder, the capacity, a write
/// and a read — since a spot one place off puts the cursor on a row of the wrong folder.
@Suite("NavigationHistory spots")
struct NavigationHistorySpotTests {
    private typealias Spot = NavigationSpot

    private func path(_ raw: String) -> VFSPath { .local(raw) }

    private func spot(_ cursor: String, expanded: [String] = []) -> NavigationSpot {
        Spot(cursor: cursor, expanded: expanded)
    }

    /// A trail through `names`, each one left at a spot on its cursor named after it, and on the
    /// newest, which has not been left.
    private func trail(_ names: [String], capacity: Int = NavigationHistory.defaultCapacity) -> NavigationHistory {
        var history = NavigationHistory(initialPath: path(names[0]), capacity: capacity)
        for (left, next) in zip(names, names.dropFirst()) {
            history.remember(spot(left), leaving: path(left))
            history.visit(path(next))
        }
        return history
    }

    // MARK: - Walking

    @Test("⌘[ lands on the spot the folder was left at, and ⌘] on the one it was walked back from")
    func walksComeBackToTheirSpots() {
        var history = trail(["/a", "/b"])
        let tree = Spot(cursor: "sub/file", expanded: ["sub"])
        history.remember(tree, leaving: path("/b"))

        #expect(history.back() == path("/a"))
        #expect(history.spot(landingOn: path("/a")) == spot("/a"))
        history.land(on: path("/a"))

        history.remember(spot("x"), leaving: path("/a"))
        _ = history.forward()
        #expect(history.spot(landingOn: path("/b")) == tree)
        history.land(on: path("/b"))
        #expect(history.spots == [spot("x"), tree])
    }

    @Test("a listing that is not the walk's own gets no spot")
    func onlyTheWalksOwnListingGetsTheSpot() {
        var history = trail(["/a", "/b"])
        #expect(history.spot(landingOn: path("/a")) == nil) // no walk in flight
        _ = history.back()
        #expect(history.spot(landingOn: path("/elsewhere")) == nil) // overtaken
        #expect(history.spot(landingOn: path("/a")) == spot("/a"))
    }

    @Test("a folder the pane has not left yet has no spot")
    func unleftFolderHasNoSpot() {
        var history = NavigationHistory(initialPath: path("/a"))
        history.visit(path("/b"))
        _ = history.back()
        #expect(history.spot(landingOn: path("/a")) == nil)
    }

    @Test("a place outside the trail is not remembered on the entry on screen")
    func placeOutsideTheTrailIsNotRemembered() {
        var history = trail(["/a", "/b"])
        history.remember(spot("hit"), leaving: VFSPath(backend: .search, path: "/jmeter"))
        #expect(history.spots == [spot("/a"), nil])
    }

    // MARK: - Reshaping the trail

    @Test("branching off drops the forward entries' spots with them")
    func branchDropsForwardSpots() {
        var history = trail(["/a", "/b", "/c"])
        history.remember(spot("/c"), leaving: path("/c"))
        _ = history.back()
        history.land(on: path("/b"))
        history.remember(spot("b again"), leaving: path("/b"))
        history.visit(path("/d"))
        #expect(history.entries == [path("/a"), path("/b"), path("/d")])
        #expect(history.spots == [spot("/a"), spot("b again"), nil])
    }

    @Test("two visits that meet once a gone folder between them is dropped keep the later spot")
    func foldKeepsTheLaterSpot() {
        var history = NavigationHistory(initialPath: path("/a"))
        history.remember(spot("earlier"), leaving: path("/a"))
        history.visit(path("/b"))
        history.remember(spot("in b"), leaving: path("/b"))
        history.visit(path("/a"))
        history.remember(spot("later"), leaving: path("/a"))
        history.visit(path("/c"))

        _ = history.jump(to: 1)
        #expect(history.dropUnreachableTarget() == nil)

        #expect(history.entries == [path("/a"), path("/c")])
        #expect(history.spots == [spot("later"), nil])
    }

    @Test("trimming to capacity drops the oldest spots with their entries")
    func trimKeepsSpotsInStep() {
        let history = trail(["/a", "/b", "/c", "/d"], capacity: 2)
        #expect(history.entries == [path("/c"), path("/d")])
        #expect(history.spots == [spot("/c"), nil])
    }

    // MARK: - Writing and reading

    private func roundTrip(_ stored: StoredNavigationHistory?) throws -> StoredNavigationHistory {
        let data = try JSONEncoder().encode(try #require(stored))
        return try JSONDecoder().decode(StoredNavigationHistory.self, from: data)
    }

    @Test("a written trail comes back with each entry's spot")
    func spotsSurviveARelaunch() throws {
        var history = trail(["/a", "/b", "/c"])
        history.remember(Spot(cursor: "sub/file", expanded: ["sub"]), leaving: path("/c"))
        _ = history.back()
        history.land(on: path("/b"))
        let stored = history.stored(
            at: path("/b"),
            endpoint: { _ in nil },
            isExcluded: { _ in false }
        )

        var restored = try NavigationHistory(restoring: roundTrip(stored), at: path("/b"))

        #expect(
            restored.spots == [spot("/a"), spot("/b"), Spot(cursor: "sub/file", expanded: ["sub"])]
        )
        _ = restored.forward()
        #expect(restored.spot(landingOn: path("/c"))?.expanded == ["sub"])
    }

    @Test("an excluded folder's neighbours fold on the way out and keep the later spot")
    func writeFoldKeepsTheLaterSpot() {
        let vault = path("/Volumes/Vault/taxes")
        var history = NavigationHistory(initialPath: path("/a"))
        history.remember(spot("earlier"), leaving: path("/a"))
        history.visit(vault)
        history.remember(spot("secret"), leaving: vault)
        history.visit(path("/a"))
        history.remember(spot("later"), leaving: path("/a"))
        history.visit(path("/b"))

        let stored = history.stored(
            at: path("/b"),
            endpoint: { _ in nil },
            isExcluded: { $0 == vault }
        )

        #expect(stored?.entries == [path("/a"), path("/b")])
        #expect(stored?.entrySpots == [spot("later"), nil])
    }

    @Test("a restored trail cut to capacity keeps each spot on its own entry")
    func restoreTrimKeepsSpotsInStep() {
        let entries = (0..<6).map { path("/p\($0)") }
        let stored = StoredNavigationHistory(
            entries: entries,
            currentIndex: 4,
            spots: (0..<6).map { spot("p\($0)") }
        )
        let restored = NavigationHistory(restoring: stored, at: path("/p4"), capacity: 3)
        #expect(restored.entries == (3..<6).map { path("/p\($0)") })
        #expect(restored.spots == (3..<6).map { spot("p\($0)") })
    }

    @Test("spots that do not pair up with the entries are dropped, and the trail kept")
    func mismatchedSpotsAreDropped() throws {
        let stored = try roundTrip(StoredNavigationHistory(
            entries: [path("/a"), path("/b")],
            currentIndex: 1,
            spots: [spot("x")]
        ))
        #expect(stored.spots == [spot("x")])
        #expect(stored.entrySpots.isEmpty)
        let restored = NavigationHistory(restoring: stored, at: path("/b"))
        #expect(restored.entries == [path("/a"), path("/b")])
        #expect(restored.spots == [nil, nil])
    }

    @Test("a trail left nowhere writes no spots key, and a flat-list spot only its cursor")
    func spotsStayOutOfTheJSONUntilNeeded() throws {
        let bare = StoredNavigationHistory(entries: [path("/a"), path("/b")], currentIndex: 1)
        let bareJSON = try #require(String(bytes: JSONEncoder().encode(bare), encoding: .utf8))
        #expect(!bareJSON.contains("spots"))

        let flat = try #require(
            String(bytes: JSONEncoder().encode(spot("notes.md")), encoding: .utf8)
        )
        #expect(flat == #"{"cursor":"notes.md"}"#)
    }

    @Test("an unreadable spot reads as no place in its folder rather than failing the trail")
    func unreadableSpotDegrades() throws {
        let json = #"[{"cursor": 7, "cursorOnParent": "yes", "expanded": "sub"}, null, {"cursorOnParent": true}]"#
        let spots = try JSONDecoder().decode([NavigationSpot?].self, from: Data(json.utf8))
        #expect(spots == [Spot(cursor: nil), nil, Spot(cursor: nil, cursorOnParent: true)])
    }
}
