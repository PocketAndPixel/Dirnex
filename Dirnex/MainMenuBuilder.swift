import AppKit
import DirnexCore

/// Builds the app's main menu from the command registry (PLAN.md §M3 "menu bar generated
/// from one action registry"). Each item's title, shortcut, and action come from
/// `CommandCatalog` + `CommandBinding` — the same source the Cmd+K palette reads — so the two
/// can never drift. Only the *layout* (which menus exist, the order, and the separators)
/// lives here, a presentation concern the registry deliberately stays out of.
///
/// The app menu keeps its standard About/Hide items hand-built (they aren't registry
/// commands a user searches for); Settings and Quit are registry commands like the rest.
///
/// Each item's key equivalent comes from the *effective* shortcut in `KeyBindingStore` — the
/// user's rebinding or the catalog default (PLAN.md §M3 "rebindable shortcuts") — so
/// regenerating the menu (which `AppDelegate` does whenever bindings change) is what makes a
/// new shortcut take effect.
@MainActor
enum MainMenuBuilder {
    static func build(bindings: KeyBindingStore = .shared) -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem(bindings: bindings))
        for spec in layout {
            mainMenu.addItem(menu(for: spec, bindings: bindings))
        }
        return mainMenu
    }

    // MARK: - Layout

    private enum Item {
        case command(String)
        /// A command shown indented under the one above it, for a setting that only qualifies
        /// that item rather than standing on its own. Purely presentational — the command,
        /// its shortcut, and its palette entry are unchanged.
        case subcommand(String)
        case separator
    }

    private struct MenuSpec {
        let title: String
        let items: [Item]
        var isWindow = false
    }

    /// The top-level menus after the app menu, mirroring the categories in the registry but
    /// owning the grouping/separators AppKit users expect. Cmd+W closes a *tab* (File);
    /// the window keeps Cmd+Shift+W (Window), matching Safari/Terminal.
    private static let layout: [MenuSpec] = [
        MenuSpec(title: "File", items: [
            .command("file.newTab"), .command("file.closeTab"), .separator,
            .command("file.openWith"), .command("file.share"), .separator,
            .command("file.copy"), .command("file.move"), .command("file.pack"),
            .command("file.syncDirectories"), .command("file.compareByContents"), .separator,
            .command("file.tags"), .command("file.manageScripts"), .separator,
            .command("file.rename"), .command("file.multiRename"), .separator,
            .command("file.newFolder"), .separator,
            .command("file.trash"), .command("file.deletePermanently")
        ]),
        MenuSpec(title: "Edit", items: [
            .command("edit.undo"), .command("edit.redo"), .separator,
            .command("edit.copy"), .command("edit.paste"), .command("edit.pasteMove")
        ]),
        MenuSpec(title: "Select", items: [
            .command("select.all"), .command("select.invert"), .separator,
            .command("select.byPattern"), .command("select.unselectByPattern")
        ]),
        MenuSpec(title: "View", items: [
            .command("view.commandPalette"), .separator,
            .command("view.toggleSidebar"), .command("view.focusSidebar"),
            .command("view.toggleHidden"),
            .command("view.toggleTags"), .command("view.toggleSyncStatus"),
            .command("view.functionBar"),
            .command("view.sizeVisualization"), .subcommand("view.gitAwareSizes"), .separator,
            .command("view.quickLook"), .command("view.quickView"), .separator,
            .command("view.terminal")
        ]),
        MenuSpec(title: "Go", items: [
            .command("go.back"), .command("go.forward"), .command("go.history"), .separator,
            .command("go.editLocation"), .command("go.parent"), .command("go.search"),
            .command("go.saveSearch"), .separator,
            .command("go.favorites"), .command("go.addToFavorites"), .separator,
            .command("go.connectServer"), .command("go.openInTerminal")
        ]),
        MenuSpec(title: "Workspace", items: [
            .command("workspace.list"), .command("workspace.save")
        ]),
        MenuSpec(title: "Window", items: [
            .command("window.minimize"), .command("window.close"), .separator,
            .command("window.previousTab"), .command("window.nextTab")
        ], isWindow: true)
    ]

    // MARK: - Building

    private static func menu(for spec: MenuSpec, bindings: KeyBindingStore) -> NSMenuItem {
        let menuItem = NSMenuItem()
        let submenu = NSMenu(title: spec.title)
        menuItem.submenu = submenu
        for item in spec.items {
            switch item {
            case .separator:
                submenu.addItem(.separator())
            case let .command(id):
                if let built = commandItem(for: id, bindings: bindings) { submenu.addItem(built) }
            case let .subcommand(id):
                if let built = commandItem(for: id, bindings: bindings) {
                    built.indentationLevel = 1
                    submenu.addItem(built)
                }
            }
        }
        if spec.isWindow {
            NSApp.windowsMenu = submenu
        }
        return menuItem
    }

    /// One menu item, fully described by the registry: title from `CommandCatalog`, effective
    /// shortcut from `KeyBindingStore`, action from `CommandBinding` (dispatched through the
    /// responder chain via a nil target).
    ///
    /// Internal so the pane's context menu is built from this same one place — a right-click item
    /// and its menu-bar twin must never be able to disagree about a title or a shortcut.
    static func commandItem(for id: String, bindings: KeyBindingStore = .shared) -> NSMenuItem? {
        guard let command = CommandCatalog.command(for: id),
              let selector = CommandBinding.selector(for: id) else { return nil }
        let shortcut = bindings.shortcut(for: id)
        let item = NSMenuItem(
            title: command.title,
            action: selector,
            keyEquivalent: shortcut?.keyEquivalent ?? ""
        )
        item.keyEquivalentModifierMask = shortcut?.modifierMask ?? []
        return item
    }

    /// The Services submenu (PLAN.md §M6), in the app menu where macOS puts it.
    ///
    /// Nothing is added to it here: handing the menu to `NSApp.servicesMenu` is the whole wiring,
    /// and AppKit fills it from the installed Services filtered by what the responder chain says it
    /// can send — which for a file pane is `PanelViewController`'s `validRequestor`/`writeSelection`
    /// answering with the marked files. It is not in the right-click menu because
    /// `NSApp.servicesMenu` is single-valued: a second copy would take the population away from
    /// this one rather than getting its own.
    private static func servicesMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Services")
        item.submenu = menu
        NSApp.servicesMenu = menu
        return item
    }

    private static func appMenuItem(bindings: KeyBindingStore) -> NSMenuItem {
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        let appName = ProcessInfo.processInfo.processName

        appMenu.addItem(
            withTitle: "About \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        if let checkForUpdates = commandItem(for: "app.checkForUpdates", bindings: bindings) {
            appMenu.addItem(checkForUpdates)
            appMenu.addItem(.separator())
        }
        if let settings = commandItem(for: "app.settings", bindings: bindings) {
            appMenu.addItem(settings)
        }
        if let fullDiskAccess = commandItem(for: "app.fullDiskAccess", bindings: bindings) {
            appMenu.addItem(fullDiskAccess)
        }
        if let tour = commandItem(for: "app.showTour", bindings: bindings) {
            appMenu.addItem(tour)
        }
        appMenu.addItem(.separator())
        appMenu.addItem(servicesMenuItem())
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide \(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        if let quit = commandItem(for: "app.quit", bindings: bindings) { appMenu.addItem(quit) }
        return appMenuItem
    }
}
