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

    /// `CreateBucket`.
    ///
    /// Everything below was measured 2026-08-13 against a real S3-compatible endpoint, with every
    /// request's SigV4 recomputed by hand and a wrong-secret control refused in the same run:
    ///
    /// - **`--data-binary` rather than `-T`**, so the request carries a *real* payload digest
    ///   rather than `UNSIGNED-PAYLOAD`. The opposite of the upload verb's trade, and for the
    ///   opposite reason: the body here is either nothing or 191 bytes, so the memory argument that
    ///   forces `-T` on a file (5.3 MB against 1.08 GB on 512 MiB) does not apply at all.
    /// - **The URL may end in `/` and does**, because it is ``S3Location/bucketURL`` — the one
    ///   definition of how a bucket is addressed, reused rather than rebuilt. Probed both ways: the
    ///   bucket lands under its own name either way, with no trailing slash in the name. That is
    ///   safe here specifically because `-T` is not involved (which would append a basename).
    /// - **`Expect: 100-continue` can never appear**, since `curl` only adds it above ~1 KiB. So the
    ///   flat 1.02 s an ignoring server costs (docs/NOTES.md ▸ curl) is unreachable on this verb.
    ///
    /// The region body is **omitted for `us-east-1`**, which is the one rule here taken from AWS's
    /// documentation rather than measured: AWS refuses a `LocationConstraint` naming its default
    /// region, while every other region requires one. The third-party endpoint probed accepts the
    /// body and ignores it (its regions are fiction), so omitting is the intersection that is
    /// correct on both — a body neither server needs is the only shape that cannot be refused.
    static func createBucket(
        account: S3Account,
        name: String,
        connectTimeout: Int = 15,
        maxTime: Int = 30
    ) -> [String] {
        var arguments = accountCommon(account, connectTimeout, maxTime) + ["-X", "PUT"]
        if let body = createBucketBody(region: account.region) {
            arguments += ["--data-binary", body, "-H", "Content-Type: application/xml"]
        } else {
            // The same "state your own emptiness" spelling `putEmptyObject` uses: an explicit
            // `Content-Length: 0` and the empty string's real SHA-256, rather than a bare `-X PUT`
            // that sends no length header for a strict server to disagree about.
            arguments += ["--data-binary", ""]
        }
        return arguments + [account.bucketLocation(named: name).bucketURL]
    }

    /// `DeleteBucket`.
    ///
    /// **Success is 204**, not 200 (measured), so a caller keyed on `== 200` classifies every
    /// successful delete as a failure — the same trap a resumed download's 206 sets, which is why
    /// ``S3Response/isSuccess`` is a range. The two refusals worth telling apart both arrive with
    /// their own code: `409 BucketNotEmpty` and `404 NoSuchBucket`.
    static func deleteBucket(
        account: S3Account,
        name: String,
        connectTimeout: Int = 15,
        maxTime: Int = 30
    ) -> [String] {
        accountCommon(account, connectTimeout, maxTime)
            + ["-X", "DELETE", account.bucketLocation(named: name).bucketURL]
    }

    /// `HeadBucket` — whether the bucket is there, and which region it answers for.
    ///
    /// The region is the reason this exists: a bucket list spans regions while a connection is
    /// signed for one, so entering a bucket needs its own. It rides `%header{x-amz-bucket-region}`,
    /// already in ``S3WriteOut/format``, so this verb needs no new plumbing.
    ///
    /// It is **not** a substitute for the `<BucketRegion>` element or for the 301 correction, and
    /// measuring said why: a real S3-compatible endpoint sends the header on *no* response at all
    /// (2026-08-13), so this answers `nil` there and the account's own region has to carry over.
    static func headBucket(
        account: S3Account,
        name: String,
        connectTimeout: Int = 15,
        maxTime: Int = 30
    ) -> [String] {
        accountCommon(account, connectTimeout, maxTime)
            + ["--head", "--output", "/dev/null", account.bucketLocation(named: name).bucketURL]
    }

    /// The `CreateBucketConfiguration` document, or `nil` when the request must carry no body.
    ///
    /// An **unstated** region takes the same no-body path as `us-east-1`, and for a stronger reason
    /// than the AWS rule below: naming a region in the body is telling the service where to put the
    /// bucket, which is precisely what a user who left the field blank did not say (``S3Region``).
    static func createBucketBody(region: String) -> String? {
        guard S3Region.isStated(region), region != S3Region.fallback else { return nil }
        return """
        <?xml version="1.0" encoding="UTF-8"?>\
        <CreateBucketConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\
        <LocationConstraint>\(region)</LocationConstraint>\
        </CreateBucketConfiguration>
        """
    }

    /// The flags and credential every account-level invocation carries.
    private static func accountCommon(
        _ account: S3Account,
        _ connectTimeout: Int,
        _ maxTime: Int
    ) -> [String] {
        common(
            signatureSpecifier: account.signatureSpecifier,
            connectTimeout: connectTimeout,
            maxTime: maxTime
        ) + configFromStandardInput
    }
}
