import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A folder dragged into the sidebar from a pane or from Finder, on the board a real drag leaves
/// (PLAN.md §M38 Slice 4).
///
/// Which rows make a pin is the core's and tested there. What is pinned here is the reading: that a
/// drag reaches the sidebar at all, that a server's folder is found on a board with no file URL, and
/// that a selection keeps its rows and its order.
///
/// Nothing here accepts a drop, since `acceptDrop` writes `FavoritesStore`, which in this target is
/// the developer's own sidebar (docs/NOTES.md ▸ Testing). Every endpoint is a key account, so nothing
/// touches the Keychain.
@Suite("A folder dragged into the sidebar")
@MainActor
struct SidebarFolderDropTests {
    private static let location = SFTPLocation(host: "example.com", username: "oleg")
    private static let endpoint = ServerEndpoint.sftp(
        location: location,
        authentication: .key(identityFile: "/Users/oleg/.ssh/id_ed25519")
    )
    private static var serverFolder: VFSPath {
        VFSPath(backend: .sftp(location), path: "/var/log")
    }

    private static var serverFile: VFSPath {
        VFSPath(backend: .sftp(location), path: "/var/log/system.log")
    }

    /// Held here because the sidebar's delegate is weak.
    private let answers = EndpointAnswers(endpoints: [location.backendID: endpoint])

    private func row(_ path: VFSPath, kind: FileEntry.Kind = .directory) -> FileEntry {
        FileEntry(
            path: path,
            name: path.lastComponent,
            kind: kind,
            byteSize: 0,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: false,
            permissions: 0o755,
            inode: 3
        )
    }

    /// A sidebar whose Favorites section is on screen.
    private func makeSidebar(pins: [FavoriteEntry] = []) -> SidebarViewController {
        let sidebar = SidebarViewController()
        sidebar.loadView()
        sidebar.delegate = answers
        sidebar.rows = [.header(.favorites)] + pins.map { .place(.favorite($0)) }
        sidebar.tableView.reloadData()
        return sidebar
    }

    private func withBoard(
        named name: String,
        _ body: (NSPasteboard) throws -> Void
    ) rethrows {
        let board = NSPasteboard(name: NSPasteboard.Name("app.dirnex.tests.sidebar-drop.\(name)"))
        board.clearContents()
        defer { board.releaseGlobally() }
        try body(board)
    }

    private func validate(
        _ sidebar: SidebarViewController,
        _ board: NSPasteboard,
        proposedRow: Int = 1
    ) -> NSDragOperation {
        sidebar.tableView(
            sidebar.tableView,
            validateDrop: StubDraggingInfo(board: board, mask: [.copy, .move]),
            proposedRow: proposedRow,
            proposedDropOperation: .above
        )
    }

    private func pins(
        _ sidebar: SidebarViewController,
        _ board: NSPasteboard
    ) -> [FavoriteEntry] {
        sidebar.droppedPins(from: StubDraggingInfo(board: board, mask: [.copy, .move]))
    }

    // MARK: - Reaching the sidebar

    /// Without this type on the table AppKit never calls `validateDrop` for a row with no file URL,
    /// so a server's folder would draw no insertion line, whatever the code below it does.
    @Test("the sidebar listens for a pane's rows")
    func registersThePanePayload() {
        let sidebar = makeSidebar()
        let types = sidebar.tableView.registeredDraggedTypes
        #expect(types.contains(PanelPasteboard.locationsType))
        #expect(types.contains(.fileURL))
        #expect(types.contains(SidebarViewController.reorderRowType))
    }

    // MARK: - A folder on a server

    /// The writer a real drag uses for such a row, a promise and not a plain item.
    @Test("a server's folder is offered to the sidebar by the promise a drag writes")
    func promisedFolderPins() throws {
        let sidebar = makeSidebar()
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: Self.serverFolder,
            restorationKey: nil
        )
        let folder = row(Self.serverFolder)
        try withBoard(named: "promise") { board in
            let writers = PanelPasteboard.dragWriters(
                for: [folder],
                routes: [folder.path: .downloadFolder],
                promisedTo: pane
            )
            try #require(writers.first is RemoteFilePromiseProvider)
            #expect(board.writeObjects(writers))

            #expect(validate(sidebar, board) == .copy)
            let pin = try #require(pins(sidebar, board).first)
            #expect(pin.path == Self.serverFolder)
            #expect(pin.serverEndpoint == Self.endpoint)
        }
    }

    @Test("a server's file draws no insertion line")
    func serverFileIsRefused() {
        let sidebar = makeSidebar()
        withBoard(named: "file") { board in
            board.writeObjects(PanelPasteboard.items(for: [row(Self.serverFile, kind: .file)]))
            #expect(validate(sidebar, board).isEmpty)
            #expect(pins(sidebar, board).isEmpty)
        }
    }

    /// A pin with no way to reconnect would draw in the sidebar and never open after a relaunch.
    @Test("a server's folder nobody can say how to reconnect draws no insertion line")
    func folderWithNoEndpointIsRefused() {
        answers.endpoints = [:]
        let sidebar = makeSidebar()
        withBoard(named: "no-endpoint") { board in
            board.writeObjects(PanelPasteboard.items(for: [row(Self.serverFolder)]))
            #expect(validate(sidebar, board).isEmpty)
        }
    }

    // MARK: - A selection

    /// Read from the file URLs, the same drag would lose its server rows in silence and still pin.
    @Test("a selection keeps its local and server folders in order and leaves its files out")
    func mixedSelectionKeepsOrder() {
        let sidebar = makeSidebar()
        let local = VFSPath.local(NSTemporaryDirectory()).appending("Pinned")
        let selection = [
            row(local),
            row(Self.serverFile, kind: .file),
            row(Self.serverFolder)
        ]
        withBoard(named: "mixed") { board in
            board.writeObjects(PanelPasteboard.items(for: selection))
            #expect(pins(sidebar, board).map(\.path) == [local, Self.serverFolder])
            #expect(pins(sidebar, board).map(\.serverEndpoint) == [nil, Self.endpoint])
        }
    }

    // MARK: - What was already true

    @Test("a folder from Finder still pins, and a file beside it still does not")
    func finderBoardStillPins() throws {
        let sidebar = makeSidebar()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarFolderDropTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try Data("x".utf8).write(to: file)

        withBoard(named: "finder") { board in
            board.writeObjects([root as NSURL, file as NSURL])
            #expect(validate(sidebar, board) == .copy)
            #expect(pins(sidebar, board).map(\.path) == [.local(root.path)])
            #expect(pins(sidebar, board).first?.endpoint == nil)
        }
    }

    /// A row's own reorder payload is read first, so it is a move and never a pin.
    @Test("a sidebar row dragged within its section is still a reorder")
    func reorderIsNotAPin() {
        let pinned = [
            FavoriteEntry(path: .local("/Users/oleg/One")),
            FavoriteEntry(path: .local("/Users/oleg/Two"))
        ]
        let sidebar = makeSidebar(pins: pinned)
        withBoard(named: "reorder") { board in
            let item = NSPasteboardItem()
            item.setString(
                "\(SidebarSection.favorites.rawValue):1",
                forType: SidebarViewController.reorderRowType
            )
            board.writeObjects([item])
            #expect(validate(sidebar, board, proposedRow: 3) == .move)
        }
    }

    @Test("a board holding nothing the sidebar can use draws no insertion line")
    func foreignBoardIsRefused() {
        let sidebar = makeSidebar()
        withBoard(named: "foreign") { board in
            board.setString("just text", forType: .string)
            #expect(validate(sidebar, board).isEmpty)
        }
    }

    // MARK: - Where the endpoint comes from

    /// The composite answers, not the tab, which is why it does not matter which pane is active or
    /// what its tab is showing when a row is dragged in from the other one.
    @Test("a pane answers for a connection its active tab is not showing")
    func paneAnswersFromTheLiveConnection() {
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: .local(NSTemporaryDirectory()),
            restorationKey: nil
        )
        pane.panel = Panel(path: .local(NSTemporaryDirectory()))
        pane.tabs[0].pendingConnection = Self.endpoint
        // Registers the connection on the composite: bookkeeping only, no round trip.
        #expect(pane.canListAfterReconnecting(to: Self.serverFolder, unasked: false, floor: 0))
        pane.tabs[0].pendingConnection = nil

        #expect(pane.tabs[0].endpoint(for: Self.serverFolder.backend) == nil)
        #expect(pane.reconnectEndpoint(for: pane.tabs[0], at: Self.serverFolder) == Self.endpoint)
    }
}

/// Answers for the endpoints it was given; every verb is ignored.
@MainActor
private final class EndpointAnswers: SidebarViewControllerDelegate {
    var endpoints: [VFSBackendID: ServerEndpoint]

    init(endpoints: [VFSBackendID: ServerEndpoint]) {
        self.endpoints = endpoints
    }

    func sidebar(
        _ sidebar: SidebarViewController,
        reconnectEndpointFor path: VFSPath
    ) -> ServerEndpoint? {
        endpoints[path.backend]
    }

    func sidebar(_ sidebar: SidebarViewController, didActivate path: VFSPath, inNewTab: Bool) {}
    func sidebarDidActivateICloud(_ sidebar: SidebarViewController, inNewTab: Bool) {}
    func sidebarDidActivatePhotos(_ sidebar: SidebarViewController, inNewTab: Bool) {}
    func sidebar(
        _ sidebar: SidebarViewController,
        didActivateFavorite entry: FavoriteEntry,
        inNewTab: Bool
    ) {}
    func sidebar(
        _ sidebar: SidebarViewController,
        didActivateSavedSearch savedSearch: SavedSearch,
        inNewTab: Bool
    ) {}
    func sidebarDidActivateRecents(_ sidebar: SidebarViewController, inNewTab: Bool) {}
    func sidebarDidActivateTrash(_ sidebar: SidebarViewController, inNewTab: Bool) {}
    func sidebarDidRequestEmptyTrash(_ sidebar: SidebarViewController) {}
    func sidebar(
        _ sidebar: SidebarViewController,
        didActivateServer server: ServerConnection,
        inNewTab: Bool
    ) {}
    func sidebar(_ sidebar: SidebarViewController, didEditServer server: ServerConnection) {}
    func sidebar(
        _ sidebar: SidebarViewController,
        didActivateVault vault: VaultLocation,
        inNewTab: Bool
    ) {}
    func sidebar(_ sidebar: SidebarViewController, didRequestLockOf vault: VaultLocation) {}
    func sidebar(_ sidebar: SidebarViewController, didRequestRenameOf vault: VaultLocation) {}
    func sidebar(_ sidebar: SidebarViewController, didActivateTag tag: FinderTag, inNewTab: Bool) {}
    func sidebarDidClickEmptyArea(_ sidebar: SidebarViewController) {}
}
