import Foundation

/// SFTP's answer to ``VFSBackend/subtreeListing(at:isCancelled:)``: ask the server to walk its own
/// tree with `find`, over the exec channel the same SSH connection already offers (PLAN.md §M22
/// Slice 4).
///
/// It is a different kind of shortcut from S3's, and the difference is worth stating because the
/// seam's own doc comment could otherwise be read as "flat stores only". A bucket is not a tree, so
/// `ListObjectsV2` answers a subtree *because of what S3 is*. A server's home directory is a real
/// tree and a listing really is one round trip per directory — the saving here is not that the work
/// disappears but that it happens **there**, once, instead of being pulled across the network a
/// directory at a time. Measured on loopback over 501 directories, where there is no latency to
/// blame: 98 ms against 34.3 s.
///
/// The whole thing is allowed to be unavailable, and that is the design rather than an oversight —
/// see ``SFTPTransport/runCommand(_:isCancelled:)``. Every path out of here that is not a confident
/// answer returns `nil`, which means "walk instead": the feature never depends on the exec channel
/// existing, only its speed does.
public extension SFTPBackend {
    func subtreeListing(at path: VFSPath, isCancelled: () -> Bool) throws -> VFSSubtreeListing? {
        try requireOwnBackend(path)
        guard !isCancelled() else { throw CancellationError() }

        let root = SSHFindCommand.normalizedRoot(path.path)
        let command = SSHFindCommand.subtree(root: root, rowLimit: subtreeRowLimit)

        // A transport failure is *not* propagated. Anything that goes wrong reaching the exec
        // channel — the account refusing it, the shell answering with something else, a `find` that
        // is not there — means only that this shortcut is unavailable, and the walk is standing
        // right behind it and will surface a real failure with a real error if there is one.
        // Cancellation is the one thing that must travel, since it is the caller's own instruction.
        let output: String?
        do {
            output = try transport.runCommand(command, isCancelled: isCancelled)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }

        guard let output, let listing = SSHFindListingParser.parse(output, under: root) else {
            return nil
        }

        return VFSSubtreeListing(
            entries: entries(from: listing.rows, under: root),
            // The server printed exactly as many rows as it was allowed to, so there is no way to
            // know whether the tree ended there or `head` did. Reported as incomplete: claiming a
            // capped slice is the whole subtree is the quiet direction, and the caller has a
            // sentence for exactly this (`SubtreeSearch.Completion.budgetExceeded`).
            isComplete: listing.rowCount < subtreeRowLimit
        )
    }

    /// The rows as `FileEntry`s, **shallowest first**.
    ///
    /// `find` prints in its own traversal order, which is depth-first — probed, and the row depths
    /// are visibly not monotonic. Truncating that order at the caller's result cap would keep an
    /// entire deep branch under the first subdirectory ahead of everything at the top, which is the
    /// "deep sliver of one branch" this milestone rejected when it made the walk breadth-first and
    /// which S3's flat listing sorts for the same reason. The sort is stable, so within one depth
    /// the server's own order survives.
    private func entries(from rows: [SSHFindListingParser.Row], under root: String) -> [FileEntry] {
        rows
            .map { (depth: $0.path.dropFirst(root.count).filter { $0 == "/" }.count, row: $0) }
            .enumerated()
            .sorted { ($0.element.depth, $0.offset) < ($1.element.depth, $1.offset) }
            .map { entry(from: $0.element.row) }
    }

    private func entry(from row: SSHFindListingParser.Row) -> FileEntry {
        let name = row.path.split(separator: "/").last.map(String.init) ?? row.path
        return FileEntry(
            path: VFSPath(backend: id, path: row.path),
            name: name,
            kind: row.kind,
            byteSize: row.byteSize,
            modificationDate: row.modificationDate,
            // No birth time over `ls`, exactly as the per-directory listing has none.
            creationDate: row.modificationDate,
            isHidden: name.hasPrefix("."),
            permissions: row.permissions,
            inode: 0,
            symlinkDestination: row.symlinkDestination,
            symlinkTargetKind: row.kind == .symlink ? .file : nil
        )
    }
}
