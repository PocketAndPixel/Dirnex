import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The loop behind Oleg's blinking icons (2026-11-17): an arrival made every pane ask again for all
/// its rows, so a row whose image the cache had let go of got its placeholder back and another load,
/// whose arrival asked again. `NSCache` lets go under memory pressure, which a test cannot raise, so
/// these make the loader forget the keys themselves (`RowIconLoader.forget`), in a real pane in a
/// window, drawing real folders' icons.
///
/// Controlled 2026-11-17 by taking each part of the fix out in turn: without the loader answering from
/// the images rows still draw, the second test failed; with that gone too and an arrival only asking,
/// as before, the second and third; with an arrival not carrying its images, the third; and with an
/// arrival not asking for the other rows, the fourth.
///
/// Serialized because the loader is one for the app and its test hooks are too; the fixture's folders
/// have names of their own, so a pane in another suite drawing at the same time counts for nothing here.
@MainActor
@Suite("Row icon arrivals", .serialized)
struct RowIconArrivalTests {
    @Test("an arrival puts each image in its row, one load per row")
    func arrivalFillsRows() async throws {
        let fixture = try IconFixture()
        defer { fixture.remove() }
        let loads = LoadCounter(under: fixture.directory)
        defer { loads.stop() }

        let source = try await fixture.drawnPane()
        try await settleUntil { fixture.allLoaded(in: source.pane) }
        #expect(loads.counts.count == IconFixture.names.count)
        #expect(loads.counts.values.allSatisfy { $0 == 1 })
    }

    @Test("a cache that let a drawn icon go neither blanks its row nor loads it again")
    func forgottenIconStaysDrawn() async throws {
        let fixture = try IconFixture()
        defer { fixture.remove() }
        let loads = LoadCounter(under: fixture.directory)
        defer { loads.stop() }
        let source = try await fixture.drawnPane()
        try await settleUntil { fixture.allLoaded(in: source.pane) }
        try await fixture.waitForSteadyCells(in: source)
        let drawn = fixture.images(in: source.pane)
        let before = loads.counts

        RowIconLoader.shared.forget(loads.keys)
        // Another image arriving, as any load anywhere in the app does: nothing here may ask.
        NotificationCenter.default.post(name: RowIconLoader.didLoadNotification, object: nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.images(in: source.pane) == drawn)
        #expect(loads.counts == before)

        // And a re-ask, as coming to the front makes (`FileIconProvider.forgetTypeIcons`): the rows
        // still draw their images, so the loader answers with those whatever the cache let go of.
        NotificationCenter.default.post(name: FileIconProvider.typeIconsDidChange, object: nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.images(in: source.pane) == drawn)
        #expect(loads.counts == before)
    }

    /// The loader keeps 256 requests waiting and drops the oldest, so a row asked for before a long
    /// scroll's worth of others never loads unless it asks again. An arrival is what makes it ask.
    @Test("a row whose request a full queue dropped is asked for again when another image arrives")
    func droppedRequestIsAskedAgain() async throws {
        let fixture = try IconFixture()
        defer { fixture.remove() }
        let loads = LoadCounter(under: fixture.directory)
        defer { loads.stop() }
        RowIconLoader.shared.holdsLoads = true
        defer { RowIconLoader.shared.holdsLoads = false }

        let source = try await fixture.drawnPane()
        try await fixture.waitForSteadyCells(in: source)
        #expect(loads.counts.isEmpty)
        // Newer requests than the rows' own, enough to push those off the end of the queue.
        let elsewhere = "/RowIconArrivalTests-gone-\(UUID().uuidString)"
        for index in 0..<300 {
            _ = RowIconLoader.shared.image(for: RowIconLoader.Key(
                path: "\(elsewhere)/\(index)",
                modified: Date(timeIntervalSince1970: 0),
                size: 0,
                kind: .item,
                pointSize: 16,
                scale: 2,
                appearance: NSAppearance.Name.aqua.rawValue
            ))
        }
        RowIconLoader.shared.holdsLoads = false
        try await settleUntil { fixture.allLoaded(in: source.pane) }
        #expect(loads.counts.count == IconFixture.names.count)
    }

    /// Not "once": with nothing kept, a cell the table makes anew for a row after dropping the one that
    /// held the image has nothing to be answered with and loads again. Seen once in a full suite run,
    /// two loads for one folder (2026-11-17). The loop is what this is about, and it never stops.
    @Test("an icon the cache lets go of as soon as it is stored stops loading once it is drawn")
    func iconTheCacheKeepsDroppingStopsLoading() async throws {
        let fixture = try IconFixture()
        defer { fixture.remove() }
        let loads = LoadCounter(under: fixture.directory)
        defer { loads.stop() }
        // The worst a cache under pressure can do: nothing it is given survives to be asked for.
        RowIconLoader.shared.didStore = { key in
            if key.path.hasPrefix(fixture.directory) { RowIconLoader.shared.forget([key]) }
        }
        defer { RowIconLoader.shared.didStore = nil }

        let source = try await fixture.drawnPane()
        try await settleUntil { fixture.allLoaded(in: source.pane) }
        try await Task.sleep(for: .milliseconds(200))
        let settled = loads.counts
        try await Task.sleep(for: .milliseconds(500))
        #expect(fixture.allLoaded(in: source.pane))
        #expect(settled.count == IconFixture.names.count)
        #expect(loads.counts == settled, "loads went on: \(settled) then \(loads.counts)")
    }
}

/// Three real folders in a folder of their own, and a pane drawing them.
@MainActor
private struct IconFixture {
    static let names = ["one", "two", "three"]
    let directory: String

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RowIconArrivalTests-\(UUID().uuidString)", isDirectory: true)
        for name in Self.names {
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        directory = url.path
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: directory)
    }

    /// A windowed pane listing the folders, once the table has made its own name cell for each row,
    /// so each one has asked. Its own: a cell made here with `makeIfNecessary` is not the one the table
    /// goes on to draw the row with, and the table's then asks again.
    func drawnPane() async throws -> WindowedPane {
        let here = VFSPath.local(directory)
        let entries = Self.names.map { Handoff.local("\(directory)/\($0)", kind: .directory) }
        let source = windowedPane(
            showing: entries,
            at: here,
            backend: Handoff.StubBackend(listings: [here: entries])
        )
        try await settleUntil { source.pane.tabs[0].hasLoaded }
        try await settleUntil {
            source.window.layoutIfNeeded()
            source.window.displayIfNeeded()
            return images(in: source.pane).allSatisfy { $0 != nil }
        }
        let table = source.pane.tableView
        try #require(
            table.rows(in: table.visibleRect).length == source.pane.parentRowCount + Self.names.count
        )
        return source
    }

    /// Wait until the table has stopped making new cells for the rows. On a cold first run it can still
    /// be swapping the cells it drew first for new ones after every row has its image, and a cell made
    /// after the cache let go, its old one already gone, rightly loads once more, which is not what the
    /// test is about (one flake in four runs, 2026-11-17).
    func waitForSteadyCells(in source: WindowedPane) async throws {
        var last = cells(in: source.pane)
        var steadySince = ContinuousClock.now
        try await settleUntil {
            source.window.displayIfNeeded()
            let now = cells(in: source.pane)
            if now != last {
                last = now
                steadySince = ContinuousClock.now
            }
            return ContinuousClock.now - steadySince >= .milliseconds(200)
        }
    }

    private func cells(in pane: PanelViewController) -> [ObjectIdentifier?] {
        (0..<Self.names.count).map { offset in
            nameCell(pane.parentRowCount + offset, in: pane).map(ObjectIdentifier.init)
        }
    }

    /// Each folder's row draws a loaded image, not the folder placeholder it starts with.
    func allLoaded(in pane: PanelViewController) -> Bool {
        let images = images(in: pane)
        return images.count == Self.names.count
            && images.allSatisfy { $0 != nil && $0 != ObjectIdentifier(FileIconProvider.parentIcon) }
    }

    /// What each folder's row draws now, by identity.
    func images(in pane: PanelViewController) -> [ObjectIdentifier?] {
        (0..<Self.names.count).map { offset in
            nameCell(pane.parentRowCount + offset, in: pane)?.imageView?.image
                .map(ObjectIdentifier.init)
        }
    }

    private func nameCell(_ row: Int, in pane: PanelViewController) -> FileCellView? {
        let column = pane.tableView.column(
            withIdentifier: NSUserInterfaceItemIdentifier(PanelViewController.Column.name.rawValue)
        )
        return pane.tableView.view(atColumn: column, row: row, makeIfNecessary: false) as? FileCellView
    }
}

/// How many loads have started for each path under one folder, and the keys they started for.
@MainActor
private final class LoadCounter {
    private(set) var counts: [String: Int] = [:]
    private(set) var keys: [RowIconLoader.Key] = []

    init(under directory: String) {
        RowIconLoader.shared.didStartLoad = { [weak self] key in
            guard let self, key.path.hasPrefix(directory) else { return }
            counts[key.path, default: 0] += 1
            keys.append(key)
        }
    }

    func stop() {
        RowIconLoader.shared.didStartLoad = nil
    }
}
