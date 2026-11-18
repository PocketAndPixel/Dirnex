import Foundation

/// Whether Spotlight covers a local folder: the question that decides whether ⌥F7 asks the index or
/// walks the folder itself (PLAN.md §M40 Slice 3).
///
/// It has to be asked first, because Spotlight answers nothing for a place it does not index and
/// says nothing about it. `mdfind -onlyin` over an SMB share Finder mounted, or over `/private/tmp`,
/// prints the same empty list a search with no matches prints, so a search there would read as
/// "nothing matched". It is asked of Spotlight itself, in one of two ways, since each sees what the
/// other cannot (both probed 2026-11-18):
///
/// - **A volume's root** goes to `mdutil -s`, which answers "Indexing enabled." or "Indexing
///   disabled." for a mount point and "unknown indexing state" for anything else. The other way
///   cannot see a root: asking `/System/Volumes` for an item named `Data` found three folders of that
///   name elsewhere and not the volume.
/// - **Any other folder** is looked up by name in its parent: `mdfind -onlyin <parent>
///   'kMDItemFSName == "<name>"'` finds an indexed folder itself (`~/Dev`, 0.1 s) and nothing for one
///   Spotlight leaves out: a hidden folder, `/private/tmp`, a folder on a volume with indexing off,
///   or one on Spotlight's Privacy list. `-onlyin` covers the parent's whole subtree, so other folders
///   of the same name come back too (six `oleg` folders for `/Users/oleg`); what answers is whether
///   **this** path is among them.
///
/// Answering "not covered" when the folder is covered costs a walk, which is slower and still right.
/// Answering "covered" when it is not costs the search. So every doubtful answer is "not covered": a
/// state `mdutil` names other than "Indexing enabled.", a path that differs from the one on disk only
/// in case (the name comparison is case-sensitive), and an `mdfind` that failed or printed nothing.
///
/// The processes are the app's; the arguments and the reading of what they print are here.
public enum SpotlightCoverage {
    /// What `mdutil -s` prints for a volume Spotlight indexes.
    static let indexedVolumeLine = "Indexing enabled."

    /// The `mdfind` arguments that look `folder` up by name in its parent, or `nil` for `/`, which has
    /// no parent and is a volume's root anyway.
    ///
    /// `-0` ends each path with a NUL rather than a newline, which a name may hold. The name is
    /// matched exactly: a `*` in it is a wildcard to `mdfind` and finds the folder along with others,
    /// which ``output(_:namesFolder:)`` then tells apart.
    public static func mdfindArguments(forFolder folder: String) -> [String]? {
        let path = trimmed(folder)
        guard path != "/" else { return nil }
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        return ["-0", "-onlyin", parent, #"kMDItemFSName == "\#(FileQuery.escape(name))""#]
    }

    /// Whether `mdfind -0` printed `folder` itself among its hits.
    ///
    /// Compared as Swift strings, which compare canonically equivalent forms as equal: `mdfind`
    /// prints every path decomposed (docs/NOTES.md ▸ mdfind), while a name on disk is usually
    /// composed.
    public static func output(_ output: Data, namesFolder folder: String) -> Bool {
        let wanted = trimmed(folder)
        return output.split(separator: 0).contains { record in
            String(bytes: record, encoding: .utf8) == wanted
        }
    }

    /// Whether `mdutil -s <mount point>` says Spotlight indexes the volume.
    ///
    /// Only "Indexing enabled." counts. "Indexing disabled." is what the NAS share prints, and a
    /// network volume that offers its own server-side search prints "Server search enabled.", which no
    /// volume here does, so it walks rather than trusting a search nobody has seen answer.
    public static func volumeIsIndexed(mdutilOutput: String) -> Bool {
        mdutilOutput.split(whereSeparator: \.isNewline).contains { line in
            line.trimmingCharacters(in: .whitespaces) == indexedVolumeLine
        }
    }

    /// `folder` without a trailing slash, which a path typed by hand can carry.
    private static func trimmed(_ folder: String) -> String {
        var path = folder
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
