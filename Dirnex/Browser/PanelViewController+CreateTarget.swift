import DirnexCore

/// Where a "create something here" command lands — F7 New Folder and ⇧F4 Edit File.
///
/// Two questions, kept apart because they answer different things and fail differently.
/// `writeDirectory` answers *is there a real directory under this pane at all*: `nil` for search
/// results, a browsed archive and the merged Trash, and the CloudDocs container for the merged
/// iCloud listing, which is the one virtual location with a real home underneath.
/// `Panel.cursorDirectory` answers *which* directory the cursor is standing in — the pane's own in
/// a flat list and at a tree's root level, and the folder containing the cursor's row deeper down.
///
/// A tree is the only shape where the two differ, and before it they could not: every row of a flat
/// list lives in the pane's own directory, so "the current directory" and "where the cursor is" were
/// the same sentence. A tree draws several directories at once, and creating at the root while the
/// cursor sits three levels down puts the new item somewhere the user is not looking — the created
/// row would appear off screen, or not at all if the root's own rows are scrolled away.
///
/// A browsed archive has no real directory, so `writeDirectory` stays `nil` there and a writable
/// one answers through `archiveCreationDirectory` instead; `createTarget` is the two together.
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
    ///
    /// **The pane's own directory is `writeDirectory`, never `panel.path`.** The two are the same
    /// folder everywhere but the merged iCloud listing, whose path is synthetic and whose home is the
    /// CloudDocs container. `Panel.cursorDirectory` answers with `panel.path` both in a flat list and
    /// at a tree's root level, so translating that one answer is the whole rule. Taking a root-level
    /// row's parent instead is what F7 did in a tree over iCloud Drive until 2026-09-16: a loose row
    /// offered «Create a folder in “com~apple~CloudDocs”», and an app library's row, whose path is
    /// `com~apple~Pages/Documents`, pointed the create at the app's container beside `Documents`,
    /// somewhere iCloud Drive does not show.
    var creationDirectory: VFSPath? {
        guard let base = writeDirectory else { return nil }
        // The `..` row belongs to no tree level — it stands for the pane's own parent — so a cursor
        // parked on it means no row is being pointed at, and the answer is the pane's own directory
        // exactly as it is in a flat list. `Panel` cannot see this flag, which is why it is asked here.
        guard !cursorOnParentRow else { return base }
        let directory = panel.cursorDirectory
        return directory == panel.path ? base : directory
    }

    /// Where F7 and ⇧F4 create inside a browsed archive that accepts writes, or `nil` anywhere else
    /// (taken 2026-11-05; `+ArchiveCreate` makes the member).
    ///
    /// **Not folded into `creationDirectory`**, which is also what paste, drop and ⌥⌘V ask: an archive
    /// already has its own route for the first two (`+ArchiveAdd`), and ⌥⌘V into one is deliberately
    /// off. Widening that property would have turned on a gesture this one does not mean.
    ///
    /// The cursor decides the folder the way `creationDirectory` lets it: the `..` row stands for the
    /// pane's own folder, and otherwise it is the folder the cursor's row is in. A nested archive and
    /// a self-extractor answer `nil`, as every other archive write does (`isWritableArchive`).
    var archiveCreationDirectory: VFSPath? {
        guard isWritableArchive else { return nil }
        guard !cursorOnParentRow else { return panel.path }
        return panel.cursorDirectory
    }

    /// The folder F7 and ⇧F4 create in: a real directory, or a folder inside a writable archive.
    /// The one answer both commands and both their validators read.
    var createTarget: VFSPath? {
        creationDirectory ?? archiveCreationDirectory
    }

    /// Whether a create lands in the pane's own directory rather than in a folder a tree draws below
    /// it — the case where a dialog has no deeper folder to name.
    var createsInPaneDirectory: Bool {
        if let archiveTarget = archiveCreationDirectory { return archiveTarget == panel.path }
        return creationDirectory == writeDirectory
    }

    /// The folder name a create dialog names, which is not always `creationDirectory`'s own.
    ///
    /// A dialog names *what the pane shows*: for the merged iCloud listing that is "iCloud Drive",
    /// never "com~apple~CloudDocs", which is a folder the user has never heard of. So only a create
    /// into a folder a tree draws below the pane's own directory, with its own row on screen, names
    /// the directory underneath. At the root level, even of a tree, the pane is named.
    ///
    /// `displayName` rather than `lastComponent` for the same reason the tab chip uses it: at a
    /// *backend root* `lastComponent` is a bare `"/"`, so F7 on a freshly connected server offered
    /// «Create a folder in "/"» — seen live on a bucket 2026-08-13, and true of an SFTP or FTP root
    /// since those shipped. Below a root the two are the same string, so nothing else moves.
    var creationDirectoryName: String {
        guard !createsInPaneDirectory, let target = createTarget else { return panel.path.displayName }
        return target.displayName
    }
}
