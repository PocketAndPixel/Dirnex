import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The two refusals `CreateBucket` gives this account, live.
///
/// An **extension of the suite next door, not a suite of its own**, and that is the whole reason
/// this file exists in this shape. `S3AccountLiveIntegrationTests` is `.serialized` because every
/// test drives the same endpoint and the same Keychain item; the trait orders a suite's own tests
/// and says nothing about two suites (docs/NOTES.md ▸ Testing), so a second `@Suite` here would
/// run these concurrently with those and collide on both. Extending the type keeps one suite —
/// and gets the parent file back under SwiftLint's 500-line ceiling along a seam that is real:
/// everything there is a pane *crossing backends*, and both of these are a verb being refused with
/// no pane involved at all.
extension S3AccountLiveIntegrationTests {
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
    func globallyTakenBucketNameIsRefused() async throws {
        // Off the main actor, for the reason ``offCooperativePool`` gives.
        try await offCooperativePool {
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
            #expect(
                error.vfsError(for: bucket) == .unsupported(.bucketNameTakenGlobally(name: name))
            )
            // The narrowness: the *other* 409 on this verb, a name this account owns, keeps reading as
            // an ordinary collision — it really is in the pane, and "already exists" is true there.
            #expect(error.vfsError(for: bucket) != .alreadyExists(bucket))
        }
    }

    /// The refusal this account gives for **every** name but one, and the sentence that names why.
    ///
    /// Measured 2026-09-02 with `curl` against this same account: `CreateBucket` on three unrelated
    /// names each answered *"not authorized to perform: s3:CreateBucket … because no identity-based
    /// policy allows the s3:CreateBucket action"*, while the byte-identical request for
    /// ``S3LiveProbeBucket/name`` — the one ARN the policy grants — answered **200**. So the
    /// account is in exactly the state a scoped key is ordinarily issued in, and the old sentence
    /// ("this account may not have permission for it") stopped where the answer starts.
    ///
    /// **AWS's own prose is the oracle for the token, and it is an independent one.** The action is
    /// named from *our* call site and never scraped (``S3Action``), so asserting that the service's
    /// message carries the same string is a cross-check rather than a tautology: an enum spelling
    /// `s3:PutBucket` would pass every headless test in the suite and fail here.
    @Test("a name this account cannot create names the missing IAM action")
    func refusedCreateNamesTheMissingAction() async throws {
        try await offCooperativePool {
            let config = try #require(S3LiveEnvironment.current)
            let transport = S3AccountCurlTransport(
                account: config.account,
                secretAccessKey: config.secretAccessKey
            )
            // Unique, so it cannot collide with a real bucket, and outside the one ARN this
            // account's policy grants — IAM is evaluated first, so the answer is 403 whoever owns
            // the name.
            let name = "dirnex-denied-probe-\(UUID().uuidString.prefix(8).lowercased())"
            let bucket = config.accountRoot.appending(name)
            let refused = try transport.createBucket(name: name)

            guard refused.status == 403 else {
                // A key with a wider grant than this test assumes would have *created* it. Say so,
                // and take it away again rather than leaving a bucket behind.
                if (200..<300).contains(refused.status) {
                    _ = try? transport.deleteBucket(name: name)
                }
                Issue.record("""
                expected 403 AccessDenied, got \(refused.status) — this key grants s3:CreateBucket \
                more widely than arn:aws:s3:::\(S3LiveProbeBucket.name), so the refusal this test \
                is about cannot be reached
                """)
                return
            }

            let error = S3ServiceError.parse(refused.body, status: refused.status)
            #expect(error.code == "AccessDenied")
            #expect(!error.isCredentialFailure)
            #expect(
                error.vfsError(for: bucket, action: .createBucket)
                    == .unsupported(.s3ActionNotPermitted(action: .createBucket))
            )
            // The service names the same action we do, from its own side of the wire.
            let message = String(bytes: refused.body, encoding: .utf8) ?? ""
            #expect(message.contains(S3Action.createBucket.iamName))
            // Narrowness: this is the *action* being named, not the 403. A caller with no verb in
            // hand still gets what it always got, which is what makes the change additive.
            #expect(error.vfsError(for: bucket) == .permissionDenied(bucket))
        }
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
