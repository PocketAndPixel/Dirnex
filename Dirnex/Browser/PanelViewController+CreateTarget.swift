import AppKit
import DirnexCore

/// Where a "create something here" command lands — F7 New Folder and ⇧F4 Edit File.
///
/// Two questions, kept apart because they answer different things and fail differently.
/// `writeDirectory` answers *is there a real directory under this pane at all*: `nil` for search
/// results, a browsed archive and the merged Trash, and the CloudDocs container for the merged
/// iCloud listing, which is the one virtual location with a real home underneath.
/// `Panel.cursorDirectory` answers *which* directory the cursor is standing in — the pane's own in
/// a flat list, and the folder containing the cursor's row in a tree.
///
/// A tree is the only shape where the two differ, and before it they could not: every row of a flat
/// list lives in the pane's own directory, so "the current directory" and "where the cursor is" were
/// the same sentence. A tree draws several directories at once, and creating at the root while the
/// cursor sits three levels down puts the new item somewhere the user is not looking — the created
/// row would appear off screen, or not at all if the root's own rows are scrolled away.
///
/// One property so the two commands cannot drift: a create target spelled twice is the shape
/// docs/NOTES.md keeps finding on the wrong side of a fix.
extension PanelViewController {
    /// The real directory a create lands in, or `nil` where this pane has none.
    ///
    /// Reads the cursor, so a caller invoked by a key or a menu must `reconcileCursorFromTable()`
    /// first: the table's selection is the live cursor until its change notification fires a runloop
    /// pass later, and a create straight after an arrow key would otherwise read the row the user
    /// just left — which in a tree is a different *directory*, not merely a different row. The tree's
    /// own keys reconcile first for the same reason (`PanelViewController+Tree`).
    var creationDirectory: VFSPath? {
        guard let base = writeDirectory else { return nil }
        // The `..` row belongs to no tree level — it stands for the pane's own parent — so a cursor
        // parked on it means no row is being pointed at, and the answer is the pane's own directory
        // exactly as it is in a flat list. `Panel` cannot see this flag, which is why it is asked here.
        guard panel.isTree, !cursorOnParentRow else { return base }
        return panel.cursorDirectory
    }

    /// The folder name a create dialog names, which is not always `creationDirectory`'s own.
    ///
    /// A dialog names *what the pane shows*: for the merged iCloud listing that is "iCloud Drive",
    /// never "com~apple~CloudDocs", which is a folder the user has never heard of. So only a tree —
    /// where the pane genuinely draws the deeper folder, with its own row on screen — names the
    /// directory underneath. At a tree's root level the two are the same string anyway.
    var creationDirectoryName: String {
        guard panel.isTree, let target = creationDirectory else { return panel.path.lastComponent }
        return target.lastComponent
    }
}
