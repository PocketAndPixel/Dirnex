import Foundation
import Testing

@testable import DirnexCore

/// The flat-store shortcut a search takes over a bucket (PLAN.md §M22 Slice 3), from both ends: the
/// pure reading of a delimiter-less page, and the backend loop that feeds it.
///
/// What every assertion here is really about is that the two routes agree. A bucket can be searched
/// two ways — this shortcut, or the ordinary breadth-first walk of `listDirectory` — and the whole
/// premise of the seam is that they return the same rows for a hundredth of the requests. So the
/// interesting failures are not "it crashed" but "it quietly saw fewer things than a walk would
/// have": no folder rows at all, an empty folder missing, the folder being searched returned as its
/// own hit.
@Suite("S3 subtree listing")
struct S3SubtreeListingTests {
    private let location = S3Location(
        host: "s3.us-east-1.amazonaws.com",
        bucket: "1000genomes",
        region: "us-east-1",
        accessKeyID: "AKIAEXAMPLE"
    )

    private var root: VFSPath { VFSPath(backend: .s3(location), path: "/") }

    private func entries(of xml: String, under path: VFSPath) throws -> [FileEntry] {
        var listing = S3SubtreeListing(root: path)
        listing.add(try S3ListingParser.parse(Data(xml.utf8)))
        return listing.entries
    }

    @Test("every folder on the way to a key becomes a row, shallowest first")
    func synthesizesFolders() throws {
        let rows = try entries(of: S3Fixtures.subtreeRootPage, under: root)

        #expect(rows.map(\.name) == ["CHANGELOG", "docs", "empty", "report.pdf", "sub", "notes.txt"])
        #expect(rows.map(\.isDirectory) == [false, true, true, false, true, false])
    }

    @Test("a synthesized row carries the real path its key names")
    func buildsRealPaths() throws {
        let rows = try entries(of: S3Fixtures.subtreeRootPage, under: root)
        let paths = rows.map(\.path.path)

        #expect(paths == [
            "/CHANGELOG", "/docs", "/empty", "/docs/report.pdf", "/docs/sub", "/docs/sub/notes.txt"
        ])
        #expect(rows.allSatisfy { $0.path.backend == .s3(location) })
    }

    /// The row that only exists as its own marker. A store with no directories has nothing else to
    /// say an empty folder is there, so dropping every trailing-slash key — the tempting reading of
    /// "markers are noise" — deletes exactly the folders that have nothing under them.
    @Test("an empty folder is visible through its marker alone")
    func markerBecomesAFolder() throws {
        let rows = try entries(of: S3Fixtures.subtreeRootPage, under: root)
        let empty = try #require(rows.first { $0.name == "empty" })

        #expect(empty.isDirectory)
        #expect(empty.path == VFSPath(backend: .s3(location), path: "/empty"))
    }

    /// `SubtreeSearch` never tests the root against the query, and this is the one row that could
    /// smuggle it back in: a folder's own marker is an ordinary `Contents` row in its own listing.
    @Test("the folder being searched is not one of its own results")
    func dropsTheRootsOwnMarker() throws {
        let docs = VFSPath(backend: .s3(location), path: "/docs")
        let rows = try entries(of: S3Fixtures.recursivePage, under: docs)

        #expect(rows.map(\.name) == ["a.txt", "sub", "b.txt"])
        #expect(rows.map(\.path.path) == ["/docs/a.txt", "/docs/sub", "/docs/sub/b.txt"])
    }

    @Test("a folder seen by a thousand keys is emitted once")
    func dedupesFolders() throws {
        var listing = S3SubtreeListing(root: root)
        for _ in 0..<3 {
            listing.add(try S3ListingParser.parse(Data(S3Fixtures.subtreeRootPage.utf8)))
        }
        #expect(listing.entries.filter { $0.name == "sub" }.count == 1)
    }

    /// A file row has to be indistinguishable from the one `listDirectory` would have produced —
    /// same size, same date, same ETag — because the pane renders hits beside ordinary rows and the
    /// revision check compares tags across both.
    @Test("a file row carries what the listing route's own row does")
    func fileRowsMatchTheListingRoute() throws {
        let rows = try entries(of: S3Fixtures.subtreeRootPage, under: root)
        let notes = try #require(rows.first { $0.name == "notes.txt" })

        #expect(notes.byteSize == 34)
        #expect(notes.entityTag == "\"6d1792d429159aabb630926c37254769\"")
        #expect(notes.hasModificationDate)
    }

    /// A common prefix is not an object, so it has no `LastModified` of any kind — and
    /// `SearchPredicate` refuses a date filter on a row that cannot answer one rather than matching
    /// it vacuously. That only works if the row says it has no date.
    @Test("a synthesized folder has no modification date to match against")
    func foldersHaveNoDate() throws {
        let rows = try entries(of: S3Fixtures.subtreeRootPage, under: root)
        let docs = try #require(rows.first { $0.name == "docs" })

        #expect(!docs.hasModificationDate)
        #expect(docs.modificationDate == FileEntry.unknownDate)
    }

    /// Rows from *outside* the searched folder would be drawn under paths implying they belong to
    /// it. Skipping them is the safe direction, and it costs nothing on a server that honours the
    /// parameter — which is every one measured.
    @Test("a key outside the requested prefix is not rendered")
    func ignoresKeysOutsideThePrefix() throws {
        let docs = VFSPath(backend: .s3(location), path: "/docs")
        let rows = try entries(of: S3Fixtures.subtreeRootPage, under: docs)

        #expect(rows.map(\.name) == ["report.pdf", "sub", "notes.txt"])
    }
}

@Suite("S3 subtree search")
struct S3SubtreeBackendTests {
    private let location = S3Location(
        host: "s3.us-east-1.amazonaws.com",
        bucket: "1000genomes",
        region: "us-east-1",
        accessKeyID: "AKIAEXAMPLE"
    )

    private func backend(
        _ transport: FakeS3Transport,
        pageLimit: Int = 1000
    ) -> S3Backend {
        S3Backend(location: location, transport: transport, pageLimit: pageLimit)
    }

    private var root: VFSPath { VFSPath(backend: .s3(location), path: "/") }

    /// The request that makes the whole shortcut: no delimiter, so the server groups nothing and
    /// answers every depth at once.
    @Test("the subtree is asked for with no delimiter")
    func asksWithoutADelimiter() throws {
        let transport = FakeS3Transport()
        transport.listPages = [.ok(S3Fixtures.subtreeRootPage)]
        _ = try backend(transport).subtreeListing(at: root, isCancelled: { false })

        #expect(transport.listRequests == [
            .init(prefix: "", delimiter: nil, continuationToken: nil)
        ])
    }

    @Test("a folder's subtree is asked for with its prefix")
    func asksUnderThePrefix() throws {
        let transport = FakeS3Transport()
        transport.listPages = [.ok(S3Fixtures.recursivePage)]
        _ = try backend(transport).subtreeListing(
            at: VFSPath(backend: .s3(location), path: "/docs"),
            isCancelled: { false }
        )
        #expect(transport.listRequests.first?.prefix == "docs/")
    }

    @Test("pages are followed with the token the server gave")
    func paginates() throws {
        let transport = FakeS3Transport()
        transport.listPages = [
            .ok(S3Fixtures.subtreeFirstPage), .ok(S3Fixtures.subtreeSecondPage)
        ]
        let rows = try #require(
            try backend(transport).subtreeListing(at: root, isCancelled: { false })
        )

        #expect(transport.listRequests.count == 2)
        #expect(transport.listRequests.last?.continuationToken == S3Fixtures.rootPageToken)
        // `docs` was synthesized on page one and its own marker arrived on page two, which adds no
        // second row — and the deep key from page one still lands last, after the shallow rows that
        // reached the accumulator after it.
        #expect(
            rows.entries.map(\.name) == [
                "docs",
                "CHANGELOG",
                "empty",
                "sub",
                "report.pdf",
                "notes.txt"
            ]
        )
    }

    /// Asked *before* the request, so a stop costs nothing further rather than one more billed page.
    @Test("a stop before the first page throws rather than billing one")
    func cancelsBeforeAsking() throws {
        let transport = FakeS3Transport()
        transport.listPages = [.ok(S3Fixtures.subtreeRootPage)]

        #expect(throws: CancellationError.self) {
            _ = try backend(transport).subtreeListing(at: root, isCancelled: { true })
        }
        #expect(transport.listRequests.isEmpty)
    }

    /// The whole point of the seam, as a number: a subtree spanning three folders is one request.
    @Test("a search over the shortcut spends one listing where a walk would spend three")
    func searchCostsOneRequest() throws {
        let transport = FakeS3Transport()
        transport.listPages = [.ok(S3Fixtures.subtreeRootPage)]
        let query = FileQuery(nameContains: "e")
        let results = try SubtreeSearch.find(
            under: root,
            using: backend(transport),
            matching: try SearchPredicate(query, answering: .answerable(by: root.backend))
        )

        #expect(transport.listRequests.count == 1)
        #expect(results.directoriesListed == 1)
        #expect(results.completion == .complete)
        #expect(results.hits.map(\.name) == ["CHANGELOG", "empty", "report.pdf", "notes.txt"])
    }

    /// A folder is a hit like any other row, which it can only be because the shortcut synthesized
    /// it — the server said nothing about `docs` except as part of two other keys.
    @Test("a search finds a folder that exists only as a prefix")
    func findsASynthesizedFolder() throws {
        let transport = FakeS3Transport()
        transport.listPages = [.ok(S3Fixtures.subtreeRootPage)]
        let results = try SubtreeSearch.find(
            under: root,
            using: backend(transport),
            matching: try SearchPredicate(
                FileQuery(nameContains: "docs"),
                answering: .answerable(by: root.backend)
            )
        )

        #expect(results.hits.map(\.name) == ["docs"])
        #expect(results.hits.first?.isDirectory == true)
    }

    /// A refusal has nothing partial to offer: an enumeration that stopped part-way holds an
    /// arbitrary lexicographic slice, so the error is raised rather than dressed as a truncation.
    @Test("a refused enumeration fails the search instead of returning a slice")
    func refusalPropagates() throws {
        let transport = FakeS3Transport()
        transport.listPages = [S3Response(status: 403, body: Data(S3Fixtures.invalidAccessKey.utf8))]

        #expect(throws: VFSError.self) {
            _ = try SubtreeSearch.find(
                under: root,
                using: backend(transport),
                matching: try SearchPredicate(
                    FileQuery(nameContains: "a"),
                    answering: .answerable(by: root.backend)
                )
            )
        }
    }
}
