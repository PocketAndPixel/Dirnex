import Foundation

/// Which members of an archive an extraction should place, and — just as importantly — which it may
/// step over without decrypting.
///
/// `bsdtar` takes the members it should extract as command-line arguments and Dirnex's other
/// extraction route (``ArchiveExtraction``) builds exactly that argv. The libarchive route had no
/// equivalent, so an encrypted archive extracted **whole** however little was asked for: previewing
/// one file inside a 600 MB archive decrypted all 600 MB. This is the missing half, and it is worth
/// having as a value rather than an `[String]?` parameter because the matching rule is the whole
/// subject — a rule that has to agree with `bsdtar`'s, since the two routes serve the same gestures
/// and a user cannot see which one ran.
///
/// ## The rule
///
/// A member matches an entry when it names that entry **or is a directory above it**, which is what
/// makes F5 on a folder inside an archive copy the folder's contents out rather than an empty
/// directory. Matching is on whole path components, so a request for `doc` never matches `docs/x` —
/// the same distinction S3's listing prefixes need for the same reason (docs/NOTES.md ▸ curl for S3),
/// arriving here because an archive entry name is a path in a flat keyspace too.
///
/// Names are compared **raw**, before ``ArchiveEntryPath/sanitized(_:)`` has judged them, and that
/// ordering is deliberate: filtering only ever removes entries, so nothing hostile can be admitted
/// by it, and an entry the user did not ask for should not be reported as a refusal either. An
/// archive carrying `../evil` alongside the file being previewed is not this preview's business.
public struct ArchiveMemberFilter: Sendable, Equatable {
    /// `nil` means "no filter at all", which is not the same as an empty list: naming zero members
    /// selects nothing, and that is a legitimate answer rather than a caller that forgot to ask.
    private let members: [String]?

    /// Every entry the archive holds — what an extraction that names no members does, and what a
    /// repack needs, since rewriting an archive requires all of it.
    public static let everything = ArchiveMemberFilter(members: nil)

    /// Only the named members. `innerPaths` are VFS inner paths as the pane spells them
    /// (`/docs/api/x.md`); the leading slash is dropped here so callers need not, exactly as
    /// ``ArchiveExtraction/member(forInnerPath:)`` does for the `bsdtar` route.
    ///
    /// Nothing is glob-escaped, and nothing needs to be: this compares strings where `bsdtar`
    /// matches shell patterns, so a member named `weird[1].txt` is simply its own name here.
    public static func members(_ innerPaths: [String]) -> ArchiveMemberFilter {
        ArchiveMemberFilter(members: innerPaths.map(normalized))
    }

    /// Whether this extraction should place the entry the archive spells `archivePath`.
    public func includes(entryNamed archivePath: String) -> Bool {
        guard let members else { return true }
        let entry = Self.normalized(archivePath)
        return members.contains { member in
            entry == member || entry.hasPrefix(member + "/")
        }
    }

    /// One name in the form both sides are compared in: no leading slash (a VFS inner path carries
    /// one and an archive entry does not) and no trailing slash (a *directory* entry carries one —
    /// zip and tar both spell it `notes/` — and the request for it does not).
    ///
    /// Interior separators are left exactly as they are. `ArchiveEntryPath` refuses `..` and drops
    /// `.` when it comes to *place* the entry, and re-deriving any of that here would be a second
    /// spelling of a rule that already has one: an entry this admits and that refuses is skipped by
    /// the extraction anyway, with the refusal reported from the one place that decides it.
    private static func normalized(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.hasPrefix("/") { trimmed = trimmed.dropFirst() }
        while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }
}
