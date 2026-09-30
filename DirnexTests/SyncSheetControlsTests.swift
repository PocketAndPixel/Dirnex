import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The Synchronize sheet's two choice controls are built from what this pair of sides actually
/// permits (PLAN.md §M25 Slice 5c), not from a fixed list of three directions and two comparisons.
///
/// Structural on purpose — segment *counts* and which one opens selected — so the assertions hold
/// in all fourteen languages, where matching a segment's title would pass only on a Mac pinned to
/// English (docs/NOTES.md ▸ Localization).
@Suite("Sync sheet: the choices it offers")
@MainActor
struct SyncSheetControlsTests {
    private static let sftp = SFTPLocation(host: "example.test", username: "oleg")

    private static func sheet(
        left: VFSPath,
        right: VFSPath,
        directions: [SyncDirection] = [.leftToRight, .bidirectional, .rightToLeft]
    ) -> SyncDirectoriesController {
        let controller = SyncDirectoriesController(
            leftDir: left,
            rightDir: right,
            backend: EmptyBackend(),
            comparisons: SyncComparison.available(between: left.backend, and: right.backend),
            directions: directions
        )
        controller.loadViewIfNeeded()
        return controller
    }

    @Test("two local folders keep all three comparisons")
    func localPairOffersEverything() {
        let sheet = Self.sheet(left: .local("/a"), right: .local("/b"))
        #expect(sheet.comparisonControl.segmentCount == 3)
        #expect(sheet.comparisonControl.selectedSegment == 1) // Size & Date, as it always was
    }

    /// The claim the whole comparison rule exists for: a server's listing carries no modification
    /// time worth comparing, so the control must not offer to compare by one — and the sheet has to
    /// open on a comparison it does offer.
    ///
    /// Comparing *contents* survives, and since M25 Slice 5d it is offered over a remote pair too:
    /// bytes are bytes, and what used to withdraw it was that the engine had nothing local to hand
    /// its comparator. So the control keeps two segments, and neither of them is the date.
    @Test("a remote side loses the date comparison and keeps size and contents")
    func remoteSideLosesOnlyTheDateComparison() {
        let remote = VFSPath(backend: .sftp(Self.sftp), path: "/srv/backup")
        let sheet = Self.sheet(left: .local("/a"), right: remote)
        #expect(sheet.comparisons == [.size, .content])
        #expect(sheet.comparisonControl.segmentCount == 2)
        // Opens on size: the strongest *cheap* one, never the one that reads every file.
        #expect(sheet.comparisonControl.selectedSegment == 0)
        #expect(sheet.comparison == .size)
    }

    /// A read-only side is a fine thing to mirror *from*, so what is withdrawn is the direction that
    /// would write to it — and the one remaining direction is the one selected.
    @Test("a read-only right side leaves only the direction that reads it")
    func readOnlyRightSideOffersOneDirection() {
        let remote = VFSPath(backend: .sftp(Self.sftp), path: "/srv/backup")
        let sheet = Self.sheet(left: .local("/a"), right: remote, directions: [.rightToLeft])
        #expect(sheet.directionControl.segmentCount == 1)
        #expect(sheet.directionControl.selectedSegment == 0)
    }

    /// A backend root's `lastComponent` is `"/"`, which names nothing — the trap this project has
    /// already paid for in the tab chip and the path bar.
    @Test("a bucket root heads its column with the bucket's name, not a slash")
    func rootColumnIsNamed() throws {
        let bucket = VFSPath(
            backend: .s3(S3Location(
                host: "s3.eu-north-1.amazonaws.com",
                bucket: "photos",
                region: "eu-north-1",
                accessKeyID: "AKIA"
            )),
            path: "/"
        )
        let sheet = Self.sheet(left: .local("/a"), right: bucket)
        let column = try #require(
            sheet.tableView.tableColumns.first { $0.identifier.rawValue == "right" }
        )
        #expect(column.title != "/")
        #expect(column.title.contains("photos"))
    }
}

/// Lists nothing, so the sheet's scan finishes at once and this suite measures the controls rather
/// than a comparison.
private struct EmptyBackend: VFSBackend {
    var id: VFSBackendID { .local }
    var capabilities: VFSCapabilities { [.read] }
    func listDirectory(at path: VFSPath) throws -> [FileEntry] { [] }
    func stat(at path: VFSPath) throws -> FileEntry { throw VFSError.notFound(path) }
}
