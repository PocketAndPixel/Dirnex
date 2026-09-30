import Foundation

/// Reads the labelled fields of a `curl` invocation carrying **several** transfers at once — the
/// mechanism ``S3PartWriteOut`` and ``S3SegmentWriteOut`` are two typed readings of.
///
/// A parallel run is one process, so the single `s3-…` write-out every ordinary invocation uses
/// cannot work: four sections would print four `s3-status=` lines into one stream with nothing to
/// say which was whose. Indexing each label by the transfer it belongs to is what makes the answers
/// attributable, and it arrived independently on both sides of this backend — parts as
/// `s3-part3-status=`, segments as `s3-seg3-status=` — which is precisely the "one rule, several
/// spellings" shape this project keeps paying for. So the rule lives here once and the two readers
/// differ only in the label they ask for and the fields they publish.
///
/// Three things about that stream were measured rather than assumed (2026-08-23, `curl` 8.7.1
/// against a local endpoint that logs what it is sent):
///
/// - **A section's write-out is emitted the moment that section finishes**, not at the end of the
///   run. That is what makes this a *progress* source as well as a result.
/// - **Sections finish in any order**, so the fields are read into a dictionary rather than a list.
/// - **The write-out opens with a newline of its own**, because a section that finishes while
///   `curl` is printing something else lands glued to the end of that line — measured with the
///   progress meter on, where `…15.9M      s3-part4-status=200` arrived as one line and a
///   prefix-keyed reader would have dropped the field. Both batches run with the meter off, so this
///   is insurance against `curl`'s own prose rather than a fix for a symptom, and it costs a byte.
struct S3IndexedWriteOut: Sendable, Equatable {
    /// What comes between `s3-` and the index — `part` or `seg`.
    let label: String
    /// Every field that has arrived, filed under the transfer that printed it.
    private(set) var values: [Int: [String: String]] = [:]
    /// The tail that has not been terminated yet — a chunked reader splits wherever the pipe
    /// happened to fill, so a half-written label is held rather than read as a whole one.
    private var pending = ""

    init(label: String) {
        self.label = label
    }

    /// The `write-out` value for one transfer: `%{stderr}`, a newline of its own, then one
    /// `s3-<label><index>-<name>=<curl variable>` line per field.
    ///
    /// `\n` is the two-character sequence `curl` expands, exactly as ``S3WriteOut/format`` uses it,
    /// so the value survives both `argv` and a config file's own unescaping. `%{stderr}` keeps the
    /// fields off stdout, where a refused transfer's `<Error>` document is the only thing worth
    /// having.
    static func format(label: String, index: Int, fields: [(String, String)]) -> String {
        (["%{stderr}", "\\n"] + fields.map { "s3-\(label)\(index)-\($0.0)=\($0.1)\\n" }).joined()
    }

    /// Fold the next piece of the run's stderr in.
    mutating func consume(_ text: String) {
        pending += text
        while let index = pending.firstIndex(where: { $0 == "\r" || $0 == "\n" }) {
            absorb(String(pending[..<index]))
            pending = String(pending[pending.index(after: index)...])
        }
    }

    /// Absorb whatever is left unterminated — what a reader holding a whole capture ends with,
    /// since the last line need not carry a newline and is a field like any other.
    mutating func flush() {
        absorb(pending)
        pending = ""
    }

    /// The transfers that have printed a status — those that are **done**, whatever they answered.
    var completed: Set<Int> {
        Set(values.compactMap { index, fields in fields["status"] != nil ? index : nil })
    }

    /// File one line under the transfer it names, ignoring everything that is not one of our
    /// labels — `curl`'s own prose shares this stream, which is the whole reason they are labelled.
    private mutating func absorb(_ line: String) {
        guard let separator = line.firstIndex(of: "="),
              let (index, field) = split(String(line[..<separator]))
        else { return }
        let value = String(line[line.index(after: separator)...])
            .trimmingCharacters(in: .whitespaces)
        values[index, default: [:]][field] = value
    }

    /// Split `s3-part12-status` into `(12, "status")`, or `nil` when the name is not one of ours.
    ///
    /// Written out rather than matched with a regular expression because the *suffix* has to be
    /// taken from the first hyphen after the digits: a field name could grow one, and the index
    /// could not (it is digits by construction).
    private func split(_ name: String) -> (Int, String)? {
        let prefix = "s3-\(label)"
        guard name.hasPrefix(prefix) else { return nil }
        let body = name.dropFirst(prefix.count)
        guard let hyphen = body.firstIndex(of: "-"),
              let index = Int(body[..<hyphen]), index >= 1 else { return nil }
        return (index, String(body[body.index(after: hyphen)...]))
    }
}
