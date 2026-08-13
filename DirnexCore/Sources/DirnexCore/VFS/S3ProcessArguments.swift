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
    ///   (``S3ResponseError``). `--fail` throws that body away. ``download(session:key:localPath:resume:)``
    ///   is the one invocation that adds it back, and its comment argues why the trade inverts
    ///   when the body's destination is a file on the user's disk.
    /// - **`--location`**, because a wrong region answers **301** naming the endpoint that would
    ///   have worked, and that answer is worth more than the redirect. Following it would re-issue
    ///   the request against a host the signature was not computed for, turning a diagnosable
    ///   "wrong region" into an undiagnosable signature failure.
    public static func common(session: S3Session) -> [String] {
        common(
            signatureSpecifier: session.location.signatureSpecifier,
            connectTimeout: session.connectTimeout,
            maxTime: session.maxTime
        )
    }

    /// The same flags for a request that has no bucket, and therefore no ``S3Session`` — the
    /// account-level `ListAllMyBuckets` in `S3AccountArguments.swift`. Factored rather than copied
    /// so the two absences argued above stay one decision: a second spelling of this list is how
    /// `--location` gets added to one of them by somebody who never read the reason.
    static func common(
        signatureSpecifier: String,
        connectTimeout: Int,
        maxTime: Int
    ) -> [String] {
        [
            // `-sS`: no progress meter, but keep curl's own error text on stderr.
            "-sS",
            "--connect-timeout", String(connectTimeout),
            "--max-time", String(maxTime),
            "--aws-sigv4", signatureSpecifier,
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
    ///
    /// **`--fail` is the one flag a transfer carries that a listing must not**, and it is here
    /// because of where the bytes go. `--output` writes whatever the server sends, and a refused
    /// download is still a *response*: measured 2026-08-13 against real AWS with a bad key, the
    /// destination came away holding a 354-byte `<Error>` document under the object's own name —
    /// a file that looks downloaded and is not. With `--fail` no file is created at all (exit 22,
    /// nothing written), while the write-out still reports `s3-status=403`, which is the whole
    /// classification a transfer needs: the `<Code>` element ``S3ServiceError`` reads is worth
    /// having for a listing, where the body is the answer, and buys nothing for a byte copy.
    ///
    /// Two neighbours from the same run, both the opposite of what they look like:
    ///
    /// - **`--remove-on-error` is deliberately absent.** It is the flag that pairs with `--fail` by
    ///   reflex, and here it would delete exactly the partial that ``resume`` exists to continue
    ///   from — defeating the feature the paragraph above measures.
    /// - **`--fail` does not truncate a partial that is already there.** Probed both with and
    ///   without `-C -`: a 403 left a 1000-byte partial byte-identical, so a transient refusal
    ///   costs a user nothing they had already downloaded.
    public static func download(
        session: S3Session,
        key: String,
        localPath: String,
        resume: Bool
    ) -> [String] {
        var arguments = common(session: session) + configFromStandardInput + ["--fail"]
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

    // MARK: - Writes

    /// Upload a local file to `key`.
    ///
    /// **`-T` streams and `--data-binary @` buffers, and that decides this outright** — it is not a
    /// stylistic choice between two spellings that both work. Measured 2026-08-13 on one 512 MiB
    /// upload: `-T` peaked at **5.3 MB** resident, `--data-binary @` at **1.08 GB** — twice the
    /// file, held in memory, for a file manager whose whole job is moving files of arbitrary size.
    ///
    /// The consequence is the payload-signing question PLAN.md left open, and the measurement
    /// answers it on the merits rather than by preference: `-T` signs the request with
    /// `x-amz-content-sha256: UNSIGNED-PAYLOAD`, because `curl` cannot hash a stream it has not read
    /// yet, while `--data-binary` computes the real digest (both confirmed on the wire against an
    /// endpoint that verifies SigV4 by hand). `UNSIGNED-PAYLOAD` is what S3 documents for exactly
    /// this case over HTTPS — the request is still fully signed, so it cannot be replayed or
    /// re-pointed, and the bytes are TLS's to protect rather than the signature's. Buying a payload
    /// digest at the price of holding every uploaded file twice in RAM is not a trade worth making.
    ///
    /// Two shapes measured in the same run that this builder exists to prevent:
    ///
    /// - **A destination URL must never end in `/`.** `curl` appends the *local* file's basename to
    ///   a `-T` URL that does — `-T /tmp/tiny.txt <bucket>/trailing/` arrived as the key
    ///   `trailing/tiny.txt`. Silent, and it writes a real object under a name nobody chose.
    /// - **`Expect: 100-continue` is left to `curl`'s own threshold** (it adds the header above
    ///   ~1 KiB — the 39-byte upload carried none, the 3 MiB one did). Against a server that ignores
    ///   it, the header costs a flat **1.02 s** per upload; against one that answers, nothing. It is
    ///   kept because the alternative is worse in the direction that matters: without it, an upload
    ///   to a bucket the key cannot write to sends the whole file before learning about the 403 —
    ///   and `curl`'s threshold already restricts the cost to files big enough for that to matter.
    public static func upload(session: S3Session, key: String, localPath: String) -> [String] {
        common(session: session) + configFromStandardInput
            + ["--upload-file", localPath, session.location.url(forKey: key)]
    }

    /// Write a zero-byte object — the folder marker `createDirectory` leaves behind, and the empty
    /// file `createFile` makes.
    ///
    /// `--data-binary ""` rather than a bare `-X PUT`, and rather than `-T /dev/null`, both of which
    /// were measured against a real endpoint:
    ///
    /// - **`-T /dev/null` is wrong twice.** `/dev/null` is not a regular file, so `curl` cannot
    ///   state a length and falls back to `Transfer-Encoding: chunked` with `UNSIGNED-PAYLOAD` — a
    ///   combination S3 rejects outright, since a chunked upload needs its own streaming signature.
    ///   And the write-out reported 5 bytes uploaded for an empty file, which is the chunk framing.
    /// - **A bare `-X PUT` sends no `Content-Length` header at all.** Legal HTTP, and one more thing
    ///   for a strict S3-compatible server to disagree about.
    ///
    /// `--data-binary ""` sends an explicit `Content-Length: 0` and the real SHA-256 of the empty
    /// string, so the request is fully signed and states its own emptiness. The URL here *may* end
    /// in `/` — that is what makes it a folder marker — and does so safely because `-T` is not
    /// involved (see ``upload(session:key:localPath:)``).
    public static func putEmptyObject(session: S3Session, key: String) -> [String] {
        common(session: session) + configFromStandardInput
            + ["-X", "PUT", "--data-binary", "", session.location.url(forKey: key)]
    }

    // MARK: - Multipart

    /// Open a multipart upload, whose answer carries the id every later request quotes.
    ///
    /// `--data-binary ""` for the same reason ``putEmptyObject(session:key:)`` uses it: this POST
    /// has no body, and it is the one spelling that states its own emptiness with a real
    /// `Content-Length: 0` and a real payload digest rather than falling back to chunked framing.
    public static func createMultipartUpload(session: S3Session, key: String) -> [String] {
        common(session: session) + configFromStandardInput
            + ["-X", "POST", "--data-binary", ""]
            + ["\(session.location.url(forKey: key))?uploads"]
    }

    /// Upload one part from a local slice file.
    ///
    /// `-T` again, so a part streams and memory stays flat whatever the part size — which is what
    /// lets the part size be chosen for request efficiency instead of being capped by RAM
    /// (``S3PartSlice`` argues why the slice is a file at all).
    ///
    /// **The upload id is percent-encoded**, and that is the continuation-token lesson applied
    /// before it can bite: an upload id is an opaque server-chosen token, so it is exactly the kind
    /// of value that round-trips raw right up until the day a server issues one containing a
    /// character that means something in a query string. The failure would be intermittent and
    /// per-server, which is the worst shape available.
    public static func uploadPart(
        session: S3Session,
        key: String,
        uploadID: String,
        partNumber: Int,
        localPath: String
    ) -> [String] {
        let query = "partNumber=\(partNumber)&uploadId=\(S3Key.encodedForQuery(uploadID))"
        return common(session: session) + configFromStandardInput
            + ["--upload-file", localPath]
            + ["\(session.location.url(forKey: key))?\(query)"]
    }

    /// Close a multipart upload, handing the server the manifest of parts to assemble.
    ///
    /// The manifest travels as a **file** for the reason
    /// ``deleteObjects(session:bodyPath:contentMD5:)`` does: 10 000 parts of `<Part>` markup runs to
    /// hundreds of kilobytes, which is past `ARG_MAX`, so an inline body would work until somebody
    /// uploaded something large enough to need the parts. It carries no secret — part numbers and
    /// ETags — and stdin is holding the credential regardless.
    ///
    /// No `Content-MD5` here, unlike the batch delete: S3 requires that header on `DeleteObjects`
    /// and does not on this verb.
    public static func completeMultipartUpload(
        session: S3Session,
        key: String,
        uploadID: String,
        bodyPath: String
    ) -> [String] {
        common(session: session) + configFromStandardInput
            + ["-X", "POST", "--data-binary", "@\(bodyPath)"]
            + ["-H", "Content-Type: application/xml"]
            + ["\(session.location.url(forKey: key))?uploadId=\(S3Key.encodedForQuery(uploadID))"]
    }

    /// Abandon a multipart upload and release the parts already stored.
    ///
    /// **This is a bill, not tidiness.** S3 keeps the parts of an unfinished upload indefinitely and
    /// charges storage for them, and they are invisible to an ordinary listing — so an upload that
    /// dies without aborting leaves the user paying for bytes they cannot see and did not keep. It
    /// is the one request in this backend whose whole purpose is to run after something went wrong.
    public static func abortMultipartUpload(
        session: S3Session,
        key: String,
        uploadID: String
    ) -> [String] {
        common(session: session) + configFromStandardInput
            + ["-X", "DELETE"]
            + ["\(session.location.url(forKey: key))?uploadId=\(S3Key.encodedForQuery(uploadID))"]
    }

    /// Copy one object to another key **inside the same bucket**, server-side.
    ///
    /// This is the rename primitive, and the reason a rename costs no local bandwidth: the bytes
    /// never leave S3. `curl` signs the `x-amz-copy-source` header itself — measured on the wire,
    /// it arrives in `SignedHeaders` as `host;x-amz-content-sha256;x-amz-copy-source;x-amz-date` —
    /// which matters because S3 requires every `x-amz-*` header to be signed and would otherwise
    /// refuse the request.
    ///
    /// What `curl` does **not** do is encode the value: the header is passed through byte for byte
    /// (probed with spaces and `+` in the source key, both of which arrived exactly as written). So
    /// the encoding is this builder's, and it uses the same path rule the URL does — S3 reads
    /// `x-amz-copy-source` as an encoded path, so a raw `+` or `#` in a key would name a different
    /// object than the one being renamed.
    public static func copyObject(
        session: S3Session,
        sourceKey: String,
        destinationKey: String
    ) -> [String] {
        let source = "/\(session.location.bucket)/\(S3Key.encodedForPath(sourceKey))"
        return common(session: session) + configFromStandardInput
            + ["-X", "PUT", "-H", "x-amz-copy-source: \(source)"]
            + [session.location.url(forKey: destinationKey)]
    }

    /// Delete one object.
    ///
    /// S3's `DeleteObject` is **idempotent** — deleting a key that is not there answers 204, not
    /// 404 — so this cannot be used to ask whether something existed. Nothing here needs to: the
    /// panel has already listed what it is deleting.
    public static func deleteObject(session: S3Session, key: String) -> [String] {
        common(session: session) + configFromStandardInput
            + ["-X", "DELETE", session.location.url(forKey: key)]
    }

    /// Delete up to ``S3DeleteBatch/maximumKeys`` objects in one request.
    ///
    /// The body is passed as a **file** rather than inline in `argv`: 1000 keys of ordinary length
    /// run to tens of kilobytes and long ones approach `ARG_MAX`, so an inline body is a batch size
    /// that works until somebody's file names are long. It carries no secret — object keys, which
    /// the URL already exposes — so a temp file is a size decision rather than a security one, and
    /// `-K -` is holding stdin for the credential regardless.
    ///
    /// `Content-MD5` is required by S3 on this verb and is computed by ``S3DeleteBatch``; `curl`
    /// signs the header but never produces one.
    public static func deleteObjects(
        session: S3Session,
        bodyPath: String,
        contentMD5: String
    ) -> [String] {
        common(session: session) + configFromStandardInput
            + ["-X", "POST", "--data-binary", "@\(bodyPath)"]
            + ["-H", "Content-MD5: \(contentMD5)", "-H", "Content-Type: application/xml"]
            + ["\(session.location.bucketURL)?delete"]
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
        "s3-size=%{size_download}\\n",
        "s3-up=%{size_upload}\\n",
        "s3-etag=%header{etag}\\n"
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
        /// Bytes this invocation sent.
        ///
        /// A separate field rather than one "transferred" number, because a single invocation can
        /// legitimately have both: a *refused* upload sends the whole file and then receives the
        /// `<Error>` document. Collapsing them would report a failed upload's size as the sum of
        /// the file and the refusal that rejected it. The caller says which direction it asked for.
        public let bytesUploaded: Int64
        /// The `ETag` response header, which is how an uploaded **part** identifies itself — the
        /// value the completion manifest has to quote back.
        ///
        /// It rides the write-out rather than a header dump because `%header{etag}` already exists
        /// for exactly this (measured 2026-08-13 returning `"f804fb…"`, quotes included), so a part
        /// upload needs no second mechanism and no `-D -` competing with `--output` for a stream.
        /// Carried **verbatim**, quotes and all: S3 compares the value byte for byte when it
        /// assembles the object, so a tidied ETag fails the completion (``S3UploadedPart``).
        public let etag: String?
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
            bytesDownloaded: values["s3-size"].flatMap(Int64.init) ?? 0,
            bytesUploaded: values["s3-up"].flatMap(Int64.init) ?? 0,
            etag: values["s3-etag"]
        )
    }
}
