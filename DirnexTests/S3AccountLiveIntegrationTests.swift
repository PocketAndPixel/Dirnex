import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The S3 **account** pane end to end, against a real endpoint, through the real controller
/// (PLAN.md §M21 Slice 9): connect with no bucket → the pane lists buckets as rows → Enter crosses
/// into one → Backspace comes back. Every request is a real `curl`, SigV4-signed, with the secret on
/// stdin.
///
/// It exists because these four gestures are **backend crossings**, and no headless test can see
/// that: each one is a connect whose success is a pane standing somewhere else. The unit tests pin
/// the rules (`ParentRowReachTests`, `ConnectServerS3AccountTests`); this pins that the rules are
/// wired to anything.
///
/// Gated on a config file rather than an environment variable, because `xcodebuild` does not forward
/// the shell environment to the test runner (docs/NOTES.md ▸ Testing). Drop a JSON file at
/// `/tmp/dirnex_s3_live_test.json`:
///
/// ```json
/// { "host": "127.0.0.1", "port": 9599, "region": "us-east-1", "accessKeyID": "…",
///   "secretAccessKey": "…", "bucket": "…", "pathStyle": true, "usesTLS": false }
/// ```
///
/// Point it at a scratch account — the suite creates and deletes a bucket named
/// `dirnex-live-probe`, one fixed name for the reason `createsAndDeletesABucket` sets out.
/// **`.serialized` is load-bearing, and it was added after watching the parallel version fail.**
/// Every test here drives the *same* endpoint and the *same* Keychain item, so run concurrently they
/// collide twice over: four panes' worth of `curl` against one server, and one instance's `deinit`
/// deleting the secret another instance is in the middle of using. The failure lands on the
/// **setup**'s wait — "the account root never listed" — which reads as a broken connect rather than
/// as two tests standing on each other.
@Suite("S3 account live integration", .serialized, .enabled(if: S3LiveEnvironment.current != nil))
@MainActor
final class S3AccountLiveIntegrationTests {
    /// The windows the panes live in, held so they outlive `pane(_:)` — see its comment for what
    /// they are for. Never ordered front, so nothing appears on screen.
    private var windows: [NSWindow] = []

    // MARK: - Fixtures

    /// A pane **in a window**, and the window is what keeps a bad afternoon from costing ten
    /// minutes of somebody's life.
    ///
    /// Every gesture here can fail — they are real network calls — and a failed
    /// `enterS3Bucket` ends at `presentOperationFailure`, which is one of the alerts the M21 audit
    /// deliberately left an `NSAlert.runModal()` fallback on: a *user* pressed Enter on that row, so
    /// an alert detached from the app beats no answer at all. In a headless suite there is no user
    /// and no window, so that fallback parks the **whole test host** on a dialog nobody is looking
    /// at — measured 2026-08-18 by sampling the hung process: `leavesABucket` → `enterS3Bucket` →
    /// `presentOperationFailure` → `-[NSAlert runModal]`, with thirteen unrelated tests sitting
    /// pending behind it and the run reading as a ten-minute timeout. Exactly the shape
    /// `RenameReachTests` cost a session, arriving on the *other* kind of alert — the kind whose
    /// fallback is right and must stay.
    ///
    /// So the fix belongs here rather than in the app: with a window, the same failure draws a
    /// sheet, which does not block, and the test fails in seconds saying what went wrong.
    private func pane(_ config: S3LiveEnvironment.Config) -> PanelViewController {
        let controller = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: .local(NSTemporaryDirectory()),
            restorationKey: nil
        )
        controller.loadViewIfNeeded()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        // Never ordered front: it exists so `view.window` is non-nil, not to be looked at.
        windows.append(window)
        return controller
    }

    private func request(
        _ config: S3LiveEnvironment.Config
    ) -> PanelViewController.S3AccountConnectRequest {
        PanelViewController.S3AccountConnectRequest(
            account: config.account,
            secretAccessKey: config.secretAccessKey,
            saveName: nil,
            activityName: nil
        )
    }

    /// Poll rather than spin the run loop: a navigation's listing lands on a detached task, and a
    /// `RunLoop.run(until:)` never suspends the main actor, so the continuation it is waiting for
    /// cannot arrive (docs/NOTES.md ▸ Testing).
    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(30),
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("timed out waiting for \(description)")
    }

    /// Connect and land the pane on the account root, listing.
    private func connectedPane(
        _ config: S3LiveEnvironment.Config
    ) async -> PanelViewController {
        let controller = pane(config)
        let attempt = await controller.connectS3Account(request(config))
        if case let .failed(detail) = attempt { Issue.record("connect failed: \(detail)") }
        await waitUntil("the account root to list") {
            controller.panel.path == config.accountRoot && !controller.panel.isEmpty
        }
        return controller
    }

    // MARK: - The four gestures

    /// The empty-bucket path: a blank bucket field is an answer, and this is the pane it reaches.
    @Test("connecting with no bucket lands on the account, whose rows are its buckets")
    func connectsToTheAccount() async throws {
        let config = try #require(S3LiveEnvironment.current)
        let controller = await connectedPane(config)

        #expect(controller.panel.path.backend.isS3Account)
        #expect(controller.panel.path.isRoot)
        let names = (0..<controller.panel.count).map { controller.panel.model[$0].name }
        #expect(names.contains(config.bucket), "\(names)")
        // Every row is a directory with no size and no date of its own — a bucket is a place, not
        // an object, and the Date column draws the dash `FileEntry.unknownDate` earns.
        let allDirectories = (0..<controller.panel.count)
            .allSatisfy { controller.panel.model[$0].kind == .directory }
        #expect(allDirectories)
        // And the account's own root is the top: there is nothing above one key's buckets.
        #expect(!controller.canGoToParent)
    }

    /// Entering a bucket row is a *connect*, not a path walk — which is what makes the wrong-region
    /// correction, the Keychain filing and the certificate sentences apply to it unchanged.
    @Test("entering a bucket row crosses into that bucket's own backend")
    func entersABucket() async throws {
        let config = try #require(S3LiveEnvironment.current)
        let controller = await connectedPane(config)

        controller.enterS3Bucket(named: config.bucket)
        await waitUntil("the bucket to list") { controller.panel.path.backend.isS3 }

        let location = try #require(controller.panel.path.backend.s3Location)
        #expect(location.bucket == config.bucket)
        #expect(controller.panel.path.isRoot)
        // The pane is standing at a bucket root, which is the one place `..` is not a path.
        #expect(controller.leavesBucketForItsAccount)
        #expect(controller.canGoToParent)
        #expect(controller.parentRowCount == 1)
    }

    /// The addressing correction, live — the gesture a user reported on 2026-08-13: connect with the
    /// bucket field blank, then Enter on a bucket row.
    ///
    /// That is the only place this failure can surface, and the reason is structural: the account
    /// connect before it is `GET https://<endpoint>/`, which carries no bucket in the host and so
    /// cannot fail on one. On an endpoint whose wildcard certificate is a label too shallow, `curl`
    /// exits 60 here before any HTTP, so the *first* assertion cannot pass without the retry — and on
    /// an endpoint that does cover bucket-prefixed hosts it passes directly.
    ///
    /// The config's own `pathStyle` is the recorded truth about which of those this endpoint is, so it
    /// is what the mode is asserted against: an endpoint that needs path-style must have been
    /// corrected to it, and one that does not must have been left alone. That keeps the claim
    /// falsifiable in **both** directions — a neutered correction fails it on the first kind of
    /// endpoint, and one that fires when it should not fails it on the second.
    @Test("entering a bucket under virtual-host addressing reaches it, correcting if it must")
    func entersABucketUnderVirtualHost() async throws {
        let live = try #require(S3LiveEnvironment.current)
        let config = S3LiveEnvironment.Config(
            account: live.account.addressed(.virtualHost),
            secretAccessKey: live.secretAccessKey,
            bucket: live.bucket
        )
        // The saved-server store is the *developer's own sidebar* — this target runs inside the app
        // (docs/NOTES.md ▸ Testing) — and a corrected connect writes the mode back into any record
        // that matches the account. Snapshot it so a live run leaves the sidebar exactly as found.
        let savedServers = ServerConnectionStore.load()
        defer { ServerConnectionStore.save(savedServers) }

        let controller = await connectedPane(config)
        controller.enterS3Bucket(named: config.bucket)
        await waitUntil("the bucket to list") { controller.panel.path.backend.isS3 }

        let location = try #require(controller.panel.path.backend.s3Location)
        #expect(location.bucket == config.bucket)
        #expect(controller.panel.path.isRoot)
        #expect(location.addressing == live.account.addressing)
    }

    /// And back out again, landing the cursor on the bucket that was left — the half that makes it
    /// a walk rather than a jump.
    ///
    /// **The account it lands on is the *bucket's*, which is not always the one that was typed.**
    /// This asserted `config.accountRoot` until 2026-08-18, which reads as the obvious claim and
    /// quietly assumes the connect never corrected anything — true of every endpoint this suite had
    /// met (the probe endpoint and the S3-compatible account do not validate regions at all) and
    /// false against real AWS the moment the region is wrong: entering the bucket takes the 301,
    /// re-aims at `eu-north-1`, and walking up then lands on the `eu-north-1` account, listing
    /// perfectly. The pane was right and the assertion was pinning a value whose whole purpose is
    /// to be corrected — the probe-size lesson in `S3TransferProgressLiveIntegrationTests`, one
    /// suite over. So the claim is the *relationship*: you come back to the account that holds the
    /// bucket you were in, whichever region that turned out to be.
    @Test("walking up from a bucket root returns to the account, cursor on the bucket")
    func leavesABucket() async throws {
        let config = try #require(S3LiveEnvironment.current)
        let controller = await connectedPane(config)
        controller.enterS3Bucket(named: config.bucket)
        await waitUntil("the bucket to list") { controller.panel.path.backend.isS3 }
        let bucket = try #require(controller.panel.path.backend.s3Location)

        controller.goToParent()
        await waitUntil("the account to list again") {
            controller.panel.path.backend.isS3Account && !controller.panel.isEmpty
        }
        #expect(controller.panel.path.isRoot)
        #expect(controller.panel.currentEntry?.name == config.bucket)
        let account = try #require(controller.panel.path.backend.s3Account)
        #expect(account.region == bucket.region, "landed on an account the bucket does not live in")
        #expect(account.host == bucket.host)
    }

    /// The fourth crossing, and the one that reads least like one: `→` on a bucket row in a tree.
    ///
    /// It cannot be a listing — `S3AccountBackend` answers for its root and nothing deeper — so until
    /// 2026-08-19 the row opened into nothing at all: a disclosure triangle promising children, and a
    /// `notFound` disappearing into the tree loader's `try?`. Nothing logged and nothing failed, which
    /// is why it needed a pair of eyes rather than a suite.
    ///
    /// What this pins is the crossing itself — that the expansion goes through the same connect Enter
    /// does, and installs rows belonging to the **bucket's** backend underneath a row belonging to the
    /// account's. Everything below them (deeper expansion, F5, ⌃Q, F8) rests on that one property, and
    /// no headless test can see it: `hasListing` never becomes true without a real connection.
    @Test("a bucket row in a tree expands into the bucket's own objects")
    func expandsABucketInATree() async throws {
        let config = try #require(S3LiveEnvironment.current)
        let controller = await connectedPane(config)
        controller.viewMode = .tree
        controller.applyViewMode()

        // The row the pane actually draws, not the account as typed: the connect may have corrected
        // the region, and the row belongs to whichever account it settled on.
        let bucketRow = controller.panel.path.appending(config.bucket)
        #expect(controller.panel.tree?.index(ofID: bucketRow) != nil, "the bucket has a row to open")

        controller.toggleTreeExpansion(for: bucketRow)
        await waitUntil("the bucket's contents to arrive under its row") {
            controller.panel.tree?.hasListing(for: bucketRow) == true
        }

        // The pane never went anywhere — this is a row opening in place, not a navigation — and the
        // rows beneath it are addressed on the bucket's own backend.
        #expect(controller.panel.path.backend.isS3Account)
        let children = try #require(controller.panel.tree?.entries(in: bucketRow))
        #expect(children.allSatisfy { $0.path.backend.s3Location?.bucket == config.bucket })
        #expect(!children.isEmpty, "an empty live bucket proves only that the listing arrived")
    }

    /// F7 and F8 on the account pane, through the routing they actually use. The bucket verbs
    /// themselves are covered against the endpoint elsewhere; what this adds is that a *pane's*
    /// backend reaches them at all — the composite has to route an `s3a://` path, and nothing but
    /// running one finds out that it does not.
    @Test("a bucket is created and deleted through the pane's own backend")
    func createsAndDeletesABucket() async throws {
        let config = try #require(S3LiveEnvironment.current)
        let controller = await connectedPane(config)
        // **One fixed name, because the account's policy grants `s3:CreateBucket` on that one ARN
        // and a UUID-suffixed name is refused 403** (measured 2026-08-20 — the fix an earlier
        // comment here predicted is not available without widening the policy). Reusing the name is
        // what exposes the create to a stale `HeadBucket`, which ``S3LiveProbeBucket`` absorbs and
        // documents; everything asserted below reads the *listing*, which does not go stale.
        let name = S3LiveProbeBucket.name
        let created = config.accountRoot.appending(name)

        try await S3LiveProbeBucket.create(at: created, through: controller.backend)
        controller.refreshCurrentDirectory(selecting: created)
        await waitUntil("the new bucket to appear") {
            (0..<controller.panel.count).contains { controller.panel.model[$0].name == name }
        }

        try controller.backend.removeItem(at: created)
        controller.refreshCurrentDirectory(selecting: nil)
        await waitUntil("the bucket to disappear") {
            !(0..<controller.panel.count)
                .contains { controller.panel.model[$0].name == name }
        }
    }

    /// What AWS says about a name this account already holds — and the reason the app never hears
    /// it (PLAN.md §M21).
    ///
    /// `S3AccountBackend.createDirectory` `stat`s first and throws `alreadyExists` before the
    /// request is built, because an **S3-compatible** endpoint answers a re-create with a silent
    /// **200** that changes nothing: relying on the service there would report success and do
    /// nothing. So the service's own refusal is unreachable from the pane and is measured one level
    /// down — the same shape as the conditional suite's `.alreadyThere`, where `createFile`'s own
    /// `stat` stands in front of `If-None-Match: *`.
    ///
    /// **The obvious assertion is worthless here, and only the control showed it.** Asserting that
    /// the second `createDirectory` throws `alreadyExists` passes with the local check *deleted* —
    /// AWS's 409 maps to the same error, so the test would be about the mapping while claiming to
    /// be about the guard. What separates them is whether a request was **made**, so the transport
    /// counts its own calls; the same lesson `RemoteTransferCancellationTests` records for
    /// `throws CancellationError`.
    /// **Every `HeadBucket` here is asked about a name whose answer is stable, and that is the whole
    /// design of the test** — see ``S3LiveProbeBucket`` for the measurement. The guard reads
    /// `HeadBucket`, which lies intermittently about a *recently deleted* name, so this used to
    /// flake in both directions on the churned probe bucket. The two counted claims now use a name
    /// that has never existed (a stable 404) and the fixture's own settled bucket (a stable 200),
    /// and the service's refusal — which needs a name the policy lets it create, so it has to be the
    /// probe — is asked **directly**, where no `HeadBucket` is involved at all.
    @Test("a name this account already owns is refused without asking, and by AWS when asked")
    func recreatingAnOwnedBucketIsRefused() throws {
        let config = try #require(S3LiveEnvironment.current)
        let counting = CountingAccountTransport(S3AccountCurlTransport(
            account: config.account,
            secretAccessKey: config.secretAccessKey
        ))
        let backend = S3AccountBackend(account: config.account, transport: counting)

        // The pairing. A guard that refused everything would satisfy the claim below just as well,
        // so pin the other direction: a name the pane cannot see *does* reach the service. What the
        // service answers is beside the point — it is a 403, since the policy grants
        // `s3:CreateBucket` on the probe ARN alone — the evidence is that the request was made.
        let unseen = config.accountRoot.appending(S3LiveProbeBucket.unownedName())
        _ = try? backend.createDirectory(at: unseen)
        #expect(counting.creates == 1, "a name the pane cannot see did not reach the service")

        // The claim: a name already in the pane costs no request at all.
        let owned = config.accountRoot.appending(config.bucket)
        #expect(throws: VFSError.alreadyExists(owned)) {
            try backend.createDirectory(at: owned)
        }
        #expect(counting.creates == 1, "the app asked the service about a name it could already see")

        // And what the service says when something does ask — measured 2026-08-18, 409 with this
        // code. It is the body `S3ResponseErrorTests` pins the mapping against. The setup call owns
        // the name whether it was free (200) or already ours (409), and neither it nor the refusal
        // goes near `HeadBucket`, so this half is exact: measured 3/3 on 2026-08-20.
        let name = S3LiveProbeBucket.name
        let bucket = config.accountRoot.appending(name)
        _ = try counting.inner.createBucket(name: name)
        defer { _ = try? counting.inner.deleteBucket(name: name) }

        let refused = try counting.inner.createBucket(name: name)
        #expect(refused.status == 409, "AWS did not refuse a name this account owns")
        let error = S3ServiceError.parse(refused.body, status: refused.status)
        #expect(error.code == "BucketAlreadyOwnedByYou")
        #expect(error.vfsError(for: bucket) == .alreadyExists(bucket))
        // Not the *other* 409 this backend has had to name: `OperationAborted` is a name that is
        // free and merely settling, and it keeps its own sentence.
        #expect(
            error.vfsError(for: bucket) != .unsupported(.bucketOperationInProgress(name: name))
        )
    }

    /// The refusal a scoped key can never see: a bucket name another AWS account already holds
    /// (PLAN.md §M21).
    ///
    /// **It needs a grant that is deliberately inert.** IAM is evaluated before the name registry,
    /// so a key scoped to its own buckets — how these are ordinarily issued — is refused with `403
    /// AccessDenied` and never learns the name was taken (measured 2026-08-19 on three well-known
    /// names). Reaching the state therefore takes `s3:CreateBucket` on one ARN that is **already
    /// owned by somebody else**, which cannot create anything: that is the whole reason it is safe
    /// to grant.
    ///
    /// ```json
    /// { "Effect": "Allow", "Action": "s3:CreateBucket", "Resource": "arn:aws:s3:::images" }
    /// ```
    ///
    /// Without it this test fails on the status, saying so — a live test's constants are claims
    /// about the endpoint, and this one is a claim about the *key*.
    @Test("a bucket name another account holds is refused as globally taken")
    func globallyTakenBucketNameIsRefused() throws {
        let config = try #require(S3LiveEnvironment.current)
        let transport = S3AccountCurlTransport(
            account: config.account,
            secretAccessKey: config.secretAccessKey
        )
        // A name owned by another account since long before this test existed. Nothing here can
        // create it, so the request has exactly one possible outcome.
        let name = "images"
        let bucket = config.accountRoot.appending(name)

        let refused = try transport.createBucket(name: name)
        #expect(
            refused.status == 409,
            """
            expected 409 BucketAlreadyExists, got \(refused.status) — a 403 means this key lacks \
            s3:CreateBucket on arn:aws:s3:::\(name); see the comment above
            """
        )
        let error = S3ServiceError.parse(refused.body, status: refused.status)
        #expect(error.code == "BucketAlreadyExists")
        #expect(error.vfsError(for: bucket) == .unsupported(.bucketNameTakenGlobally(name: name)))
        // The narrowness: the *other* 409 on this verb, a name this account owns, keeps reading as
        // an ordinary collision — it really is in the pane, and "already exists" is true there.
        #expect(error.vfsError(for: bucket) != .alreadyExists(bucket))
    }
}

/// Wraps a real account transport and records how many times each verb was asked for — the only
/// evidence available for a claim about a request that must *not* be made.
final class CountingAccountTransport: S3AccountTransport, @unchecked Sendable {
    let inner: any S3AccountTransport
    private let lock = NSLock()
    private var createCount = 0

    init(_ inner: any S3AccountTransport) { self.inner = inner }

    var creates: Int { lock.withLock { createCount } }

    func listBuckets(continuationToken: String?) throws -> S3Response {
        try inner.listBuckets(continuationToken: continuationToken)
    }

    func createBucket(name: String) throws -> S3Response {
        lock.withLock { createCount += 1 }
        return try inner.createBucket(name: name)
    }

    func deleteBucket(name: String) throws -> S3Response { try inner.deleteBucket(name: name) }

    func headBucket(name: String) throws -> S3Response { try inner.headBucket(name: name) }
}

/// The opt-in configuration for the live S3 suite.
enum S3LiveEnvironment {
    struct Config {
        let account: S3Account
        let secretAccessKey: String
        let bucket: String

        var accountRoot: VFSPath { VFSPath(backend: .s3Account(account), path: "/") }
    }

    /// A file here turns the suite on; its absence keeps it off in CI, which has no endpoint.
    static let configPath = "/tmp/dirnex_s3_live_test.json"

    private struct File: Decodable {
        let host: String
        let port: Int?
        let region: String
        let accessKeyID: String
        let secretAccessKey: String
        let bucket: String
        let pathStyle: Bool?
        let usesTLS: Bool?
    }

    static var current: Config? {
        guard let data = FileManager.default.contents(atPath: configPath),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        return Config(
            account: S3Account(
                host: file.host,
                port: file.port,
                region: file.region,
                accessKeyID: file.accessKeyID,
                addressing: file.pathStyle == true ? .path : .virtualHost,
                usesTLS: file.usesTLS ?? true
            ),
            secretAccessKey: file.secretAccessKey,
            bucket: file.bucket
        )
    }
}
