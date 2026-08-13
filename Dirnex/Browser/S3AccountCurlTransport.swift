import DirnexCore
import Foundation

/// Drives the system `curl` to satisfy an `S3AccountBackend`'s requests — the four that are about an
/// **account** rather than a bucket (PLAN.md §M21 Slice 9).
///
/// A sibling of `S3CurlTransport` rather than an extension of it, because the two protocols are
/// genuinely different: every request here exists precisely where there is no bucket, so there is no
/// `S3Location` to hold. What they share is the process — the credential on stdin, the two-pipe
/// drain, the bounded wait — and that is `S3CurlRunner`, so the split costs a type and no duplicated
/// plumbing.
///
/// The same contract `S3Transport` has in the one place that matters: **a refusal by the server is a
/// returned `S3Response`, never a throw.** `curl` exits 0 for a missing bucket, a denied account and
/// a bad signature alike, so the HTTP status is the classification and the exit code only answers
/// whether anything was reached at all. It is the inverse of the FTP transport's rule and it is why
/// S3 has transports of its own (docs/NOTES.md ▸ curl for S3).
struct S3AccountCurlTransport: S3AccountTransport {
    let account: S3Account
    /// The secret access key, resolved from the Keychain by the caller and held for the connection's
    /// lifetime — each invocation re-signs, since HTTP keeps no session.
    let secretAccessKey: String
    var connectTimeout: Int = 15
    /// Wall-clock bound for one account request. Every verb here is metadata — a bucket list, a
    /// create, a delete, a head — so there is no transfer budget to distinguish.
    var metadataTimeout: Int = 30

    init(account: S3Account, secretAccessKey: String, connectTimeout: Int = 15) {
        self.account = account
        self.secretAccessKey = secretAccessKey
        self.connectTimeout = connectTimeout
    }

    func listBuckets(continuationToken: String?) throws -> S3Response {
        try perform(S3ProcessArguments.listBuckets(
            account: account,
            continuationToken: continuationToken,
            connectTimeout: connectTimeout,
            maxTime: metadataTimeout
        ))
    }

    func createBucket(name: String) throws -> S3Response {
        try perform(S3ProcessArguments.createBucket(
            account: account,
            name: name,
            connectTimeout: connectTimeout,
            maxTime: metadataTimeout
        ))
    }

    func deleteBucket(name: String) throws -> S3Response {
        try perform(S3ProcessArguments.deleteBucket(
            account: account,
            name: name,
            connectTimeout: connectTimeout,
            maxTime: metadataTimeout
        ))
    }

    func headBucket(name: String) throws -> S3Response {
        try perform(S3ProcessArguments.headBucket(
            account: account,
            name: name,
            connectTimeout: connectTimeout,
            maxTime: metadataTimeout
        ))
    }

    private func perform(_ arguments: [String]) throws -> S3Response {
        try S3CurlRunner(
            accessKeyID: account.accessKeyID,
            secretAccessKey: secretAccessKey,
            fallbackTimeout: metadataTimeout
        ).perform(arguments)
    }
}
