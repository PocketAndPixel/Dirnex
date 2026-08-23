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
    }

    /// The `write-out` value for part `number`.
    public static func format(forPart number: Int) -> String {
        S3IndexedWriteOut.format(
            label: Self.label,
            index: number,
            fields: [
                ("status", "%{http_code}"),
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
            bytesUploaded: raw["up"].flatMap(Int64.init) ?? 0
        )
    }
}
