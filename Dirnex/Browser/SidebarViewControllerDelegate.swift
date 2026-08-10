import AppKit
import DirnexCore

/// What a sidebar row's activation and its context-menu items ask the window to do.
///
/// Lifted out of `SidebarViewController.swift` when that file reached SwiftLint's 500-line ceiling,
/// and by concept rather than to shave lines: the protocol is the sidebar's *contract with the
/// window*, where the file it left is the source list's own view code. Every section — favorites,
/// servers, vaults, tags — states its verbs here, and each is implemented in the matching
/// `BrowserWindowController+…` extension.
@MainActor
protocol SidebarViewControllerDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarViewController, didActivate path: VFSPath)
    /// A saved-search row was picked — re-run its query in the active pane and show the hits in
    /// a virtual results panel (PLAN.md §M4 "Saved searches … in the places strip").
    func sidebar(_ sidebar: SidebarViewController, didActivateSavedSearch savedSearch: SavedSearch)
    /// The Recents row was picked — show recently-used files in a virtual results panel, the way a
    /// saved search does (PLAN.md §M8 "Recents row … Finder's is a saved search"). It carries no
    /// model, so it is a bare callback rather than a `didActivate…(_:)` with a payload.
    func sidebarDidActivateRecents(_ sidebar: SidebarViewController)
    /// The Trash row was picked — show every volume's trash as one merged listing (PLAN.md §M8).
    /// Like Recents it carries no model: the Trash is not a single directory to navigate to.
    func sidebarDidActivateTrash(_ sidebar: SidebarViewController)
    /// The iCloud Drive row was picked — show the CloudDocs container merged with every iCloud
    /// app's own document folder, the way Finder's iCloud Drive is assembled (PLAN.md §M9). It
    /// carries no payload for the same reason the Trash doesn't: what it opens is a merge, not the
    /// single directory the row's own path names.
    func sidebarDidActivateICloud(_ sidebar: SidebarViewController)
    /// "Empty Trash…" was chosen on the Trash row — permanently erase every volume's trash, after
    /// a confirmation naming what will go (PLAN.md §M8).
    func sidebarDidRequestEmptyTrash(_ sidebar: SidebarViewController)
    /// A saved-server row was picked — connect (SFTP) or mount (SMB) it and browse it in the active
    /// pane (PLAN.md §M5 "click → connect/mount + navigate").
    func sidebar(_ sidebar: SidebarViewController, didActivateServer server: ServerConnection)
    /// A saved-server's "Edit…" was chosen — re-open the connect prompt prefilled from it.
    func sidebar(_ sidebar: SidebarViewController, didEditServer server: ServerConnection)
    /// A vault row was picked — unlock it (asking for the passphrase) and browse it in the active
    /// pane, or, if it is already unlocked, just go there (PLAN.md §M19). One gesture for both
    /// states because the user's intent is the same either way: *open my vault*.
    func sidebar(_ sidebar: SidebarViewController, didActivateVault vault: VaultLocation)
    /// A vault's "Lock" was chosen — unmount it, moving any pane standing inside it out first.
    func sidebar(_ sidebar: SidebarViewController, didRequestLockOf vault: VaultLocation)
    /// A vault's "Rename…" was chosen, from the context menu or F2 — rename the volume itself,
    /// unlocking it first if it is locked (PLAN.md §M19). Unlike a favorite's rename this is not a
    /// row label: a vault has no name but its volume's.
    func sidebar(_ sidebar: SidebarViewController, didRequestRenameOf vault: VaultLocation)
    /// A vault's "Show in Finder When Unlocked" was toggled — save it, and apply it to the live
    /// volume if the vault happens to be open (PLAN.md §M19).
    func sidebar(
        _ sidebar: SidebarViewController,
        didSet showsInFinder: Bool,
        asShowsInFinderFor vault: VaultLocation
    )
    /// A tag row was picked — search for the files carrying it and show the hits in a virtual
    /// results panel (PLAN.md §M6 "Finder tags: … filter chips in search"), like Finder's own
    /// sidebar tags.
    func sidebar(_ sidebar: SidebarViewController, didActivateTag tag: FinderTag)
    /// A click landed on the sidebar's empty space or a non-selectable header. Keep keyboard
    /// focus on the active file pane rather than letting the source list steal it — the pane's
    /// file commands (F5/F6/F8) are dispatched through the responder chain and go dead the moment
    /// no pane is first responder.
    func sidebarDidClickEmptyArea(_ sidebar: SidebarViewController)
}
