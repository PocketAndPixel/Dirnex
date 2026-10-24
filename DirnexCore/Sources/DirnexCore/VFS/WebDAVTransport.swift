import Foundation

/// One HTTP answer from a WebDAV server, in the shape the backend classifies.
///
/// The body travels whether or not the request succeeded, because a refusal's body can be the
/// outcome — a 207 or 424 multistatus naming the members that failed (``WebDAVServiceError``).
public struct WebDAVHTTPResponse: Sendable, Equatable {
    /// The HTTP status. Never 0: a run that got no answer is a thrown transport failure.
    public let status: Int
    /// The response body — a multistatus, an HTML error page, or empty for a download, whose bytes
    /// went to a file.
    public let body: Data
    /// Every header, names lowercased, each with all its values in order (``WebDAVWriteOut``).
    public let headers: [String: [String]]
    /// Bytes received by this request — the delta, for a resumed download.
    public let bytesDownloaded: Int64
    /// Bytes sent by this request.
    public let bytesUploaded: Int64

    public init(
        status: Int,
        body: Data = Data(),
        headers: [String: [String]] = [:],
        bytesDownloaded: Int64 = 0,
        bytesUploaded: Int64 = 0
    ) {
        self.status = status
        self.body = body
        self.headers = headers.reduce(into: [:]) { $0[$1.key.lowercased(), default: []] += $1.value }
        self.bytesDownloaded = bytesDownloaded
        self.bytesUploaded = bytesUploaded
    }

    /// Whether the server said yes: the whole 2xx range, since a resumed download answers 206 and a
    /// listing 207.
    public var isSuccess: Bool { (200..<300).contains(status) }

    /// Every value of one header, in order. Several is the ordinary case for `WWW-Authenticate`
    /// and `DAV`.
    public func values(_ name: String) -> [String] { headers[name.lowercased()] ?? [] }

    /// The first value of one header.
    public func value(_ name: String) -> String? { values(name).first }
}

/// The non-hermetic boundary beneath a ``WebDAVBackend``: it sends one HTTP request per call and
/// hands back the raw answer. Everything above it — the URL rules, the multistatus parser, the
/// listing split, the stat rule, the resume decision, the error mapping and the connect probe — is
/// pure and tested in `DirnexCore`; the app supplies a `Process`-driven implementation over the
/// system `curl`, and tests a fake fed the bytes the NAS and macOS's Apache sent (PLAN.md §2).
///
/// Paths are the **backend's** — the pane's `/` — and the transport builds the URL through
/// ``WebDAVProcessArguments``, which maps them under the location's root.
///
/// A method throws only when there was no answer, or the answer stopped part-way: a
/// ``WebDAVResponseError/transport(_:)``, read off `curl`'s exit code by
/// ``WebDAVWriteOut/response(exitCode:standardOutput:standardError:)``. **A refusal is a returned
/// value**, as on S3, since `curl` exits 0 for a 401, a 404 and a 423 alike.
///
/// Every method is synchronous and may block on the network; the backend is only ever called off
/// the main thread.
public protocol WebDAVTransport: Sendable {
    /// One PROPFIND for the named properties (``WebDAVProcessArguments/propfindBody``) at `depth`,
    /// naming the path as a collection when `isCollection`.
    func propfind(_ backendPath: String, depth: WebDAVDepth, isCollection: Bool) throws
        -> WebDAVHTTPResponse

    /// Several `Depth: 1` PROPFINDs of folders in **one** `curl`, so over one connection
    /// (``WebDAVProcessArguments/listings(session:requests:credentials:)``, PLAN.md §M32 Slice 5).
    ///
    /// One answer per path, in order. A refusal is a section's answer; the first section's ends the
    /// run, and the sections after it come back ``WebDAVBatchAnswer/notSent``, as do those after a
    /// section that got no answer. Throws only when there was no run to read, and
    /// `CancellationError` when `isCancelled` answered `true`.
    func propfindBatch(_ backendPaths: [String], isCancelled: () -> Bool) throws
        -> [WebDAVBatchAnswer]

    /// Download one file to a local path, resuming from the local file's length when `resume`.
    ///
    /// `progress` reports **deltas** as the destination grows, and `isCancelled` is polled while
    /// the bytes move, for the reason ``S3Transport/upload(localPath:to:progress:isCancelled:)``
    /// gives: a transfer is one `curl` that may run for an hour, and a Stop or a progress bar has to
    /// reach inside it. The exact count is ``WebDAVHTTPResponse/bytesDownloaded``.
    func download(
        _ backendPath: String,
        to localPath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> WebDAVHTTPResponse

    /// Download one file as several byte ranges **at once**, each into its own file and each
    /// carrying `If-Match` with the file's tag, for the caller to join (``SegmentAssembly``,
    /// ``WebDAVProcessArguments/downloadSegments(session:file:segments:credentials:)``).
    ///
    /// One download is one `curl` and one connection, and a link that holds each connection to a
    /// rate gives N times that to N of them: measured at 4 MiB/s a connection, 40 MiB took 10.12 s
    /// in one stream and 2.46 s in four (``SegmentedDownloadLimits/webdav``).
    ///
    /// The default **forwards** to the plain download and says so (``WebDAVSegmentedDownload/whole(_:)``),
    /// S3's rule for an additive verb: one stream produces the same file, unguarded as the plain
    /// download always was, so a transport without this is slow and never wrong. `progress`
    /// reports deltas as the pieces grow.
    func downloadSegments(
        _ segments: [DownloadSegment],
        of file: WebDAVTaggedFile,
        to localPath: String,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> WebDAVSegmentedDownload

    // MARK: - The write half (PLAN.md §M32 Slice 4)

    /// One MKCOL.
    func mkcol(_ backendPath: String) throws -> WebDAVHTTPResponse

    /// Upload one local file with `-T`, carrying `condition` as a header.
    ///
    /// `progress` reports **deltas** from `curl`'s meter, which is the only measure an upload has;
    /// the exact count is ``WebDAVHTTPResponse/bytesUploaded``, which the backend settles the bar
    /// on. A cancelled run throws `CancellationError` and changes nothing on the server (Apache
    /// writes a PUT into a temporary file, measured — ``WebDAVProcessArguments``).
    func upload(
        localPath: String,
        to backendPath: String,
        condition: S3WriteCondition,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> WebDAVHTTPResponse

    /// One PUT with an empty body, carrying `condition` as a header.
    func putEmpty(_ backendPath: String, condition: S3WriteCondition) throws -> WebDAVHTTPResponse

    /// One MOVE with `Overwrite: F`.
    func move(_ backendPath: String, to destinationPath: String) throws -> WebDAVHTTPResponse

    /// One COPY of a file with `Overwrite: F`.
    func copy(_ backendPath: String, to destinationPath: String) throws -> WebDAVHTTPResponse

    /// One DELETE.
    func delete(_ backendPath: String) throws -> WebDAVHTTPResponse
}

public extension WebDAVTransport {
    /// The plain download, reported as what it is: the whole file in one stream, with nothing to
    /// join.
    func downloadSegments(
        _ segments: [DownloadSegment],
        of file: WebDAVTaggedFile,
        to localPath: String,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> WebDAVSegmentedDownload {
        .whole(try download(
            file.backendPath,
            to: localPath,
            resume: false,
            progress: progress,
            isCancelled: isCancelled
        ))
    }
}
