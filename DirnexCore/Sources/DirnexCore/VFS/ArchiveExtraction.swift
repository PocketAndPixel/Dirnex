import Foundation

/// Builds the `bsdtar` command that extracts specific members of an archive into a directory —
/// the pure, tested half of F5 copy-out (PLAN.md §M4 "copy out with F5"), mirroring how
/// `SpotlightQuery` builds `mdfind` arguments and `ArchiveTOCParser` parses `bsdtar` output.
/// The app's `ArchiveExtractor` runs the process; this touches no disk and spawns nothing, so
/// it stays unit-testable.
///
/// Extraction feeds a *temp-extract-then-normal-copy*: `CopyEngine` takes one backend for both
/// source and dest, so a cross-backend archive→local copy can't go straight through it. Instead
/// the app extracts the selected members to a temp directory and hands the resulting real files
/// to the existing copy queue — reusing all its conflict/progress/undo machinery. `bsdtar`
/// rebuilds each member's *full* inner path under the destination (so `/docs/api/x.md` lands at
/// `<dest>/docs/api/x.md`), which is exactly where `extractedLocation(ofInnerPath:inDirectory:)`
/// points the copy queue's source.
public enum ArchiveExtraction {
    /// The `bsdtar` argv that extracts `innerPaths` from the archive at `archiveOnDiskPath` into
    /// `destinationDirectory`. Each inner path (a `VFSPath.path` like `/docs/api/x.md`) maps to
    /// the archive-relative member `bsdtar` matches; a directory member extracts recursively, and
    /// `bsdtar` best-effort extracts whatever members it finds.
    public static func extractionArguments(
        archiveOnDiskPath: String,
        innerPaths: [String],
        destinationDirectory: String
    ) -> [String] {
        ["-x", "-f", archiveOnDiskPath, "-C", destinationDirectory]
            + innerPaths.map(member(forInnerPath:))
    }

    /// Where an extracted inner path lands under `destinationDirectory`. `bsdtar` reconstructs the
    /// member's full inner path minus its leading slash, so `/docs/api/x.md` → `<dest>/docs/api/x.md`.
    /// This is the *real* on-disk name (unescaped) the copy queue then reads as its source.
    public static func extractedLocation(
        ofInnerPath innerPath: String,
        inDirectory destinationDirectory: String
    ) -> String {
        let relative = String(innerPath.drop { $0 == "/" })
        return (destinationDirectory as NSString).appendingPathComponent(relative)
    }

    // MARK: - Members

    /// The archive-relative member pattern `bsdtar` matches for a VFS inner path: the leading
    /// slash dropped and glob metacharacters escaped, since `bsdtar` treats each member as a
    /// shell-glob pattern (a name like `weird[1].txt` would otherwise be read as a character
    /// class and go unmatched — validated against bsdtar 3.5.3 / libarchive 3.7.4).
    static func member(forInnerPath innerPath: String) -> String {
        globEscaped(String(innerPath.drop { $0 == "/" }))
    }

    /// Backslash-escape the shell-glob metacharacters `bsdtar` honors in a member pattern
    /// (`\ * ? [`), so the pattern matches the member's literal name.
    static func globEscaped(_ member: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(member.count)
        for character in member {
            if character == "\\" || character == "*" || character == "?" || character == "[" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }
}
