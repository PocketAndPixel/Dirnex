import Foundation

public extension S3ProcessArguments {
    /// Download several ranges of one object **at once**, in a single `curl` (docs/HISTORY.md ▸ After M19).
    ///
    /// One process rather than several is what keeps this a change of shape and not of
    /// architecture: `S3CurlRunner` already spawns one child, drains both pipes, bounds the wait and
    /// terminates on cancel, so a Stop still stops every segment and nothing here needs a thread.
    /// The alternative was probed and does work — N processes each writing into one destination at
    /// its own offset through a seeked `FileHandle` produces a byte-identical file — and was not
    /// taken, because it needs concurrent orchestration, N stderr drains, per-segment meters, and a
    /// sparse destination whose size has stopped being the byte count.
    ///
    /// Probed on the live fixture bucket 2026-08-20: 4 sections in 7.9 s with the reassembled bytes
    /// **SHA-256 identical** to a single-stream reference; an all-good run exits 0 with one
    /// `s3-seg<n>-status=206` per section and part files of exactly the planned lengths; and a
    /// section aimed at a missing key exits **22** with `s3-seg<n>-status=404` among the lines, the
    /// other segments complete and the failing section's file **not created** — so `--fail` holds
    /// per section and no `<Error>` document lands under a segment's name.
    ///
    /// Four flags, and each is here for a measured reason:
    ///
    /// - **`--parallel-immediate` is not optional, and its absence is silent.** Without it `curl`
    ///   runs the *first* transfer alone and only then starts the rest, so it can see whether the
    ///   connection is reusable — measured on the upload twin, four transfers took 1.02 s against
    ///   0.51 s with it. A run of N would otherwise cost two rounds rather than one, which reads as
    ///   "parallel downloads are only half as fast as they should be" and nothing reports it.
    /// - **`fail`, per section.** It is the one flag a transfer carries that a listing must not:
    ///   `output` writes whatever the server sends, and a refused download is still a *response*,
    ///   so without it a segment file would come away holding an `<Error>` document that assembly
    ///   would splice into the middle of the user's file. With it, nothing is created at all.
    /// - **The meter is off (`-sS`).** Progress comes from the segment files growing, which is exact
    ///   and free; and with the meter on, a section finishing mid-row glues its first field to the
    ///   end of that row.
    /// - **No `--continue-at` anywhere.** A segment is a `Range` request against a file this code
    ///   created for it, so there is never a partial to resume from; resume belongs to the
    ///   single-stream path, which is what a download with bytes already on disk still takes.
    ///
    /// `credentials` is the already-built config line
    /// (``S3ConfigFile/credentials(accessKeyID:secretAccessKey:)``), passed in rather than assembled
    /// here so this stays a builder that never sees a secret's halves — the same division
    /// `S3CurlRunner` has always had, one layer along.
    static func downloadSegments(
        session: S3Session,
        key: String,
        segments: [S3DownloadSegment],
        credentials: String
    ) -> S3ParallelInvocation {
        let url = session.location.url(forKey: key)
        let sections = segments.map { segment in
            [
                credentials.hasSuffix("\n") ? credentials : credentials + "\n",
                "connect-timeout = \(session.connectTimeout)\n",
                "max-time = \(session.maxTime)\n",
                "aws-sigv4 = \(S3ConfigFile.quote(session.location.signatureSpecifier))\n",
                "fail\n",
                "range = \(S3ConfigFile.quote(segment.headerValue))\n",
                "output = \(S3ConfigFile.quote(segment.localPath))\n",
                "url = \(S3ConfigFile.quote(url))\n",
                "write-out = \(S3ConfigFile.quote(S3SegmentWriteOut.format(forSegment: segment.number)))\n"
            ].joined()
        }
        return S3ParallelInvocation(
            arguments: [
                "-Z",
                "--parallel-immediate",
                "--parallel-max", String(max(1, segments.count)),
                "-sS",
                "-K", "-"
            ],
            configuration: sections.joined(separator: "next\n")
        )
    }
}
