import Foundation
import Testing

@testable import DirnexCore

/// What stands between a marked set of rows and real paths, and what that is allowed to cost
/// without asking (PLAN.md §M24 Slice 1).
///
/// Two claims are worth more than the rest and the suite is built around them. The **classification**
/// has to separate a local file whose bytes are here from one whose bytes are not, because that
/// distinction is invisible in every other field a row carries — the name, the size and the dates of
/// an evicted placeholder are all real — and getting it wrong is a multi-gigabyte download behind a
/// keystroke. And the **request rule** has to fire where the byte rule structurally cannot see it,
/// which is the only reason it exists.
@Suite("Materialization plan")
struct MaterializationPlanTests {
    // MARK: - Fixtures

    private static let s3 = VFSBackendID("s3://bucket")
    private static let sftp = VFSBackendID("sftp://user@host")

    private func entry(
        _ path: VFSPath,
        kind: FileEntry.Kind = .file,
        size: Int64 = 1024,
        isDataless: Bool = false
    ) -> FileEntry {
        FileEntry(
            path: path,
            name: path.lastComponent,
            kind: kind,
            byteSize: size,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_600_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 7,
            isDataless: isDataless
        )
    }

    private func remote(_ name: String, size: Int64 = 1024) -> FileEntry {
        entry(VFSPath(backend: Self.s3, path: "/prefix/\(name)"), size: size)
    }

    private func local(_ name: String, size: Int64 = 1024) -> FileEntry {
        entry(.local("/Users/oleg/\(name)"), size: size)
    }

    private func plan(_ entries: [FileEntry], cached: Set<VFSPath> = []) -> MaterializationPlan {
        MaterializationPlan.plan(for: entries) { cached.contains($0.path) }
    }

    // MARK: - Classification

    /// The whole point of the type, in one assertion per reason a row is not yet a readable file.
    @Test("every backend lands on the source that says what it will take to read it")
    func classifiesEverySource() {
        let placeholder = entry(.local("/Users/oleg/evicted.raw"), isDataless: true)
        let member = entry(
            VFSPath(backend: .archive(forArchiveAt: "/tmp/pkg.zip"), path: "/docs/x.md")
        )
        let held = remote("held.bin")
        let result = plan(
            [local("here.txt"), placeholder, member, held, remote("far.bin")],
            cached: [held.path]
        )

        #expect(result.items.map(\.source) == [
            .present, .cloudPlaceholder, .archiveMember, .cached, .remote
        ])
    }

    /// An evicted placeholder is the row every other field lies about: its name, size and dates are
    /// real, so nothing but this flag separates it from a file that is genuinely here. Pinned on its
    /// own because reading one *blocks* — it is the failure `SF_DATALESS` exists to prevent, and a
    /// classification that answered `.present` would put it behind a keystroke with nothing said.
    @Test("a dataless local file needs bytes and an identical present one does not")
    func placeholderNeedsBytes() {
        let path = VFSPath.local("/Users/oleg/photo.raw")
        let evicted = plan([entry(path, size: 40_000_000, isDataless: true)])
        let here = plan([entry(path, size: 40_000_000)])

        #expect(evicted.needsNothing == false)
        #expect(evicted.cloudMaterializations.count == 1)
        #expect(evicted.byteTotal == 40_000_000)
        #expect(here.needsNothing)
        #expect(here.byteTotal == 0)
    }

    /// The cache is the app's and the core cannot see it, so what it is *asked* is part of the
    /// contract. A local row must never be put to it — a placeholder's bytes land at the path it
    /// already names, so there is no copy for a cache to hold and a `true` there would claim a file
    /// that is not on disk.
    @Test("the cache is asked about remote and archive rows only")
    func cacheIsAskedOnlyWhereACopyCouldExist() {
        var asked: [String] = []
        let member = VFSPath(backend: .archive(forArchiveAt: "/tmp/pkg.zip"), path: "/x.md")
        _ = MaterializationPlan.plan(
            for: [
                local("here.txt"),
                entry(.local("/Users/oleg/evicted.raw"), isDataless: true),
                entry(member),
                remote("far.bin")
            ]
        ) { asked.append($0.name); return false }

        #expect(asked == ["x.md", "far.bin"])
    }

    /// ⌥F3 takes one row from each pane and the two panes can be showing the same folder, so this is
    /// not hypothetical: counted twice it would put a request in the total that nothing is going to
    /// make, and fetch the same object over the top of itself.
    @Test("two rows naming one object are one fetch")
    func duplicatesCollapse() {
        let file = remote("report.pdf", size: 5_000)
        let result = plan([file, local("a.txt"), file])

        #expect(result.items.count == 2)
        #expect(result.requestCount == 1)
        #expect(result.byteTotal == 5_000)
    }

    @Test("rows keep the order they were given, classified or not")
    func orderIsPreserved() {
        let names = ["a", "b", "c", "d"]
        let result = plan([remote("a"), local("b"), remote("c"), local("d")])

        #expect(result.items.map(\.entry.name) == names)
        #expect(result.remoteFetches.map(\.name) == ["a", "c"])
    }

    // MARK: - What it costs

    /// The ordinary use of every gesture M24 touches, and it has to weigh nothing at all: a local
    /// set that reported bytes would confirm a transfer that is not going to happen.
    @Test("a set already on this disk needs nothing and weighs nothing")
    func localSetIsFree() {
        let result = plan((0..<50).map { local("f\($0)", size: 900_000_000) })

        #expect(result.needsNothing)
        #expect(result.byteTotal == 0)
        #expect(result.requestCount == 0)
        #expect(result.totalsAreExact)
    }

    /// A copy already pulled down is not a request and not bytes — which is what makes a preview
    /// followed by ⌥F3 followed by a checksum cost one transfer rather than three.
    @Test("cached rows drop out of both totals")
    func cachedRowsCostNothing() {
        let held = (0..<40).map { remote("h\($0)", size: 10_000_000) }
        let result = plan(held + [remote("new.bin", size: 512)], cached: Set(held.map(\.path)))

        #expect(result.requestCount == 1)
        #expect(result.byteTotal == 512)
    }

    /// `requestCount` counts round trips, and an archive member is not one — it is a local
    /// extraction, 0.001 s of it since M19's member filter. Pinned because it is a *deliberate*
    /// omission: folding extractions in would make the one quantity `unaskedRequestLimit` is derived
    /// from (a measured network connect) mean something else.
    @Test("archive members need bytes without being round trips")
    func archiveMembersAreNotRequests() {
        let archive = VFSBackendID.archive(forArchiveAt: "/tmp/pkg.zip")
        let members = (0..<200).map { entry(VFSPath(backend: archive, path: "/m\($0)")) }
        let result = plan(members)

        #expect(result.needsNothing == false)
        #expect(result.archiveExtractions.count == 200)
        #expect(result.requestCount == 0)
    }

    // MARK: - When the totals are floors rather than totals

    /// `byteSize` is the directory file's own size and never its subtree's, so a folder marked for
    /// ⌥F5 on a server stands for an unknown number of bytes in an unknown number of requests.
    /// Reporting its 4 KB as the answer would confirm nothing and download gigabytes.
    @Test("a remote directory makes the totals a floor")
    func remoteDirectoryIsInexact() {
        let folder = entry(
            VFSPath(backend: Self.sftp, path: "/srv/data"), kind: .directory, size: 4096
        )

        #expect(plan([folder]).totalsAreExact == false)
    }

    /// The same folder on this disk is exact, because nothing about it has to move. Without this the
    /// rule would read "a set containing a folder always confirms", which is every ordinary ⌥F5.
    @Test("a local directory leaves the totals exact")
    func localDirectoryIsExact() {
        let folder = entry(.local("/Users/oleg/docs"), kind: .directory, size: 4096)
        let result = plan([folder, local("a.txt")])

        #expect(result.totalsAreExact)
        #expect(result.needsNothing)
    }

    /// A negative size can only come from a listing field nobody understood — the unknown-size row
    /// of `RemoteFetchPolicy`'s table, wearing a number.
    @Test("a size a listing did not understand makes the totals a floor")
    func negativeSizeIsInexact() {
        #expect(plan([remote("mystery.bin", size: -1)]).totalsAreExact == false)
    }
}
