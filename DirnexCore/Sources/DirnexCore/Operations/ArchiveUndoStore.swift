import Foundation

/// Where the bytes an archive rewrite displaced are kept, so ⌘Z can put them back.
///
/// A rewrite (F8 delete inside an archive, ⌘V/F5/F6 add, an edited member saved back) extracts the
/// container, edits the tree and repacks — there is no diff to journal, so the only exact reversal
/// is the container as it was. This holds that copy for the life of its journal record, inside the
/// budget ``ArchiveUndoBudget`` decides. What it costs is measured in that type's doc comment, and
/// is not what it looks like: on one APFS volume the copy is a clone and consumes nothing.
///
/// **The undo is a swap, not a restore, and that is what makes Redo free.** ``exchange`` gives the
/// archive the snapshot's bytes *and* the snapshot the archive's, so the step is its own inverse:
/// ⌘Z puts the original back, ⇧⌘Z puts the rewrite back, and neither direction needs a second copy
/// or a second code path. It is also the only shape that never destroys anything — a one-way
/// "restore over the archive" would throw away the rewrite the user might still want.
public struct ArchiveUndoStore: Sendable {
    /// The directory the snapshots live in. Handed in rather than derived so tests get a temp root
    /// and the app gets its Application Support one.
    public let root: URL
    public let budget: ArchiveUndoBudget

    public init(root: URL, budget: ArchiveUndoBudget = .default) {
        self.root = root
        self.budget = budget
    }

    // MARK: - Contents

    /// Every snapshot the store is holding, for ``ArchiveUndoBudget/plan(adding:held:live:)``.
    ///
    /// Sizes only, no timestamps: what a snapshot is *worth* is the journal's business, and the
    /// store cannot answer it better than the journal can (see that method).
    ///
    /// A file it cannot `stat` is reported as zero bytes rather than skipped, so it is still
    /// evictable — a store that could not describe its own junk could never clear it.
    public func held() -> [ArchiveUndoBudget.Held] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasSuffix(Self.suffix) }.map { name in
            let path = root.appendingPathComponent(name).path
            var status = stat()
            let size = stat(path, &status) == 0 ? Int64(status.st_size) : 0
            return .init(path: path, byteSize: size)
        }
    }

    // MARK: - Capture

    /// Preserve the current bytes of the archive at `archiveOnDiskPath` before a rewrite replaces
    /// them, evicting whatever the budget says must go. `nil` means the rewrite is not undoable —
    /// the archive is bigger than the whole budget, or the copy could not be made.
    ///
    /// `live` is every snapshot path the journal still names, in journal order; see
    /// ``ArchiveUndoBudget/plan(adding:held:live:)`` for what it protects and why the order matters.
    ///
    /// **A failure here never fails the rewrite.** The user asked for a delete, not for a copy of
    /// their archive, so a store that cannot write loses the undo and nothing else. The gesture has
    /// already said which it will be, from ``ArchiveUndoBudget/admits(archiveOfSize:)`` — that
    /// answer is about the archive's size and so is stable, where this one can also be an I/O
    /// failure in our own directory.
    public func capture(archiveAt archiveOnDiskPath: String, live: [String]) -> ArchiveUndoSnapshot? {
        guard let witness = ArchiveUndoWitness.current(ofFileAt: archiveOnDiskPath) else { return nil }

        let plan = budget.plan(adding: witness.byteSize, held: held(), live: live)
        for path in plan.evict { try? FileManager.default.removeItem(atPath: path) }
        guard plan.admits else { return nil }

        guard (try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )) != nil else { return nil }
        excludeFromBackup()

        let snapshot = root.appendingPathComponent(UUID().uuidString + Self.suffix)
        guard Self.duplicate(from: archiveOnDiskPath, to: snapshot.path) else { return nil }
        return ArchiveUndoSnapshot(
            archive: archiveOnDiskPath,
            snapshot: snapshot.path,
            restored: witness
        )
    }

    /// Delete the snapshot at `path` — the rewrite that took it failed, so it reverses nothing.
    public func discard(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Delete every snapshot no journal record still names. Called at launch, where the persisted
    /// journal is the whole live set: a record that fell off the bottom of the stack, or a journal
    /// that was cleared or failed to decode, leaves its snapshot holding disk for nobody.
    public func prune(live: Set<String>) {
        for snapshot in held() where !live.contains(snapshot.path) {
            try? FileManager.default.removeItem(atPath: snapshot.path)
        }
    }

    // MARK: - The swap

    /// Give the archive at `archiveOnDiskPath` the snapshot's bytes and the snapshot the archive's.
    ///
    /// Ordered so that nothing is ever the only copy of itself:
    ///
    /// 1. Stage the snapshot's bytes as a hidden sibling of the archive — a clone on the archive's
    ///    own volume, which is also what makes step 3 possible at all (`replaceItemAt` and
    ///    `rename(2)` both refuse to cross a volume, measured).
    /// 2. Copy the archive's *current* bytes into the store beside the snapshot, so they survive
    ///    step 3 and become what a Redo swaps back in.
    /// 3. `rename(2)` the staged file over the archive — one atomic syscall in one directory.
    /// 4. `rename(2)` the kept copy over the snapshot.
    ///
    /// A failure before step 3 leaves everything exactly as it was. `rename(2)` rather than
    /// `replaceItemAt` because a rename carries the source file's own metadata across, which is what
    /// makes the restored archive's modification time the *original's* — the fact the next Redo's
    /// witness is checked against.
    public static func exchange(archiveAt archiveOnDiskPath: String, snapshotAt snapshotPath: String) throws {
        let archiveURL = URL(fileURLWithPath: archiveOnDiskPath)
        let staged = archiveURL.deletingLastPathComponent()
            .appendingPathComponent(".dirnex-undo-\(UUID().uuidString)")
        let kept = snapshotPath + ".incoming"
        let name = archiveURL.lastPathComponent

        func fail() -> VFSError { .unsupported(.archiveUpdateFailed(archive: name)) }

        guard duplicate(from: snapshotPath, to: staged.path) else { throw fail() }
        guard duplicate(from: archiveOnDiskPath, to: kept) else {
            try? FileManager.default.removeItem(at: staged)
            throw fail()
        }
        guard rename(staged.path, archiveOnDiskPath) == 0 else {
            try? FileManager.default.removeItem(at: staged)
            try? FileManager.default.removeItem(atPath: kept)
            throw fail()
        }
        // Past here the archive is already back; a failure now costs the *redo*, not the undo, so
        // it is reported rather than rolled back — putting the rewrite back over the restored
        // archive would undo the thing that just succeeded.
        guard rename(kept, snapshotPath) == 0 else {
            try? FileManager.default.removeItem(atPath: kept)
            throw fail()
        }
    }

    // MARK: - Bytes

    /// Copy `source` to `destination` keeping its modification time exactly, by whichever mechanism
    /// the two paths allow: an APFS clone when they share a volume (instant, and it consumes no
    /// blocks — 0.1 ms and 0 bytes for a 200 MB archive, measured), a real copy when they do not.
    ///
    /// The explicit `utimensat` is what makes the two routes interchangeable. A clone carries the
    /// nanosecond stamp by itself and `FileManager.copyItem` was measured to as well, but only one
    /// of them is *documented* to — and an ``ArchiveUndoWitness`` compares the stamp exactly, so a
    /// route that rounded it would refuse a perfectly good undo on a volume nobody tested.
    static func duplicate(from source: String, to destination: String) -> Bool {
        var status = stat()
        guard stat(source, &status) == 0 else { return false }

        let cloned = clonefile(source, destination, 0) == 0
        if !cloned {
            guard (try? FileManager.default.copyItem(
                atPath: source, toPath: destination
            )) != nil else { return false }
        }
        var times = [
            timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
            timespec(
                tv_sec: status.st_mtimespec.tv_sec,
                tv_nsec: status.st_mtimespec.tv_nsec
            )
        ]
        _ = utimensat(AT_FDCWD, destination, &times, 0)
        return true
    }

    /// Snapshots are Dirnex's own bookkeeping, not the user's documents — up to a budget's worth of
    /// whole archives, all of which the user still has. Time Machine has no business carrying a
    /// second copy of them.
    private func excludeFromBackup() {
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// The extension every snapshot carries, so ``held()`` describes only files this store wrote —
    /// a stray `.DS_Store` is not something to evict, and the `.incoming` file ``exchange`` stages
    /// must not be counted as a snapshot of its own.
    private static let suffix = ".dirnexarchive"
}

/// A captured archive and where it will put itself back — what ``ArchiveUndoStore/capture(archiveAt:live:)``
/// hands the caller so it can journal the rewrite once the rewrite has actually landed.
public struct ArchiveUndoSnapshot: Sendable, Equatable {
    public let archive: String
    public let snapshot: String
    /// What the archive looked like *before* the rewrite — and so what it will look like again once
    /// ⌘Z has run, which is the witness the Redo direction is checked against.
    public let restored: ArchiveUndoWitness

    public init(archive: String, snapshot: String, restored: ArchiveUndoWitness) {
        self.archive = archive
        self.snapshot = snapshot
        self.restored = restored
    }

    /// The journal record for the finished rewrite, read off the archive as it now stands.
    ///
    /// Called *after* the rewrite has replaced the archive, because half of the record is a
    /// description of what the rewrite produced: an undo may only proceed while the archive is
    /// still that file. `nil` when the archive cannot be read, which leaves the operation
    /// unjournalled rather than journalled with a guard nothing can satisfy.
    public func record(date: Date = Date()) -> UndoRecord? {
        guard let current = ArchiveUndoWitness.current(ofFileAt: archive) else { return nil }
        return .archiveRewrite(
            archive: .local(archive),
            snapshot: .local(snapshot),
            expected: current,
            restored: restored,
            date: date
        )
    }
}
