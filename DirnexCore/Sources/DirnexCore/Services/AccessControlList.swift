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
///
/// `Codable` because an ACL change is undoable and the journal survives relaunch: the step carries
/// the whole prior list and the whole new one. **Whole lists, never a diff** — order is meaning, so
/// "entry 2 changed" is not a description of an ACL edit that also moved it.
public struct AccessControlList: Sendable, Hashable, Codable {
    /// The entries, in evaluation order.
    public var entries: [ACLEntry]

    public init(entries: [ACLEntry] = []) { self.entries = entries }

    /// The list with the entry at `index` moved to `destination`, or unchanged if either is out of
    /// range. The editor's Move Up / Move Down, as a pure function — reordering *is* the edit here,
    /// so it is a rule with a test rather than an array shuffle in a button handler.
    public func moving(from index: Int, to destination: Int) -> AccessControlList {
        guard entries.indices.contains(index), entries.indices.contains(destination) else {
            return self
        }
        var moved = entries
        moved.insert(moved.remove(at: index), at: destination)
        return AccessControlList(entries: moved)
    }

    /// No entries — a file with no ACL. `acl_get_file` reports this as `nil` + `ENOENT`, a normal
    /// answer the reader maps to an empty list rather than an error.
    public var isEmpty: Bool { entries.isEmpty }

    /// This list as it can honestly apply to an item of `kind` — the adjustment a **recursive** apply
    /// owes every file it reaches with a list a *directory* authored (PLAN.md §M14 Slice 4).
    ///
    /// **The kernel does not do this for you, and it fails in the quiet direction.** Probed
    /// 2026-08-01: `acl_set_file` accepts a directory's canonical text on a regular file, returns
    /// `0`, and `acl_get_file` reads it back **verbatim** — `delete_child`, `file_inherit` and
    /// `directory_inherit` all still stored — while `ls -le` shows only `allow read,write,execute,
    /// append`. So the bits survive on disk, mean nothing, and are invisible to every tool that
    /// displays an ACL *except* one that reads the canonical text, which is exactly what Dirnex's
    /// Sharing tab does. Propagating verbatim would put `delete_child` on a file's rights matrix —
    /// a false claim on the one tab whose whole job is that answer.
    ///
    /// `chmod(1)` strips both on the way in (probed: `chmod +a "everyone allow delete_child" f`
    /// exits 0 and yields `0: group:everyone allow` — an entry with nothing in it), so stripping is
    /// what the platform's own front end does. The one thing it does *not* do is notice what it has
    /// left behind, which is why the second half matters: an entry reduced to no rights is dropped
    /// rather than written. It would occupy a position in the evaluation order while allowing and
    /// denying nothing, and ``ACLEntry/isMeaningful`` already states that the editor refuses to
    /// create one — a recursion may not create through the back door what the editor refuses at the
    /// front.
    ///
    /// The `inherited` marker is *not* a directory control and is kept: it records where an entry
    /// came from, and a file can legitimately carry one.
    public func adjusted(for kind: FileEntry.Kind) -> AccessControlList {
        guard kind != .directory else { return self }
        let adjusted = entries.compactMap { entry -> ACLEntry? in
            var copy = entry
            copy.rights.remove(.deleteChild)
            copy.inheritance.subtract(ACLInheritance.directoryOnly)
            return copy.isMeaningful ? copy : nil
        }
        return AccessControlList(entries: adjusted)
    }

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
