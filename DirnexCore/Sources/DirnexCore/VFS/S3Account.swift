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
/// `Codable` for the same reason ``S3Location`` is and with the same safety: a saved account is a
/// `ServerEndpoint` in the sidebar's plain-JSON store, and everything here is an address.
public struct S3Account: Sendable, Hashable, Codable {
    /// Host of the S3 endpoint, without a scheme and — see above — without a bucket.
    public let host: String
    /// TCP port. 443 unless the user says otherwise.
    public let port: Int
    /// The region requests are signed for. SigV4's credential scope always names one, even where
    /// the server has no regions.
    public let region: String
    /// The access key id — an identifier, not a secret.
    public let accessKeyID: String
    /// How a bucket *reached from* this account is spelled into the URL.
    ///
    /// The service-level call this type was built for ignores it — `GET /` has no bucket anywhere —
    /// but every verb that names a bucket needs it, which is what makes it the account's business
    /// rather than one caller's: `CreateBucket` is `PUT https://<bucket>.<host>/` under
    /// virtual-host and `PUT https://<host>/<bucket>` under path-style, and a wrong guess reaches a
    /// host that does not resolve or writes an object where a bucket was meant.
    public let addressing: S3Addressing
    /// Whether the endpoint is reached over TLS.
    public let usesTLS: Bool

    public init(
        host: String,
        port: Int? = nil,
        region: String,
        accessKeyID: String,
        addressing: S3Addressing = .virtualHost,
        usesTLS: Bool = true
    ) {
        self.host = host
        self.port = port ?? (usesTLS ? 443 : 80)
        self.region = region
        self.accessKeyID = accessKeyID
        self.addressing = addressing
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

public extension S3Account {
    /// The connection to one bucket in this account — the account's fields with a bucket added.
    ///
    /// The inverse of ``S3Location/account``, and the reason both exist as one definition apiece:
    /// the account pane's rows *become* connections when the user walks into one, and a second
    /// place spelling out how a bucket is addressed is how the two drift (docs/NOTES.md's most
    /// repeated finding).
    ///
    /// `region` is an override for the case that only arises here: a bucket list spans regions
    /// while an account is signed for one, so a row that named its own `<BucketRegion>` is entered
    /// with *that* region rather than the account's. When the server named none — which is the
    /// ordinary case for an S3-compatible endpoint, measured on a real one 2026-08-13 — the
    /// account's own region carries over, and the existing 301 correction handles the rest.
    func bucketLocation(named bucket: String, region: String? = nil) -> S3Location {
        S3Location(
            host: host,
            port: port,
            bucket: bucket,
            region: region ?? self.region,
            accessKeyID: accessKeyID,
            addressing: addressing,
            usesTLS: usesTLS
        )
    }

    /// The stable, round-trippable descriptor stored inside a `VFSBackendID`:
    /// `<scheme><accessKeyID>@<host>:<port>/<region>`.
    ///
    /// ``S3Location/descriptor`` with the bucket segment absent, and absent rather than empty: a
    /// trailing `/` would make the two grammars differ by a character that is easy to lose, where a
    /// missing segment is a parse that simply fails.
    var descriptor: String {
        let insecure = usesTLS ? "" : "+http"
        return "\(addressing.accountScheme)\(accessKeyID)@\(host)\(insecure):\(port)/\(region)"
    }

    /// The backend id that addresses this account.
    var backendID: VFSBackendID { VFSBackendID(descriptor) }

    /// Parse an account descriptor, or `nil` when it isn't one / is malformed.
    init?(descriptor: String) {
        guard let addressing = S3Addressing.matchingAccount(descriptor: descriptor) else {
            return nil
        }
        let body = descriptor.dropFirst(addressing.accountScheme.count)
        guard let atIndex = body.firstIndex(of: "@") else { return nil }
        let accessKeyID = String(body[..<atIndex])

        let remainder = body[body.index(after: atIndex)...]
        let segments = remainder.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 2 else { return nil }
        let region = String(segments[1])

        guard let colonIndex = segments[0].lastIndex(of: ":"),
              let port = Int(segments[0][segments[0].index(after: colonIndex)...])
        else { return nil }
        var host = String(segments[0][..<colonIndex])

        let usesTLS = !host.hasSuffix("+http")
        if !usesTLS { host = String(host.dropLast("+http".count)) }

        guard !accessKeyID.isEmpty, !host.isEmpty, !region.isEmpty else { return nil }
        self.init(
            host: host,
            port: port,
            region: region,
            accessKeyID: accessKeyID,
            addressing: addressing,
            usesTLS: usesTLS
        )
    }

    /// Recover the account a backend id addresses, or `nil` when the id isn't an account id.
    init?(backendID: VFSBackendID) {
        self.init(descriptor: backendID.rawValue)
    }

    /// The same account with ``addressing`` replaced — the twin of ``S3Location/addressed(_:)``, and
    /// one definition apiece for the same reason: a rebuild that drops a field still connects.
    ///
    /// It matters here even though the one request an account makes ignores the mode, because the
    /// mode is what every *bucket* reached from this account inherits. An account corrected to
    /// path-style is the whole point of correcting it.
    func addressed(_ addressing: S3Addressing) -> S3Account {
        S3Account(
            host: host,
            port: port,
            region: region,
            accessKeyID: accessKeyID,
            addressing: addressing,
            usesTLS: usesTLS
        )
    }

    /// How this account names itself in an error the user reads.
    ///
    /// The endpoint rather than the key id, because that is what the user typed and what they can
    /// check — and two accounts on one endpoint are told apart by the key id in the *sidebar*, not
    /// in an error sentence.
    var connectionDescriptor: String { "\(accessKeyID)@\(host)" }

    /// The Keychain account key for this account's secret access key.
    ///
    /// Deliberately the same shape as ``S3Location/keychainAccount`` minus the bucket, so the two
    /// cannot collide: a bucket's entry always carries a trailing `/<bucket>` and an account's
    /// never does.
    var keychainAccount: String { "\(accessKeyID)@\(host):\(port)/\(region)" }
}

public extension VFSBackendID {
    /// The backend id addressing one S3 account.
    static func s3Account(_ account: S3Account) -> VFSBackendID { account.backendID }

    /// The S3 account this id addresses, or `nil` when it isn't an account id.
    var s3Account: S3Account? { S3Account(backendID: self) }

    /// Whether this id addresses an S3 *account* — the bucket list — rather than one bucket.
    var isS3Account: Bool { S3Addressing.matchingAccount(descriptor: rawValue) != nil }
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
            addressing: addressing,
            usesTLS: usesTLS
        )
    }
}
