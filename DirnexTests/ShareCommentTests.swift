import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A stand-in for the NetFS enumerator, answering the shares a server pane lists.
private struct ListedShares: SMBShareEnumerating {
    let answer: [SMBShare]

    func shares() throws -> [SMBShare] { answer }
}

/// A share's comment on an SMB server's list, drawn after its name (PLAN.md §M40 Slice 8,
/// `FileCellView+Comment`), and a tab opened before its listing arrives.
///
/// The comment was a column of its own at first, which changed the tab's columns with the listing:
/// Size and Date hidden on a flat list, Comment between Name and them in a tree, where it pushed Date
/// off a narrow pane. It is part of the name now, and the columns are the user's own throughout. Each
/// pane sits in a window that is never shown, because a pane in no window has no width to fit
/// (`NameColumnFitTests`).
@MainActor
@Suite("Share comments and tabs opened on a server", .serialized)
struct ShareCommentTests {
    private static let server = SMBLocation(host: "nas", username: "dirnex-test")
    private static var root: VFSPath { VFSPath(backend: .smbServer(server), path: "/") }
    private static let homeComment = "Home directory of dirnex-test"

    @MainActor
    private final class Hosted {
        let pane: PanelViewController
        private let window: NSWindow

        /// A pane on `folder`, with its own first listing landed.
        init(folder: String = "/var/empty") async throws {
            // `/var/empty` by default: empty, and written by nothing (`NameColumnFitTests`).
            pane = PanelViewController(
                backend: CompositeBackend(local: LocalBackend()),
                restoration: nil,
                defaultPath: .local(folder),
                restorationKey: nil
            )
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: true
            )
            window.isReleasedWhenClosed = false
            window.contentViewController = pane
            window.setContentSize(NSSize(width: 800, height: 500))
            window.layoutIfNeeded()
            try await settleUntil { [pane] in pane.tabs[0].hasLoaded }
        }

        /// Stand the pane on the server's list, as a connect lands it.
        func showShares() {
            let entries = [share("home", comment: homeComment), share("media", comment: "")]
            pane.panel = Panel(
                model: DirectoryModel(listing: DirectoryListing(path: root, entries: entries))
            )
            pane.reloadEverything()
        }

        /// Register a server listing `home`, as a connect does before it lands on the list.
        func registerServer() throws {
            let composite = try #require(pane.backend as? CompositeBackend)
            composite.register(
                smbServer: SMBServerBackend(
                    server: server,
                    enumerator: ListedShares(answer: [SMBShare(name: "home", comment: homeComment)])
                ),
                password: nil
            )
        }

        var columnIDs: [String] {
            pane.tableView.tableColumns.filter { !$0.isHidden }.map(\.identifier.rawValue)
        }

        func nameCell(row: Int) -> FileCellView? {
            let index = pane.tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
            return pane.tableView(
                pane.tableView,
                viewFor: pane.tableView.tableColumns[index],
                row: row
            ) as? FileCellView
        }

        func close() {
            pane.watcher = nil
            window.contentViewController = nil
            window.close()
        }
    }

    private static func share(_ name: String, comment: String) -> FileEntry {
        FileEntry(
            path: VFSPath(backend: .smbServer(server), path: "/\(name)"),
            name: name,
            kind: .directory,
            byteSize: 0,
            modificationDate: FileEntry.unknownDate,
            creationDate: FileEntry.unknownDate,
            isHidden: false,
            permissions: 0o755,
            inode: 0,
            comment: comment
        )
    }

    /// The ink of the run starting at `location` in the cell's name label.
    private static func ink(of cell: FileCellView?, at location: Int) -> NSColor? {
        cell?.textField?.attributedStringValue.attribute(
            .foregroundColor,
            at: location,
            effectiveRange: nil
        ) as? NSColor
    }

    // MARK: - The comment

    @Test("a share's comment follows its name in a quieter ink, and the columns stay as they are")
    func commentFollowsTheName() async throws {
        let hosted = try await Hosted()
        defer { hosted.close() }

        hosted.showShares()

        #expect(hosted.columnIDs == ["name", "size", "date"])
        let home = hosted.nameCell(row: 0)
        #expect(home?.textField?.stringValue == "home" + FileCellView.commentGap + Self.homeComment)
        #expect(Self.ink(of: home, at: 0) == .labelColor)
        #expect(Self.ink(of: home, at: "home".utf16.count) == .secondaryLabelColor)
        #expect(
            hosted.nameCell(row: 1)?.textField?.stringValue == "media",
            "an empty comment is none"
        )
    }

    @Test("on the cursor's fill the comment takes the cursor's ink, and a restyle draws it once")
    func commentFollowsTheCursor() async throws {
        let hosted = try await Hosted()
        defer { hosted.close() }
        hosted.showShares()
        let home = try #require(hosted.nameCell(row: 0))
        let commentStart = "home".utf16.count
        let cursorInk = home.palette.cursorForeground

        home.backgroundStyle = .emphasized
        #expect(Self.ink(of: home, at: 0) == cursorInk)
        #expect(Self.ink(of: home, at: commentStart) == cursorInk.withAlphaComponent(0.7))

        home.backgroundStyle = .normal
        home.applyStyle()
        #expect(home.textField?.stringValue == "home" + FileCellView.commentGap + Self.homeComment)
        #expect(Self.ink(of: home, at: commentStart) == .secondaryLabelColor)
    }

    @Test("a cell recycled for a row with no comment draws its name alone")
    func recycledCellDropsTheComment() async throws {
        let hosted = try await Hosted()
        defer { hosted.close() }
        hosted.showShares()
        let home = try #require(hosted.nameCell(row: 0))

        // Taken away without the name being set again, as a restyle of the same cell would meet it.
        home.comment = nil
        home.applyStyle()

        #expect(home.textField?.stringValue == "home")
    }

    // MARK: - A tab opened before its listing arrives

    @Test("a server opened in a new tab draws itself, not the previous tab's rows")
    func newTabDrawsItself() async throws {
        let folder = try Self.folderOfTwoFiles()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let hosted = try await Hosted(folder: folder)
        defer { hosted.close() }
        try hosted.registerServer()
        let pane = hosted.pane
        #expect(pane.tableView.numberOfRows == 3, "`..` and the two files")

        pane.openInNewTab(Self.root)

        // Its listing has not landed: the pane is the new tab's, empty, and counts nothing yet.
        #expect(!pane.tabs[pane.activeTabIndex].hasLoaded)
        #expect(pane.tableView.numberOfRows == 0)
        #expect(pane.statusLabel.stringValue.isEmpty)

        try await settleUntil { pane.tabs[pane.activeTabIndex].hasLoaded }
        #expect(pane.tableView.numberOfRows == 1)
        #expect(hosted.nameCell(row: 0)?.textField?.stringValue
            == "home" + FileCellView.commentGap + Self.homeComment)
        #expect(!pane.statusLabel.stringValue.isEmpty)
    }

    @Test("a new tab on the folder already shown keeps its rows while it lists")
    func newTabOnTheSameFolderKeepsItsRows() async throws {
        let folder = try Self.folderOfTwoFiles()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let hosted = try await Hosted(folder: folder)
        defer { hosted.close() }
        let pane = hosted.pane

        pane.addTab()

        #expect(!pane.tabs[pane.activeTabIndex].hasLoaded)
        #expect(pane.tableView.numberOfRows == 3, "the same folder's rows, not an empty pane")
        try await settleUntil { pane.tabs[pane.activeTabIndex].hasLoaded }
        #expect(pane.tableView.numberOfRows == 3)
    }

    /// A temporary folder holding `a.png` and `b.md`.
    private static func folderOfTwoFiles() throws -> String {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareComment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["a.png", "b.md"] {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        return folder.path
    }
}
