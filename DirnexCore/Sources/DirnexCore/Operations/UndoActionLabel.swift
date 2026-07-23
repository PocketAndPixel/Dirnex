import Foundation

/// The name of a reversible action — shown in the menu as "Undo <label>" / "Redo <label>" and in
/// the "finished with issues" alert. It is `DirnexCore` *data*: an English ``title`` that is the
/// fallback, keyed for translation by the stable ``rawValue``, exactly like `SidebarSection`,
/// `SearchKind`, and the command registry (see `LocalizationKey`). The core ships no resources; the
/// app joins each label to its translation through `LocalizedCatalog`.
///
/// Two origins meet here. The file-operation labels (``copy``…``moveToTrash``) are authored in the
/// core by `UndoRecord`'s builders. The selection-gesture labels (``mark``…``selectRange``) are
/// authored in the app and passed *into* the core on a `SelectionChange` — the core stays
/// UI-agnostic about the gesture, but the vocabulary is finite and naming it here is what lets one
/// coverage test prove every label is translated. Making it an enum also makes a mistyped label a
/// compile error rather than a silently-untranslated magic string.
///
/// The ``rawValue`` is the stable translation key and never changes: renaming a case orphans its
/// translations in every language (caught by `LocalizationCoverageTests`), and — because a
/// file-operation record persists across relaunch — also changes the journal's on-disk form, which
/// decodes-or-resets exactly as `UndoController` documents.
public enum UndoActionLabel: String, Sendable, Equatable, Codable, CaseIterable {
    // File operations — authored in the core by `UndoRecord`'s builders.
    case copy
    case move
    case newFolder
    case rename
    case moveToTrash

    // Selection gestures — authored in the app, passed in on a `SelectionChange`.
    case mark
    case selectAll
    case invertSelection
    case selectFiles
    case unselectFiles
    case clearSelection
    case selectRange

    /// The English display name — the fallback the app shows when a translation is missing, and the
    /// only presentation a resource-free `swift test` ever sees.
    public var title: String {
        switch self {
        case .copy: return "Copy"
        case .move: return "Move"
        case .newFolder: return "New Folder"
        case .rename: return "Rename"
        case .moveToTrash: return "Move to Trash"
        case .mark: return "Mark"
        case .selectAll: return "Select All"
        case .invertSelection: return "Invert Selection"
        case .selectFiles: return "Select Files"
        case .unselectFiles: return "Unselect Files"
        case .clearSelection: return "Clear Selection"
        case .selectRange: return "Select Range"
        }
    }
}
