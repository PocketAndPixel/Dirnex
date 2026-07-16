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

    /// Pop the top action, moving its inverse onto the redo stack, and reverse it on a
    /// background thread. Returns the record and the reversal report so the caller can refresh
    /// the panes and message any items that couldn't be put back; `nil` when there was nothing
    /// to undo.
    func undo() async -> (record: UndoRecord, report: UndoReport)? {
        guard let record = journal.takeForUndo() else { return nil }
        return await apply(record)
    }

    /// Pop the top redo action, moving its inverse (the original operation) back onto the undo
    /// stack, and re-apply it on a background thread. `nil` when there was nothing to redo.
    func redo() async -> (record: UndoRecord, report: UndoReport)? {
        guard let record = journal.takeForRedo() else { return nil }
        return await apply(record)
    }

    /// Persist the shuffled stacks, then revert `record` off the main thread — the shared tail
    /// of `undo` and `redo`, which differ only in which stack they popped.
    private func apply(_ record: UndoRecord) async -> (record: UndoRecord, report: UndoReport) {
        persist()
        let backend = backend
        let report = await Task.detached(priority: .userInitiated) {
            UndoJournal.revert(record, using: backend)
        }.value
        return (record, report)
    }

    // MARK: - Persistence

    /// Both stacks in one blob, so redo survives relaunch alongside undo. A change from the old
    /// bare-`[UndoRecord]` shape (and the enriched `UndoStep`) means a journal written by a
    /// pre-redo build simply fails to decode and starts empty — a one-time reset, never a crash.
    private struct Persisted: Codable {
        let undo: [UndoRecord]
        let redo: [UndoRecord]
    }

    private func persist() {
        let blob = Persisted(undo: journal.records, redo: journal.redoRecords)
        guard let data = try? JSONEncoder().encode(blob) else { return }
        UserDefaults.standard.set(data, forKey: Self.persistenceKey)
    }

    private static func load() -> UndoJournal {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let blob = try? JSONDecoder().decode(Persisted.self, from: data)
        else { return UndoJournal() }
        return UndoJournal(records: blob.undo, redoRecords: blob.redo)
    }
}
