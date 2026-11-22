import AppKit
import DirnexCore

/// The palette's places and workspaces (PLAN.md §M40 Slice 1): building the rows when it opens, and
/// opening one when it is picked.
extension CommandPaletteController {
    /// The browser window the palette floats over: its sidebar says which places there are, and its
    /// panes are where a place or a workspace opens. `nil` with no browser window under the palette,
    /// which then offers commands and scripts only.
    var browser: BrowserWindowController? {
        targetWindow?.windowController as? BrowserWindowController
    }

    /// What this opening offers: the registry, the user's scripts, and the places and workspaces,
    /// joined in that order so a command keeps its place ahead of a folder with a similar name when
    /// the two score the same.
    ///
    /// Read once per opening, so a script made in the organizer, a folder just pinned or a workspace
    /// just saved is there the next time ⌘K opens.
    func commandsOffered() -> [Command] {
        let commands = LocalizedCatalog.all + UserScriptStore.load().paletteCommands
        guard let browser else { return commands }
        return commands + PalettePlaces.commands(
            groups: Self.placeGroups(of: browser),
            workspaces: WorkspaceStore.load().workspaces
        )
    }

    /// Open the place or workspace `id` names, as the stores hold it now.
    ///
    /// The id is resolved again rather than trusted, since a pin can be removed or a workspace
    /// renamed while the palette is open. One that has gone closes the palette with a beep. A place
    /// inside an unlocked vault opens and is not remembered (``PaletteDestination/isRememberable(vaultMountPoints:)``).
    ///
    /// The open waits a turn, after `dismiss()` has made the browser window key again, as a command's
    /// action does: a place lands in the active pane and puts the focus there. With `inNewTab` (⌘Return
    /// or a ⌘-click) a place opens in a new tab of that pane; a workspace has no such reading, since it
    /// sets both panes' tabs, so it opens as it does for Return.
    func runDestination(_ id: String, inNewTab: Bool = false) {
        let browser = browser
        let destination = browser.flatMap {
            PaletteDestination.resolve(
                id,
                places: Self.placeGroups(of: $0),
                workspaces: WorkspaceStore.load().workspaces
            )
        }
        if let destination, destination.isRememberable(
            vaultMountPoints: VaultMounts.shared.mountPoints
        ) {
            recents.record(id, among: offeredIDs)
        }
        dismiss()
        guard let destination, let browser else {
            NSSound.beep()
            return
        }
        DispatchQueue.main.async {
            browser.open(destination, inNewTab: inNewTab)
        }
    }

    /// Every place `browser`'s sidebar offers, from the same assembly Go ▸ Places renders.
    private static func placeGroups(of browser: BrowserWindowController) -> [SidebarPlaceGroup] {
        SidebarPlaces.groups(from: browser.sidebar.placeSources())
    }
}
