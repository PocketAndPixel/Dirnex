import Foundation

/// How a bucket is addressed in the request URL — the one axis on which AWS and every
/// S3-compatible server disagree, and the reason a location needs more than a host and a bucket.
///
/// The distinction is not cosmetic, which is why it rides in the descriptor's scheme the way
/// `FTPSecurity` does: a saved connection that lost this field would build a URL naming a host that
/// does not resolve (`my-bucket.127.0.0.1`) or a path the server reads as a key.
public enum S3Addressing: String, Sendable, Hashable, Codable, CaseIterable {
    /// `https://<bucket>.<host>/<key>` — what AWS has wanted since the path-style deprecation, and
    /// what Cloudflare R2 and Backblaze B2 also accept.
    case virtualHost
    /// `https://<host>/<bucket>/<key>` — what MinIO, a NAS, and anything reached by IP need, since
    /// a bucket cannot be prefixed onto an address that is not a name.
    case path

    /// The scheme this mode is spelled with inside a descriptor. Two schemes rather than a flag for
    /// the same reason `FTPSecurity` has three: a descriptor is the whole identity of a saved
    /// connection, and a mode that does not round-trip comes back as a different server.
    public var scheme: String {
        switch self {
        case .virtualHost: return "s3://"
        case .path: return "s3p://"
        }
    }

    /// The mode a descriptor's scheme names, or `nil` when the prefix isn't an S3 scheme. Longest
    /// prefix wins, so `s3p://` is never read as `s3://` with a stray `p`.
    static func matching(descriptor: String) -> S3Addressing? {
        allCases
            .sorted { $0.scheme.count > $1.scheme.count }
            .first { descriptor.hasPrefix($0.scheme) }
    }
}

/// Where an S3 backend connects: one bucket on one endpoint, with the access key id that reaches it
/// and the region its requests are signed for — and no secret.
///
/// The secret access key never lives here, for the same reason `FTPLocation` holds no password: it
/// is resolved from the Keychain by the app and fed to `curl` through a `-K -` config file on
/// **stdin**, never in `argv` where any `ps` would read it (NOTES.md ▸ curl). So an `S3Location` is
/// safe to serialize into a tab, a bookmark or a `VFSBackendID` and hand around freely.
///
/// It is deliberately *bucket*-rooted rather than account-rooted. Listing an account's buckets is a
/// separate call (`ListAllMyBuckets`) that a great many real keys are not permitted to make — a
/// key scoped to one bucket is the ordinary way these are issued — so an account-rooted design
/// fails at the root for exactly the users whose credentials are set up properly.
///
/// That call is nonetheless made, as an **assist rather than a root**: ``S3Account`` and the connect
/// sheet's bucket picker offer the buckets a key *can* see, beside a field that is still typed. The
/// same argument that rules it out as a root is what makes it safe as an option — a key that cannot
/// ask loses nothing it had.
public struct S3Location: Sendable, Hashable, Codable {
    /// Host of the S3 endpoint, without a scheme or a bucket: `s3.us-east-1.amazonaws.com`,
    /// `<account>.r2.cloudflarestorage.com`, or a bare address for a server on the LAN.
    public let host: String
    /// TCP port. 443 unless the user says otherwise, which is what a local MinIO usually needs.
    public let port: Int
    /// The bucket this connection is rooted at.
    public let bucket: String
    /// The region requests are signed for. Required even where it is fiction: SigV4's credential
    /// scope always names one, and an S3-compatible server that has no regions still expects the
    /// signature to be computed against whatever it was configured with (commonly `us-east-1`, or
    /// `auto` for R2).
    public let region: String
    /// The access key id — an identifier, not a secret, and the Keychain lookup's account half.
    public let accessKeyID: String
    /// How the bucket is spelled into the URL.
    public let addressing: S3Addressing
    /// Whether the endpoint is reached over TLS. Separate from ``addressing`` because they vary
    /// independently: a local MinIO is path-style *and* plain HTTP, while R2 is virtual-host TLS.
    public let usesTLS: Bool

    public init(
        host: String,
        port: Int? = nil,
        bucket: String,
        region: String,
        accessKeyID: String,
        addressing: S3Addressing = .virtualHost,
        usesTLS: Bool = true
    ) {
        self.host = host
        self.port = port ?? (usesTLS ? 443 : 80)
        self.bucket = bucket
        self.region = region
        self.accessKeyID = accessKeyID
        self.addressing = addressing
        self.usesTLS = usesTLS
    }

    /// The endpoint host for the AWS region `region`. Regional rather than the legacy global
    /// `s3.amazonaws.com`, because a bucket addressed through the wrong region answers **301
    /// PermanentRedirect** rather than serving it (probed against a real bucket 2026-08-12) — and
    /// the global host is only ever right for `us-east-1`.
    public static func awsHost(region: String) -> String { "s3.\(region).amazonaws.com" }

    /// The AWS region an endpoint host names, or `nil` when it names none.
    ///
    /// The one caller is the wrong-region redirect, and the shape it has to read was measured
    /// rather than derived from ``awsHost(region:)``. AWS's 301 carries
    /// `<Endpoint>nasa-nex.s3-us-west-2.amazonaws.com</Endpoint>` (probed 2026-08-12) — which is
    /// **bucket-prefixed** and uses the legacy **dash** spelling, neither of which the host this
    /// project builds ever has. A reader written against our own format therefore recovers nothing
    /// from the one document that exists to hand it over.
    ///
    /// Both separators are accepted, and the bucket is skipped by taking the segment that begins
    /// `s3` rather than by counting from the left: a bucket name may legally contain dots, so the
    /// segment count is not fixed.
    static func region(fromEndpoint endpoint: String) -> String? {
        let segments = endpoint.split(separator: ".", omittingEmptySubsequences: false)
        guard let index = segments.firstIndex(where: { $0 == "s3" || $0.hasPrefix("s3-") }),
              segments.count > index + 1
        else { return nil }
        let marker = segments[index]
        // `s3-us-west-2.amazonaws.com` carries the region inside the marker itself; `s3.us-west-2…`
        // puts it in the next segment. The global `s3.amazonaws.com` names no region at all, which
        // is why the next segment is checked against the suffix rather than taken on faith.
        if marker.hasPrefix("s3-") { return String(marker.dropFirst(3)) }
        let candidate = String(segments[index + 1])
        return candidate == "amazonaws" ? nil : candidate
    }
}

public extension S3Location {
    /// The stable, round-trippable descriptor stored inside a `VFSBackendID`:
    /// `<scheme><accessKeyID>@<host>:<port>/<region>/<bucket>`.
    ///
    /// The port is always present so decoding is unambiguous, the addressing mode rides in the
    /// scheme, and the region is spelled out rather than derived from the host — it is recoverable
    /// from an AWS host and from nothing else, and a saved R2 connection signed for the wrong
    /// region fails with a signature error that names nothing the user can act on.
    ///
    /// Plain HTTP is marked by a `+http` suffix on the scheme's host segment rather than a third
    /// scheme, since TLS and addressing vary independently and four schemes for two flags is how a
    /// descriptor grammar stops being readable.
    var descriptor: String {
        let insecure = usesTLS ? "" : "+http"
        return "\(addressing.scheme)\(accessKeyID)@\(host)\(insecure):\(port)/\(region)/\(bucket)"
    }

    /// The backend id that addresses this bucket.
    var backendID: VFSBackendID { VFSBackendID(descriptor) }

    /// Parse a descriptor, or `nil` when it isn't one / is malformed.
    init?(descriptor: String) {
        guard let addressing = S3Addressing.matching(descriptor: descriptor) else { return nil }
        let body = descriptor.dropFirst(addressing.scheme.count)
        guard let atIndex = body.firstIndex(of: "@") else { return nil }
        let accessKeyID = String(body[..<atIndex])

        let remainder = body[body.index(after: atIndex)...]
        let segments = remainder.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }
        let (region, bucket) = (String(segments[1]), String(segments[2]))

        guard let colonIndex = segments[0].lastIndex(of: ":"),
              let port = Int(segments[0][segments[0].index(after: colonIndex)...])
        else { return nil }
        var host = String(segments[0][..<colonIndex])

        let usesTLS = !host.hasSuffix("+http")
        if !usesTLS { host = String(host.dropLast("+http".count)) }

        guard !accessKeyID.isEmpty, !host.isEmpty, !region.isEmpty, !bucket.isEmpty else {
            return nil
        }
        self.init(
            host: host,
            port: port,
            bucket: bucket,
            region: region,
            accessKeyID: accessKeyID,
            addressing: addressing,
            usesTLS: usesTLS
        )
    }

    /// Recover the bucket a backend id addresses, or `nil` when the id isn't an S3 id.
    init?(backendID: VFSBackendID) {
        self.init(descriptor: backendID.rawValue)
    }

    /// The origin every request to this connection is built on, port included only when it is not
    /// the scheme's default — a redundant `:443` is legal but changes the `Host` header, and SigV4
    /// signs that header, so it is one more way for a signature to disagree with the server.
    var origin: String {
        let scheme = usesTLS ? "https" : "http"
        let authority = addressing == .virtualHost ? "\(bucket).\(host)" : host
        let isDefaultPort = (usesTLS && port == 443) || (!usesTLS && port == 80)
        return isDefaultPort ? "\(scheme)://\(authority)" : "\(scheme)://\(authority):\(port)"
    }

    /// The URL of one object, with `key` percent-encoded to S3's rule.
    func url(forKey key: String) -> String {
        let encoded = S3Key.encodedForPath(key)
        return addressing == .virtualHost
            ? "\(origin)/\(encoded)"
            : "\(origin)/\(bucket)/\(encoded)"
    }

    /// The URL a `ListObjectsV2` call is issued against — the bucket's own root, which is where
    /// every listing query lives whatever prefix it asks for.
    var bucketURL: String {
        addressing == .virtualHost ? "\(origin)/" : "\(origin)/\(bucket)/"
    }

    /// The `--aws-sigv4` argument value naming the provider, region and service. `aws:amz` is the
    /// provider pair for S3 and for every S3-compatible server, which is what lets one spelling
    /// reach AWS, R2, B2 and MinIO alike.
    var signatureSpecifier: String { "aws:amz:\(region):s3" }

    /// The Keychain service every S3 secret key is filed under.
    static var keychainService: String { "com.dirnex.s3" }

    /// The Keychain account key for this connection's secret access key.
    ///
    /// Keyed on the access key id *and* the endpoint and bucket, not on the id alone: one key id
    /// legitimately reaches several buckets, and two accounts on different endpoints may issue ids
    /// that collide (an S3-compatible server picks its own id format and some are short).
    var keychainAccount: String { "\(accessKeyID)@\(host):\(port)/\(region)/\(bucket)" }

    /// How this connection names itself in an error the user reads.
    var connectionDescriptor: String { "\(bucket) on \(host)" }
}

/// What an endpoint the user typed resolves to: the three fields an `S3Location` needs and one
/// field of text can carry.
public struct S3Endpoint: Sendable, Hashable {
    public let host: String
    /// The explicit port, or `nil` to take the scheme's default.
    public let port: Int?
    public let usesTLS: Bool

    public init(host: String, port: Int? = nil, usesTLS: Bool = true) {
        self.host = host
        self.port = port
        self.usesTLS = usesTLS
    }
}

public extension S3Endpoint {
    /// Read an endpoint out of one text field.
    ///
    /// One field rather than three because of what people actually have in hand: R2 hands over
    /// `https://<account>.r2.cloudflarestorage.com`, a MinIO container is `http://127.0.0.1:9000`,
    /// and a NAS is a bare `nas.local:9000` — asking a user to take a URL apart into host, port and
    /// a TLS checkbox is asking them to do work the string already did.
    ///
    /// Three rules that are decisions rather than parsing:
    ///
    /// - **No scheme means TLS**, the same direction the FTP form's security picker defaults in:
    ///   plaintext is a thing you say, not a thing you fall into.
    /// - **A path is dropped**, so a console URL pasted whole still resolves. The bucket is its own
    ///   field, and reading `https://host/my-bucket` as naming one would silently disagree with
    ///   whatever the bucket field says.
    /// - **A port must be a number in range**, and a trailing `:` with junk after it is refused
    ///   rather than quietly ignored — a mistyped port that resolves to the default connects to a
    ///   server the user did not mean.
    static func parse(_ text: String) -> S3Endpoint? {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var usesTLS = true
        if let scheme = ["https://", "http://"].first(where: { rest.lowercased().hasPrefix($0) }) {
            usesTLS = scheme == "https://"
            rest = rest.dropFirst(scheme.count)
        }
        if let slash = rest.firstIndex(of: "/") { rest = rest[..<slash] }

        var host = String(rest)
        var port: Int?
        // IPv6 arrives bracketed (`[::1]:9000`), so the port separator is the colon *after* the
        // closing bracket — the address's own colons are inside it.
        let portSearchStart = host.hasPrefix("[")
            ? host.firstIndex(of: "]").map { host.index(after: $0) } ?? host.startIndex
            : host.startIndex
        if let colon = host[portSearchStart...].firstIndex(of: ":") {
            guard let value = Int(host[host.index(after: colon)...]),
                  (1...65535).contains(value) else { return nil }
            port = value
            host = String(host[..<colon])
        }
        guard !host.isEmpty,
              !host.hasPrefix("-"),
              !host.contains(where: \.isWhitespace) else { return nil }
        return S3Endpoint(host: host, port: port, usesTLS: usesTLS)
    }
}

public extension VFSBackendID {
    /// The backend id addressing one S3 bucket.
    static func s3(_ location: S3Location) -> VFSBackendID { location.backendID }

    /// The S3 bucket this id addresses, or `nil` when it isn't an S3 id.
    var s3Location: S3Location? { S3Location(backendID: self) }

    /// Whether this id addresses an S3 bucket, in either addressing mode.
    var isS3: Bool { S3Addressing.matching(descriptor: rawValue) != nil }
}
