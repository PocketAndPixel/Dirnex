import Foundation
import Testing

@testable import DirnexCore

/// A tab's trail written down with the tab and read back at launch. What is asserted is mostly
/// what is *left out* on each side — every entry that comes back is a place ⌘[ will try to open —
/// and that a trail which cannot be read costs only itself, never the tab it is stored in.
@Suite("NavigationHistory storage")
struct NavigationHistoryStorageTests {
    private static let sftpLocation = SFTPLocation(host: "example.com", username: "oleg")
    private static let sftpEndpoint = ServerEndpoint.sftp(
        location: sftpLocation,
        authentication: .key(identityFile: "/Users/oleg/.ssh/id_ed25519")
    )
    private static let server = VFSBackendID.sftp(sftpLocation)

    private func path(_ raw: String) -> VFSPath { .local(raw) }
    private func remote(_ raw: String) -> VFSPath { VFSPath(backend: Self.server, path: raw) }

    private func trail(_ entries: [VFSPath]) -> NavigationHistory {
        var history = NavigationHistory(initialPath: entries[0])
        for entry in entries.dropFirst() {
            history.visit(entry)
        }
        return history
    }

    private func storing(
        _ history: NavigationHistory,
        at path: VFSPath,
        endpoint: ServerEndpoint? = nil,
        excluding excluded: Set<VFSPath> = []
    ) -> StoredNavigationHistory? {
        history.stored(
            at: path,
            endpoint: { $0 == endpoint?.backendID ? endpoint : nil },
            isExcluded: { excluded.contains($0) }
        )
    }

    // MARK: - Writing

    @Test("a trail of one place is not written, since a fresh restore is the same thing")
    func singleEntryIsNotWritten() {
        let history = NavigationHistory(initialPath: path("/a"))
        #expect(storing(history, at: path("/a")) == nil)
    }

    @Test("the trail is written with the tab's place as its position, forward entries included")
    func writesTheWholeTrail() {
        var history = trail([path("/a"), path("/b"), path("/c")])
        _ = history.back()
        history.land(on: path("/b"))
        let stored = storing(history, at: path("/b"))
        #expect(stored?.entries == [path("/a"), path("/b"), path("/c")])
        #expect(stored?.currentIndex == 1)
        #expect(stored?.endpoints == nil)
    }

    @Test("a walk still in flight at quit is written from the place on screen")
    func walkInFlightIsWrittenFromTheScreen() {
        var history = trail([path("/a"), path("/b"), path("/c")])
        _ = history.back()
        #expect(storing(history, at: path("/c"))?.currentIndex == 2)
    }

    @Test("a trail that does not end at the tab's place is not written")
    func mismatchIsNotWritten() {
        let history = trail([path("/a"), path("/b")])
        let results = VFSPath(backend: .search, path: "/jmeter")
        #expect(storing(history, at: results) == nil)
    }

    @Test("an excluded folder is left out and the neighbours that meet fold into one")
    func excludedFoldersAreLeftOut() {
        let vault = path("/Volumes/Vault/taxes")
        let history = trail([path("/a"), vault, path("/a"), path("/b")])
        let stored = storing(history, at: path("/b"), excluding: [vault])
        #expect(stored?.entries == [path("/a"), path("/b")])
        #expect(stored?.currentIndex == 1)
    }

    @Test("a trail whose own place is excluded is not written at all")
    func excludedPlaceIsNotWritten() {
        let vault = path("/Volumes/Vault")
        let history = trail([path("/a"), vault])
        #expect(storing(history, at: vault, excluding: [vault]) == nil)
    }

    @Test("listings that cannot be restored are left out of the trail")
    func unrestorableListingsAreLeftOut() {
        let trash = VFSPath(backend: .trash, path: "/")
        let history = trail([path("/a"), trash, path("/b")])
        #expect(storing(history, at: path("/b"))?.entries == [path("/a"), path("/b")])
    }

    @Test("a server entry is kept with its endpoint, written once for every entry on it")
    func serverEntriesCarryOneEndpoint() {
        let history = trail([remote("/var"), remote("/var/log"), path("/a")])
        let stored = storing(history, at: path("/a"), endpoint: Self.sftpEndpoint)
        #expect(stored?.entries == [remote("/var"), remote("/var/log"), path("/a")])
        #expect(stored?.serverEndpoints == [Self.sftpEndpoint])
    }

    @Test("a server entry with no way to reconnect is left out")
    func serverWithoutEndpointIsLeftOut() {
        let history = trail([remote("/var"), path("/a")])
        let stored = storing(history, at: path("/a"))
        #expect(stored == nil) // only `/a` is left, which is not worth writing
    }

    @Test("a server whose every entry is excluded leaves no endpoint behind")
    func excludedServerLeavesNoEndpoint() {
        let history = trail([path("/a"), remote("/var"), path("/b")])
        let stored = storing(
            history,
            at: path("/b"),
            endpoint: Self.sftpEndpoint,
            excluding: [remote("/var")]
        )
        #expect(stored?.entries == [path("/a"), path("/b")])
        #expect(stored?.endpoints == nil)
    }

    // MARK: - JSON

    @Test("a written trail reads back the same")
    func roundTrips() throws {
        let stored = StoredNavigationHistory(
            entries: [remote("/var"), path("/a")],
            currentIndex: 1,
            endpoints: [Self.sftpEndpoint]
        )
        let data = try JSONEncoder().encode(stored)
        #expect(try JSONDecoder().decode(StoredNavigationHistory.self, from: data) == stored)
    }

    @Test("a trail that never left the Mac writes no endpoints key")
    func localTrailOmitsEndpoints() throws {
        let stored = StoredNavigationHistory(entries: [path("/a"), path("/b")], currentIndex: 1)
        let json = try #require(String(bytes: JSONEncoder().encode(stored), encoding: .utf8))
        #expect(!json.contains("endpoints"))
    }

    /// The reason the decoder never throws: the trail is one field of a tab, and the tabs of a pane
    /// are one array, so a throw here would empty the pane on the way in.
    @Test("an unreadable trail costs only itself, never the tab it is stored in")
    func unreadableTrailKeepsTheTab() throws {
        struct Tab: Decodable {
            let path: String
            let history: StoredNavigationHistory?
        }
        let json = #"[{"path": "/a", "history": "garbage"},"#
            + #" {"path": "/b", "history": {"entries": [{"nope": 1}], "currentIndex": 0}}]"#
        let tabs = try JSONDecoder().decode([Tab].self, from: Data(json.utf8))
        #expect(tabs.map(\.path) == ["/a", "/b"])
        #expect(tabs.allSatisfy { $0.history?.entries == [] })
        let restored = NavigationHistory(restoring: tabs[1].history, at: path("/b"))
        #expect(restored.entries == [path("/b")])
    }

    // MARK: - Reading

    @Test("no stored trail restores a fresh one at the tab's place")
    func nothingStoredIsFresh() {
        let restored = NavigationHistory(restoring: nil, at: path("/a"))
        #expect(restored.entries == [path("/a")])
        #expect(restored.capacity == 80)
    }

    @Test("a stored trail comes back with its forward entries and settled")
    func restoresTheTrail() {
        let stored = StoredNavigationHistory(
            entries: [path("/a"), path("/b"), path("/c")],
            currentIndex: 1
        )
        var restored = NavigationHistory(restoring: stored, at: path("/b"))
        #expect(restored.entries == [path("/a"), path("/b"), path("/c")])
        #expect(restored.currentIndex == 1)
        #expect(restored.landedIndex == 1)
        #expect(restored.walk == nil)
        #expect(restored.forward() == path("/c"))
    }

    @Test("a trail that does not end at the tab's restored place is not used")
    func mismatchRestoresFresh() {
        let stored = StoredNavigationHistory(entries: [path("/a"), path("/b")], currentIndex: 1)
        #expect(NavigationHistory(restoring: stored, at: path("/z")).entries == [path("/z")])
    }

    @Test("a position outside the trail is not used")
    func outOfRangeRestoresFresh() {
        let stored = StoredNavigationHistory(entries: [path("/a"), path("/b")], currentIndex: 7)
        #expect(NavigationHistory(restoring: stored, at: path("/b")).entries == [path("/b")])
    }

    @Test("server entries come back only with a readable endpoint for that server")
    func serverEntriesNeedTheirEndpoint() {
        let entries = [remote("/var"), path("/a"), path("/b")]
        let withEndpoint = StoredNavigationHistory(
            entries: entries,
            currentIndex: 2,
            endpoints: [Self.sftpEndpoint]
        )
        #expect(NavigationHistory(restoring: withEndpoint, at: path("/b")).entries == entries)

        let without = StoredNavigationHistory(entries: entries, currentIndex: 2)
        #expect(
            NavigationHistory(restoring: without, at: path("/b")).entries == [path("/a"), path("/b")]
        )
    }

    @Test(
        "a trail longer than the capacity loses its oldest first, then its newest, never its place"
    )
    func capacityKeepsThePlace() {
        let entries = (0..<10).map { path("/p\($0)") }
        let nearEnd = StoredNavigationHistory(entries: entries, currentIndex: 8)
        let restored = NavigationHistory(restoring: nearEnd, at: path("/p8"), capacity: 4)
        #expect(restored.entries == (6..<10).map { path("/p\($0)") })
        #expect(restored.currentPath == path("/p8"))

        let atStart = StoredNavigationHistory(entries: entries, currentIndex: 1)
        let early = NavigationHistory(restoring: atStart, at: path("/p1"), capacity: 4)
        // Older entries go first, as they do in a session, so `/p0` goes before any newer one.
        #expect(early.entries == (1..<5).map { path("/p\($0)") })
        #expect(early.currentPath == path("/p1"))
        #expect(!early.canGoBack)
    }
}
