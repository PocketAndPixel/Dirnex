import Foundation

/// The put-back records Dirnex writes for its **own** deletes, so an item it trashed can go home
/// even when macOS wrote no record for it (PLAN.md §M26 Slice 4).
///
/// ## Why there is a second source at all
///
/// `FileManager.trashItem` writes Finder's `ptbL`/`ptbN` pair into the trash directory's
/// `.DS_Store`, and ``TrashPutBack`` reads it. ``ProviderAwareTrashPerformer`` cannot: an item
/// inside a File Provider domain is moved by a `renamex_np` of ours, and this package can read
/// those records but not write them. That is the one regression M26 knowingly introduced — the item
/// lands in the right trash and then has no way home — and this is what takes it back, from the
/// origin the delete already knew.
///
/// The data is not measured or recovered: ``DeletePass/Restoration`` already pairs every trashed
/// item's origin with where it landed, because ⌘Z needed exactly that. So this is a durable record
/// in the shape ``TrashPutBack/origins(inDSStore:ofTrashAt:)`` already hands the restore flow, and
/// nothing in ``TrashPerformer`` changes.
///
/// ## Finder's record wins wherever it exists
///
/// An ordinary local delete still goes through `trashItem`, which writes the pair — so the common
/// case must keep answering from the `.DS_Store` and never from here, or Dirnex's Put Back and
/// Finder's own could send one file to two different folders. That is the whole correctness
/// argument, and it is ``origin(of:finderRecord:)``: a second source of truth for a question
/// already answered is the shape this codebase keeps paying for, so this one answers only where the
/// first is silent.
///
/// ## What it deliberately cannot do
///
/// An item **Finder** deleted out of a provider domain (on Box that does not land on this Mac at
/// all — it goes to Box's server-side trash), and anything trashed before this shipped, have no
/// record here and none in the `.DS_Store` either. Both keep today's honest answer: the restore
/// flow says it does not know where the item came from, by name, rather than guessing at a folder.
public struct TrashOriginRecords: Sendable, Equatable, Codable {
    /// One item's journey: where it landed, and where it came from.
    ///
    /// Keyed on the **full landing path**, never the filename. ``TrashPutBack/origins(inDSStore:ofTrashAt:)``
    /// may key by name because a `.DS_Store` only ever describes its own directory; this store spans
    /// `~/.Trash`, every volume's `.Trashes/<uid>`, iCloud's and every provider mount's at once, and
    /// two of them can hold the same name.
    public struct Record: Sendable, Equatable, Codable {
        public let trashed: VFSPath
        public let origin: TrashOrigin

        public init(trashed: VFSPath, origin: TrashOrigin) {
            self.trashed = trashed
            self.origin = origin
        }
    }

    /// Oldest first. An array rather than a dictionary because the order *is* the eviction rule
    /// below, and because a lookup here is bounded by ``limit`` — a linear scan over a couple of
    /// thousand paths costs less than the `.DS_Store` parse it sits beside.
    public private(set) var records: [Record]

    /// The ceiling ``prune(stillTrashed:inTrashesRead:)`` is the backstop for.
    ///
    /// Records go stale and that is tolerable — Finder's own outlive their files by weeks, which is
    /// why `origins` is deliberately a superset the caller matches into. What they may not be is
    /// permanent, and pruning alone does not guarantee that: it runs when the Trash is *read*, and a
    /// user who never opens it would never prune. So the oldest record is the one that goes, which
    /// is also the one least likely to be put back.
    public let limit: Int

    public init(records: [Record] = [], limit: Int = 2000) {
        self.limit = max(limit, 1)
        // Collapse duplicate landing paths on the way in (a hand-edited or half-written store),
        // keeping the *newest* — the same rule `record` applies, so a decode cannot disagree with a
        // write about which of two records for one path answers.
        var seen = Set<VFSPath>()
        self.records = records.reversed().filter { seen.insert($0.trashed).inserted }.reversed()
        trim()
    }

    // MARK: - Recording

    /// File what a Trash pass moved, skipping anything `shouldSkip` claims.
    ///
    /// **`shouldSkip` is the vault rule** (PLAN.md §M19, ``VaultPrivacy``), and it is the reason
    /// this is not simply "record every delete". A record pairs a file's name with the folder it
    /// came from and outlives both — exactly the *implicit* memory a vault's contents must stay out
    /// of, and a file deleted from inside a mounted vault would otherwise leave its name and its
    /// origin sitting in a plain store outside the encrypted image. The frecency index and session
    /// restore already have this rule; the predicate comes from the caller for the same reason
    /// ``Frecency/forget(where:)``'s does — only the app holds the live mount points.
    ///
    /// **Both ends are asked**, not just the origin: a landing path inside a vault is a record of
    /// the vault's own trash, which names the file just as plainly.
    ///
    /// - Returns: whether anything changed, so a caller can skip a needless write.
    @discardableResult
    public mutating func record(
        _ restorations: [DeletePass.Restoration],
        unless shouldSkip: (VFSPath) -> Bool
    ) -> Bool {
        var changed = false
        for restoration in restorations {
            guard let directory = restoration.original.parent else { continue }
            guard !shouldSkip(restoration.original), !shouldSkip(restoration.trashed) else { continue }
            let record = Record(
                trashed: restoration.trashed,
                origin: TrashOrigin(directory: directory, name: restoration.original.lastComponent)
            )
            // A landing path is unique while the item is there and can be handed out again once it
            // has been put back or emptied, so the newest answer replaces the older one rather than
            // sitting behind it.
            records.removeAll { $0.trashed == record.trashed }
            records.append(record)
            changed = true
        }
        if changed { trim() }
        return changed
    }

    // MARK: - Reading

    /// Where the item now at `trashed` came from — **`finderRecord` wherever there is one**.
    ///
    /// The merge rule, in one place and with a test on it, rather than a `??` at the call site: the
    /// direction is the whole correctness argument above, and inverting it would send an ordinary
    /// local item to a folder Finder disagrees about.
    public func origin(of trashed: VFSPath, finderRecord: TrashOrigin?) -> TrashOrigin? {
        if let finderRecord { return finderRecord }
        return records.last { $0.trashed == trashed }?.origin
    }

    // MARK: - Forgetting

    /// Drop every record for an item that is no longer in a trash this pass actually read.
    ///
    /// Scoped to `trashesRead` rather than applied to the whole store, because "not in the listing"
    /// and "in a listing nobody could take" are different facts: a volume that unmounted between
    /// the enumeration and the listing, or a trash whose read failed, contributes no entries at all,
    /// and pruning against the merged set would throw away every record it owns.
    ///
    /// - Parameters:
    ///   - stillTrashed: the landing paths the pass actually found.
    ///   - trashesRead: the trash directories it managed to list.
    /// - Returns: whether anything went.
    @discardableResult
    public mutating func prune(stillTrashed: Set<VFSPath>, inTrashesRead trashesRead: Set<VFSPath>) -> Bool {
        let before = records.count
        records.removeAll { record in
            guard let trash = record.trashed.parent, trashesRead.contains(trash) else { return false }
            return !stillTrashed.contains(record.trashed)
        }
        return records.count != before
    }

    /// Drop every record naming a path `shouldForget` claims, at **either** end.
    ///
    /// The second wall behind ``record(_:unless:)``'s guard, for the case the guard cannot cover: an
    /// image unlocked outside Dirnex and browsed in the window before the mount notification landed
    /// (the shape ``Frecency/forget(where:)`` exists for, and called from the same funnel).
    @discardableResult
    public mutating func forget(where shouldForget: (VFSPath) -> Bool) -> Bool {
        let before = records.count
        records.removeAll { shouldForget($0.trashed) || shouldForget($0.origin.directory) }
        return records.count != before
    }

    private mutating func trim() {
        guard records.count > limit else { return }
        records.removeFirst(records.count - limit)
    }
}
