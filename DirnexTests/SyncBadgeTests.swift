import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The app layer's side of the cloud sync badge (PLAN.md §M6). What a status *means* — the truth
/// table over the ubiquity attributes, and the reader itself — is `DirnexCore`'s
/// (`CloudSyncStatusTests`, `CloudSyncStorageTests`) and is tested there. What is left here is the
/// wiring and the pixels: that every state has a glyph the system will actually hand back, that the
/// badge takes no width when there is nothing to say, and that the palette command is wired.
@Suite("Sync badge")
@MainActor
struct SyncBadgeTests {
    /// A symbol name that doesn't exist returns `nil` from `NSImage`, so a typo would silently draw
    /// nothing at all — the badge would just never appear, on the states hardest to reproduce.
    @Test("every status resolves to a real SF Symbol")
    func everyStatusHasAGlyph() {
        for status in CloudSyncStatus.allCases {
            #expect(
                SyncBadgeStyle.image(for: status) != nil,
                "no SF Symbol resolves for \(status)"
            )
        }
    }

    @Test("every status has tooltip text")
    func everyStatusHasALabel() {
        for status in CloudSyncStatus.allCases {
            #expect(!SyncBadgeStyle.label(for: status).isEmpty)
        }
    }

    /// The bargain the whole feature rests on: an ordinary row must give its name the full cell.
    @Test("a badge with nothing to say takes no width, and one with something does")
    func widthIsPaidOnlyWhenThereIsSomethingToShow() {
        let badge = SyncBadgeView()
        #expect(badge.intrinsicContentSize.width == 0)

        badge.status = .notDownloaded
        #expect(badge.intrinsicContentSize.width > 0)

        badge.status = nil
        #expect(badge.intrinsicContentSize.width == 0)
    }

    @Test("the name cell carries a badge and every other column does not")
    func onlyTheNameCellHasABadge() {
        let name = FileCellView(showsImage: true, identifier: .init("name"))
        #expect(name.syncBadge != nil)

        let size = FileCellView(showsImage: false, identifier: .init("size"))
        #expect(size.syncBadge == nil)
        // Setting a status on a column that has no badge is a no-op, not a crash: the table's
        // render pass sets it on the name column only, but the accessor is on every cell.
        size.syncStatus = .notDownloaded
        #expect(size.syncStatus == nil)
    }

    /// Renaming (F2) hands the editor the whole cell. A tagged, not-downloaded file would otherwise
    /// be renamed through a box narrower than every other row's.
    @Test("beginning a rename clears the badge so the editor gets the full width")
    func renameEditorReclaimsTheBadgeWidth() {
        let cell = FileCellView(showsImage: true, identifier: .init("name"))
        cell.syncStatus = .notDownloaded
        #expect(cell.syncBadge?.intrinsicContentSize.width ?? 0 > 0)

        cell.beginNameEditing(delegate: NameEditingDelegate())
        #expect(cell.syncStatus == nil)
        #expect(cell.syncBadge?.intrinsicContentSize.width == 0)
    }

    /// The cloud hangs past the cell on purpose, into the table's intercell gutter: its ink is 16pt
    /// against a dot's 9pt, so aligning the two *edges* — which the obvious layout does — leaves the
    /// cloud's centre 7pt left of the dot's, and the eye reads the centre. Measured against the live
    /// table, this lands both on the same spot, under the header's sort arrow.
    @Test("the badge hangs into the gutter so its centre matches a dot's")
    func badgeOverhangsTheCellToCentreOnTheDotSlot() throws {
        let cell = FileCellView(showsImage: true, identifier: .init("name"))
        cell.frame = NSRect(x: 0, y: 0, width: 293.5, height: 22)
        cell.syncStatus = .notDownloaded
        cell.layoutSubtreeIfNeeded()

        let badge = try #require(cell.syncBadge)
        #expect(badge.frame.maxX > cell.bounds.maxX)
    }

    /// The regression this nearly shipped with: the dots used to hang off the badge's leading edge,
    /// so giving the badge its overhang dragged them out into the gutter too — 5pt off the position
    /// they were measured into against Finder. They hold their own place now, and yield only to a
    /// badge that is actually there.
    @Test("the dots keep their flush place, and give way only for a real badge")
    func dotsHoldTheirPlaceUnlessTheBadgeNeedsRoom() throws {
        let cell = FileCellView(showsImage: true, identifier: .init("name"))
        cell.frame = NSRect(x: 0, y: 0, width: 293.5, height: 22)
        cell.tags = [FinderTag(name: "Red", color: .red)]
        cell.layoutSubtreeIfNeeded()

        // Within a point: Auto Layout rounds to the backing store, and the regression this guards
        // against moved them by 5.
        let dots = try #require(cell.tagDots)
        #expect(abs(dots.frame.maxX - (cell.bounds.maxX - 1)) < 1)

        // A tagged *and* not-downloaded file: Finder draws the dots first and the cloud outermost,
        // so the dots step aside rather than sitting under it.
        cell.syncStatus = .notDownloaded
        cell.layoutSubtreeIfNeeded()
        let badge = try #require(cell.syncBadge)
        #expect(dots.frame.maxX <= badge.frame.minX + 0.01)
    }

    @Test("the View-menu toggle is wired to a real selector")
    func toggleCommandIsWired() {
        #expect(CommandCatalog.command(for: "view.toggleSyncStatus") != nil)
        #expect(CommandBinding.selector(for: "view.toggleSyncStatus") != nil)
    }

    /// Absent and up-to-date are the same answer to a renderer — both draw nothing — which is why
    /// the snapshot stores only the noteworthy rows.
    @Test("a snapshot answers nil for a row it has nothing on")
    func snapshotOmitsQuietRows() {
        let file = VFSPath.local("/tmp/cloud/away.txt")
        let snapshot = CloudSyncSnapshot(statusByPath: [file: .notDownloaded])
        #expect(snapshot.status(for: file) == .notDownloaded)
        #expect(snapshot.status(for: .local("/tmp/cloud/here.txt")) == nil)
    }

    /// The condition the follow-up poll hangs off. A snapshot of resting states must not keep the
    /// provider looking, and one with a transfer in it must — the bug a live run caught was a badge
    /// stuck on "downloading" because nothing ever looked again.
    @Test("a snapshot knows whether anything in it is still moving")
    func snapshotReportsTransfersInFlight() {
        let away = VFSPath.local("/tmp/cloud/away.txt")
        let arriving = VFSPath.local("/tmp/cloud/arriving.txt")

        #expect(CloudSyncSnapshot(statusByPath: [:]).hasTransfersInFlight == false)
        #expect(
            CloudSyncSnapshot(statusByPath: [away: .notDownloaded]).hasTransfersInFlight == false
        )
        #expect(
            CloudSyncSnapshot(statusByPath: [away: .notDownloaded, arriving: .downloading])
                .hasTransfersInFlight
        )
        #expect(CloudSyncSnapshot(statusByPath: [arriving: .uploading]).hasTransfersInFlight)
    }

    private final class NameEditingDelegate: NSObject, NSTextFieldDelegate {}
}
