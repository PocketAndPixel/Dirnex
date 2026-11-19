import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The Comment column on an SMB server's list of shares (PLAN.md §M40 Slice 8,
/// `PanelViewController+ShareComments`).
///
/// A flat list hides Size and Date, which a share row leaves as dashes, and gives their room to the
/// comment, so Name stays where it was; a tree keeps them, since its deeper rows are files, and pays
/// for the comment out of Name. The tab's stored columns are the user's own throughout. Each pane
/// sits in a window that is never shown, because a pane in no window has no width to fit
/// (`NameColumnFitTests`).
@MainActor
@Suite("Comment column on a list of shares", .serialized)
struct ShareCommentColumnTests {
    private static let server = SMBLocation(host: "nas", username: "dirnex-test")
    private static var root: VFSPath { VFSPath(backend: .smbServer(server), path: "/") }
    private static let homeComment = "Home directory of dirnex-test"

    private static let storedLayout = [
        ColumnLayout(id: "name", width: 300),
        ColumnLayout(id: "size", width: 90),
        ColumnLayout(id: "date", width: 131)
    ]

    @MainActor
    private final class Hosted {
        let pane: PanelViewController
        private let window: NSWindow

        init() async throws {
            // Empty, and written by nothing (`NameColumnFitTests` gives the reason).
            pane = PanelViewController(
                backend: CompositeBackend(local: LocalBackend()),
                restoration: nil,
                defaultPath: .local("/var/empty"),
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
            // The pane's own first listing lands first, so it cannot replace the one set below.
            try await settleUntil { [pane] in pane.tabs[0].hasLoaded }
            pane.tabs[pane.activeTabIndex].columnLayout = storedLayout
            pane.applyColumnLayout(for: pane.tabs[pane.activeTabIndex])
        }

        /// Stand the pane on the server's list, as a connect lands it, flat or as a tree.
        func showShares(asTree: Bool = false) {
            let entries = [
                share("home", comment: homeComment),
                share("media", comment: "")
            ]
            pane.panel = Panel(
                model: DirectoryModel(listing: DirectoryListing(path: root, entries: entries))
            )
            if asTree { pane.panel.enterTreeMode() }
            pane.reloadEverything()
        }

        /// Stand the pane back on an empty local folder.
        func showFolder() {
            let listing = DirectoryListing(path: .local("/var/empty"), entries: [])
            pane.panel = Panel(model: DirectoryModel(listing: listing))
            pane.reloadEverything()
        }

        func column(_ id: String) -> NSTableColumn? {
            let index = pane.tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(id))
            return index >= 0 ? pane.tableView.tableColumns[index] : nil
        }

        var visibleIDs: [String] {
            pane.tableView.tableColumns.filter { !$0.isHidden }.map(\.identifier.rawValue)
        }

        /// What the visible columns take, with the spacing `NSTableView` adds after each one.
        var fillsPane: Bool {
            let spacing = pane.tableView.intercellSpacing.width
            let used = pane.tableView.tableColumns.filter { !$0.isHidden }
                .reduce(0) { $0 + $1.width + spacing }
            return abs(used - pane.scrollView.contentView.bounds.width) < 0.5
        }

        /// The text the comment column draws on `row`.
        func commentCell(row: Int) -> FileCellView? {
            pane.tableView(pane.tableView, viewFor: column("comment"), row: row) as? FileCellView
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

    @Test("a flat list shows each share's comment in the room Size and Date leave")
    func flatListReplacesSizeAndDate() async throws {
        let hosted = try await Hosted()
        defer { hosted.close() }
        let nameWidth = try #require(hosted.column("name")).width
        let spacing = hosted.pane.tableView.intercellSpacing.width

        hosted.showShares()

        #expect(hosted.visibleIDs == ["name", "comment"])
        #expect(try #require(hosted.column("name")).width == nameWidth)
        #expect(try #require(hosted.column("comment")).width == 90 + 131 + spacing)
        #expect(hosted.column("comment")?.title == PanelViewController.Column.comment.title)
        #expect(hosted.fillsPane)
        #expect(hosted.commentCell(row: 0)?.textField?.stringValue == Self.homeComment)
        #expect(hosted.commentCell(row: 0)?.toolTip == Self.homeComment)
        #expect(hosted.commentCell(row: 1)?.textField?.stringValue.isEmpty == true)
        #expect(hosted.commentCell(row: 1)?.toolTip == nil)
        #expect(!hosted.pane.canShowSizeBars, "a share has no size to draw a bar of")
    }

    @Test("the tab's stored columns stay the user's own, and come back on leaving")
    func storedLayoutIsUntouched() async throws {
        let hosted = try await Hosted()
        defer { hosted.close() }
        hosted.pane.captureColumnLayout()
        let before = try #require(hosted.pane.tabs[hosted.pane.activeTabIndex].columnLayout)

        hosted.showShares()
        hosted.pane.captureColumnLayout()
        #expect(hosted.pane.tabs[hosted.pane.activeTabIndex].columnLayout == before)

        hosted.showFolder()
        #expect(hosted.visibleIDs == ["name", "size", "date"])
        #expect(hosted.column("comment") == nil)
        #expect(hosted.column("size")?.width == 90)
        #expect(hosted.column("date")?.width == 131)
        #expect(hosted.fillsPane)
        hosted.pane.captureColumnLayout()
        #expect(hosted.pane.tabs[hosted.pane.activeTabIndex].columnLayout == before)
    }

    @Test("a tab switched to on a list of shares shows the comment, not the stored columns")
    func layoutAppliedOnTheList() async throws {
        let hosted = try await Hosted()
        defer { hosted.close() }
        hosted.showShares()

        hosted.pane.applyColumnLayout(for: hosted.pane.tabs[hosted.pane.activeTabIndex])

        #expect(hosted.visibleIDs == ["name", "comment"])
        #expect(hosted.fillsPane)
    }

    @Test("a tree keeps Size and Date for the files under a share, with Comment after Name")
    func treeKeepsSizeAndDate() async throws {
        let hosted = try await Hosted()
        defer { hosted.close() }
        let nameWidth = try #require(hosted.column("name")).width
        let spacing = hosted.pane.tableView.intercellSpacing.width

        hosted.pane.captureColumnLayout()
        let before = try #require(hosted.pane.tabs[hosted.pane.activeTabIndex].columnLayout)

        hosted.showShares(asTree: true)

        #expect(hosted.visibleIDs == ["name", "comment", "size", "date"])
        #expect(hosted.column("comment")?.width == PanelViewController.Column.comment.defaultWidth)
        #expect(try #require(hosted.column("name")).width
            == nameWidth - PanelViewController.Column.comment.defaultWidth - spacing)
        #expect(hosted.fillsPane)
        #expect(hosted.pane.canShowSizeBars)
        // Name is narrower by the comment's room, and the stored Name is not.
        hosted.pane.captureColumnLayout()
        #expect(hosted.pane.tabs[hosted.pane.activeTabIndex].columnLayout == before)

        // Leaving the tree for the flat list on the same listing hides them.
        hosted.pane.panel.exitTreeMode()
        hosted.pane.reloadEverything()
        #expect(hosted.visibleIDs == ["name", "comment"])
        #expect(try #require(hosted.column("name")).width == nameWidth)
        #expect(hosted.fillsPane)
    }
}
