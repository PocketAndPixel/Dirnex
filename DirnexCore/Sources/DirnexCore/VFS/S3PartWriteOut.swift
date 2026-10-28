import Foundation

/// The write-out for one part of a **parallel** upload batch, and the reader for what a whole batch
/// produces (docs/HISTORY.md ▸ After M19).
///
/// The mechanism — indexed labels read off one stream, in any order, from chunks split anywhere —
/// is ``S3IndexedWriteOut``'s, and its doc comment carries what was measured about that stream.
/// What lives here is the part that is about an *upload*: which fields a part reports, and that an
/// ETag is carried verbatim.
public struct S3PartWriteOut: Sendable, Equatable {
    /// What one part reported.
    public struct Fields: Sendable, Equatable {
        /// The HTTP status, or 0 when the section never got an answer (`curl` prints `000`).
        public let status: Int
        /// The `ETag` the completion manifest has to quote back, **verbatim** — quotes included,
        /// since S3 compares it byte for byte (``S3UploadedPart``).
        public let etag: String?
        /// Bytes this section sent.
        public let bytesUploaded: Int64
        /// This section's own `curl` exit code, or `nil` when it printed none.
        public let exitCode: Int32?
    }

    /// The `write-out` value for part `number`.
    public static func format(forPart number: Int) -> String {
        S3IndexedWriteOut.format(
            label: Self.label,
            index: number,
            fields: [
                ("status", "%{http_code}"),
                ("exit", "%{exitcode}"),
                ("etag", "%header{etag}"),
                ("up", "%{size_upload}")
            ]
        )
    }

    private static let label = "part"
    private var reader = S3IndexedWriteOut(label: S3PartWriteOut.label)

    public init() {}

    /// Fold the next piece of the batch's stderr in.
    public mutating func consume(_ text: String) {
        reader.consume(text)
    }

    /// Read a complete capture in one go — the form a caller with the whole stream in hand uses.
    public static func parse(stderr: String) -> S3PartWriteOut {
        var out = S3PartWriteOut()
        out.reader.consume(stderr)
        out.reader.flush()
        return out
    }

    /// The parts whose status has arrived — those that are **done**, whatever they answered.
    ///
    /// This is the progress hook: a part reports its own length the moment it appears here, which
    /// is the only observable a parallel upload has. `curl`'s parallel meter does carry an aggregate
    /// upload percentage, and it is deliberately not read: its columns are a claim about that
    /// version's table, where these labels are a claim about a string this file writes.
    public var completedParts: Set<Int> { reader.completed }

    /// What part `number` reported, or `nil` when nothing of it has arrived yet.
    ///
    /// A part with no status is *not* a part with status 0: a section `curl` never ran — the whole
    /// invocation died at a bad argument, or the process was terminated — prints nothing at all, and
    /// a caller has to tell that from a section that ran and was refused.
    public func fields(forPart number: Int) -> Fields? {
        guard let raw = reader.values[number], let status = raw["status"].flatMap(Int.init) else {
            return nil
        }
        let etag = raw["etag"]
        return Fields(
            status: status,
            etag: (etag?.isEmpty ?? true) ? nil : etag,
            bytesUploaded: raw["up"].flatMap(Int64.init) ?? 0,
            exitCode: raw["exit"].flatMap(Int32.init)
        )
    }

    /// Part `number`'s answer, or the transport failure it was — the segments' rule
    /// (``S3SegmentWriteOut/response(forSegment:processExitCode:)``), read for a part.
    ///
    /// What a cut part looks like differs, and it is why this is a classification fix rather than
    /// a rescue. Measured 2026-10-23 on two parts, the second held to a rate it could not finish:
    /// it reported **`status=100`**, the `Expect: 100-continue` go-ahead that arrived before the
    /// body, with `exit=28`. Read by status, that is a refusal with a status no refusal has; read
    /// by exit code, it is the timeout it was.
    ///
    /// `body` is the whole run's stdout, handed to every part for the reason
    /// `S3CurlRunner.performParts` gives.
    public func response(
        forPart number: Int,
        processExitCode: Int32,
        body: Data
    ) throws -> S3Response {
        guard let fields = fields(forPart: number) else {
            throw S3ResponseError.transport(.classify(curlExit: processExitCode))
        }
        let exitCode = fields.exitCode ?? processExitCode
        guard S3WriteOut.isAnswer(status: fields.status, exitCode: exitCode) else {
            throw S3ResponseError.transport(.classify(curlExit: exitCode))
        }
        return S3Response(
            status: fields.status,
            body: body,
            bytesTransferred: fields.bytesUploaded,
            etag: fields.etag
        )
    }
}
