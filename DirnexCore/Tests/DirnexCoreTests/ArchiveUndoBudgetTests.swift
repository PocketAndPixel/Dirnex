import Foundation
import Testing

@testable import DirnexCore

/// What an undoable archive rewrite is allowed to keep (HISTORY.md ▸ After M19, 2026-09-01). Pure
/// arithmetic over a store's contents — the bytes are `ArchiveUndoStoreTests`' subject.
@Suite("ArchiveUndoBudget")
struct ArchiveUndoBudgetTests {
    private func held(_ path: String, _ bytes: Int64) -> ArchiveUndoBudget.Held {
        .init(path: path, byteSize: bytes)
    }

    @Test("a snapshot no record points at is evicted whatever the arithmetic")
    func deadSnapshotsGoFirst() {
        let budget = ArchiveUndoBudget(bytes: 1000)
        let plan = budget.plan(
            adding: 10,
            held: [held("/a", 100), held("/b", 100)],
            live: ["/b"]
        )
        #expect(plan.evict == ["/a"])
        #expect(plan.admits)
    }

    @Test("a rewrite that fits alongside what is live evicts nothing")
    func roomForEverybody() {
        let budget = ArchiveUndoBudget(bytes: 1000)
        let plan = budget.plan(
            adding: 400,
            held: [held("/a", 300), held("/b", 200)],
            live: ["/a", "/b"]
        )
        #expect(plan.evict.isEmpty)
        #expect(plan.admits)
    }

    @Test("live snapshots are given up in journal order, and only as many as it takes")
    func journalOrderDecides() {
        let budget = ArchiveUndoBudget(bytes: 1000)
        // `live` is furthest-from-the-next-⌘Z first, and the store's own listing order is
        // deliberately the *opposite* here: what decides has to be the journal's order, not
        // whatever `contentsOfDirectory` happened to return.
        let plan = budget.plan(
            adding: 500,
            held: [held("/near", 300), held("/mid", 300), held("/far", 300)],
            live: ["/far", "/mid", "/near"]
        )
        // 900 held + 500 incoming is over; giving up `/far` leaves 600 + 500 still over; giving up
        // `/mid` leaves 300 + 500, which fits — and the one nearest a keystroke survives.
        #expect(plan.evict == ["/far", "/mid"])
        #expect(plan.admits)
    }

    @Test(
        "an archive larger than the whole budget is refused, and no live snapshot is traded for it"
    )
    func tooLargeToEverKeep() {
        let budget = ArchiveUndoBudget(bytes: 1000)
        let plan = budget.plan(
            adding: 2000,
            held: [held("/a", 300), held("/dead", 300)],
            live: ["/a"]
        )
        #expect(!plan.admits)
        // The dead one still goes — it is holding disk for nobody either way — and the live one
        // stays, because emptying the store would not have made 2000 fit in 1000.
        #expect(plan.evict == ["/dead"])
    }

    @Test("what a confirmation may promise depends on the archive's size and nothing else")
    func admissionIsAboutTheArchiveAlone() {
        let budget = ArchiveUndoBudget(bytes: 1000)
        #expect(budget.admits(archiveOfSize: 1000))
        #expect(!budget.admits(archiveOfSize: 1001))
    }

    @Test("the shipped budget is five gigabytes")
    func shippedDefault() {
        #expect(ArchiveUndoBudget.default.bytes == 5_368_709_120)
    }
}
