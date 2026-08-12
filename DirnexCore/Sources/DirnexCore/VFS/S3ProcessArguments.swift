import Foundation

/// Everything an S3 invocation needs that isn't the operation itself — the account and the time
/// budget. Bundled so each argument builder takes one parameter, exactly as `FTPSession` is.
public struct S3Session: Sendable, Hashable {
    public let location: S3Location
    /// Seconds allowed for the TCP/TLS connect.
    public let connectTimeout: Int
    /// Seconds allowed for the whole invocation. Generous for transfers, tight for metadata.
    public let maxTime: Int

    public init(location: S3Location, connectTimeout: Int = 15, maxTime: Int = 120) {
        self.location = location
        self.connectTimeout = connectTimeout
        self.maxTime = maxTime
    }

    /// The same session with a different time budget — how a caller arms a long transfer without
    /// loosening the metadata calls that share the connection settings.
    public func with(maxTime: Int) -> S3Session {
        S3Session(location: location, connectTimeout: connectTimeout, maxTime: maxTime)
    }
}

/// Builds the `curl` arguments for each S3 operation. Pure and tested for the same reason
/// `FTPProcessArguments` is: the security-sensitive assembly — above all that **no secret ever
/// reaches `argv`** — is verifiable without spawning anything.
///
/// The stock `curl` signs SigV4 itself (`--aws-sigv4`), which is what lets S3 join `bsdtar`,
/// `sftp` and FTP as a wire protocol reached with a system tool rather than a vendor SDK
/// (PLAN.md §M21). The secret access key travels through ``S3ConfigFile`` on **stdin**.
public enum S3ProcessArguments {
    /// Read the credential from stdin. Verified end-to-end against real AWS 2026-08-12: a fake key
    /// delivered this way comes back `InvalidAccessKeyId` — meaning a well-formed signature was
    /// computed and the key looked up — where the same request *unsigned* answers `NoSuchBucket`.
    /// Two different answers is what proves the credential arrived, so the control is the probe.
    static let configFromStandardInput = ["-K", "-"]

    /// Flags every invocation carries: silence, the signature specifier, the time budget, and the
    /// labelled write-out that carries the response's status back on stderr.
    ///
    /// Two flags are **deliberately absent**, and both would be natural to add:
    ///
    /// - **`--fail`**, because the error document *is* the classification here. S3 speaks HTTP, so
    ///   `curl` exits 0 for a missing key, a denied bucket, a bad signature and a wrong region
    ///   alike; the `<Code>` element in the body is the only thing that separates them
    ///   (``S3ResponseError``). `--fail` throws that body away.
    /// - **`--location`**, because a wrong region answers **301** naming the endpoint that would
    ///   have worked, and that answer is worth more than the redirect. Following it would re-issue
    ///   the request against a host the signature was not computed for, turning a diagnosable
    ///   "wrong region" into an undiagnosable signature failure.
    public static func common(session: S3Session) -> [String] {
        [
            // `-sS`: no progress meter, but keep curl's own error text on stderr.
            "-sS",
            "--connect-timeout", String(session.connectTimeout),
            "--max-time", String(session.maxTime),
            "--aws-sigv4", session.location.signatureSpecifier,
            "--write-out", S3WriteOut.format
        ]
    }

    /// One page of `ListObjectsV2`.
    ///
    /// `delimiter` is `/` for a directory listing — the query convention that makes a flat store
    /// look like a tree — and `nil` for a recursive sweep, where every key under the prefix is
    /// wanted and nothing should be grouped away into `CommonPrefixes`.
    public static func list(
        session: S3Session,
        prefix: String,
        delimiter: String? = "/",
        continuationToken: String? = nil,
        maxKeys: Int = 1000
    ) -> [String] {
        let url = listURL(
            session: session,
            prefix: prefix,
            delimiter: delimiter,
            continuationToken: continuationToken,
            maxKeys: maxKeys
        )
        return common(session: session) + configFromStandardInput + [url]
    }

    /// Download one object to `localPath`, optionally resuming from what is already there.
    ///
    /// Resume is `curl -C -`, and it works against S3 exactly as it does over FTP — measured
    /// 2026-08-12 against a real bucket: a 257 098-byte object resumed from a 100 000-byte partial
    /// answered **206** with `size_download` 157 098, and the result compared identical to a whole
    /// download. The caller must still check the remote size first; see ``S3Backend``.
    public static func download(
        session: S3Session,
        key: String,
        localPath: String,
        resume: Bool
    ) -> [String] {
        var arguments = common(session: session) + configFromStandardInput
        arguments += ["--output", localPath]
        if resume { arguments += ["--continue-at", "-"] }
        return arguments + [session.location.url(forKey: key)]
    }

    /// Ask for one object's metadata only. The exact `Content-Length` comes back through the
    /// write-out's `s3-length` field — `size_download` is 0 for a HEAD, so reading the transferred
    /// count instead would report every object as empty.
    public static func head(session: S3Session, key: String) -> [String] {
        common(session: session) + configFromStandardInput
            + ["--head", "--output", "/dev/null", session.location.url(forKey: key)]
    }

    /// The `ListObjectsV2` URL.
    ///
    /// The parameters are emitted in a fixed order and **not sorted**, which is safe because
    /// `curl` canonicalizes the query itself when it signs. That was measured rather than assumed
    /// (2026-08-12), and it is the kind of assumption that fails as `SignatureDoesNotMatch` for one
    /// user with one prefix: a deliberately out-of-order query was signed by `curl`, its
    /// `Authorization` header captured, and the signature recomputed by hand both ways — the
    /// **sorted** canonical query reproduces `curl`'s signature exactly and the as-written order
    /// does not.
    ///
    /// `encoding-type=url` is asked for on every listing. A key may legally contain characters that
    /// cannot appear in XML at all, so the alternative is a whole page failing to parse because of
    /// one object somebody uploaded years ago. Whether the server honored it is read back off the
    /// response, never assumed (``S3ListingPage/isURLEncoded``).
    static func listURL(
        session: S3Session,
        prefix: String,
        delimiter: String?,
        continuationToken: String?,
        maxKeys: Int
    ) -> String {
        var query = ["list-type=2", "encoding-type=url", "max-keys=\(maxKeys)"]
        if let delimiter {
            query.append("delimiter=\(S3Key.encodedForQuery(delimiter))")
        }
        if !prefix.isEmpty {
            query.append("prefix=\(S3Key.encodedForQuery(prefix))")
        }
        if let continuationToken {
            // The one query value whose encoding was measured rather than reasoned about: a raw
            // token carrying `+`, `/` or `=` is rejected with `InvalidArgument`, and one that
            // happens to be alphanumeric round-trips raw perfectly — so it fails intermittently.
            query.append("continuation-token=\(S3Key.encodedForQuery(continuationToken))")
        }
        return "\(session.location.bucketURL)?\(query.joined(separator: "&"))"
    }
}

/// Builds the `curl` config file fed on **stdin** (`-K -`) — the one place the secret access key
/// appears, and the reason it never appears in `argv` or on disk.
///
/// `--aws-sigv4` takes its key pair from `curl`'s ordinary `user` setting, so the same escaping
/// rules `FTPConfigFile` documents apply verbatim: an unescaped newline in a value makes `curl`
/// read the remainder as further *directives*, which is a config-injection surface rather than a
/// formatting bug. A secret access key is 40 characters of base64 and will not normally contain
/// one — but "normally" is not a security argument, and an S3-compatible server picks its own
/// secret format.
public enum S3ConfigFile {
    /// The config text authenticating one connection.
    public static func credentials(accessKeyID: String, secretAccessKey: String) -> String {
        "user = \(quote("\(accessKeyID):\(secretAccessKey)"))\n"
    }

    /// Quote a value for `curl`'s config parser, escaping every character that would otherwise end
    /// the value or start a new directive.
    static func quote(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }
}

/// The `--write-out` template every S3 invocation carries, and the reader for what it produces.
///
/// The response's *status* is the classification for this backend, so it has to come back
/// out-of-band from the body. `%{stderr}` switches the remainder of the write-out to stderr, which
/// leaves the body alone on stdout — no temp file for a listing, and the transport already drains
/// both pipes.
///
/// The fields are **labelled** rather than positional because stderr is not ours alone: on a
/// transport failure `curl` prints its own message there first, and the write-out lands after it.
/// Measured 2026-08-12 against an unresolvable host, stderr came back as
/// `curl: (6) Could not resolve host: …` followed by `000` — so a reader that takes the whole
/// stream, or its first line, reads prose as a status. Labelled lines make the prose ignorable.
public enum S3WriteOut {
    /// The `-w` argument. `\n` is the two-character sequence `curl` itself expands, not a Swift
    /// newline, so it survives being passed through `argv`.
    public static let format = [
        "%{stderr}",
        "s3-status=%{http_code}\\n",
        "s3-region=%header{x-amz-bucket-region}\\n",
        "s3-length=%header{content-length}\\n",
        "s3-size=%{size_download}\\n"
    ].joined()

    /// What one invocation reported about its response.
    public struct Fields: Sendable, Equatable {
        /// The HTTP status, or 0 when there was no response at all (`curl` prints `000`).
        public let status: Int
        /// `x-amz-bucket-region`, which AWS sends on **every** response including the 301 that a
        /// wrong region answers with. That header is a better source for the correct region than
        /// the `<Endpoint>` element in the error document, which is bucket-prefixed and spelled in
        /// the legacy dash form (`nasa-nex.s3-us-west-2.amazonaws.com`) — both measured the same
        /// day. `nil` when absent, which is the ordinary case for an S3-compatible server.
        public let bucketRegion: String?
        /// `Content-Length`, the only place a HEAD reports the object's size.
        public let contentLength: Int64?
        /// Bytes this invocation actually moved — the *delta* for a resumed download, so nothing
        /// has to subtract a prior length the way the `sftp` transport does.
        public let bytesDownloaded: Int64
    }

    /// Read the labelled lines out of a stderr stream, ignoring anything else in it.
    public static func parse(stderr: String) -> Fields {
        var values: [String: String] = [:]
        for line in stderr.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "="),
                  line.hasPrefix("s3-") else { continue }
            let name = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            values[name] = value
        }
        return Fields(
            status: values["s3-status"].flatMap(Int.init) ?? 0,
            bucketRegion: values["s3-region"],
            contentLength: values["s3-length"].flatMap(Int64.init),
            bytesDownloaded: values["s3-size"].flatMap(Int64.init) ?? 0
        )
    }
}
