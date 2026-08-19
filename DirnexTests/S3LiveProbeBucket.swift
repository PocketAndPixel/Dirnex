import DirnexCore
import Foundation

@testable import Dirnex

/// The one bucket name the live S3 account's policy lets a test create, and the way to create it
/// through the app's own routing without meeting the phantom AWS leaves behind.
///
/// **`HeadBucket` goes on answering 200 for a bucket this account has deleted, intermittently, for
/// far longer than a test run.** Measured 2026-08-20 against the live account, polling immediately
/// after a `DELETE` returned 204: `404 404 200 200 200 200 200 200 404 200 404 404` — while
/// `ListAllMyBuckets` read the name as absent **12 times out of 12**, and `HeadBucket` on a
/// *settled* bucket answered 200 all 30 times. So the staleness is specific to a name that was just
/// deleted, the listing is exact where the head is not, and roughly one read in three disagrees with
/// the truth.
///
/// That is what made `createsAndDeletesABucket` and `recreatingAnOwnedBucketIsRefused` flake in
/// **both** directions rather than fail: `S3AccountBackend.createDirectory` `stat`s before it asks
/// (the guard `recreatingAnOwnedBucketIsRefused` exists to pin), and that `stat` is a `HeadBucket`,
/// so a previous run's cleanup makes the create refuse a name that is not there, while an unlucky
/// 404 after a create makes the guard let a second one through.
///
/// **The obvious fix is not available here, and probing is what showed it.** The comment this
/// replaces predicted a UUID-suffixed name, at the cost of an IAM policy naming
/// `arn:aws:s3:::dirnex-live-probe-*`. Measured: this account's policy grants `s3:CreateBucket` on
/// the one exact ARN, so a unique name comes back **403 AccessDenied** and creates nothing —
/// the flake cannot be spent away, it has to be absorbed.
enum S3LiveProbeBucket {
    /// The single name `s3:CreateBucket` is granted on.
    static let name = "dirnex-live-probe"

    /// A name this account certainly does *not* own and certainly never has — so `HeadBucket`
    /// answers a stable 404 for it (measured 3/3), which is what makes it usable as the "the guard
    /// let this through" control. Creating it is refused by IAM, and that is beside the point: the
    /// evidence is that the request was made at all.
    static func unownedName() -> String { "\(name)-\(UUID().uuidString.prefix(8).lowercased())" }

    /// Create the probe bucket **through `backend`** — the routing under test — past the phantom.
    ///
    /// The listing is the authority on whether a refusal was real, since it is the half that does
    /// not go stale: retry while it says the name is free, and take a genuine leftover back out
    /// first (a previous run whose cleanup did not run). Bounded, and the last attempt is left
    /// un-caught so a real problem is reported as itself rather than as a timeout.
    static func create(at path: VFSPath, through backend: any VFSBackend) async throws {
        for _ in 0..<40 {
            do {
                try backend.createDirectory(at: path)
                return
            } catch let error as VFSError {
                guard case .alreadyExists = error else { throw error }
                if try listed(path, on: backend) { try backend.removeItem(at: path) }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        try backend.createDirectory(at: path)
    }

    /// Whether the *listing* — `ListAllMyBuckets`, not `HeadBucket` — has this name.
    private static func listed(_ path: VFSPath, on backend: any VFSBackend) throws -> Bool {
        guard let parent = path.parent else { return false }
        let name = path.lastComponent
        return try backend.listDirectory(at: parent).contains { $0.name == name }
    }
}
