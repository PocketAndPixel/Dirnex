import DirnexCore
import Foundation

/// The window's undo owner: it holds the `DirnexCore.UndoJournal`, persists it across
/// launches, and runs the reversal off the main thread (PLAN.md §M2 "Undo journal … journal
/// survives relaunch"). All the byte-touching reversal logic lives in the tested core
/// `UndoJournal`; this is the thin AppKit shell that records completed operations and drives
/// Cmd+Z.
///
/// Deliberately boring JSON in `UserDefaults`, matching `TabPersistence` (PLAN.md §2
/// "JSON/plist for config"). The plan pencils in SQLite for the journal, which will earn its
/// keep once undo shares a database with the M3 frecency store; a bounded stack of recent
/// operations doesn't need it yet.
/// What `undo()`/`redo()` popped, so the window can finish the job: a file operation was
/// already reverted against the backend (here is its report), or a selection change needs its
/// marks installed on a pane.
enum UndoOutcome {
    /// `administrator` is the part that needed root, run first after the password, when there was
    /// one; `report` is then the rest of the record's.
    case fileOperation(
        record: UndoRecord,
        report: UndoReport,
        administrator: AttributeBatchEscalation.Result? = nil
    )
    case selection(SelectionChange)
}

/// Which stack ⌘Z or ⇧⌘Z works on.
enum UndoDirection: Sendable {
    case undo
    case redo
}

@MainActor
final class UndoController {
    private nonisolated static let persistenceKey = "Dirnex.undoJournal"

    private var journal: UndoJournal
    private let backend: any VFSBackend
    private let defaults: UserDefaults

    /// `defaults` is the domain the journal is persisted in, with no default so every caller names
    /// it. The app test target runs inside the app, where `.standard` is the developer's own journal
    /// (docs/NOTES.md ▸ Testing).
    init(backend: any VFSBackend, defaults: UserDefaults) {
        self.backend = backend
        self.defaults = defaults
        journal = Self.load(from: defaults)
    }

    /// The label of the action Cmd+Z would reverse next (`.move`, `.copy`, `.rename`, …), for
    /// the menu title — or `nil` when there's nothing to undo. Data the window joins to a
    /// translation (`LocalizedCatalog`).
    var nextLabel: UndoActionLabel? { journal.top?.label }
    /// The label of the action Cmd+Shift+Z would re-apply next, or `nil` when there's nothing
    /// to redo.
    var nextRedoLabel: UndoActionLabel? { journal.redoTop?.label }

    /// Push a freshly-completed, reversible operation onto the stack and persist it. A fresh
    /// operation also clears the redo stack (`UndoJournal.record`).
    func record(_ record: UndoRecord) {
        journal.record(record)
        persist()
    }

    /// Push a marking change (Space, Cmd+A, invert, pattern select, mouse) onto the same stack,
    /// so Cmd+Z walks back through it like any other action. Also clears the redo stack.
    func recordSelection(_ change: SelectionChange) {
        journal.record(.selection(change))
        persist()
    }

    /// Take `change` back off the top of the stack, as though it had never been recorded
    /// (`UndoJournal.withdraw`). `false`, with nothing changed, when it is not the newest entry.
    /// Nothing is persisted: a selection change never is.
    func withdrawSelection(_ change: SelectionChange) -> Bool {
        journal.withdraw(.selection(change))
    }

    /// Asked before an undo or a redo that needs root, with what would run as root: `true` to go on.
    typealias AdministratorConsent = @MainActor (EscalatedAttributeBatch, UndoDirection) async -> Bool
    /// Runs the administrator bodies; `AdministratorShell` in the app, a plain shell in tests.
    typealias AdministratorTransport = @Sendable ([String]) async throws -> Void

    /// Pop the top action, moving its inverse onto the redo stack, and apply it: a file
    /// operation is reversed on a background thread and returns a report; a selection change is
    /// handed back for the window to apply on the main thread. `nil` when there was nothing to
    /// undo, or when the user declined the administrator dialog it needed.
    ///
    /// **An undo that needs root asks first** (PLAN.md §M40 Slice 5): a change to an item only an
    /// administrator can change back, such as one the administrator dialog made. `consent` is the
    /// dialog; on a yes the part that needs root runs through `shell` after the password, and the
    /// rest of the record through the journal's executor. Cancel, there or at the password, leaves
    /// the step where it was. `actor` is whom the steps are measured for, injected for the tests.
    func undo(
        actor: UserContext = .current(),
        consent: AdministratorConsent,
        shell: @escaping AdministratorTransport = { try await AdministratorShell.run($0) }
    ) async -> UndoOutcome? {
        await reverse(.undo, actor: actor, consent: consent, shell: shell)
    }

    /// Pop the top redo action, moving its inverse (the original action) back onto the undo
    /// stack, and re-apply it. `nil` when there was nothing to redo, or the user declined. A redo
    /// that needs root asks as an undo does.
    func redo(
        actor: UserContext = .current(),
        consent: AdministratorConsent,
        shell: @escaping AdministratorTransport = { try await AdministratorShell.run($0) }
    ) async -> UndoOutcome? {
        await reverse(.redo, actor: actor, consent: consent, shell: shell)
    }

    /// Run `request` once every ⌘Z and ⇧⌘Z sent before it has finished.
    ///
    /// One at a time, because an undo that needs root takes its entry only after the dialog, and a
    /// second ⌘Z pressed while the first was still asking would find the same entry on top and ask
    /// about it again, or take the one beneath it unasked. Before this, two quick presses reverted
    /// their records at the same time, on two threads.
    func enqueue(_ request: @escaping @MainActor () async -> Void) {
        let previous = lastRequest
        lastRequest = Task { @MainActor in
            await previous?.value
            await request()
        }
    }

    private var lastRequest: Task<Void, Never>?

    /// The shared body of `undo` and `redo`. A record with no local attribute step is taken at once,
    /// as it always was. One with such a step is measured off the main thread first, and taken by
    /// identity afterwards, since a queued job may have recorded something newer meanwhile
    /// (`UndoJournal.takeForUndo(_:)`).
    private func reverse(
        _ direction: UndoDirection,
        actor: UserContext,
        consent: AdministratorConsent,
        shell: @escaping AdministratorTransport
    ) async -> UndoOutcome? {
        let next = direction == .undo ? journal.top : journal.redoTop
        guard let next else { return nil }
        guard case let .fileOperation(record) = next, record.changesLocalAttributes else {
            return await apply(direction == .undo ? journal.takeForUndo() : journal.takeForRedo())
        }
        let escalation = await BlockingWork.run { EscalatedUndo(reverting: record, actor: actor) }
        // Nothing needs root, or nothing a command can make (a Created date): the executor writes
        // what it can and names the rest, as before.
        guard let escalation, escalation.batch.hasCommands else {
            take(next, direction)
            return await apply(next)
        }
        guard await consent(escalation.batch, direction) else { return nil }
        let result = await AttributeBatchEscalation.run(escalation.batch, shell: shell)
        // Cancelled at the password, before anything ran: a choice, and the step stays.
        if result.wasCancelled, result.outcome.changedCount == 0 { return nil }
        take(next, direction)
        persist()
        let backend = backend
        let remainder = escalation.remainder
        let report = await BlockingWork.run { UndoJournal.revert(remainder, using: backend) }
        return .fileOperation(record: record, report: report, administrator: result)
    }

    private func take(_ entry: UndoEntry, _ direction: UndoDirection) {
        switch direction {
        case .undo: journal.takeForUndo(entry)
        case .redo: journal.takeForRedo(entry)
        }
    }

    /// Persist the shuffled stacks, then apply `entry` — the shared tail of `undo` and `redo`,
    /// which differ only in which stack they popped. A file operation touches bytes and so is
    /// reverted off the main thread; a selection change is pure in-memory state the caller sets
    /// on the pane.
    private func apply(_ entry: UndoEntry?) async -> UndoOutcome? {
        guard let entry else { return nil }
        persist()
        switch entry {
        case let .fileOperation(record):
            let backend = backend
            let report = await BlockingWork.run {
                UndoJournal.revert(record, using: backend)
            }
            return .fileOperation(record: record, report: report)
        case let .selection(change):
            return .selection(change)
        }
    }

    // MARK: - Persistence

    /// Both stacks in one blob, so redo survives relaunch alongside undo. Only file operations
    /// are persisted — a selection change references a directory listing that may not exist next
    /// launch, so marks are session-only and dropped here, leaving the file-op history intact and
    /// in order. A journal written by a pre-redo build simply fails to decode and starts empty —
    /// a one-time reset, never a crash.
    private struct Persisted: Codable {
        let undo: [UndoRecord]
        let redo: [UndoRecord]
    }

    private func persist() {
        let blob = Persisted(
            undo: journal.records.compactMap(\.fileOperation),
            redo: journal.redoRecords.compactMap(\.fileOperation)
        )
        guard let data = try? JSONEncoder().encode(blob) else { return }
        defaults.set(data, forKey: Self.persistenceKey)
    }

    /// Every archive snapshot the *persisted* stacks still name, **furthest from the next ⌘Z
    /// first** — what `ArchiveUndoStorage` prunes against at launch and what a capture evicts from.
    ///
    /// Ordered, not a set, because that order is the whole answer to "which of these will be wanted
    /// last" and only the journal has it (``ArchiveUndoBudget/plan(adding:held:live:)``). Undo's
    /// stack comes first, oldest end leading, since its bottom is the furthest thing from any key
    /// the user can press; the redo stack follows, because everything on it is one ⇧⌘Z away.
    ///
    /// Read from the file rather than from a live journal: this runs at launch, before any window
    /// exists. A journal that fails to decode answers empty, which prunes the store empty — right
    /// rather than merely convenient, since a journal nothing can read reverses nothing.
    nonisolated static func persistedArchiveSnapshots(in defaults: UserDefaults) -> [String] {
        let journal = load(from: defaults)
        let records = (journal.records + journal.redoRecords).compactMap(\.fileOperation)
        var seen: Set<String> = []
        return records.flatMap { $0.archiveSnapshotPaths.sorted() }.filter { seen.insert($0).inserted }
    }

    private nonisolated static func load(from defaults: UserDefaults) -> UndoJournal {
        guard let data = defaults.data(forKey: persistenceKey),
              let blob = try? JSONDecoder().decode(Persisted.self, from: data)
        else { return UndoJournal() }
        return UndoJournal(
            records: blob.undo.map(UndoEntry.fileOperation),
            redoRecords: blob.redo.map(UndoEntry.fileOperation)
        )
    }
}
