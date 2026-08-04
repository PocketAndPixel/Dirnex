import Foundation
import Testing

@testable import DirnexCore

@Suite("Sidebar item order")
struct SidebarItemOrderTests {
    /// The Cloud section's shape: a scan hands back rows in its own order, each with a stable
    /// identity, and the order re-arranges them.
    private func apply(_ order: SidebarItemOrder, _ items: [String]) -> [String] {
        order.apply(to: items) { $0 }
    }

    // MARK: - Applying an order

    @Test("an empty order leaves the scan's own order untouched")
    func emptyOrderIsIdentity() {
        let scanned = ["icloud", "mount:Dropbox", "mount:GoogleDrive-a@b.com"]
        #expect(apply(SidebarItemOrder(), scanned) == scanned)
    }

    @Test("known items come back in the stored order, whatever the scan produced")
    func storedOrderWins() {
        let order = SidebarItemOrder(identities: ["mount:Dropbox", "icloud"])
        #expect(apply(order, ["icloud", "mount:Dropbox"]) == ["mount:Dropbox", "icloud"])
    }

    @Test("an item the order has never seen lands at the end")
    func unknownItemsAppend() {
        // A mount that appears after the user arranged the section is new, and new things land at
        // the bottom of a hand-arranged list rather than in an alphabetical slot that would push a
        // hand-placed row aside.
        let order = SidebarItemOrder(identities: ["mount:Dropbox", "icloud"])
        let rows = apply(order, ["icloud", "mount:OneDrive", "mount:Dropbox"])
        #expect(rows == ["mount:Dropbox", "icloud", "mount:OneDrive"])
    }

    @Test("an identity whose item is gone contributes no row")
    func absentIdentitiesDropOut() {
        let order = SidebarItemOrder(identities: ["mount:Dropbox", "icloud", "mount:Box"])
        #expect(apply(order, ["icloud", "mount:Box"]) == ["icloud", "mount:Box"])
    }

    @Test("duplicate identities collapse on the way in")
    func initializerDeduplicates() {
        let order = SidebarItemOrder(identities: ["icloud", "mount:Box", "icloud"])
        #expect(order.identities == ["icloud", "mount:Box"])
    }

    // MARK: - Reordering

    @Test("a drag records the whole displayed order, not just the row that moved")
    func reorderRecordsDisplayedOrder() {
        var order = SidebarItemOrder()
        order.reorder(displayed: ["icloud", "mount:Dropbox", "mount:Box"], from: 2, to: 0)
        #expect(order.identities == ["mount:Box", "icloud", "mount:Dropbox"])
    }

    @Test("destination is an index in the resulting list")
    func destinationIsPostRemoval() {
        // Array semantics, matching `Favorites.move`: the app converts `NSTableView`'s pre-removal
        // drop row before calling, so moving the first row to index 2 lands it third, not fourth.
        var order = SidebarItemOrder()
        order.reorder(displayed: ["a", "b", "c"], from: 0, to: 2)
        #expect(order.identities == ["b", "c", "a"])
    }

    @Test("an out-of-range source is ignored and an out-of-range destination clamps")
    func rangesAreDefended() {
        var ignored = SidebarItemOrder()
        ignored.reorder(displayed: ["a", "b"], from: 7, to: 0)
        #expect(ignored.identities.isEmpty)

        var clamped = SidebarItemOrder()
        clamped.reorder(displayed: ["a", "b", "c"], from: 0, to: 99)
        #expect(clamped.identities == ["b", "c", "a"])
    }

    @Test("an item that is not on screen keeps its slot across a reorder")
    func absentItemsKeepTheirPosition() {
        // Signing out of a Drive account must not cost it its place: reordering the two rows that
        // are left leaves the absent identity between them, so it comes back where the user put it.
        var order = SidebarItemOrder(
            identities: ["icloud", "mount:GoogleDrive-a@b.com", "mount:Box"]
        )
        order.reorder(displayed: ["icloud", "mount:Box"], from: 1, to: 0)
        #expect(order.identities == ["mount:Box", "mount:GoogleDrive-a@b.com", "icloud"])
    }

    @Test("a reorder that brings in an unknown item keeps it")
    func reorderAdoptsUnknownItems() {
        var order = SidebarItemOrder(identities: ["icloud"])
        order.reorder(displayed: ["icloud", "mount:Box"], from: 1, to: 0)
        #expect(order.identities == ["mount:Box", "icloud"])
    }

    // MARK: - Codable

    @Test("encodes as a bare array of identities")
    func encodesAsArray() throws {
        let order = SidebarItemOrder(identities: ["mount:Box", "icloud"])
        let json = try #require(String(bytes: try JSONEncoder().encode(order), encoding: .utf8))
        #expect(json == #"["mount:Box","icloud"]"#)
    }

    @Test("round-trips, sanitizing a hand-edited store")
    func decodeDeduplicates() throws {
        let data = Data(#"["icloud","mount:Box","icloud"]"#.utf8)
        let order = try JSONDecoder().decode(SidebarItemOrder.self, from: data)
        #expect(order.identities == ["icloud", "mount:Box"])
    }
}
