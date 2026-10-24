import Foundation

/// One file as a stat just found it: where it is, and the strong entity tag every range of it is
/// guarded by. Bundled because a range is only worth asking for against the version it was cut from.
public struct WebDAVTaggedFile: Sendable, Equatable {
    /// The file, as the backend holds it — the pane's path, mapped under the root by the builder.
    public let backendPath: String
    /// The tag as the server spelled it, quotes and all. Never a weak one.
    public let entityTag: String

    public init(backendPath: String, entityTag: String) {
        self.backendPath = backendPath
        self.entityTag = entityTag
    }
}

/// What a segmented download turned out to be — the answer
/// ``WebDAVTransport/downloadSegments(_:of:to:progress:isCancelled:)`` gives.
///
/// Two cases for the reason ``S3SegmentedDownload`` has two: a transport that cannot split the
/// request has produced the file by the older route, and the caller's next step is different. Each
/// section's answer is kept as a status, as S3's is, since over HTTP every section has one worth
/// reading: 206 is a range, 200 is the whole file, 412 is a file that changed.
public enum WebDAVSegmentedDownload: Sendable, Equatable {
    /// Each segment's answer, in the order the segments were given. The pieces are on disk under
    /// the paths the segments named, and joining them is the caller's (``SegmentAssembly``).
    case segments([WebDAVBatchAnswer])
    /// This transport could not split the request, so the **whole** file was downloaded to the
    /// destination in one stream, unguarded, as the plain download is.
    case whole(WebDAVHTTPResponse)
}

public extension WebDAVProcessArguments {
    /// Download several ranges of one file **at once**, in one `curl`, each section guarded by
    /// `If-Match` with the file's tag (PLAN.md §M32, after Slice 6).
    ///
    /// S3's shape (``S3ProcessArguments/downloadSegments(session:key:segments:credentials:)``): one
    /// `-Z` run, one config section per range on stdin, each writing its own file, so a Stop stops
    /// every section and nothing here needs a thread. Measured 2026-10-24 against macOS's Apache:
    /// four sections opened four connections at once, each answered 206 with exactly its range, and
    /// the pieces joined SHA-256 identical to the file.
    ///
    /// What each section carries, and why:
    ///
    /// - **`If-Match`, not `If-Range`.** Both make a section conditional on the file the caller
    ///   stat'ed, and they fail differently. A stale `If-Range` answers **200 with the whole file**
    ///   (measured: 41 943 040 bytes for a 100-byte range), so every section of a changed file would
    ///   download all of it. A stale `If-Match` answers 412 and sends nothing, and with `fail` no
    ///   file is created. The tag goes as read, quotes and all, and only a strong one is sent: a
    ///   weak tag fails `If-Match` for a file nobody touched (``RemoteFileRevision/preconditionTag``).
    /// - **`fail`, per section**, for the reason the single download carries `--fail`: `output`
    ///   writes whatever the server sends, and a refusal's HTML page would otherwise be spliced into
    ///   the middle of the user's file. Every section, unlike the batched listing's first-only
    ///   `fail`: nothing after a refused range is worth sending more of.
    /// - **The connection's own options repeated in every section** — the timeouts, `-4`, the
    ///   scheme and credential, the pin — because `curl` reads one option set per transfer, and a
    ///   section without the pin would be an unpinned connection on the path nobody watches.
    /// - **No `--continue-at`.** A segment is a range into a file of its own, so there is never a
    ///   partial to resume; a download with bytes already on disk takes the single stream.
    ///
    /// And in `argv`: `-q` first (``common(session:showingProgress:)``), `--parallel-immediate`,
    /// without which `curl` runs the first section alone before starting the rest (NOTES.md ▸ curl
    /// for S3), and the meter off, since progress is the segment files growing.
    ///
    /// `credentials` is the config line, or `nil` when the session sends none, built by the caller
    /// so this never sees a password.
    static func downloadSegments(
        session: WebDAVSession,
        file: WebDAVTaggedFile,
        segments: [DownloadSegment],
        credentials: String?
    ) -> WebDAVBatchInvocation {
        let url = url(session, file.backendPath, isCollection: false)
        let sections = segments.map { segment in
            ([
                "connect-timeout = \(session.connectTimeout)\n",
                "max-time = \(session.maxTime)\n",
                "fail\n"
            ] + connectionLines(session: session, credentials: credentials) + [
                "header = \(FTPConfigFile.quote("If-Match: \(file.entityTag)"))\n",
                "range = \(FTPConfigFile.quote(segment.headerValue))\n",
                "output = \(FTPConfigFile.quote(segment.localPath))\n",
                "write-out = \(FTPConfigFile.quote(WebDAVSegmentWriteOut.format(segment: segment.number)))\n",
                "url = \(FTPConfigFile.quote(url))\n"
            ]).joined()
        }
        return WebDAVBatchInvocation(
            arguments: [
                "-q",
                "-Z",
                "--parallel-immediate",
                "--parallel-max", String(max(1, segments.count)),
                "-sS"
            ] + configFromStandardInput,
            configuration: sections.joined(separator: "next\n")
        )
    }
}

/// The per-section write-out of a segmented download, and the reader that turns a run's stdout into
/// one ``WebDAVBatchAnswer`` per segment.
///
/// The batched listing's reader (``WebDAVBatchWriteOut``) with the byte count added, since the
/// pieces' lengths are what assembly checks and what the bar settles on. Each section prints its
/// line the moment it finishes, labelled by segment number, so sections finishing in any order are
/// told apart.
public enum WebDAVSegmentWriteOut {
    static let label = "dav-seg="

    /// The line for segment `number`: the status, the section's own exit code and the bytes it
    /// received.
    static func format(segment number: Int) -> String {
        "\(label)\(number) %{http_code} %{exitcode} %{size_download}\n"
    }

    /// One answer per segment, in the order given.
    ///
    /// Each section is read by ``WebDAVWriteOut/isAnswer(status:exitCode:)`` off its own
    /// `%{exitcode}`, for the reason S3's segments are: the run's code belongs to none of them, and a
    /// section cut by `max-time` reports the 206 it had already seen. A section with no line never
    /// ran. The last line for a segment wins, as in the listing's reader.
    public static func answers(
        segments: [DownloadSegment],
        standardOutput: String
    ) -> [WebDAVBatchAnswer] {
        var reported: [Int: Line] = [:]
        for line in standardOutput.split(whereSeparator: \.isNewline) where line.hasPrefix(label) {
            let fields = line.dropFirst(label.count).split(separator: " ")
            guard fields.count == 4,
                  let number = Int(fields[0]),
                  let status = Int(fields[1]),
                  let exit = Int32(fields[2]),
                  let bytes = Int64(fields[3])
            else { continue }
            reported[number] = Line(status: status, exit: exit, bytes: bytes)
        }
        return segments.map { segment in
            guard let line = reported[segment.number] else { return .notSent }
            guard WebDAVWriteOut.isAnswer(status: line.status, exitCode: line.exit) else {
                return .noAnswer(.classify(curlExit: line.exit))
            }
            return .response(WebDAVHTTPResponse(status: line.status, bytesDownloaded: line.bytes))
        }
    }

    /// What one section's line said.
    private struct Line {
        let status: Int
        let exit: Int32
        let bytes: Int64
    }
}
