import Foundation

/// How F8 and ⇧F8 resolve over the rows they would delete, when those rows need not share a
/// directory.
///
/// In a plain listing every row lives in the pane's own directory, so asking the pane and asking the
/// rows were one question. A **search snapshot** is where they part: its container is the synthetic
/// `search:` path, which can delete nothing, while every hit is an ordinary file in an ordinary
/// folder — so asking the container kept F8 gray over every search result there was. Each row's own
/// directory answers here instead, which is what F2 already asks (`renameDirectory` in the app) and
/// for the same reason. It is also the right subject in a tree, where an expanded folder can be a
/// Trash the pane's root is not.
///
/// **The weakest answer wins.** A row that cannot be deleted refuses the whole gesture, as it would
/// on its own; a row that can only be deleted for good makes the whole gesture the *confirmed*
/// permanent delete. Never the reverse: `LocalBackend` refuses to trash an item that is already in
/// a Trash (`alreadyInTrash`), so treating a mixed set as Trash-able would end in a failure report
/// for exactly the row the user could have deleted, while the permanent answer is always asked
/// first and names the count it will destroy. A mixed set is rare by
/// construction — Spotlight returns nothing inside `~/.Trash` (measured 2026-10-14: `mdls` reads a
/// trashed file, `mdfind -name` on the same name returns nothing), and a walk's hits all live on
/// the one backend it walked.
public enum DeleteRouting {
    /// The strategy for deleting every one of `paths`, each asked of the directory it lives in.
    ///
    /// - Parameters:
    ///   - paths: what the gesture would delete. Empty answers `.unsupported`, so a validator needs
    ///     no separate "is anything selected" half.
    ///   - paneDirectory: the directory to ask about a path with no parent — the root, which no
    ///     listing has as a row, so in practice it is never consulted.
    ///   - capabilities: the owning backend's answer for a directory
    ///     (`VFSBackend.capabilities(for:)`). Asked once per distinct directory rather than once per
    ///     row, so a validator over thousands of marked hits in a handful of folders stays cheap.
    public static func strategy(
        for paths: some Sequence<VFSPath>,
        paneDirectory: VFSPath,
        capabilities: (VFSPath) -> VFSCapabilities
    ) -> DeleteStrategy {
        let directories = Set(paths.map { $0.parent ?? paneDirectory })
        guard !directories.isEmpty else { return .unsupported }
        var combined = DeleteStrategy.trash
        for directory in directories {
            switch capabilities(directory).deleteStrategy {
            case .unsupported: return .unsupported
            case .permanent: combined = .permanent
            case .trash: break
            }
        }
        return combined
    }
}

public extension DeletePass.Outcome {
    /// The paths of `paths` this pass actually removed from where they were: everything that
    /// neither failed nor was refused by a volume with no Trash.
    ///
    /// Not ``restorations``' originals, which is the tempting shortcut and the wrong one. A trashed
    /// item is listed there only when the backend could say *where* it landed, and a permanent pass
    /// lists nothing at all — so a caller dropping rows by that list would leave every permanently
    /// deleted row on screen. Order follows `paths`.
    func deleted(from paths: [VFSPath]) -> [VFSPath] {
        let kept = Set(failures.map(\.path)).union(refused)
        return paths.filter { !kept.contains($0) }
    }
}
