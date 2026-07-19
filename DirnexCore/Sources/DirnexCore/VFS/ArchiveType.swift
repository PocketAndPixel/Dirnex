import Foundation

/// Which files Dirnex will open as a browsable archive (PLAN.md §M4 ArchiveBackend).
///
/// Pure filename-suffix matching, kept in core so both the panel (deciding Enter =
/// "browse into" vs. "launch") and any future pack UI agree on one list. The set is the
/// container formats `bsdtar`/libarchive read reliably; a single-stream `.gz` is not a
/// folder, so it is deliberately excluded.
public enum ArchiveType {
    /// Lowercased suffixes, longest-first so `.tar.gz` wins over a bare `.gz` check.
    static let browsableSuffixes: [String] = [
        ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar",
        ".tgz", ".tbz", ".tbz2", ".txz",
        ".zip", ".jar", ".cbz", ".7z"
    ]

    /// Whether `filename` names a browsable archive. The name must have real content
    /// before the suffix, so a dotfile literally named ".zip" is not treated as one.
    public static func isBrowsable(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        return browsableSuffixes.contains { lower.count > $0.count && lower.hasSuffix($0) }
    }
}
