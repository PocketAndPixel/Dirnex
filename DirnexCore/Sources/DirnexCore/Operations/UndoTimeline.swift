import Foundation

// The unified Cmd+Z timeline (PLAN.md §M2 "Undo journal"). The journal used to hold only
// byte-touching file operations; a selection change is a second, *non*-byte-touching kind of
// action that now rides the same stack so a single Cmd+Z walks back through everything the
// user did — marks included — in the order they did it.
//
// Reverting the two is nothing alike: a file op drives a `VFSBackend` (`UndoJournal.revert`),
// while a selection change just swaps a pane's in-memory marks. So the journal stays dumb — it
// only shuffles and inverts `UndoEntry`s — and the app dispatches on the case to apply one.

// MARK: - Pane identity

/// Which of the two panes a marking change belongs to, so a reverted selection is routed back
/// to the pane it came from. The headless core is otherwise UI-agnostic, but a dual-pane layout
/// is the app's defining shape (PLAN.md §1) and a selection entry is meaningless without knowing
/// whose marks it restores.
public enum PaneSide: String, Sendable, Codable {
    case left
    case right
}

// MARK: - Selection change

/// A recorded change to one pane's marks, for the unified undo timeline.
///
/// Unlike an `UndoRecord`, applying this touches *no bytes* — it assigns a pane's selection set
/// — so it never drives a `VFSBackend`. It is invertible by swapping the two mark sets, which is
/// exactly what makes Redo fall out for free, the same way it does for a file operation: undoing
/// pushes the inverse onto redo, redoing reverts that (re-marking) and pushes the original back.
///
/// The convention matches `UndoRecord`'s steps: **applying the entry undoes the gesture**, so the
/// set to install on apply is the *pre-change* marks (`priorSelection`).
public struct SelectionChange: Sendable, Equatable, Codable {
    /// The pane whose marks changed.
    public let pane: PaneSide
    /// The directory the pane showed when the change happened. Recorded so the app can tell
    /// whether the pane still shows it at undo time and decline to apply marks from a directory
    /// the user has since left — the marks are path-keyed, so applying them elsewhere is inert
    /// anyway, but silently doing nothing visible is worse than not touching the current view.
    public let directory: VFSPath
    /// The marks as they were *before* the gesture — the set Undo restores.
    public let priorSelection: Set<VFSPath>
    /// The marks the gesture produced — the set Redo restores.
    public let newSelection: Set<VFSPath>
    /// The gesture's name, shown in the menu as "Undo \(label)" ("Mark", "Select All",
    /// "Invert Selection", "Select Files", "Unselect Files", "Clear Selection", "Select Range").
    public let label: String

    public init(
        pane: PaneSide,
        directory: VFSPath,
        priorSelection: Set<VFSPath>,
        newSelection: Set<VFSPath>,
        label: String
    ) {
        self.pane = pane
        self.directory = directory
        self.priorSelection = priorSelection
        self.newSelection = newSelection
        self.label = label
    }

    /// The marks to install when this entry is *applied* — the pre-change set, so applying it
    /// reverses the gesture (the same "apply == revert" convention `UndoRecord.steps` follow).
    public var selectionToApply: Set<VFSPath> { priorSelection }

    /// The change that reverses this one: the two mark sets swapped, so applying the inverse
    /// installs `newSelection`. One swap drives both undo and redo (see `UndoEntry.inverted`).
    var inverse: SelectionChange {
        SelectionChange(
            pane: pane,
            directory: directory,
            priorSelection: newSelection,
            newSelection: priorSelection,
            label: label
        )
    }
}

// MARK: - Timeline entry

/// One entry on the window's single undo timeline: either a byte-touching file operation or an
/// in-memory selection change. The journal shuffles and inverts these; the app reads the case to
/// decide *how* to apply one (drive the backend vs. set a pane's marks).
public enum UndoEntry: Sendable, Equatable, Codable {
    case fileOperation(UndoRecord)
    case selection(SelectionChange)

    /// The menu label of whichever action this is ("Move", "Select All", …).
    public var label: String {
        switch self {
        case let .fileOperation(record): return record.label
        case let .selection(change): return change.label
        }
    }

    /// The file-operation record, or `nil` for a selection entry. The app routes on this: a file
    /// op goes to the byte-reverting executor, a selection entry to the pane's mark setter.
    public var fileOperation: UndoRecord? {
        if case let .fileOperation(record) = self { return record }
        return nil
    }

    /// The selection change, or `nil` for a file operation.
    public var selection: SelectionChange? {
        if case let .selection(change) = self { return change }
        return nil
    }

    /// Only file operations survive relaunch; selection marks are session state that references
    /// a directory listing which may not even exist next launch, so it is never persisted.
    var isPersistable: Bool {
        if case .fileOperation = self { return true }
        return false
    }

    /// The entry that reverses this one — a file op or a selection, each inverted its own way.
    var inverted: UndoEntry {
        switch self {
        case let .fileOperation(record): return .fileOperation(record.inverted)
        case let .selection(change): return .selection(change.inverse)
        }
    }
}
