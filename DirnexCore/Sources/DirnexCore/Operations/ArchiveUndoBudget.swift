import Foundation

/// How much disk Dirnex keeps so an archive rewrite can be undone, and what it drops to stay
/// inside that (HISTORY.md ▸ After M19, 2026-09-01 "an archive rewrite is undoable").
///
/// Deleting a member rewrites the whole container, so the only exact reversal is the container as
/// it was — there is no diff to journal, and the bytes that left have nowhere else to live. That
/// makes undo here a *storage* question rather than a missing hook, and this is the answer to it:
/// one budget across every snapshot, oldest dropped first.
///
/// **What it costs is measured and is not what it looks like.** On the same APFS volume the
/// snapshot is a `clonefile`, so taking it consumes **zero** bytes and takes 0.1 ms for a 200 MB
/// archive; after the rewrite replaces the original, nothing is freed, because the snapshot now
/// holds the blocks the archive released; deleting it later returns all of them (measured
/// 2026-09-01: 0 bytes on the clone, 12 KB on the replace, 104 845 312 freed for a 100 MB archive).
/// So an undoable rewrite does not *spend* disk — it defers reclaiming the archive's old bytes
/// until the record leaves the journal. Across volumes there is no clone (`EXDEV`) and the snapshot
/// is a real copy onto the store's volume, which is the case this budget really bounds.
///
/// Pure: it decides, and ``ArchiveUndoStore`` carries the decision out.
public struct ArchiveUndoBudget: Sendable, Equatable {
    /// 5 GB. Chosen as a number that is one sentence to explain rather than derived from anything:
    /// large enough that an ordinary archive is always undoable, small enough that a user who never
    /// thinks about it is never surprised by where their free space went.
    public static let `default` = ArchiveUndoBudget(bytes: 5 << 30)

    /// The most the store may hold, in bytes.
    public let bytes: Int64

    public init(bytes: Int64) {
        self.bytes = max(0, bytes)
    }

    /// One snapshot the store is already holding.
    public struct Held: Sendable, Equatable {
        /// Its file's path in the store — the identity throughout, because it is exactly what an
        /// ``UndoStep/restoreArchive(archive:snapshot:expected:restored:)`` step carries. Deriving
        /// an id from the name and matching on that would be a second spelling of the same fact.
        public let path: String
        public let byteSize: Int64

        public init(path: String, byteSize: Int64) {
            self.path = path
            self.byteSize = byteSize
        }
    }

    /// What to do about an incoming snapshot: which held ones to delete, and whether the new one
    /// fits once they are gone.
    public struct Plan: Sendable, Equatable {
        public let evict: [String]
        /// Whether the incoming snapshot may be taken at all. `false` means the rewrite goes ahead
        /// and is simply not undoable — which the gesture's confirmation says *before* it runs, so
        /// the user is never told an operation is reversible when it is not.
        public let admits: Bool

        public init(evict: [String], admits: Bool) {
            self.evict = evict
            self.admits = admits
        }
    }

    /// Decide what a snapshot of `incoming` bytes costs the store.
    ///
    /// `live` is every snapshot path the journal still names, **in journal order, furthest from the
    /// next ⌘Z first**. An order rather than a set, and the journal's rather than the store's,
    /// because that is the only thing that actually answers "which of these will be wanted last".
    /// A first version sorted by the snapshot files' `st_birthtime` and was wrong twice over: it
    /// approximates the journal's order rather than knowing it, and — read as `tv_sec`, which is
    /// how anyone writes it — it gives every snapshot taken in the same second an equal key, so
    /// `sorted(by:)` (which is not stable) evicts an arbitrary one. That failed about one full test
    /// run in three while passing alone every time, which is what a non-deterministic comparator
    /// looks like from outside.
    ///
    /// Three rules, in order:
    ///
    /// 1. **A snapshot nothing points at is evicted whatever the arithmetic.** Anything absent from
    ///    `live` belongs to a record that fell off the bottom of the journal, or to a journal that
    ///    was cleared, and is holding the user's disk for nobody.
    /// 2. **An archive bigger than the whole budget is refused, and refused without evicting
    ///    anything live** — emptying the store would still not make it fit, so trading away other
    ///    people's undo buys nothing.
    /// 3. Otherwise live snapshots go from the front of that order until the rest plus the newcomer
    ///    fit.
    public func plan(adding incoming: Int64, held: [Held], live: [String]) -> Plan {
        let named = Set(live)
        var evict = held.filter { !named.contains($0.path) }.map(\.path)
        let sizes = Dictionary(held.map { ($0.path, $0.byteSize) }) { first, _ in first }
        let survivors = live.filter { sizes[$0] != nil }

        guard incoming <= bytes else { return Plan(evict: evict, admits: false) }

        var total = survivors.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
        for path in survivors where total + incoming > bytes {
            evict.append(path)
            total -= sizes[path] ?? 0
        }
        return Plan(evict: evict, admits: true)
    }

    /// Whether an archive of `byteSize` can be kept at all — the question a confirmation sheet asks
    /// *before* the rewrite, so it can say truthfully whether Undo will put the archive back.
    ///
    /// Deliberately independent of what the store currently holds: everything else is evictable, so
    /// the only permanent answer is the one about the archive's own size. A sheet that consulted the
    /// live contents would promise or refuse undo depending on what the user happened to have done
    /// earlier in the session, which is not a distinction anybody could act on.
    public func admits(archiveOfSize byteSize: Int64) -> Bool {
        byteSize <= bytes
    }
}
