import Foundation
import Testing

@testable import DirnexCore

/// The map an engine reads a materialized set back through (PLAN.md §M24 Slice 4).
///
/// Four claims, and every one of them is a rule some gesture would otherwise have to keep by hand:
/// a local row stands for itself so an ordinary run needs no branch, a placeholder is a local row
/// for exactly that reason, an absent row answers `nil` rather than throwing, and the last copy of
/// a repeated source wins because the earlier one's directory may already be gone.
@Suite("Materialized paths")
struct MaterializedPathsTests {
    private static let remote = VFSBackendID("test-remote://host")

    private func remotePath(_ path: String) -> VFSPath {
        VFSPath(backend: Self.remote, path: path)
    }

    private func file(_ source: VFSPath, at localPath: String) -> MaterializedFile {
        MaterializedFile(
            source: source,
            localPath: localPath,
            revision: RemoteFileRevision(byteSize: 1, modified: nil)
        )
    }

    // MARK: - Standing for itself

    /// The ordinary local run: nothing was materialized, and every row is still readable. This is
    /// what lets one code path serve a marked set of plain files and a marked set of objects.
    @Test("a local path stands for itself even when nothing was materialized")
    func localPathsNeedNoEntry() {
        let paths = MaterializedPaths()
        #expect(paths.isEmpty)
        #expect(paths.localPath(for: .local("/tmp/a.txt")) == .local("/tmp/a.txt"))
    }

    /// A dataless file's bytes land at the path it already names, so there is nothing for this to
    /// hold and nothing to look up. Asserting it here is what stops a later "be helpful and ask the
    /// map first" from turning a placeholder into a row nobody can hash.
    @Test("a cloud placeholder is a local path and answers with its own path")
    func placeholdersAreLocal() {
        let paths = MaterializedPaths([remotePath("/o.bin"): "/tmp/copy/o.bin"])
        #expect(
            paths.localPath(for: .local("/Users/oleg/photo.raw")) == .local("/Users/oleg/photo.raw")
        )
    }

    // MARK: - Standing in

    @Test("a materialized row answers with the copy")
    func substitutesAMaterializedRow() {
        let source = remotePath("/prefix/report.pdf")
        let paths = MaterializedPaths([file(source, at: "/tmp/d0/report.pdf")])
        #expect(paths.localPath(for: source) == .local("/tmp/d0/report.pdf"))
        #expect(!paths.isEmpty)
    }

    /// `nil` is the answer a checksum turns into ``ChecksumEntryStatus/notDownloaded``, which is an
    /// ordinary row of a report. A throw here is what would let a caller `try?` a file out of a
    /// manifest that then verifies clean while covering less than it claims.
    @Test("a row nothing fetched answers nil rather than throwing")
    func unmaterializedRowIsNil() {
        let paths = MaterializedPaths([file(remotePath("/a.bin"), at: "/tmp/d0/a.bin")])
        #expect(paths.localPath(for: remotePath("/b.bin")) == nil)
    }

    /// Two objects can share a name and must not share a copy — the same fact that makes
    /// `MaterializeRunner` give each one its own directory.
    @Test("two sources with the same name keep separate copies")
    func sameNameDifferentPrefixes() {
        let left = remotePath("/a/report.pdf")
        let right = remotePath("/b/report.pdf")
        let paths = MaterializedPaths([
            file(left, at: "/tmp/d0/report.pdf"),
            file(right, at: "/tmp/d1/report.pdf")
        ])
        #expect(paths.localPath(for: left) == .local("/tmp/d0/report.pdf"))
        #expect(paths.localPath(for: right) == .local("/tmp/d1/report.pdf"))
    }

    /// The first copy is the one whose directory may already have been swept away.
    @Test("a repeated source keeps the last copy")
    func repeatedSourceTakesTheLatest() {
        let source = remotePath("/o.bin")
        let paths = MaterializedPaths([
            file(source, at: "/tmp/d0/o.bin"),
            file(source, at: "/tmp/d1/o.bin")
        ])
        #expect(paths.localPath(for: source) == .local("/tmp/d1/o.bin"))
    }

    // MARK: - Two phases

    /// Verifying a remote manifest fetches the manifest, reads it, and only then knows what else to
    /// fetch — so one map has to be assembled out of two.
    @Test("merging keeps both phases, with the later one winning a collision")
    func mergingCombinesPhases() {
        let manifest = remotePath("/data/files.sha256")
        let claimed = remotePath("/data/a.bin")
        let first = MaterializedPaths([file(manifest, at: "/tmp/m/files.sha256")])
        let second = MaterializedPaths([
            file(claimed, at: "/tmp/d0/a.bin"),
            file(manifest, at: "/tmp/m2/files.sha256")
        ])

        let merged = first.merging(second)

        #expect(merged.localPath(for: claimed) == .local("/tmp/d0/a.bin"))
        #expect(merged.localPath(for: manifest) == .local("/tmp/m2/files.sha256"))
    }
}
