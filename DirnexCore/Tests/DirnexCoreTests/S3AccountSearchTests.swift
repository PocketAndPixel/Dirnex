import Foundation
import Testing

@testable import DirnexCore

/// ⌥F7 on an S3 account pane: one search across every bucket the key can see, under a bound per
/// bucket the user is told before it starts (PLAN.md §M38 Slice 5).
///
/// The failures that matter here are all quiet ones: a bound that lets the whole bucket through, a
/// bucket cut short with nothing to say so, a bucket that refused ending every other bucket's search,
/// or a bucket in another region read as empty. Each test below watches one of them.
@Suite("S3 account search")
struct S3AccountSearchTests {
    private typealias Fixtures = S3AccountSearchFixtures

    private func location(_ bucket: String, region: String? = nil) -> S3Location {
        let plain = Fixtures.account.bucketLocation(named: bucket)
        return region.map { plain.movingRegion(to: $0) } ?? plain
    }

    private func search(
        _ account: S3AccountBackend,
        router: FakeBucketRouter,
        objectsPerBucket: Int = S3AccountSearch.objectsPerBucket,
        limit: Int = .max,
        isCancelled: () -> Bool = { false },
        onProgress: (S3AccountSearch.Progress) -> Void = { _ in }
    ) throws -> S3AccountSearch.Results {
        try S3AccountSearch.find(
            in: account,
            transport: router.transport,
            matching: Fixtures.everyFile(),
            objectsPerBucket: objectsPerBucket,
            limit: limit,
            isCancelled: isCancelled,
            onProgress: onProgress
        )
    }

    // MARK: - Every bucket

    @Test("every bucket the account lists is searched, and each hit carries its own bucket")
    func searchesEveryBucket() throws {
        let (account, _) = Fixtures.accountBackend([("alpha", nil), ("beta", nil)])
        let router = FakeBucketRouter()
        router.fake(for: location("alpha")).listPages = [Fixtures.page(["a.txt", "docs/b.txt"])]
        router.fake(for: location("beta")).listPages = [Fixtures.page(["c.txt"])]

        let results = try search(account, router: router)

        #expect(results.completion == .complete)
        #expect(results.hits.map(\.name) == ["a.txt", "b.txt", "c.txt"])
        #expect(results.hits.map(\.path.backend) == [
            .s3(location("alpha")), .s3(location("alpha")), .s3(location("beta"))
        ])
        #expect(results.buckets.map(\.outcome) == [.complete, .complete])
        #expect(results.buckets.map(\.hits) == [2, 1])
        #expect(results.stoppedShort.isEmpty)
    }

    /// The first page is the probe. Asking for it again to start the listing would bill every bucket
    /// one page for nothing — on an account of fifty small buckets, a hundred requests for fifty.
    @Test("each page is asked for once, with no delimiter, the first included")
    func asksEachPageOnce() throws {
        let (account, _) = Fixtures.accountBackend([("alpha", nil)])
        let router = FakeBucketRouter()
        let fake = router.fake(for: location("alpha"))
        fake.listPages = [Fixtures.page(["a.txt"], next: "t1"), Fixtures.page(["b.txt"])]

        _ = try search(account, router: router)

        #expect(fake.listRequests == [
            .init(prefix: "", delimiter: nil, continuationToken: nil),
            .init(prefix: "", delimiter: nil, continuationToken: "t1")
        ])
    }

    @Test("an account with no buckets is a complete search with nothing in it")
    func emptyAccount() throws {
        let (account, _) = Fixtures.accountBackend([])
        let router = FakeBucketRouter()

        let results = try search(account, router: router)

        #expect(results.completion == .complete)
        #expect(results.hits.isEmpty && results.buckets.isEmpty)
        #expect(router.asked.isEmpty)
    }

    /// The scope itself: with no bucket list there is no search, and an empty result would read as
    /// "nothing matched" — `SubtreeSearch`'s rule for a root it cannot list.
    @Test("an account that cannot list its buckets fails the search")
    func unlistableAccountThrows() throws {
        let transport = FakeS3AccountTransport()
        transport.listPages = [Fixtures.accessDenied]
        let account = S3AccountBackend(account: Fixtures.account, transport: transport)

        #expect(throws: VFSError.self) {
            _ = try search(account, router: FakeBucketRouter())
        }
    }

    // MARK: - The bound

    /// The bound is the whole promise the dialog makes, so it is checked in keys: three of the four
    /// a two-page bucket holds, the second page cut rather than taken whole.
    @Test("a bucket past the bound stops at exactly that many objects, and says so")
    func boundCutsABucketShort() throws {
        let (account, _) = Fixtures.accountBackend([("big", nil)])
        let router = FakeBucketRouter()
        let fake = router.fake(for: location("big"))
        fake.listPages = [
            Fixtures.page(["1.txt", "2.txt"], next: "t1"),
            Fixtures.page(["3.txt", "4.txt"], next: "t2"),
            Fixtures.page(["5.txt"])
        ]

        let results = try search(account, router: router, objectsPerBucket: 3)

        #expect(results.hits.map(\.name) == ["1.txt", "2.txt", "3.txt"])
        #expect(results.buckets.map(\.outcome) == [.stoppedShort])
        #expect(results.stoppedShort == ["big"])
        #expect(fake.listRequests.count == 2)
        // Every bucket was visited, so the search itself finished; the cut is reported per bucket.
        #expect(results.completion == .complete)
    }

    @Test("a bound reached on a page boundary asks for no further page")
    func boundOnAPageBoundary() throws {
        let (account, _) = Fixtures.accountBackend([("big", nil)])
        let router = FakeBucketRouter()
        let fake = router.fake(for: location("big"))
        fake.listPages = [
            Fixtures.page(["1.txt", "2.txt"], next: "t1"),
            Fixtures.page(["3.txt"])
        ]

        let results = try search(account, router: router, objectsPerBucket: 2)

        #expect(fake.listRequests.count == 1)
        #expect(results.buckets.map(\.outcome) == [.stoppedShort])
    }

    /// A bucket holding exactly the bound has been searched whole, and naming it as cut short would
    /// send the user into it for nothing.
    @Test("a bucket of exactly the bound, with nothing after it, is complete")
    func exactlyTheBoundIsComplete() throws {
        let (account, _) = Fixtures.accountBackend([("even", nil)])
        let router = FakeBucketRouter()
        router.fake(for: location("even")).listPages = [Fixtures.page(["1.txt", "2.txt"])]

        let results = try search(account, router: router, objectsPerBucket: 2)

        #expect(results.buckets.map(\.outcome) == [.complete])
        #expect(results.stoppedShort.isEmpty)
    }

    /// The reason the bound is per bucket: a shared allowance spent by the first bucket would leave
    /// the second unsearched.
    @Test("a bucket cut short leaves the next bucket its own bound")
    func boundIsPerBucket() throws {
        let (account, _) = Fixtures.accountBackend([("big", nil), ("small", nil)])
        let router = FakeBucketRouter()
        router.fake(for: location("big")).listPages = [
            Fixtures.page(["1.txt", "2.txt"], next: "t1"), Fixtures.page(["3.txt"])
        ]
        router.fake(for: location("small")).listPages = [Fixtures.page(["x.txt", "y.txt"])]

        let results = try search(account, router: router, objectsPerBucket: 2)

        #expect(results.buckets.map(\.outcome) == [.stoppedShort, .complete])
        #expect(results.hits.map(\.name) == ["1.txt", "2.txt", "x.txt", "y.txt"])
    }

    // MARK: - A bucket that cannot be searched

    @Test("a bucket that refuses is reported by name, and the search goes on")
    func refusedBucketIsReported() throws {
        let (account, _) = Fixtures.accountBackend([("locked", nil), ("open", nil)])
        let router = FakeBucketRouter()
        router.fake(for: location("locked")).listPages = [Fixtures.accessDenied]
        router.fake(for: location("open")).listPages = [Fixtures.page(["a.txt"])]

        let results = try search(account, router: router)

        #expect(results.completion == .complete)
        #expect(results.hits.map(\.name) == ["a.txt"])
        #expect(results.failed.map(\.name) == ["locked"])
        #expect(results.buckets.first?.outcome == .failed(.unsupported(.s3ActionNotPermitted(
            action: .listBucket
        ))))
    }

    @Test("a bucket that does not answer is reported, and the search goes on")
    func unreachableBucketIsReported() throws {
        let (account, _) = Fixtures.accountBackend([("gone", nil), ("open", nil)])
        let router = FakeBucketRouter()
        router.fake(for: location("gone")).thrownError = .transport(.couldNotConnect)
        router.fake(for: location("open")).listPages = [Fixtures.page(["a.txt"])]

        let results = try search(account, router: router)

        #expect(results.failed.map(\.name) == ["gone"])
        #expect(results.hits.map(\.name) == ["a.txt"])
    }
}

// MARK: - Reaching a bucket, ending early, and what the app reads

extension S3AccountSearchTests {
    /// Without the correction a bucket in another region reads as refused — the user is told it
    /// could not be searched while it is right there.
    @Test("a bucket in another region is re-aimed where the redirect says, and its hits live there")
    func followsARegionRedirect() throws {
        let (account, _) = Fixtures.accountBackend([("west", nil)])
        let router = FakeBucketRouter()
        router.fake(for: location("west")).listPages = [Fixtures.wrongRegion(naming: "us-west-2")]
        let settled = location("west", region: "us-west-2")
        router.fake(for: settled).listPages = [Fixtures.page(["a.txt"])]

        let results = try search(account, router: router)

        #expect(settled.host == "s3.us-west-2.amazonaws.com")
        #expect(results.hits.map(\.path.backend) == [.s3(settled)])
        #expect(results.buckets.first?.location == settled)
        #expect(results.buckets.first?.outcome == .complete)
    }

    @Test("a second redirect is not followed")
    func followsOneRedirectOnly() throws {
        let (account, _) = Fixtures.accountBackend([("west", nil)])
        let router = FakeBucketRouter()
        router.fake(for: location("west")).listPages = [Fixtures.wrongRegion(naming: "us-west-2")]
        router.fake(for: location("west", region: "us-west-2")).listPages = [
            Fixtures.wrongRegion(naming: "eu-west-1")
        ]

        let results = try search(account, router: router)

        #expect(results.failed.map(\.name) == ["west"])
        #expect(router.asked.count == 2)
    }

    /// AWS lists each bucket's region, and asking there first saves every foreign bucket a 301.
    @Test("a bucket listed with its region is asked there first")
    func usesTheListedRegion() throws {
        let (account, _) = Fixtures.accountBackend([("west", "us-west-2")])
        let router = FakeBucketRouter()
        let settled = location("west", region: "us-west-2")
        router.fake(for: settled).listPages = [Fixtures.page(["a.txt"])]

        let results = try search(account, router: router)

        #expect(router.asked.first == settled)
        #expect(router.fakes[location("west").descriptor] == nil)
        #expect(results.hits.count == 1)
    }

    @Test("a certificate one label too shallow is retried path-style")
    func retriesPathStyle() throws {
        let (account, _) = Fixtures.accountBackend([("dotted.name", nil)])
        let router = FakeBucketRouter()
        router.fake(for: location("dotted.name")).thrownError = .transport(.certificateNotTrusted)
        let settled = location("dotted.name").addressed(.path)
        router.fake(for: settled).listPages = [Fixtures.page(["a.txt"])]

        let results = try search(account, router: router)

        #expect(results.buckets.first?.location == settled)
        #expect(results.hits.map(\.path.backend) == [.s3(settled)])
    }

    // MARK: - Ending early

    @Test("a stop between buckets keeps the hits found and searches nothing more")
    func stopBetweenBuckets() throws {
        let (account, _) = Fixtures.accountBackend([("alpha", nil), ("beta", nil)])
        let router = FakeBucketRouter()
        let alpha = router.fake(for: location("alpha"))
        alpha.listPages = [Fixtures.page(["a.txt"])]
        router.fake(for: location("beta")).listPages = [Fixtures.page(["b.txt"])]

        let results = try search(
            account,
            router: router,
            isCancelled: { alpha.listRequests.count == 1 }
        )

        #expect(results.completion == .stopped)
        #expect(results.hits.map(\.name) == ["a.txt"])
        #expect(results.buckets.map(\.outcome) == [.complete, .notSearched])
        #expect(router.fakes[location("beta").descriptor]?.listRequests.isEmpty ?? true)
    }

    /// The pages already paid for hold real matches, so a stop inside a bucket keeps them — the
    /// opposite of the single-bucket shortcut, which throws and has nothing else to show.
    @Test("a stop inside a bucket keeps the pages already read")
    func stopInsideABucket() throws {
        let (account, _) = Fixtures.accountBackend([("alpha", nil), ("beta", nil)])
        let router = FakeBucketRouter()
        let alpha = router.fake(for: location("alpha"))
        alpha.listPages = [Fixtures.page(["a.txt"], next: "t1"), Fixtures.page(["b.txt"])]

        let results = try search(
            account,
            router: router,
            isCancelled: { alpha.listRequests.count == 1 }
        )

        #expect(results.completion == .stopped)
        #expect(results.hits.map(\.name) == ["a.txt"])
        #expect(results.buckets.map(\.outcome) == [.interrupted, .notSearched])
        #expect(alpha.listRequests.count == 1)
        #expect(results.stoppedShort.isEmpty)
    }

    @Test("the result limit ends the search in the bucket it fills up in")
    func resultLimit() throws {
        let (account, _) = Fixtures.accountBackend([("alpha", nil), ("beta", nil)])
        let router = FakeBucketRouter()
        router.fake(for: location("alpha")).listPages = [Fixtures.page(["1.txt", "2.txt", "3.txt"])]

        let results = try search(account, router: router, limit: 2)

        #expect(results.completion == .truncated)
        #expect(results.hits.map(\.name) == ["1.txt", "2.txt"])
        #expect(results.buckets.map(\.outcome) == [.interrupted, .notSearched])
        #expect(router.fakes[location("beta").descriptor] == nil)
    }

    // MARK: - What the app reads

    /// The app registers these so a hit can be opened and copied; a bucket with no hit has no row in
    /// the results and needs no connection.
    @Test("the connections to register are the buckets with hits, where they settled")
    func connectionsAreTheBucketsWithHits() throws {
        let (account, _) = Fixtures.accountBackend([("west", nil), ("none", nil)])
        let router = FakeBucketRouter()
        router.fake(for: location("west")).listPages = [Fixtures.wrongRegion(naming: "us-west-2")]
        router.fake(for: location("west", region: "us-west-2")).listPages = [
            Fixtures.page(["a.txt"])
        ]
        router.fake(for: location("none")).listPages = [Fixtures.page([])]

        let results = try search(account, router: router)

        #expect(results.connections == [location("west", region: "us-west-2")])
    }

    @Test("progress counts buckets and names the one being searched")
    func reportsProgress() throws {
        let (account, _) = Fixtures.accountBackend([("alpha", nil), ("beta", nil)])
        let router = FakeBucketRouter()
        router.fake(for: location("alpha")).listPages = [Fixtures.page(["a.txt"])]
        router.fake(for: location("beta")).listPages = [Fixtures.page(["b.txt", "c.txt"])]
        var reports: [S3AccountSearch.Progress] = []

        _ = try search(account, router: router, onProgress: { reports.append($0) })

        #expect(reports == [
            .init(bucketsSearched: 0, bucketCount: 2, hits: 0, currentBucket: nil),
            .init(bucketsSearched: 0, bucketCount: 2, hits: 0, currentBucket: "alpha"),
            .init(bucketsSearched: 1, bucketCount: 2, hits: 1, currentBucket: nil),
            .init(bucketsSearched: 1, bucketCount: 2, hits: 1, currentBucket: "beta"),
            .init(bucketsSearched: 2, bucketCount: 2, hits: 3, currentBucket: nil)
        ])
    }
}
