import Foundation
import Testing

@testable import DirnexCore

/// The member renames an archive rewrite's undo carries, so a results tab can follow ⌘Z and ⇧⌘Z of
/// F2 or ⇧F2 inside an archive (2026-11-05).
///
/// The swap itself is pinned in `ArchiveUndoJournalTests`. What is pinned here is the rider: which
/// renames each direction reports, that they survive the persisted journal, and that a journal
/// written before they existed still reads.
@Suite("Archive undo: renames")
struct ArchiveUndoRenameTests {
    private static let archive = "/Users/tester/pkg.zip"

    private static func member(_ inner: String) -> VFSPath {
        VFSPath(backend: .archive(forArchiveAt: archive), path: inner)
    }

    private static func rename(_ from: String, _ to: String) -> PathRename {
        PathRename(from: member(from), to: member(to))
    }

    /// The batch as ⇧F2 runs it inside an archive, deepest first.
    private static let forward = [rename("/docs/a.txt", "/docs/b.txt"), rename("/docs", "/guides")]

    private static func record(renamed: [PathRename] = forward) -> UndoRecord {
        UndoRecord.archiveRewrite(
            archive: .local(archive),
            snapshot: .local("/tmp/store/s"),
            expected: .init(byteSize: 10, modified: Date(timeIntervalSince1970: 1.5)),
            restored: .init(byteSize: 20, modified: Date(timeIntervalSince1970: 2.5)),
            renamed: renamed
        )
    }

    private static let clean = UndoReport(failures: [])

    // MARK: - Each direction

    /// Undo runs the renames backwards, last first, each the other way round, which is what puts a
    /// hit inside the renamed folder back: `/guides` becomes `/docs` before `/docs/b.txt` is looked
    /// for.
    @Test("undo reports the renames reversed, and redo reports them forward")
    func eachDirectionReportsItsRenames() {
        let record = Self.record()

        #expect(SearchSnapshot.renames(appliedBy: record, report: Self.clean) == [
            Self.rename("/guides", "/docs"), Self.rename("/docs/b.txt", "/docs/a.txt")
        ])
        #expect(
            SearchSnapshot.renames(appliedBy: record.inverted, report: Self.clean) == Self.forward
        )
        // Two laps come back exactly, so a second ⌘Z after ⇧⌘Z reports what the first did.
        #expect(record.inverted.inverted.steps == record.steps)
    }

    /// Folded through a snapshot, the two directions land the hits where the disk has them.
    @Test("a results tab follows undo and redo through the archive")
    func snapshotFollowsBothDirections() throws {
        let original = [Self.member("/docs"), Self.member("/docs/a.txt"), Self.member("/top.txt")]
        let renamed = original.map { SearchSnapshot.path($0, after: Self.forward) }
        #expect(
            renamed == [
                Self.member("/guides"),
                Self.member("/guides/b.txt"),
                Self.member("/top.txt")
            ]
        )

        let record = Self.record()
        let undone = renamed.map {
            SearchSnapshot.path(
                $0,
                after: SearchSnapshot.renames(appliedBy: record, report: Self.clean)
            )
        }
        #expect(undone == original)
        let redone = undone.map {
            SearchSnapshot.path(
                $0,
                after: SearchSnapshot.renames(appliedBy: record.inverted, report: Self.clean)
            )
        }
        #expect(redone == renamed)
    }

    /// The swap is all or nothing, so a refused one moved no member and its renames must not be
    /// followed.
    @Test("a refused swap reports no renames")
    func refusedSwapReportsNothing() {
        let failure = OperationItemFailure(
            path: .local(Self.archive),
            error: .unsupported(.archiveUndoCopyUnavailable(archive: "pkg.zip"))
        )
        #expect(
            SearchSnapshot.renames(appliedBy: Self.record(), report: UndoReport(failures: [failure])).isEmpty
        )
    }

    /// The narrowness control: a rewrite that renamed nothing (a delete, an add, a save back) carries
    /// nothing and reports nothing, which is every archive record journaled until now.
    @Test("a rewrite that renamed nothing carries no renames")
    func otherRewritesCarryNothing() {
        let record = Self.record(renamed: [])
        #expect(record.steps == [.restoreArchive(
            archive: .local(Self.archive),
            snapshot: .local("/tmp/store/s"),
            expected: .init(byteSize: 10, modified: Date(timeIntervalSince1970: 1.5)),
            restored: .init(byteSize: 20, modified: Date(timeIntervalSince1970: 2.5)),
            renames: nil
        )])
        #expect(SearchSnapshot.renames(appliedBy: record, report: Self.clean).isEmpty)
    }

    // MARK: - The persisted journal

    @Test("the renames survive the journal's JSON")
    func renamesPersist() throws {
        let record = Self.record()
        let decoded = try JSONDecoder().decode(UndoRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
    }

    /// The journal is persisted, so a ⌘Z after updating must still read a step a build from before
    /// this change wrote. Such a step has no `renames` key at all; spelled out by hand here rather
    /// than produced by today's encoder, so the test cannot pass by agreeing with itself.
    @Test("a step journaled before renames existed still decodes, with none")
    func olderJournalDecodes() throws {
        // `JSONEncoder`'s default spelling: paths as their two fields, dates as seconds since 2001.
        let json = """
        {"restoreArchive":{\
        "archive":{"path":"/Users/tester/pkg.zip","backend":"local"},\
        "snapshot":{"path":"/tmp/store/s","backend":"local"},\
        "expected":{"byteSize":10,"modified":-978307198.5},\
        "restored":{"byteSize":20,"modified":-978307197.5}}}
        """
        let step = try JSONDecoder().decode(UndoStep.self, from: Data(json.utf8))
        #expect(step == .restoreArchive(
            archive: .local(Self.archive),
            snapshot: .local("/tmp/store/s"),
            expected: .init(byteSize: 10, modified: Date(timeIntervalSince1970: 1.5)),
            restored: .init(byteSize: 20, modified: Date(timeIntervalSince1970: 2.5)),
            renames: nil
        ))
    }
}
