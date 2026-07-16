import Foundation

// Total Commander's universal undo (PLAN.md §M2 "Undo journal: Cmd+Z reverses
// move/rename/copy/new-folder; delete-to-Trash restore; journal survives relaunch").
//
// The journal is a bounded stack of `UndoRecord`s, newest on top; Cmd+Z pops the top and
// applies its inverse. It lives in `DirnexCore` because reversing an operation *touches
// bytes* ("if it touches bytes, it lives in DirnexCore and has tests" — §2), so the
// reversal executor and the record-building logic — the parts that can corrupt data if
// they get the inverse wrong — are here under property tests, and the app is a thin shell
// that records completed operations and drives `revert` off the main thread.
//
// A record never carries the *reason* an operation happened, only enough to undo it: the
// filesystem primitives that put things back. Anything that can't be cleanly reversed (a
// copy/move that overwrote an existing file — the replaced original is already gone) is
// counted in `nonReversibleCount` and surfaced to the user, never silently dropped.

// MARK: - Reversal primitives

/// One filesystem primitive that undoes part of an operation. Each variant is the inverse
/// of a thing an operation did; a record is a list of them, applied in order.
///
/// Every step is itself invertible (`inverse`), which is what makes Redo fall out for free:
/// reverting a record's steps undoes the operation, and reverting the *inverted* steps redoes
/// it. So the redo executor is the same `revert` — it just runs the opposite steps.
public enum UndoStep: Sendable, Equatable, Codable {
    /// Undo a move / rename / trash: put the item back by moving `from` (its current
    /// location) to `to` (where it lived before). Refuses to clobber a reoccupied `to`.
    /// Symmetric — its inverse moves the item the other way.
    case restore(from: VFSPath, to: VFSPath)
    /// Undo a copy: remove the copy that was created at `copy`. A no-op if it's already
    /// gone. Removes a copied subtree wholesale, matching Finder's "Undo Copy". Carries the
    /// original `source` so the inverse (`makeCopy`) can re-create the copy for Redo.
    case removeCopy(source: VFSPath, copy: VFSPath)
    /// Redo a copy: re-copy `source` to exactly `copy`. The inverse of `removeCopy`.
    case makeCopy(source: VFSPath, copy: VFSPath)
    /// Undo a New Folder: remove the folder at `path`, but *only while it is still empty* —
    /// never destroy files the user has since put inside it.
    case removeCreatedFolder(VFSPath)
    /// Redo a New Folder: re-create the folder at `path`. The inverse of `removeCreatedFolder`.
    case createFolder(VFSPath)

    /// The step that reverses this one — the heart of Redo (see `UndoRecord.inverted`).
    var inverse: UndoStep {
        switch self {
        case let .restore(from, to): return .restore(from: to, to: from)
        case let .removeCopy(source, copy): return .makeCopy(source: source, copy: copy)
        case let .makeCopy(source, copy): return .removeCopy(source: source, copy: copy)
        case let .removeCreatedFolder(path): return .createFolder(path)
        case let .createFolder(path): return .removeCreatedFolder(path)
        }
    }
}

// MARK: - Journal record

/// One reversible action on the undo stack: a user-facing label, the steps that invert it,
/// and how many parts of the original operation can't be reversed at all.
public struct UndoRecord: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    /// The operation's name, shown in the menu as "Undo \(label)" ("Move", "Copy",
    /// "Rename", "New Folder", "Move to Trash").
    public let label: String
    public let date: Date
    /// The inverse operations, applied in order by `UndoJournal.revert`.
    public let steps: [UndoStep]
    /// Items in the original operation that overwrote an existing file and so can't be
    /// undone (the replaced original is gone). Surfaced when the record is reverted.
    public let nonReversibleCount: Int

    public init(
        id: UUID = UUID(),
        label: String,
        date: Date = Date(),
        steps: [UndoStep],
        nonReversibleCount: Int = 0
    ) {
        self.id = id
        self.label = label
        self.date = date
        self.steps = steps
        self.nonReversibleCount = nonReversibleCount
    }
}

extension UndoRecord {
    /// The record that reverses this one: same label and non-reversible count, every step
    /// inverted. Undoing a record pushes its `inverted` onto the redo stack; redoing reverts
    /// that (re-applying the original operation) and pushes *its* inverted — the original
    /// record — back onto the undo stack. So one inversion drives both directions.
    var inverted: UndoRecord {
        UndoRecord(
            label: label,
            date: date,
            steps: steps.map(\.inverse),
            nonReversibleCount: nonReversibleCount
        )
    }
}

// MARK: - Record builders

public extension UndoRecord {
    /// Build the undo record for a completed copy/move from the engine's per-item outcomes
    /// (`OperationReport.outcomes`). Returns `nil` when nothing is reversible — every item
    /// was skipped by the conflict policy, or every landing overwrote an existing file — so
    /// an un-undoable operation simply never enters the journal.
    ///
    /// - A **copy** is undone by removing each fresh copy (`removeCopy`).
    /// - A **move** is undone by moving each item back to its source (`restore`).
    /// - An item that **overwrote** an existing file is counted in `nonReversibleCount`, not
    ///   reversed: deleting the replacement wouldn't bring back the original it clobbered.
    static func transfer(
        kind: FileOperation.Kind,
        outcomes: [OperationItemOutcome],
        date: Date = Date()
    ) -> UndoRecord? {
        var steps: [UndoStep] = []
        var nonReversible = 0
        for outcome in outcomes {
            guard let landed = outcome.landedAt else { continue } // skipped: nothing happened
            if outcome.replacedExisting {
                nonReversible += 1
                continue
            }
            switch kind {
            case .copy: steps.append(.removeCopy(source: outcome.source, copy: landed))
            case .move: steps.append(.restore(from: landed, to: outcome.source))
            }
        }
        guard !steps.isEmpty else { return nil }
        return UndoRecord(
            label: kind == .copy ? "Copy" : "Move",
            date: date,
            steps: steps,
            nonReversibleCount: nonReversible
        )
    }

    /// Undo a New Folder by removing the folder — while it's still empty (`removeCreatedFolder`).
    static func newFolder(at path: VFSPath, date: Date = Date()) -> UndoRecord {
        UndoRecord(label: "New Folder", date: date, steps: [.removeCreatedFolder(path)])
    }

    /// Undo an inline rename by moving the new name back to the old one.
    static func rename(from old: VFSPath, to new: VFSPath, date: Date = Date()) -> UndoRecord {
        UndoRecord(label: "Rename", date: date, steps: [.restore(from: new, to: old)])
    }

    /// Undo a Multi-Rename batch by moving each renamed item back to its original name — one
    /// record, so a single Cmd+Z reverses the whole batch (PLAN.md §M4 "applies as one undoable
    /// batch"). Returns `nil` when nothing was renamed. Because the tool never applies a rename
    /// whose target equals another still-present name, every original is free at undo time and
    /// `.restore`'s clobber guard never trips on a batch of its own making.
    static func multiRename(
        _ items: [(original: VFSPath, renamed: VFSPath)],
        date: Date = Date()
    ) -> UndoRecord? {
        let steps = items.map { UndoStep.restore(from: $0.renamed, to: $0.original) }
        guard !steps.isEmpty else { return nil }
        return UndoRecord(label: "Rename", date: date, steps: steps)
    }

    /// Undo a Move-to-Trash by restoring each item from the Trash location it landed at back
    /// to where it came from. Returns `nil` if nothing was actually trashed (e.g. the backend
    /// reported no Trash location for any item).
    static func trash(
        _ items: [(original: VFSPath, trashed: VFSPath)],
        date: Date = Date()
    ) -> UndoRecord? {
        let steps = items.map { UndoStep.restore(from: $0.trashed, to: $0.original) }
        guard !steps.isEmpty else { return nil }
        return UndoRecord(label: "Move to Trash", date: date, steps: steps)
    }
}

// MARK: - Reversal report

/// What happened when a record was reverted: the steps that couldn't be applied (an item
/// vanished, its old location is reoccupied, a permission error). An empty list means the
/// undo fully succeeded.
public struct UndoReport: Sendable, Equatable {
    public let failures: [OperationItemFailure]

    public init(failures: [OperationItemFailure]) {
        self.failures = failures
    }

    public var succeeded: Bool { failures.isEmpty }
}

// MARK: - The journal

/// A bounded, newest-on-top pair of `UndoEntry` stacks — one for undo, one for redo. Value
/// type: the app owns one per window, records completed actions into it, and persists both
/// stacks across launches. An entry is either a byte-touching file operation or an in-memory
/// selection change; the journal treats them uniformly and only the app cares which is which.
///
/// The redo stack mirrors every editor's undo/redo: undoing moves an action's inverse onto
/// redo; redoing moves it (inverted again — the original) back onto undo; and a *fresh*
/// action clears redo, because once history diverges there is no forward to redo to.
public struct UndoJournal: Sendable, Equatable {
    /// The most that is kept per stack; older entries fall off the bottom. A stack, not a full
    /// history — undo walks back from the most recent action.
    public let capacity: Int
    public private(set) var records: [UndoEntry]
    public private(set) var redoRecords: [UndoEntry]

    public init(records: [UndoEntry] = [], redoRecords: [UndoEntry] = [], capacity: Int = 50) {
        self.capacity = max(1, capacity)
        self.records = Array(records.suffix(self.capacity))
        self.redoRecords = Array(redoRecords.suffix(self.capacity))
    }

    /// The action Cmd+Z would reverse next, or `nil` when there's nothing to undo.
    public var top: UndoEntry? { records.last }
    /// The action Cmd+Shift+Z would re-apply next, or `nil` when there's nothing to redo.
    public var redoTop: UndoEntry? { redoRecords.last }

    public var canUndo: Bool { !records.isEmpty }
    public var canRedo: Bool { !redoRecords.isEmpty }

    /// Push a freshly-completed action onto the undo stack. A brand-new action invalidates
    /// the redo stack: you can't redo forward past a point where history diverged.
    public mutating func record(_ entry: UndoEntry) {
        redoRecords.removeAll()
        records = trimmed(records + [entry])
    }

    /// Convenience: record a byte-touching file operation, the common case at most call sites.
    public mutating func record(_ record: UndoRecord) {
        self.record(.fileOperation(record))
    }

    /// Pop the top undo action and move its inverse onto the redo stack. The caller applies
    /// the returned entry (a file op off the main thread, a selection change on it); this only
    /// shuffles the stacks. `nil` on an empty undo stack.
    public mutating func takeForUndo() -> UndoEntry? {
        guard let entry = records.popLast() else { return nil }
        redoRecords = trimmed(redoRecords + [entry.inverted])
        return entry
    }

    /// Pop the top redo action and move its inverse — the original action — back onto the undo
    /// stack. The caller applies the returned entry, which re-applies the original action. `nil`
    /// on an empty redo stack.
    public mutating func takeForRedo() -> UndoEntry? {
        guard let entry = redoRecords.popLast() else { return nil }
        records = trimmed(records + [entry.inverted])
        return entry
    }

    /// Pop the top undo action without touching redo — a raw stack primitive for inspection.
    @discardableResult
    public mutating func removeTop() -> UndoEntry? {
        records.popLast()
    }

    public mutating func clear() {
        records.removeAll()
        redoRecords.removeAll()
    }

    /// Drop the oldest entries so a stack never exceeds `capacity`.
    private func trimmed(_ stack: [UndoEntry]) -> [UndoEntry] {
        stack.count > capacity ? Array(stack.suffix(capacity)) : stack
    }

    // MARK: - Reversal executor

    /// Apply a record's inverse steps against `backend`, collecting per-step failures rather
    /// than aborting on the first — so undoing a five-item move that hits one reoccupied slot
    /// still restores the other four. Pure with respect to the journal; the caller pops the
    /// record and runs this off the main thread.
    public static func revert(_ record: UndoRecord, using backend: any VFSBackend) -> UndoReport {
        var failures: [OperationItemFailure] = []
        for step in record.steps {
            switch step {
            case let .restore(from, to):
                restore(from: from, to: to, using: backend, failures: &failures)
            case let .removeCopy(_, copy):
                removeCopy(at: copy, using: backend, failures: &failures)
            case let .makeCopy(source, copy):
                makeCopy(source: source, copy: copy, using: backend, failures: &failures)
            case let .removeCreatedFolder(path):
                removeCreatedFolder(at: path, using: backend, failures: &failures)
            case let .createFolder(path):
                createFolder(at: path, using: backend, failures: &failures)
            }
        }
        return UndoReport(failures: failures)
    }

    /// Move `from` back to `to`. Refuses to overwrite a reoccupied `to` (undo must never
    /// destroy data the user created since), and — because a cross-volume move was undone by
    /// copy-then-delete originally — falls back to the copy engine when a plain rename can't
    /// cross the volume boundary.
    private static func restore(
        from: VFSPath,
        to: VFSPath,
        using backend: any VFSBackend,
        failures: inout [OperationItemFailure]
    ) {
        if (try? backend.stat(at: to)) != nil {
            failures.append(.init(path: to, error: .alreadyExists(to)))
            return
        }
        do {
            try backend.moveItem(at: from, to: to)
        } catch let VFSError.io(_, code) where code == EXDEV {
            crossVolumeRestore(from: from, to: to, using: backend, failures: &failures)
        } catch let error as VFSError {
            failures.append(.init(path: from, error: error))
        } catch {
            failures.append(.init(path: from, error: .io(path: from, code: 0)))
        }
    }

    /// The cross-volume fallback for `restore`: reverse a copy-then-delete move by moving the
    /// item back through the copy engine. Only reachable for a move (name preserved, so it
    /// lands back at exactly `to`); a rename never crosses volumes, so it never gets here.
    private static func crossVolumeRestore(
        from: VFSPath,
        to: VFSPath,
        using backend: any VFSBackend,
        failures: inout [OperationItemFailure]
    ) {
        guard from.lastComponent == to.lastComponent, let parent = to.parent,
              let entry = try? backend.stat(at: from) else {
            failures.append(.init(path: from, error: .io(path: from, code: EXDEV)))
            return
        }
        let report = CopyEngine.run(
            FileOperation(kind: .move, sources: [entry], destinationDirectory: parent),
            using: backend,
            conflictPolicy: .fail
        )
        failures.append(contentsOf: report.failures)
    }

    /// Remove a copy the operation created. Already gone → nothing to do (treat as undone).
    private static func removeCopy(
        at path: VFSPath,
        using backend: any VFSBackend,
        failures: inout [OperationItemFailure]
    ) {
        guard (try? backend.stat(at: path)) != nil else { return }
        do {
            try backend.removeItem(at: path)
        } catch let error as VFSError {
            failures.append(.init(path: path, error: error))
        } catch {
            failures.append(.init(path: path, error: .io(path: path, code: 0)))
        }
    }

    /// Re-create a copy that Undo removed (Redo of a Copy): copy `source` back to exactly
    /// `copy`. Refuses to overwrite a reoccupied `copy` — redo, like undo, never destroys data
    /// the user created since. Runs the tested copy engine with `keepBoth` (so it always lands
    /// somewhere without clobbering), then renames the landing to the exact recorded path, so a
    /// keep-both original ("file copy.txt") is reproduced faithfully rather than as `source`'s
    /// bare name.
    private static func makeCopy(
        source: VFSPath,
        copy: VFSPath,
        using backend: any VFSBackend,
        failures: inout [OperationItemFailure]
    ) {
        if (try? backend.stat(at: copy)) != nil {
            failures.append(.init(path: copy, error: .alreadyExists(copy)))
            return
        }
        guard let entry = try? backend.stat(at: source), let parent = copy.parent else {
            failures.append(.init(path: source, error: .notFound(source)))
            return
        }
        let report = CopyEngine.run(
            FileOperation(kind: .copy, sources: [entry], destinationDirectory: parent),
            using: backend,
            conflictPolicy: .keepBoth
        )
        guard report.failures.isEmpty else {
            failures.append(contentsOf: report.failures)
            return
        }
        guard let landed = report.outcomes.first?.landedAt else {
            failures.append(.init(path: source, error: .notFound(source)))
            return
        }
        guard landed != copy else { return }
        do {
            try backend.moveItem(at: landed, to: copy)
        } catch let error as VFSError {
            failures.append(.init(path: copy, error: error))
        } catch {
            failures.append(.init(path: copy, error: .io(path: copy, code: 0)))
        }
    }

    /// Remove a folder New Folder created — but only if it's still an empty directory.
    /// A folder the user has since filled, or one already replaced by something else, is
    /// left untouched: undo protects existing data over completing the reversal.
    private static func removeCreatedFolder(
        at path: VFSPath,
        using backend: any VFSBackend,
        failures: inout [OperationItemFailure]
    ) {
        guard let entry = try? backend.stat(at: path), entry.kind == .directory else { return }
        guard let children = try? backend.listDirectory(at: path), children.isEmpty else { return }
        do {
            try backend.removeItem(at: path)
        } catch let error as VFSError {
            failures.append(.init(path: path, error: error))
        } catch {
            failures.append(.init(path: path, error: .io(path: path, code: 0)))
        }
    }

    /// Re-create a folder Undo removed (Redo of New Folder). An existing directory at `path`
    /// means the redo is already satisfied — a no-op success. Anything *else* now occupying the
    /// path is refused rather than clobbered, mirroring `makeCopy`/`restore`.
    private static func createFolder(
        at path: VFSPath,
        using backend: any VFSBackend,
        failures: inout [OperationItemFailure]
    ) {
        if let existing = try? backend.stat(at: path) {
            if existing.kind != .directory {
                failures.append(.init(path: path, error: .alreadyExists(path)))
            }
            return
        }
        do {
            try backend.createDirectory(at: path)
        } catch let error as VFSError {
            failures.append(.init(path: path, error: error))
        } catch {
            failures.append(.init(path: path, error: .io(path: path, code: 0)))
        }
    }
}
