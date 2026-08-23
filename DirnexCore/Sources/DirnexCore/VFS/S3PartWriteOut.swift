import Foundation

/// The write-out for one part of a **parallel** batch, and the reader for what a whole batch
/// produces (docs/HISTORY.md ▸ After M19).
///
/// A batch is one `curl` carrying several transfers, so the single `s3-…` write-out every other
/// invocation uses cannot work here: four sections would print four `s3-status=` lines into one
/// stream with nothing to say which was whose. Indexing the labels by part number is what makes the
/// answers attributable, and it is the same shape the segmented *download* design reached for
/// independently (PLAN.md §4, `s3-seg3-status=`) — one stream, several transfers, labels that
/// carry their own identity.
///
/// Three things about that stream were measured rather than assumed (2026-08-23, `curl` 8.7.1
/// against a local endpoint that logs what it is sent):
///
/// - **A section's write-out is emitted the moment that section finishes**, not at the end of the
///   run. That is what makes this a *progress* source as well as a result: a part that has landed
///   says so while the others are still going.
/// - **Sections finish in any order**, so the labels are read into a dictionary rather than a list.
/// - **The write-out opens with a newline of its own**, because a section that finishes while
///   `curl` is printing something else lands glued to the end of that line — measured with the
///   progress meter on, where `…15.9M      s3-part4-status=200` arrived as one line and a
///   prefix-keyed reader would have dropped the field. The batch runs with the meter off, so this
///   is insurance against `curl`'s own prose rather than a fix for a symptom, and it costs a byte.
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
    ///
    /// `\n` is the two-character sequence `curl` expands, exactly as ``S3WriteOut/format`` uses it,
    /// so the value survives both `argv` and a config file's own unescaping. `%{stderr}` keeps the
    /// fields off stdout, where a refused part's `<Error>` document is the only thing worth having.
    public static func format(forPart number: Int) -> String {
        [
            "%{stderr}",
            "\\n",
            "s3-part\(number)-status=%{http_code}\\n",
            "s3-part\(number)-etag=%header{etag}\\n",
            "s3-part\(number)-up=%{size_upload}\\n"
        ].joined()
    }

    private var values: [Int: [String: String]] = [:]
    /// The tail that has not been terminated yet — a chunked reader splits wherever the pipe
    /// happened to fill, so a half-written label is held rather than read as a whole one.
    private var pending = ""

    public init() {}

    /// Fold the next piece of the batch's stderr in.
    public mutating func consume(_ text: String) {
        pending += text
        while let index = pending.firstIndex(where: { $0 == "\r" || $0 == "\n" }) {
            absorb(String(pending[..<index]))
            pending = String(pending[pending.index(after: index)...])
        }
    }

    /// Read a complete capture in one go — the form a caller with the whole stream in hand uses.
    public static func parse(stderr: String) -> S3PartWriteOut {
        var reader = S3PartWriteOut()
        reader.consume(stderr)
        // The last line need not be terminated, and it is a field like any other.
        reader.absorb(reader.pending)
        reader.pending = ""
        return reader
    }

    /// The parts whose status has arrived — those that are **done**, whatever they answered.
    ///
    /// This is the progress hook: a part reports its own length the moment it appears here, which
    /// is the only observable a parallel upload has. `curl`'s parallel meter does carry an aggregate
    /// upload percentage, and it is deliberately not read: its columns are a claim about that
    /// version's table, where these labels are a claim about a string this file writes.
    public var completedParts: Set<Int> {
        Set(values.compactMap { number, fields in fields["status"] != nil ? number : nil })
    }

    /// What part `number` reported, or `nil` when nothing of it has arrived yet.
    ///
    /// A part with no status is *not* a part with status 0: a section `curl` never ran — the whole
    /// invocation died at a bad argument, or the process was terminated — prints nothing at all, and
    /// a caller has to tell that from a section that ran and was refused.
    public func fields(forPart number: Int) -> Fields? {
        guard let raw = values[number], let status = raw["status"].flatMap(Int.init) else {
            return nil
        }
        let etag = raw["etag"]
        return Fields(
            status: status,
            etag: (etag?.isEmpty ?? true) ? nil : etag,
            bytesUploaded: raw["up"].flatMap(Int64.init) ?? 0
        )
    }

    /// File one line under the part it names, ignoring everything that is not one of our labels —
    /// `curl`'s own prose shares this stream, which is the whole reason the fields are labelled.
    private mutating func absorb(_ line: String) {
        guard let separator = line.firstIndex(of: "="),
              let (number, field) = Self.label(in: String(line[..<separator]))
        else { return }
        let value = String(line[line.index(after: separator)...])
            .trimmingCharacters(in: .whitespaces)
        values[number, default: [:]][field] = value
    }

    /// Split `s3-part12-status` into `(12, "status")`, or `nil` when the name is not one of ours.
    ///
    /// Written out rather than matched with a regular expression because the *suffix* has to be
    /// taken from the last hyphen: a field name could grow one, and the part number could not
    /// (it is digits by construction).
    private static func label(in name: String) -> (Int, String)? {
        let prefix = "s3-part"
        guard name.hasPrefix(prefix) else { return nil }
        let body = name.dropFirst(prefix.count)
        guard let hyphen = body.firstIndex(of: "-"),
              let number = Int(body[..<hyphen]), number >= 1 else { return nil }
        return (number, String(body[body.index(after: hyphen)...]))
    }
}
