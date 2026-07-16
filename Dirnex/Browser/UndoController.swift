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
    case fileOperation(record: UndoRecord, report: UndoReport)
    case selection(SelectionChange)
}

@MainActor
final class UndoController {
    private static let persistenceKey = "Dirnex.undoJournal"

    private var journal: UndoJournal
    private let backend: any VFSBackend

    init(backend: any VFSBackend) {
        self.backend = backend
        journal = Self.load()
    }

    /// Whether Cmd+Z has anything to reverse right now.
    var canUndo: Bool { journal.canUndo }
    /// Whether Cmd+Shift+Z has anything to re-apply right now.
    var canRedo: Bool { journal.canRedo }

    /// The label of the action Cmd+Z would reverse next ("Move", "Copy", "Rename", …), for
    /// the menu title — or `nil` when there's nothing to undo.
    var nextLabel: String? { journal.top?.label }
    /// The label of the action Cmd+Shift+Z would re-apply next, or `nil` when there's nothing
    /// to redo.
    var nextRedoLabel: String? { journal.redoTop?.label }

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

    /// Pop the top action, moving its inverse onto the redo stack, and apply it: a file
    /// operation is reversed on a background thread and returns a report; a selection change is
    /// handed back for the window to apply on the main thread. `nil` when there was nothing to
    /// undo.
    func undo() async -> UndoOutcome? {
        await apply(journal.takeForUndo())
    }

    /// Pop the top redo action, moving its inverse (the original action) back onto the undo
    /// stack, and re-apply it. `nil` when there was nothing to redo.
    func redo() async -> UndoOutcome? {
        await apply(journal.takeForRedo())
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
            let report = await Task.detached(priority: .userInitiated) {
                UndoJournal.revert(record, using: backend)
            }.value
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
        UserDefaults.standard.set(data, forKey: Self.persistenceKey)
    }

    private static func load() -> UndoJournal {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let blob = try? JSONDecoder().decode(Persisted.self, from: data)
        else { return UndoJournal() }
        return UndoJournal(
            records: blob.undo.map(UndoEntry.fileOperation),
            redoRecords: blob.redo.map(UndoEntry.fileOperation)
        )
    }
}
