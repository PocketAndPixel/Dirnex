import Foundation

/// Decides where — if anywhere — an archive entry is allowed to land on disk.
///
/// **An archive is untrusted input, and its entry names are the attack.** A name like
/// `../../../../Users/oleg/.ssh/authorized_keys` is a perfectly legal zip entry, and an extractor
/// that joins it onto the destination directory writes exactly there. The bug has a name — Zip Slip
/// — and it has been shipped by archivers on every platform, repeatedly, because the vulnerable
/// version is the one you write without thinking about it.
///
/// Dirnex has more reason than most to care: it can browse an archive that arrived over FTP or SFTP,
/// and the whole point of the encrypted-archive feature is receiving files from someone else.
///
/// This is a pure function over a string, which is what lets every rule below be a test rather than
/// a comment. The rules are deliberately strict — an entry that cannot be placed is *skipped and
/// reported*, never guessed at:
///
/// - An **absolute** path is refused. There is no sane reading of `/etc/passwd` as a member name.
/// - Any `..` component is refused, wherever it appears. Not resolved, not clamped — refused. A
///   resolver that cancels `a/../b` into `b` is one bug away from canceling `a/../../b` into `../b`,
///   and there is no legitimate archive that needs the feature.
/// - A `.` component and an empty component are dropped, since `./notes/x` and `notes//x` are
///   ordinary spellings that mean something unambiguous.
/// - A NUL byte is refused: it terminates the string at the syscall boundary, so a name carrying one
///   would be created under a *different, shorter* name than the one that was checked.
/// - A name that is empty once cleaned is refused, because there is nothing to create.
///
/// Windows-style `\` separators are deliberately **not** translated. The zip specification says `/`,
/// a backslash is a legal character in a POSIX filename, and rewriting it would silently rename the
/// user's file. The cost is that an archive from a non-conforming Windows tool extracts one file
/// with a backslash in its name rather than a nested folder — visible and fixable, unlike a
/// misplaced write.
public enum ArchiveEntryPath {
    /// Why an entry cannot be placed. Carried out to the caller so the extraction report can name
    /// the entry it refused rather than silently producing fewer files than the archive listed.
    public enum Refusal: Sendable, Equatable {
        case absolutePath
        case parentTraversal
        case emptyName
        case containsNulByte
    }

    /// Where an entry may go, or why it may not go anywhere.
    ///
    /// Deliberately not a `Result`: a refusal here is a *report*, something the extraction summary
    /// lists back to the user, not an error that aborts the archive. Modeling it as a thrown
    /// failure would make the natural implementation stop at the first hostile entry and lose the
    /// nine good files after it.
    public enum Placement: Sendable, Equatable {
        /// A `/`-separated relative path with no `.` or `..` components, guaranteed by construction
        /// to stay inside whatever directory it is joined onto.
        case allowed(String)
        case refused(Refusal)
    }

    /// The relative path this entry may be created at, or the reason it may not.
    public static func sanitized(_ rawName: String) -> Placement {
        guard !rawName.contains("\0") else { return .refused(.containsNulByte) }
        guard !rawName.isEmpty else { return .refused(.emptyName) }
        guard !rawName.hasPrefix("/") else { return .refused(.absolutePath) }

        var components: [String] = []
        for component in rawName.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { return .refused(.parentTraversal) }
            components.append(String(component))
        }

        guard !components.isEmpty else { return .refused(.emptyName) }
        return .allowed(components.joined(separator: "/"))
    }

    /// Whether a symlink stored in an archive may be created.
    ///
    /// A symlink is the second half of the traversal problem and the one that survives a correct
    /// path check: an archive can store `docs -> /` as a legitimate-looking entry and then store
    /// `docs/passwd`, whose *own* name is perfectly innocent. Every write would then go through the
    /// link, outside the destination, having passed ``sanitized(_:)`` cleanly.
    ///
    /// So a link's **target** is held to the same rule as an entry name: relative, and never
    /// climbing out. Note the asymmetry with ``sanitized(_:)`` — a `..` inside a link target is
    /// judged by where it *ends up*, because `../sibling/file` is an entirely ordinary symlink and
    /// refusing all of them would be wrong. The link's own directory depth is what pays for them.
    ///
    /// - Parameters:
    ///   - target: The link's stored target.
    ///   - linkPath: The link's own sanitized archive path, whose depth decides how many `..`
    ///     components it can afford.
    public static func isSafeSymlinkTarget(_ target: String, forLinkAt linkPath: String) -> Bool {
        guard !target.isEmpty, !target.contains("\0"), !target.hasPrefix("/") else { return false }

        // The link lives in this many directories below the extraction root.
        var depth = linkPath.split(separator: "/", omittingEmptySubsequences: true).count - 1
        guard depth >= 0 else { return false }

        for component in target.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                depth -= 1
                // Escapes the moment it would step above the extraction root — checked at every
                // component rather than on the total, so `../../a/b` cannot pay its way back in.
                if depth < 0 { return false }
            } else {
                depth += 1
            }
        }
        return true
    }
}
