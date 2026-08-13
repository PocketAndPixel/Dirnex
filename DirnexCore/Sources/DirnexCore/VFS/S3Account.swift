import Foundation

/// An S3 **account**: an endpoint, a region and the key that reaches them — everything an
/// `S3Location` has except the bucket (PLAN.md §M21 Slice 7).
///
/// It exists because one S3 request is not about a bucket. `ListAllMyBuckets` is a *service*-level
/// call, so it is the one thing the connect form can ask before the user has named the bucket it is
/// there to name — which is what turns "type the bucket exactly right" into "pick it from a list".
///
/// **The bucket's absence from the host is the whole correctness of this type**, and it is why an
/// `S3Location` with an ignored `bucket` field would not do. Under virtual-host addressing
/// ``S3Location/origin`` spells the bucket into the *host* (`<bucket>.s3.<region>.amazonaws.com`),
/// and a `GET /` against that host is not an error: it is the request S3 documents as `GET Bucket`
/// — the legacy `ListObjects` — which answers 200 with that one bucket's objects. So the natural
/// shortcut would hand a parser looking for buckets a perfectly well-formed listing of the wrong
/// thing, which is the quiet direction this backend's every other rule is written against. (Taken
/// from the S3 API reference rather than measured: it needs a real endpoint that resolves
/// bucket-prefixed hosts, which the local probe endpoint is not.)
///
/// Like ``S3Location`` it holds **no secret**: the secret access key is fed to `curl` through a
/// `-K -` config file on stdin and never reaches `argv` (NOTES.md ▸ curl).
public struct S3Account: Sendable, Hashable {
    /// Host of the S3 endpoint, without a scheme and — see above — without a bucket.
    public let host: String
    /// TCP port. 443 unless the user says otherwise.
    public let port: Int
    /// The region requests are signed for. SigV4's credential scope always names one, even where
    /// the server has no regions.
    public let region: String
    /// The access key id — an identifier, not a secret.
    public let accessKeyID: String
    /// Whether the endpoint is reached over TLS.
    public let usesTLS: Bool

    public init(
        host: String,
        port: Int? = nil,
        region: String,
        accessKeyID: String,
        usesTLS: Bool = true
    ) {
        self.host = host
        self.port = port ?? (usesTLS ? 443 : 80)
        self.region = region
        self.accessKeyID = accessKeyID
        self.usesTLS = usesTLS
    }

    /// The origin a service-level request is built on — the endpoint itself, port included only
    /// when it is not the scheme's default, for the reason ``S3Location/origin`` gives: SigV4 signs
    /// the `Host` header, and a redundant `:443` changes it.
    var origin: String {
        let scheme = usesTLS ? "https" : "http"
        let isDefaultPort = (usesTLS && port == 443) || (!usesTLS && port == 80)
        return isDefaultPort ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
    }

    /// The URL `ListAllMyBuckets` is issued against: the endpoint's own root, with the trailing
    /// slash `curl` would add anyway stated rather than left to it.
    var serviceURL: String { "\(origin)/" }

    /// The `--aws-sigv4` argument value. Identical to ``S3Location/signatureSpecifier`` because it
    /// names the region and the service and knows nothing about buckets — which is what makes a
    /// service-level request signable with no new machinery at all.
    var signatureSpecifier: String { "aws:amz:\(region):s3" }
}

public extension S3Location {
    /// The account this connection belongs to — the same endpoint, region and key with the bucket
    /// dropped.
    ///
    /// So a *saved* server can list its siblings without the user retyping anything, and — the half
    /// that matters more — so there is exactly one definition of how an account is spelled. Two
    /// call sites building an endpoint URL by hand is how the wrong-host reading argued in
    /// ``S3Account`` arrives without anyone deciding on it.
    var account: S3Account {
        S3Account(
            host: host,
            port: port,
            region: region,
            accessKeyID: accessKeyID,
            usesTLS: usesTLS
        )
    }
}
