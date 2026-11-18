import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Recents shows and sorts by when each file was last opened, under a Date column titled Last Opened
/// (PLAN.md §M40 Slice 2), and every other listing keeps Date Modified.
///
/// The core pins the order and the parse (`RecentsListingTests`). What is pinned here is the pane's:
/// the header's title and sort indicator following the listing on screen, through a landing, ⌘[ and
/// a tab switch, and the cells drawing the last-opened date rather than the modification date.
@MainActor
@Suite("Recents shows when each file was last opened")
struct RecentsLastOpenedTests {
    @MainActor
    private struct Fixture {
        let directory: URL
        let pane: PanelViewController

        var folder: VFSPath { .local(directory.path) }

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("RecentsLastOpenedTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in ["a.txt", "b.txt"] {
                try Data("x".utf8).write(to: directory.appendingPathComponent(name))
            }
            pane = PanelViewController(
                backend: CompositeBackend(local: LocalBackend()),
                restoration: nil,
                defaultPath: .local(directory.path),
                restorationKey: nil
            )
            // Loaded now, as in `ResultsInPlaceTests`: a landing focuses the table, which would load
            // the view then and re-list the tab in front.
            pane.loadViewIfNeeded()
            NotificationCenter.default.removeObserver(pane)
        }

        func remove() {
            pane.watcher = nil
            try? FileManager.default.removeItem(at: directory)
        }

        func go(to path: VFSPath) async throws {
            pane.navigate(to: path)
            try await settled(on: path)
        }

        func settled(on path: VFSPath) async throws {
            try await settleUntil {
                pane.panel.path == path && pane.tabs[pane.activeTabIndex].hasLoaded
                    && pane.tabs[pane.activeTabIndex].history.walk == nil
            }
        }

        /// A video watched today that was written last year, and a report written yesterday that was
        /// last opened a fortnight ago: by modification they sort the other way round.
        var hits: [FileEntry] {
            [
                hit("report.txt", modified: 1_763_380_800, opened: 1_762_000_000),
                hit("video.mov", modified: 1_735_725_600, opened: 1_763_467_200)
            ]
        }

        private func hit(_ name: String, modified: TimeInterval, opened: TimeInterval) -> FileEntry {
            FileEntry(
                path: .local(directory.appendingPathComponent("elsewhere/\(name)").path),
                name: name,
                kind: .file,
                byteSize: 1,
                modificationDate: Date(timeIntervalSince1970: modified),
                creationDate: Date(timeIntervalSince1970: modified),
                isHidden: false,
                permissions: 0o644,
                inode: 9
            ).withLastUsedDate(Date(timeIntervalSince1970: opened))
        }

        func landRecents(over target: PanelViewController.ResultsTarget?) {
            pane.landResults(
                hits,
                as: .init(
                    pathSummary: PanelViewController.ResultsPresentation.recentsIdentity,
                    sort: RecentsQuery.resultSort,
                    query: nil,
                    scope: nil,
                    title: "Recents"
                ),
                over: target
            )
        }

        private func tableColumn(_ column: PanelViewController.Column) -> NSTableColumn? {
            pane.tableView.tableColumns.first { $0.identifier.rawValue == column.rawValue }
        }

        var dateTitle: String? { tableColumn(.date)?.title }

        /// The column carrying a sort indicator, and which way it points.
        var indicator: (column: PanelViewController.Column, ascending: Bool)? {
            let ascending = NSImage(named: "NSAscendingSortIndicator")
            for column in [PanelViewController.Column.name, .size, .date] {
                guard let tableColumn = tableColumn(column),
                      let image = pane.tableView.indicatorImage(in: tableColumn) else { continue }
                return (column, image == ascending)
            }
            return nil
        }

        /// What the Date column draws on `row`.
        func dateText(row: Int) -> String? {
            let index = pane.tableView.column(
                withIdentifier: NSUserInterfaceItemIdentifier(
                    PanelViewController.Column.date.rawValue
                )
            )
            let cell = pane.tableView.view(atColumn: index, row: row, makeIfNecessary: true)
            return (cell as? FileCellView)?.textField?.stringValue
        }
    }

    @Test("Recents lists by last opened, under Last Opened, newest first, and draws that date")
    func recentsShowsLastOpened() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pane = fixture.pane
        try await fixture.go(to: fixture.folder)
        #expect(fixture.dateTitle == PanelViewController.Column.date.title)

        fixture.landRecents(over: pane.resultsTarget(inNewTab: false))
        #expect(fixture.dateTitle == PanelViewController.Column.lastOpenedTitle)
        #expect(fixture.indicator?.column == .date)
        #expect(fixture.indicator?.ascending == false)
        #expect(pane.panel.model.visibleEntries.map(\.name) == ["video.mov", "report.txt"])

        // The date drawn is the last-opened one, spelled as the column spells any date: the same
        // formatter given that instant as a modification date.
        for (row, entry) in pane.panel.model.visibleEntries.enumerated() {
            let opened = try #require(entry.lastUsedDate)
            let asModified = FileEntry(
                path: entry.path,
                name: entry.name,
                kind: .file,
                byteSize: 1,
                modificationDate: opened,
                creationDate: opened,
                isHidden: false,
                permissions: 0o644,
                inode: 9
            )
            #expect(fixture.dateText(row: row) == FileFormatting.dateString(for: asModified))
            #expect(fixture.dateText(row: row) != FileFormatting.dateString(for: entry))
        }
    }

    @Test("⌘[ from Recents puts Date Modified back, with the folder's own sort indicated")
    func backToTheFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pane = fixture.pane
        try await fixture.go(to: fixture.folder)
        let folderSort = pane.panel.model.sort
        #expect(folderSort.key == .name)

        fixture.landRecents(over: pane.resultsTarget(inNewTab: false))
        pane.goBack(nil)
        try await fixture.settled(on: fixture.folder)
        #expect(fixture.dateTitle == PanelViewController.Column.date.title)
        #expect(fixture.indicator?.column == .name)
        #expect(fixture.indicator?.ascending == folderSort.ascending)
    }

    @Test("switching tabs moves the header with the tab: its title and its sort indicator")
    func tabSwitch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pane = fixture.pane
        try await fixture.go(to: fixture.folder)

        // ⌘: Recents in a tab of its own beside the folder.
        fixture.landRecents(over: pane.resultsTarget(inNewTab: true))
        #expect(pane.tabs.count == 2)
        #expect(fixture.dateTitle == PanelViewController.Column.lastOpenedTitle)
        #expect(fixture.indicator?.column == .date)

        pane.selectTab(at: 0)
        try await fixture.settled(on: fixture.folder)
        #expect(fixture.dateTitle == PanelViewController.Column.date.title)
        #expect(fixture.indicator?.column == .name)

        pane.selectTab(at: 1)
        #expect(fixture.dateTitle == PanelViewController.Column.lastOpenedTitle)
        #expect(fixture.indicator?.column == .date)
        #expect(fixture.indicator?.ascending == false)
    }

    @Test("a folder opened from Recents' tab sorts by its modification date, not by an empty one")
    func folderFromRecentsTab() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pane = fixture.pane
        try await fixture.go(to: fixture.folder)
        fixture.landRecents(over: pane.resultsTarget(inNewTab: true))

        // The Recents tab carries its sort into the folder (no folder lay under it), and the folder's
        // Date column is the modification date, which its rows all have.
        try await fixture.go(to: fixture.folder)
        #expect(pane.panel.model.sort == RecentsQuery.resultSort)
        #expect(fixture.dateTitle == PanelViewController.Column.date.title)
        #expect(fixture.indicator?.column == .date)
        #expect(fixture.dateText(row: pane.parentRowCount) != "—")
    }
}
