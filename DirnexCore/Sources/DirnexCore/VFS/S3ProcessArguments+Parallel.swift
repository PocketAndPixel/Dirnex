import Foundation

/// One `curl` invocation and the config it reads on stdin — the pair a batch needs, since a
/// parallel run puts every per-transfer option in the **config** and only the run's own flags in
/// `argv`.
public struct S3ParallelInvocation: Sendable, Equatable {
    /// The `curl` arguments. Carries no secret, and nothing that varies per part.
    public let arguments: [String]
    /// The multi-section config, written to the child's stdin. This is where the credential rides,
    /// as it does for every other invocation — never `argv`, where any `ps` would read it.
    public let configuration: String
}

public extension S3ProcessArguments {
    /// Upload several parts of one multipart upload **at once**, in a single `curl`.
    ///
    /// One process rather than several is what keeps this a change of shape and not of
    /// architecture: `S3CurlRunner` already spawns one child, drains both pipes, bounds the wait
    /// and terminates on cancel, so a Stop still stops everything and nothing here needs a thread.
    /// It is the shape the segmented-download design reached for on the same grounds (docs/HISTORY.md ▸ After M19).
    ///
    /// Measured 2026-08-23 (`curl` 8.7.1, four 8 MiB parts against a local endpoint that logs when
    /// each request starts and ends):
    ///
    /// - **`--parallel-immediate` is not optional, and its absence is silent.** Without it `curl`
    ///   runs the *first* transfer alone and only then starts the rest, so it can see whether the
    ///   connection is reusable — four parts took 1.02 s against 0.51 s with it, all four starting
    ///   at 0.000. A batch of N would otherwise cost two rounds rather than one, which reads as
    ///   "parallel uploads are only twice as fast as they should be" and nothing reports it.
    /// - **Every per-transfer option belongs in its own section.** The credential, the signature
    ///   specifier and both timeouts are repeated per part; `argv` carries only `-Z`, the
    ///   concurrency cap, and the silencing.
    /// - **The meter is off (`-sS`).** Progress comes from the indexed write-outs as each part
    ///   lands (``S3PartWriteOut``), which needs no reading of `curl`'s parallel table — and with
    ///   the meter on, a section finishing mid-row glues its first field to the end of that row.
    ///
    /// `credentials` is the already-built config line (``S3ConfigFile/credentials(accessKeyID:secretAccessKey:)``),
    /// passed in rather than assembled here so this stays a builder that never sees a secret's
    /// halves — the same division `S3CurlRunner` has always had, one layer along.
    static func uploadParts(
        session: S3Session,
        parts: [S3PartRequest],
        credentials: String
    ) -> S3ParallelInvocation {
        let sections = parts.map { part in
            let query = "partNumber=\(part.number)&uploadId=\(S3Key.encodedForQuery(part.uploadID))"
            return [
                credentials.hasSuffix("\n") ? credentials : credentials + "\n",
                "connect-timeout = \(session.connectTimeout)\n",
                "max-time = \(session.maxTime)\n",
                "aws-sigv4 = \(S3ConfigFile.quote(session.location.signatureSpecifier))\n",
                "upload-file = \(S3ConfigFile.quote(part.localPath))\n",
                "url = \(S3ConfigFile.quote("\(session.location.url(forKey: part.key))?\(query)"))\n",
                "write-out = \(S3ConfigFile.quote(S3PartWriteOut.format(forPart: part.number)))\n"
            ].joined()
        }
        return S3ParallelInvocation(
            arguments: [
                "-Z",
                "--parallel-immediate",
                "--parallel-max", String(max(1, parts.count)),
                "-sS",
                "-K", "-"
            ],
            configuration: sections.joined(separator: "next\n")
        )
    }
}
