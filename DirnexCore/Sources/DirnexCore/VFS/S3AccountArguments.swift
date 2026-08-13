import Foundation

/// The one `curl` invocation that is about an **account** rather than a bucket (PLAN.md §M21
/// Slice 7). Its own file because `S3ProcessArguments.swift` sits at the `file_length` ceiling, and
/// because this is the seam anyway: everything there takes an ``S3Session``, which is a bucket.
public extension S3ProcessArguments {
    /// `ListAllMyBuckets` — the buckets this access key can see.
    ///
    /// Verified 2026-08-13 against an endpoint that recomputes SigV4 by hand: `curl --aws-sigv4`
    /// signs a service-level `GET /` — no bucket in the path *or* the host — with the canonical URI
    /// `/`, an empty canonical query and the real SHA-256 of the empty body, and the signature
    /// verified. A wrong secret against the same URL was refused, which is the control that makes
    /// the pass evidence rather than a server being agreeable. So account-level access needs no new
    /// signing machinery at all; it needs a URL with the bucket left out (``S3Account``).
    ///
    /// **`max-buckets` is deliberately not sent.** AWS returns the whole list in one response unless
    /// it is, so sending it would *create* the pagination it looks like it manages — and this is a
    /// picker, where one request is the whole interaction. The continuation token is still read and
    /// still looped (``S3BucketEnumeration``), because a server this backend has never met is free
    /// to page whatever we ask for, and a list that stops early looks exactly like an account with
    /// fewer buckets in it.
    ///
    /// The token is percent-encoded going back for the reason measured on the object listing's:
    /// it is an opaque server-chosen string, so a raw one round-trips perfectly right up until a
    /// server issues one carrying `+`, `/` or `=` — intermittent, per-server, and indistinguishable
    /// from a signature problem when it lands.
    ///
    /// A tighter time budget than a transfer's by default: this runs while somebody is looking at a
    /// sheet waiting for a menu to drop, so it has to give up while they still care.
    static func listBuckets(
        account: S3Account,
        continuationToken: String? = nil,
        connectTimeout: Int = 15,
        maxTime: Int = 30
    ) -> [String] {
        var url = account.serviceURL
        if let continuationToken, !continuationToken.isEmpty {
            url += "?continuation-token=\(S3Key.encodedForQuery(continuationToken))"
        }
        return common(
            signatureSpecifier: account.signatureSpecifier,
            connectTimeout: connectTimeout,
            maxTime: maxTime
        ) + configFromStandardInput + [url]
    }
}
