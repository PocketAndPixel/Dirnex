import AppKit
import DirnexCore

/// Joins the headless command registry (`DirnexCore.CommandCatalog`) to concrete AppKit
/// selectors. The registry owns the *what* — titles, categories, shortcuts, search keywords;
/// this table owns the *how* — the selector each command sends. Every selector is dispatched
/// to `nil` (the responder chain), exactly as the menu items always have been, so a command
/// lands on the focused pane, the key window, or the app, wherever it is implemented. The
/// menu bar and the Cmd+K palette both read from here, so neither can offer a command the
/// other can't run.
@MainActor
enum CommandBinding {
    /// The selector for `id`, or `nil` if the command has no wired action (none today).
    static func selector(for id: String) -> Selector? {
        selectors[id]
    }

    private static let selectors: [String: Selector] = [
        "file.newTab": #selector(PanelViewController.newTab(_:)),
        "file.closeTab": #selector(PanelViewController.closeCurrentTab(_:)),
        "file.openWith": #selector(PanelViewController.showOpenWithMenu(_:)),
        "file.share": #selector(PanelViewController.shareSelection(_:)),
        "file.copy": #selector(PanelViewController.copyToOtherPane(_:)),
        "file.move": #selector(PanelViewController.moveToOtherPane(_:)),
        "file.pack": #selector(PanelViewController.packSelection(_:)),
        "file.syncDirectories": #selector(PanelViewController.synchronizeDirectories(_:)),
        "file.compareByContents": #selector(PanelViewController.compareByContents(_:)),
        "file.manageScripts": #selector(PanelViewController.manageUserScripts(_:)),
        "file.tags": #selector(PanelViewController.showTagsMenu(_:)),
        "file.rename": #selector(PanelViewController.renameSelection(_:)),
        "file.multiRename": #selector(PanelViewController.multiRenameSelection(_:)),
        "file.newFolder": #selector(PanelViewController.newFolder(_:)),
        "file.trash": #selector(PanelViewController.moveSelectionToTrash(_:)),
        "file.deletePermanently": #selector(PanelViewController.deleteSelectionPermanently(_:)),
        "edit.undo": #selector(PanelViewController.undoLastOperation(_:)),
        "edit.redo": #selector(PanelViewController.redoLastOperation(_:)),
        "edit.copy": #selector(PanelViewController.copy(_:)),
        "edit.paste": #selector(PanelViewController.paste(_:)),
        "edit.pasteMove": #selector(PanelViewController.pasteAndMoveFromClipboard(_:)),
        "select.all": #selector(NSResponder.selectAll(_:)),
        "select.invert": #selector(PanelViewController.invertSelectionFiles(_:)),
        "select.byPattern": #selector(PanelViewController.selectFilesByPattern(_:)),
        "select.unselectByPattern": #selector(PanelViewController.unselectFilesByPattern(_:)),
        "view.commandPalette": #selector(AppDelegate.showCommandPalette(_:)),
        "view.toggleSidebar": #selector(NSSplitViewController.toggleSidebar(_:)),
        "view.toggleHidden": #selector(PanelViewController.toggleShowHidden(_:)),
        "view.toggleTags": #selector(PanelViewController.toggleShowTags(_:)),
        "view.toggleSyncStatus": #selector(PanelViewController.toggleShowSyncStatus(_:)),
        "view.functionBar": #selector(PanelViewController.toggleFunctionBar(_:)),
        // The focused pane, not the app: unlike Show Tags, this mode is per tab (it *spends*
        // something to be on), so it lands wherever the responder chain does.
        "view.sizeVisualization": #selector(PanelViewController.toggleSizeVisualization(_:)),
        "view.quickLook": #selector(PanelViewController.toggleQuickLookPreview(_:)),
        "view.quickView": #selector(PanelViewController.toggleQuickViewPanel(_:)),
        // The window controller, not a pane: the drawer spans both panes, and this is the one
        // command that must also fire while the *terminal* holds focus — where no pane is in the
        // responder chain, but the window controller still is.
        "view.terminal": #selector(BrowserWindowController.toggleTerminalDrawer(_:)),
        "go.openInTerminal": #selector(PanelViewController.openInTerminal(_:)),
        "go.connectServer": #selector(PanelViewController.connectToServer(_:)),
        "go.editLocation": #selector(PanelViewController.editLocation(_:)),
        "go.search": #selector(PanelViewController.findFiles(_:)),
        "go.saveSearch": #selector(PanelViewController.saveCurrentSearch(_:)),
        "go.parent": #selector(PanelViewController.goToParentDirectory(_:)),
        "go.back": #selector(PanelViewController.goBack(_:)),
        "go.forward": #selector(PanelViewController.goForward(_:)),
        "go.history": #selector(PanelViewController.showHistory(_:)),
        "go.hotlist": #selector(PanelViewController.showHotlist(_:)),
        "go.addToHotlist": #selector(PanelViewController.addToHotlist(_:)),
        "workspace.list": #selector(PanelViewController.showWorkspaces(_:)),
        "workspace.save": #selector(PanelViewController.saveWorkspace(_:)),
        "window.minimize": #selector(NSWindow.performMiniaturize(_:)),
        "window.close": #selector(NSWindow.performClose(_:)),
        "window.previousTab": #selector(PanelViewController.showPreviousTab(_:)),
        "window.nextTab": #selector(PanelViewController.showNextTab(_:)),
        "app.settings": #selector(AppDelegate.showSettings(_:)),
        "app.fullDiskAccess": #selector(AppDelegate.showFullDiskAccess(_:)),
        "app.showTour": #selector(AppDelegate.showFirstRunTour(_:)),
        "app.checkForUpdates": #selector(AppDelegate.checkForUpdates(_:)),
        "app.quit": #selector(NSApplication.terminate(_:))
    ]
}
