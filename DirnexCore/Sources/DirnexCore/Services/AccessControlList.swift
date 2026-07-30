import Foundation

/// An ordered list of ACL entries — the full editable model of a file's access-control list (PLAN.md
/// §M14 Slice 3).
///
/// **Order is meaning.** macOS evaluates entries top to bottom and takes the first that decides, so a
/// deny placed before an allow is not the same ACL as the pair reversed. The model is therefore an
/// ordered `[ACLEntry]` that is never silently canonicalized or sorted — the exit criterion is that
/// an ACL authored in Dirnex reads back under `ls -le` *in the order Dirnex showed*, and one authored
/// with `chmod +a` displays in Dirnex in the same order the OS evaluates it.
///
/// The read/write path is `acl_to_text` → ``parse(_:)`` and ``canonicalText()`` → `acl_from_text`
/// (`AccessControlListIO`). This type is the pure, tested half: text in, model out, model in, text
/// out — verified both by round-tripping a **real** captured ACL and by having the OS read back what
/// it wrote.
public struct AccessControlList: Sendable, Hashable {
    /// The entries, in evaluation order.
    public var entries: [ACLEntry]

    public init(entries: [ACLEntry] = []) { self.entries = entries }

    /// No entries — a file with no ACL. `acl_get_file` reports this as `nil` + `ENOENT`, a normal
    /// answer the reader maps to an empty list rather than an error.
    public var isEmpty: Bool { entries.isEmpty }

    /// The `acl_to_text` / `acl_from_text` version header line.
    public static let header = "!#acl 1"

    /// Parse canonical ACL text into the ordered model.
    ///
    /// Handles the one thing that makes `acl_to_text` output not a plain line format: it **wraps** at
    /// roughly column 60 with a trailing `\` continuation (captured live), so a single logical entry
    /// can span several physical lines. Un-wrapping — dropping every backslash-before-newline — comes
    /// first; then each remaining non-header line is one entry.
    public static func parse(_ canonicalText: String) throws -> AccessControlList {
        let unwrapped = canonicalText
            .replacingOccurrences(of: "\\\r\n", with: "")
            .replacingOccurrences(of: "\\\n", with: "")
        var entries: [ACLEntry] = []
        for rawLine in unwrapped.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("!#acl") { continue }
            entries.append(try ACLEntry.parse(line: line))
        }
        return AccessControlList(entries: entries)
    }

    /// Serialize to canonical text `acl_from_text` accepts. One unwrapped line per entry — no column
    /// wrapping, which the parser round-trips and which the OS re-canonicalizes on write anyway.
    public func canonicalText() -> String {
        ([Self.header] + entries.map { $0.canonicalLine() }).joined(separator: "\n") + "\n"
    }
}
