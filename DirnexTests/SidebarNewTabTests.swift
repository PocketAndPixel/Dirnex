import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Opening a sidebar place in a new tab: ⌘-click on a row, or ⌘Return on the row the keyboard has
/// selected.
///
/// The claim is about routing, and each half is pinned where it is decided: the source list reads ⌘
/// off the event it was handed, the sidebar carries it through its one activation funnel to the
/// window's verbs, and the pane puts what a new tab needs onto *that* tab. What the window then does
/// with each verb is a navigation, which this target cannot run without listing real places, so it
/// was verified in the running app.
///
/// Nothing here writes a store: a header click is recorded rather than allowed to fold, because
/// folding writes the collapse state of the developer's own sidebar (docs/NOTES.md ▸ Testing).
@Suite("Sidebar opens in a new tab")
@MainActor
struct SidebarNewTabTests {
    private let mount = CloudStorageMount(
        directoryName: "Dropbox-Home",
        providerID: "Dropbox",
        accountLabel: "Home",
        name: "Dropbox",
        path: .local("/Users/u/Library/CloudStorage/Dropbox-Home")
    )
    private let favorite = FavoriteEntry(path: .local("/Users/u/Work"))

    private func loadedSidebar(
        rows: [SidebarViewController.Row] = []
    ) -> (SidebarViewController, ActivationRecorder) {
        let sidebar = SidebarViewController()
        sidebar.loadView()
        let recorder = ActivationRecorder()
        sidebar.delegate = recorder
        sidebar.rows = rows
        sidebar.tableView.reloadData()
        return (sidebar, recorder)
    }

    // MARK: - The keyboard

    private func returnKey(
        _ modifiers: NSEvent.ModifierFlags,
        keypad: Bool = false
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: keypad ? "\u{3}" : "\r",
            charactersIgnoringModifiers: keypad ? "\u{3}" : "\r",
            isARepeat: false,
            keyCode: keypad ? 76 : 36
        ))
    }

    @Test("⌘Return and ⌘Enter ask for a new tab; Return and Enter alone do not")
    func commandReturnAsksForANewTab() throws {
        let table = SidebarTableView()
        var asked: [Bool] = []
        table.onActivateSelection = { asked.append($0) }

        table.keyDown(with: try returnKey([]))
        table.keyDown(with: try returnKey(.command))
        table.keyDown(with: try returnKey([], keypad: true))
        table.keyDown(with: try returnKey(.command, keypad: true))
        #expect(asked == [false, true, false, true])
    }

    @Test("⌘Return on a selected row opens its place in a new tab")
    func commandReturnOpensTheSelectedRow() throws {
        let (sidebar, recorder) = loadedSidebar(rows: [.place(.cloudMount(mount))])
        sidebar.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        sidebar.tableView.keyDown(with: try returnKey(.command))
        sidebar.tableView.keyDown(with: try returnKey([]))
        #expect(recorder.events == ["\(mount.path.path) new-tab", mount.path.path])
    }

    /// ⌘Return only reaches `keyDown` if nothing ahead of it claims the chord: the menu bar is
    /// searched for key equivalents first, and an item bound to it would take the key from every
    /// view in the window.
    @Test("no menu item claims ⌘Return, so it reaches the sidebar")
    func noMenuItemClaimsCommandReturn() {
        let claimants = Self.flatten(MainMenuBuilder.build()).filter {
            $0.keyEquivalent == "\r" && $0.keyEquivalentModifierMask.contains(.command)
        }
        #expect(claimants.map(\.title) == [])
    }

    private static func flatten(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(flatten) ?? []) }
    }

    // MARK: - The mouse

    /// A sidebar laid out in a window, so a click's location resolves to a row. Kept for the life of
    /// the process (docs/NOTES.md ▸ Testing).
    private static var windows: [NSWindow] = []

    @MainActor
    private struct LaidOut {
        let sidebar: SidebarViewController
        let recorder: ActivationRecorder
        let window: NSWindow

        var table: SidebarTableView { sidebar.tableView }

        /// A left-mouse-down at the middle of `row`, holding `modifiers`.
        func click(row: Int, _ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            let rect = table.rect(ofRow: row)
            let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            return try #require(NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: point,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ))
        }
    }

    private func laidOut(_ rows: [SidebarViewController.Row]) -> LaidOut {
        let (sidebar, recorder) = loadedSidebar(rows: rows)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        Self.windows.append(window)
        window.contentView = sidebar.view
        window.layoutIfNeeded()
        sidebar.tableView.layoutSubtreeIfNeeded()
        return LaidOut(sidebar: sidebar, recorder: recorder, window: window)
    }

    @Test("⌘-click on a row opens its place in a new tab and selects the row")
    func commandClickOpensInANewTab() throws {
        let fixture = laidOut([
            .header(.favorites), .place(.favorite(favorite)), .place(.cloudMount(mount))
        ])
        let table = fixture.table
        // The click must land on the row it is aimed at, or the rest proves nothing.
        let aimed = try fixture.click(row: 2, .command)
        #expect(table.row(at: table.convert(aimed.locationInWindow, from: nil)) == 2)

        table.mouseDown(with: aimed)
        #expect(fixture.recorder.events == ["\(mount.path.path) new-tab"])
        // A single-selection table reads ⌘ as "toggle", which would have left nothing selected.
        #expect(table.selectedRow == 2)

        table.mouseDown(with: try fixture.click(row: 1, .command))
        #expect(fixture.recorder.events.last == "favorite new-tab")
        #expect(table.selectedRow == 1)
    }

    @Test("⌘-click on a header folds it, as a plain click does, and opens nothing")
    func commandClickOnAHeaderFolds() throws {
        // A header below an item, the real sidebar's shape (Recents comes first). A source-list group
        // row placed *first* answers `row(at:)` with -1 at the middle of its own `rect(ofRow:)` in a
        // headless window, which would measure the fixture rather than the click.
        let fixture = laidOut([
            .place(.cloudMount(mount)), .header(.favorites), .place(.favorite(favorite))
        ])
        var folded: [Int] = []
        fixture.table.onHeaderClick = { folded.append($0) }

        let aimed = try fixture.click(row: 1, .command)
        let table = fixture.table
        #expect(table.row(at: table.convert(aimed.locationInWindow, from: nil)) == 1)

        table.mouseDown(with: aimed)
        #expect(folded == [1])
        #expect(fixture.recorder.events.isEmpty)
    }

    // MARK: - The sidebar's funnel

    @Test("every place that replaces a listing carries the new-tab request to the window")
    func placesCarryTheRequest() {
        let (sidebar, recorder) = loadedSidebar()
        let server = ServerConnection(
            name: "NAS",
            endpoint: .sftp(
                location: SFTPLocation(host: "example.com", username: "u"),
                authentication: .key(identityFile: "/Users/u/.ssh/id_ed25519")
            )
        )
        let vault = VaultLocation(imagePath: "/Users/u/Secret.sparsebundle", volumeName: "Secret")
        let places: [SidebarPlace] = [
            .cloudMount(mount), .favorite(favorite), .iCloudDrive(.local("/Users/u/iCloud")),
            .photos, .server(server), .vault(vault)
        ]

        for place in places { sidebar.activate(place, inNewTab: true) }
        #expect(recorder.events == [
            "\(mount.path.path) new-tab", "favorite new-tab", "icloud new-tab", "photos new-tab",
            "server new-tab", "vault new-tab"
        ])

        // The narrowness half: without ⌘ every one of them stays in the tab it was picked in.
        recorder.events = []
        for place in places { sidebar.activate(place) }
        #expect(
            recorder.events == [mount.path.path, "favorite", "icloud", "photos", "server", "vault"]
        )
    }

    /// Recents and the Trash open a results tab on every click, so ⌘ must still open them — once.
    @Test("a place that always opens its own tab still opens under ⌘")
    func resultsPlacesStillOpen() {
        let (sidebar, recorder) = loadedSidebar()
        sidebar.activate(.recents, inNewTab: true)
        sidebar.activate(.trash, inNewTab: true)
        #expect(recorder.events == ["recents", "trash"])
    }

    // MARK: - The pane

    private static let endpoint = ServerEndpoint.sftp(
        location: SFTPLocation(host: "example.com", username: "u"),
        authentication: .key(identityFile: "/Users/u/.ssh/id_ed25519")
    )

    /// The view is never loaded and the tab is opened in the background, so nothing lists and no
    /// connection is made (`FavoriteReconnectTests` states why that matters).
    private static func pane() -> PanelViewController {
        let here = VFSPath.local(NSTemporaryDirectory())
        let vc = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: here,
            restorationKey: nil
        )
        vc.panel = Panel(path: here)
        return vc
    }

    @Test("a pin's connection goes on the new tab, and the tab it was opened from keeps its own")
    func pendingConnectionLandsOnTheNewTab() {
        let vc = Self.pane()
        let remote = VFSPath(
            backend: .sftp(SFTPLocation(host: "example.com", username: "u")),
            path: "/var/log"
        )
        let pin = FavoriteEntry(name: "Logs", path: remote, endpoint: Self.endpoint)

        vc.openInNewTab(remote, activate: false, pendingConnection: vc.pendingConnection(for: pin))
        #expect(vc.tabs.count == 2)
        #expect(vc.tabs[1].panel.path == remote)
        #expect(vc.tabs[1].pendingConnection == Self.endpoint)
        #expect(vc.tabs[0].pendingConnection == nil)
    }

    @Test("deciding a pin's connection records nothing on the active tab")
    func decidingRecordsNothing() {
        let vc = Self.pane()
        let remote = VFSPath(
            backend: .sftp(SFTPLocation(host: "example.com", username: "u")),
            path: "/var/log"
        )
        let pin = FavoriteEntry(name: "Logs", path: remote, endpoint: Self.endpoint)
        #expect(vc.pendingConnection(for: pin) == Self.endpoint)
        #expect(vc.tabs[0].pendingConnection == nil)
    }
}

/// Records which verb the sidebar asked the window for, and whether it asked for a new tab.
@MainActor
private final class ActivationRecorder: SidebarViewControllerDelegate {
    var events: [String] = []

    private func record(_ name: String, _ inNewTab: Bool) {
        events.append(inNewTab ? "\(name) new-tab" : name)
    }

    func sidebar(_ sidebar: SidebarViewController, didActivate path: VFSPath, inNewTab: Bool) {
        record(path.path, inNewTab)
    }

    func sidebar(
        _ sidebar: SidebarViewController,
        didActivateFavorite entry: FavoriteEntry,
        inNewTab: Bool
    ) {
        record("favorite", inNewTab)
    }

    func sidebarDidActivateICloud(_ sidebar: SidebarViewController, inNewTab: Bool) {
        record("icloud", inNewTab)
    }

    func sidebarDidActivatePhotos(_ sidebar: SidebarViewController, inNewTab: Bool) {
        record("photos", inNewTab)
    }

    func sidebar(
        _ sidebar: SidebarViewController,
        didActivateServer server: ServerConnection,
        inNewTab: Bool
    ) {
        record("server", inNewTab)
    }

    func sidebar(
        _ sidebar: SidebarViewController,
        didActivateVault vault: VaultLocation,
        inNewTab: Bool
    ) {
        record("vault", inNewTab)
    }

    func sidebarDidActivateRecents(_ sidebar: SidebarViewController) { events.append("recents") }
    func sidebarDidActivateTrash(_ sidebar: SidebarViewController) { events.append("trash") }

    func sidebar(_ sidebar: SidebarViewController, didActivateSavedSearch savedSearch: SavedSearch) {}
    func sidebarDidRequestEmptyTrash(_ sidebar: SidebarViewController) {}
    func sidebar(_ sidebar: SidebarViewController, didEditServer server: ServerConnection) {}
    func sidebar(_ sidebar: SidebarViewController, didRequestLockOf vault: VaultLocation) {}
    func sidebar(_ sidebar: SidebarViewController, didRequestRenameOf vault: VaultLocation) {}
    func sidebar(_ sidebar: SidebarViewController, didActivateTag tag: FinderTag) {}
    func sidebarDidClickEmptyArea(_ sidebar: SidebarViewController) {}
}
