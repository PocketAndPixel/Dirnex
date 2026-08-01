import Foundation

/// Which files a checksum job looks at (PLAN.md §M14 Slice 2) — the pure half of `ChecksumRunner`.
///
/// Split out because these are *decisions*, not I/O: which of a directory's entries a walk descends
/// into, and which of them may be reported as ``ChecksumEntryStatus/extra``. Each one is a rule
/// that reads as obvious and is wrong in a specific, quiet way when got backwards, so each one is
/// a test against literals with no temp tree in sight.
public enum ChecksumScope {
    // MARK: - Walking

    /// Whether a directory entry should be descended into while gathering files to hash.
    ///
    /// **Symlinks are never followed by the walk**, which is the one rule here that costs
    /// something. A link into an ancestor is a cycle that would hash forever, and a link to a file
    /// already in the tree would put the same bytes in the manifest twice under two names, so a
    /// recursive walk cannot follow one safely. A link the user *pointed at* is different and is
    /// still hashed as its target — `ChecksumEngine` `stat`s rather than `lstat`s — so "explicit is
    /// followed, discovered is not" is the whole rule, and it is what `shasum` does with a
    /// directory argument too.
    public static func shouldDescend(into entry: FileEntry) -> Bool {
        entry.kind == .directory
    }

    /// Whether an entry found by the walk is something to hash.
    ///
    /// Only regular files. A socket, a device or a symlink has no bytes that mean anything in a
    /// manifest, and `ChecksumEngine` would refuse each of them one call later anyway — refusing
    /// here keeps them out of the byte total the progress bar is drawn from, where they would make
    /// a run that finished look like it stopped short.
    public static func isHashable(_ entry: FileEntry) -> Bool {
        entry.kind == .file
    }

    /// One file's relative, `/`-separated name under the manifest's directory — the spelling every
    /// checksum format uses.
    public static func relativeName(of path: VFSPath, under root: VFSPath) -> String? {
        guard path.backend == root.backend else { return nil }
        let rootPath = root.isRoot ? "/" : root.path + "/"
        guard path.path.hasPrefix(rootPath) else { return nil }
        return String(path.path.dropFirst(rootPath.count))
    }

    // MARK: - Verifying

    /// Whether a verification walk should descend into the subdirectory at `relativeName`.
    ///
    /// **Only into subtrees the manifest actually mentions**, and this is the rule that decides
    /// whether ``ChecksumEntryStatus/extra`` is useful or unusable. A manifest is a claim about
    /// what it names, so the interesting extras are the ones *beside* those names — a folder of a
    /// hundred files whose manifest lists ninety-nine. Walking the whole tree instead would hand a
    /// one-line manifest sitting in a home directory a report of every file on the disk, all
    /// flagged "extra", which is a listing rather than an answer. Walking only the top level would
    /// be the mirror mistake: a manifest spelling `sub/dir/file.txt` describes a tree, and its
    /// extras live in that tree.
    public static func shouldDescend(
        intoSubdirectory relativeName: String,
        manifestNames: Set<String>
    ) -> Bool {
        let prefix = relativeName + "/"
        return manifestNames.contains { $0.hasPrefix(prefix) }
    }

    /// The names a verification compares against, out of everything the walk found.
    ///
    /// Two things come out, and both are one-liners that matter:
    ///
    /// - **The manifest's own file is dropped.** A checksum file cannot list itself, so leaving it
    ///   in reports it as `extra` on every single run — noise on the one row that is guaranteed to
    ///   appear.
    /// - **A hidden file the manifest does not name is dropped**, while a hidden file it *does*
    ///   name stays. Every macOS folder grows a `.DS_Store`, and reporting it as "extra" beside a
    ///   real answer trains the user to ignore the extra column. A manifest that deliberately
    ///   covers a dotfile still verifies it, because dropping it there would report `missing` for a
    ///   file that is sitting right in front of them — which is the same bug in the loud direction.
    public static func comparableListing(
        walked: [(name: String, isHidden: Bool)],
        manifestName: String,
        manifestNames: Set<String>
    ) -> [String] {
        walked.compactMap { entry in
            guard entry.name != manifestName else { return nil }
            guard !entry.isHidden || manifestNames.contains(entry.name) else { return nil }
            return entry.name
        }
    }
}
