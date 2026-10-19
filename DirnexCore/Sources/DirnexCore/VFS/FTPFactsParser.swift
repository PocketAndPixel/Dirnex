import Foundation

/// Parses the reply to `MLSD` (RFC 3659 §7) for the one thing `LIST` cannot give: each item's
/// **exact modification time, in UTC**.
///
/// A `LIST` stamp is the server's wall clock with no zone and, for a recent file, no year — a
/// server in Paris lists a file written at 17:41 in Kyiv as `16:41`, and nothing in the row says
/// which clock that is (``FTPListingParser/Entry/modificationDate``). `MLSD` states it outright:
///
///     modify=20261019164100;perm=radfwMT;size=3;type=file;unique=1000011g519a280; a.txt
///
/// `curl` sends it as a listing command (`-X MLSD`, or `request = "MLSD"` in a config section) over
/// the same data connection as `LIST`, which the project had recorded as impossible from M13 until
/// 2026-10-19, when it was traced on the wire (docs/NOTES.md ▸ curl for FTP).
///
/// ## Why it supplies times and never rows
///
/// Probed 2026-10-19 against pyftpdlib: **`MLSD` follows symlinks.** A link to a folder came back as
/// `type=dir` carrying the folder's own `unique` fact, indistinguishable from the folder itself,
/// where `LIST` printed `lrwxr-xr-x … linkdir -> sub`. A recursive delete walking `MLSD` rows would
/// go *through* the link and empty its target, which is the one direction a file manager may never
/// fail in. RFC 3659 leaves the choice to the server, so no client can know in advance which kind it
/// is talking to. The rows therefore stay `LIST`'s — kind, size, mode, owner and link target — and
/// this parser only answers when a row was last modified (``FTPListingParser/applyingFacts(_:to:)``).
///
/// The grammar is RFC 3659's: zero or more `fact=value;` pairs, **one space**, then the name taken
/// verbatim to the end of the line. A fact value cannot contain a space, so the first space is the
/// separator however many spaces or semicolons the name itself holds. Fact names and the `type`
/// values are case-insensitive.
enum FTPFactsParser {
    /// One `MLSD` row, reduced to what a `LIST` row is matched and timed by.
    struct Entry: Equatable {
        let name: String
        /// What the server says the item is, or `nil` when it said something this parser does not
        /// map. A kind that cannot be compared vetoes nothing — see
        /// ``FTPListingParser/applyingFacts(_:to:)``.
        let kind: FileEntry.Kind?
        /// The `modify` fact, exact and in UTC, or `nil` when the row carried none or one that does
        /// not parse.
        let modificationDate: Date?
    }

    /// Parse a raw `MLSD` reply into its rows. The `cdir` and `pdir` rows (the directory itself and
    /// its parent, which some servers send) are dropped, as are lines with no name.
    static func parse(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.hasSuffix("\r") ? line.dropLast() : line[...]
            guard let entry = parseLine(trimmed) else { continue }
            entries.append(entry)
        }
        return entries
    }

    private static func parseLine(_ line: Substring) -> Entry? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        let name = String(line[line.index(after: space)...])
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        var type: String?
        var modify: Substring?
        for fact in line[..<space].split(separator: ";") {
            guard let equals = fact.firstIndex(of: "=") else { continue }
            let value = fact[fact.index(after: equals)...]
            switch fact[..<equals].lowercased() {
            case "type": type = value.lowercased()
            case "modify": modify = value
            default: continue
            }
        }
        if type == "cdir" || type == "pdir" { return nil }
        return Entry(
            name: name,
            kind: type.flatMap(kind(ofType:)),
            modificationDate: modify.flatMap(date(fromModifyFact:))
        )
    }

    /// The kinds a `type` fact can be matched against a `LIST` row by.
    ///
    /// `OS.unix=symlink` is ProFTPD's spelling and `OS.unix=slink:<target>` the other one in use;
    /// either says the server *did not* follow the link, so the fact describes the link itself.
    private static func kind(ofType type: String) -> FileEntry.Kind? {
        switch type {
        case "file": return .file
        case "dir": return .directory
        case "os.unix=symlink": return .symlink
        default: return type.hasPrefix("os.unix=slink") ? .symlink : nil
        }
    }

    /// `YYYYMMDDHHMMSS`, optionally followed by `.` and a fraction of a second, read as **UTC** —
    /// RFC 3659's `time-val`. Anything else is `nil` rather than a guess.
    static func date(fromModifyFact value: Substring) -> Date? {
        let parts = value.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let whole = parts[0]
        guard whole.count == 14, whole.allSatisfy(\.isASCII), whole.allSatisfy(\.isNumber) else {
            return nil
        }
        let digits = whole.compactMap(\.wholeNumberValue)
        func number(_ range: Range<Int>) -> Int { digits[range].reduce(0) { $0 * 10 + $1 } }

        var components = DateComponents()
        components.year = number(0..<4)
        components.month = number(4..<6)
        components.day = number(6..<8)
        components.hour = number(8..<10)
        components.minute = number(10..<12)
        components.second = number(12..<14)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        // `date(from:)` normalizes an out-of-range field (month 13 becomes January) instead of
        // failing, so a malformed stamp would come back as a plausible wrong date.
        guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else {
            return nil
        }
        guard parts.count == 2 else { return date }
        let fraction = parts[1]
        guard !fraction.isEmpty, fraction.allSatisfy(\.isASCII), fraction.allSatisfy(\.isNumber),
              let seconds = Double("0." + fraction) else { return nil }
        return date.addingTimeInterval(seconds)
    }
}
