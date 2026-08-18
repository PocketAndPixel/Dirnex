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
    /// A class rather than a struct so `deinit` can take the Keychain items back out.
    ///
    /// The flows under test file a secret on every successful connect — that is what makes walking
    /// out of a bucket work at all — so running this suite leaves two live-looking credentials in
    /// whoever's login Keychain ran it. They are for a scratch endpoint and they are still clutter
    /// somebody would have to find and delete by hand. Removing them from **inside the test host**
    /// is also the only way that costs nothing: the items belong to this process, so `security` at
    /// a shell would raise an authorization prompt where this raises none.
    deinit {
        guard let config = S3LiveEnvironment.current else { return }
        SecretKeychain.removePassword(for: config.account)
        SecretKeychain.removePassword(for: config.account.bucketLocation(named: config.bucket))
    }

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

    /// F7 and F8 on the account pane, through the routing they actually use. The bucket verbs
    /// themselves are covered against the endpoint elsewhere; what this adds is that a *pane's*
    /// backend reaches them at all — the composite has to route an `s3a://` path, and nothing but
    /// running one finds out that it does not.
    @Test("a bucket is created and deleted through the pane's own backend")
    func createsAndDeletesABucket() async throws {
        let config = try #require(S3LiveEnvironment.current)
        let controller = await connectedPane(config)
        // **One fixed name, deliberately, and the alternative is written down because it is the
        // obvious "fix".** Re-creating a name a previous run deleted can meet `409
        // OperationAborted` — "a conflicting conditional operation is currently in progress against
        // this resource" — which is not a collision and does not clear quickly: measured
        // 2026-08-18, three retries over 15 s did not settle it. What provokes it is *changing the
        // account's region between runs*; create/delete/create inside one region succeeds every
        // time, so an ordinary run of this suite never meets it. A UUID-suffixed name removes the
        // class outright and costs a policy that grants `s3:CreateBucket` on
        // `arn:aws:s3:::dirnex-live-probe-*` rather than on the one exact ARN — worth doing if this
        // ever flakes, and not worth the extra setup step before then. The refusal itself is pinned
        // headlessly against AWS's real body in `S3ResponseErrorTests`.
        let name = "dirnex-live-probe"
        let created = config.accountRoot.appending(name)

        try controller.backend.createDirectory(at: created)
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
    @Test("a name this account already owns is refused without asking, and by AWS when asked")
    func recreatingAnOwnedBucketIsRefused() throws {
        let config = try #require(S3LiveEnvironment.current)
        let name = "dirnex-live-probe"
        let counting = CountingAccountTransport(S3AccountCurlTransport(
            account: config.account,
            secretAccessKey: config.secretAccessKey
        ))
        let backend = S3AccountBackend(account: config.account, transport: counting)
        let bucket = config.accountRoot.appending(name)
        _ = try? counting.inner.deleteBucket(name: name)
        defer { _ = try? counting.inner.deleteBucket(name: name) }

        // The pairing. A guard that refused everything would satisfy the claim below just as well.
        try backend.createDirectory(at: bucket)
        #expect(counting.creates == 1, "creating a free name did not reach the service")

        // The claim: a name already in the pane costs no request at all.
        #expect(throws: VFSError.alreadyExists(bucket)) {
            try backend.createDirectory(at: bucket)
        }
        #expect(counting.creates == 1, "the app asked the service about a name it could already see")

        // And what the service says when something does ask — measured 2026-08-18, 409 with this
        // code. It is the body `S3ResponseErrorTests` pins the mapping against.
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
