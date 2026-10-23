import Foundation
import Testing

@testable import DirnexCore

/// The subtree shortcut and the tree refresh's batch over WebDAV (PLAN.md §M32 Slice 5), against a
/// fake fed the bodies macOS's Apache sent for every folder of one real tree, with the run stopping
/// where `curl` was measured to stop it.
@Suite("WebDAV backend: subtree and batched listings")
struct WebDAVBackendListingsTests {
    private static let location = WebDAVLocation(
        host: "127.0.0.1",
        port: 8088,
        username: "probe",
        usesTLS: false,
        rootPath: "/basic"
    )

    /// Every folder of `/basic/tree` and the body Apache answered its `Depth: 1` with, captured in
    /// one batched run through the shipped argument builder on 2026-10-23.
    private static let tree: [String: String] = [
        "/tree": "apache-tree-root-207",
        "/tree/empty": "apache-tree-empty-207",
        "/tree/c d+é": "apache-tree-c-d-plus-e-207",
        "/tree/a": "apache-tree-a-207",
        "/tree/b": "apache-tree-b-207",
        "/tree/a/a1": "apache-tree-a-a1-207",
        "/tree/a/a2": "apache-tree-a-a2-207",
        "/tree/b/b1": "apache-tree-b-b1-207",
        "/tree/b/b1/deep": "apache-tree-b-b1-deep-207"
    ]

    private func path(_ path: String) -> VFSPath {
        VFSPath(backend: Self.location.backendID, path: path)
    }

    /// The tree's server, with `override` answering first for the paths it names.
    private func server(
        _ override: [String: () throws -> WebDAVHTTPResponse] = [:]
    ) -> FakeWebDAVTransport {
        FakeWebDAVTransport { request in
            if let answer = override[request.path] { return try answer() }
            guard let name = Self.tree[request.path] else { return WebDAVHTTPResponse(status: 404) }
            return try WebDAVFixtures.multistatus(name)
        }
    }

    private func backend(_ transport: FakeWebDAVTransport) -> WebDAVBackend {
        WebDAVBackend(location: Self.location, transport: transport)
    }

    /// The same tree walked one `listDirectory` at a time, which is what the shortcut must be
    /// indistinguishable from.
    private func walked(_ root: String) throws -> [FileEntry] {
        let backend = backend(server())
        var found: [FileEntry] = []
        var queue = [path(root)]
        while !queue.isEmpty {
            let directory = queue.removeFirst()
            for entry in try backend.listDirectory(at: directory) {
                found.append(entry)
                if entry.kind == .directory { queue.append(entry.path) }
            }
        }
        return found
    }

    // MARK: - The subtree

    @Test("the whole tree in one run per level, identical to the walk")
    func wholeTree() throws {
        let transport = server()
        let listing = try #require(
            try backend(transport).subtreeListing(at: path("/tree")) { false }
        )

        #expect(listing.isComplete)
        #expect(listing.entries == (try walked("/tree")))
        #expect(listing.entries.count == 13)
        #expect(listing.entries.filter { $0.kind == .directory }.count == 8)
        #expect(listing.entries.filter { $0.kind == .file }.map(\.byteSize).reduce(0, +) == 5112)
        #expect(transport.batches.count == 4, "one run per level, four levels below the root")
        #expect(transport.batches.first == ["/tree"])
        #expect(Set(transport.batches[1]) == ["/tree/empty", "/tree/c d+é", "/tree/a", "/tree/b"])
        #expect(transport.batches.last == ["/tree/b/b1/deep"])
        #expect(transport.propfinds.isEmpty, "nothing went the one-request-per-curl way")
    }

    @Test("rows carry their real paths and decoded names, shallowest first")
    func realPathsBreadthFirst() throws {
        let listing = try #require(try backend(server()).subtreeListing(at: path("/tree")) { false })
        let names = listing.entries.map(\.name)
        let spaced = try #require(listing.entries.first { $0.name == "c d+é" })
        #expect(spaced.path == path("/tree/c d+é"), "a + is a plus and %20 a space")
        #expect(
            listing.entries.contains { $0.path == path("/tree/c d+é/r.bin") && $0.byteSize == 5000 }
        )
        let depth = listing.entries.map { $0.path.path.split(separator: "/").count }
        #expect(depth == depth.sorted(), "breadth-first by construction")
        #expect(names.contains("z"))
    }

    @Test("a folder below the root the server refuses is skipped, as the walk skips it")
    func refusedSubfolderSkipped() throws {
        let transport = server(["/tree/a": { WebDAVHTTPResponse(status: 403) }])
        let listing = try #require(
            try backend(transport).subtreeListing(at: path("/tree")) { false }
        )
        #expect(listing.isComplete)
        #expect(listing.entries.contains { $0.path == path("/tree/a") })
        #expect(!listing.entries.contains { $0.path.parent == path("/tree/a") })
        #expect(listing.entries.contains { $0.name == "z" }, "the other branches are all there")
    }

    @Test("a root that cannot be listed is no shortcut, so the walk reports why")
    func refusedRoot() throws {
        let transport = server(["/tree": { WebDAVHTTPResponse(status: 404) }])
        #expect(try backend(transport).subtreeListing(at: path("/tree")) { false } == nil)
        #expect(transport.batchedRequests == ["/tree"])
    }

    /// The first section carries `fail`, so its 404 ends the run; the rest are that folder's
    /// siblings and still have to be asked.
    @Test("a first folder refused on its own sends the rest of the level in another run")
    func firstSectionRefusedResends() throws {
        let transport = FakeWebDAVTransport { request in
            guard request.path != "/tree/empty", let name = Self.tree[request.path] else {
                return WebDAVHTTPResponse(status: 404)
            }
            return try WebDAVFixtures.multistatus(name)
        }
        let listing = try #require(
            try backend(transport).subtreeListing(at: path("/tree")) { false }
        )
        #expect(listing.isComplete)
        #expect(listing.entries.contains { $0.name == "z" })
        let level = try #require(transport.batches.dropFirst().first)
        #expect(level.first == "/tree/empty")
        #expect(transport.batches[2] == Array(level.dropFirst()), "the siblings, in a second run")
    }

    @Test("a refused login ends the walk after one request, and is no shortcut")
    func refusedLoginStops() throws {
        let transport = FakeWebDAVTransport { _ in WebDAVHTTPResponse(status: 401) }
        #expect(try backend(transport).subtreeListing(at: path("/tree")) { false } == nil)
        #expect(transport.batchedRequests == ["/tree"])

        let lower = server(["/tree/empty": { WebDAVHTTPResponse(status: 401) }])
        #expect(try backend(lower).subtreeListing(at: path("/tree")) { false } == nil)
        #expect(lower.batchedRequests == ["/tree", "/tree/empty"], "nothing after the refused login")
    }

    /// Skipping a folder nobody answered for would return a subtree short of a branch that still
    /// claimed to be complete; the sizer would report its total as the folder's.
    @Test("a folder that got no answer makes the level no shortcut")
    func silenceIsNoShortcut() throws {
        let transport = server(
            ["/tree/b": { throw WebDAVResponseError.transport(.operationTimedOut) }]
        )
        #expect(try backend(transport).subtreeListing(at: path("/tree")) { false } == nil)
    }

    @Test("a run that could not start, or answered the wrong number, is no shortcut")
    func brokenRunIsNoShortcut() throws {
        let failing = server()
        failing.batchAnswer = { _ in throw WebDAVResponseError.transport(.other) }
        #expect(try backend(failing).subtreeListing(at: path("/tree")) { false } == nil)

        let miscounted = server()
        miscounted.batchAnswer = { _ in [] }
        #expect(try backend(miscounted).subtreeListing(at: path("/tree")) { false } == nil)
    }

    @Test("the row cap stops the walk and says it is incomplete")
    func rowCap() throws {
        var capped = backend(server())
        capped.subtreeRowLimit = 6
        let listing = try #require(try capped.subtreeListing(at: path("/tree")) { false })
        #expect(!listing.isComplete)
        #expect(listing.entries.count == 6)
    }

    @Test("Stop is honoured before the first level and between levels")
    func cancellation() {
        let stopped = server()
        #expect(throws: CancellationError.self) {
            _ = try backend(stopped).subtreeListing(at: path("/tree")) { true }
        }
        #expect(stopped.batches.isEmpty)

        let midway = server()
        #expect(throws: CancellationError.self) {
            _ = try backend(midway).subtreeListing(at: path("/tree")) { !midway.batches.isEmpty }
        }
        #expect(midway.batches == [["/tree"]])
    }

    @Test("folder sizes and Find Files take the shortcut: one run per level, no per-folder request")
    func consumersTakeTheShortcut() throws {
        let sized = server()
        let total = try DirectorySizer.size(
            of: path("/tree"),
            using: backend(sized),
            budget: .remote
        )
        #expect(total == 5112)
        #expect(sized.batches.count == 4)
        #expect(sized.propfinds.isEmpty)

        let searched = server()
        let results = try SubtreeSearch.find(
            under: path("/tree"),
            using: backend(searched),
            matching: try SearchPredicate(
                FileQuery(nameContains: "r.bin"),
                answering: .answerable(by: Self.location.backendID)
            ),
            budget: .remote
        )
        #expect(results.hits.map(\.path) == [path("/tree/c d+é/r.bin")])
        #expect(results.directoriesListed == 1)
        #expect(searched.propfinds.isEmpty)
    }

    // MARK: - The tree refresh's batch

    @Test("several open folders are one run, each listed as list mode lists it")
    func batchedRefresh() throws {
        let transport = server()
        let folders = ["/tree", "/tree/a", "/tree/b/b1"].map(path)
        let answers = try backend(transport).listDirectories(at: folders) { false }
        #expect(transport.batches == [["/tree", "/tree/a", "/tree/b/b1"]])
        let single = backend(server())
        for (folder, answer) in zip(folders, answers) {
            #expect(answer == (try single.listDirectory(at: folder)))
        }
    }

    @Test("one open folder goes the ordinary way")
    func singleFolderIsOrdinary() throws {
        let transport = server()
        let answers = try backend(transport).listDirectories(at: [path("/tree/a")]) { false }
        #expect(transport.batches.isEmpty)
        #expect(transport.propfinds.count == 1)
        #expect(answers.first??.count == 3)
    }

    @Test("a refused folder keeps its rows (nil) and the others list")
    func refusedFolderInRefresh() throws {
        let transport = server(["/tree/a": { WebDAVHTTPResponse(status: 404) }])
        let answers = try backend(transport).listDirectories(
            at: ["/tree", "/tree/a", "/tree/b"].map(path)
        ) { false }
        #expect(answers[0]?.count == 5)
        #expect(answers[1] == nil)
        #expect(answers[2]?.count == 1)
    }

    @Test("a refused login in a refresh is one request, and every folder keeps its rows")
    func refusedLoginInRefresh() throws {
        let transport = FakeWebDAVTransport { _ in WebDAVHTTPResponse(status: 401) }
        let answers = try backend(transport).listDirectories(
            at: ["/tree", "/tree/a", "/tree/b"].map(path)
        ) { false }
        #expect(answers == [nil, nil, nil])
        #expect(transport.batchedRequests == ["/tree"])
    }

    @Test("a refresh whose run could not start keeps every folder's rows")
    func brokenRunInRefresh() throws {
        let transport = server()
        transport.batchAnswer = { _ in throw WebDAVResponseError.transport(.other) }
        let answers = try backend(transport).listDirectories(at: ["/tree", "/tree/a"].map(path)) { false }
        #expect(answers == [nil, nil])
    }

    @Test("a level wider than the limit is split into runs of at most the limit")
    func chunking() throws {
        let limit = WebDAVProcessArguments.listingBatchLimit
        let names = (0..<(limit + 50)).map { "/wide/d\($0)" }
        let transport = FakeWebDAVTransport { request in
            WebDAVHTTPResponse(
                status: 207,
                body: Data(Self.emptyFolder("/basic" + request.path).utf8)
            )
        }
        let answers = try backend(transport).listDirectories(at: names.map(path)) { false }
        #expect(transport.batches.map(\.count) == [limit, 50])
        #expect(answers.allSatisfy { $0 == [] })
    }

    /// A multistatus naming one empty folder. Written by hand: what the test is about is how many
    /// runs a wide level takes, and the parse of a real empty folder is pinned above.
    private static func emptyFolder(_ serverPath: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:"><D:response><D:href>\(serverPath)/</D:href>\
        <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>\
        <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>
        """
    }
}
