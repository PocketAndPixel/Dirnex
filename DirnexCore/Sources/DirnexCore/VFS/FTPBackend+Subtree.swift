import Foundation

/// FTP's answer to ``VFSBackend/subtreeListing(at:isCancelled:)``: walk the tree a **level** at a
/// time, with every directory of one level listed in a single connection
/// (docs/HISTORY.md ▸ After M19).
///
/// It is the third shape this seam has taken and the weakest of the three, which is worth saying
/// plainly. S3 is not a tree, so one delimiter-less listing answers a subtree outright. SFTP has an
/// exec channel, so the server can be asked to run `find` and walk it *there*. FTP has neither —
/// there is no recursive verb `curl` can send, and `LIST -R` was retired at the probe (it exists on
/// a minority of servers, none of them reachable from this Mac, so the fast path would have shipped
/// unverified; see ``FTPProcessArguments/listDirectories(session:requests:credentials:)``). So the
/// work does not move to the server and the request count does not collapse to one: this still
/// costs one `LIST` per directory, exactly as the walk does.
///
/// What it stops paying is the **connection** around each of them, which turns out to be nearly all
/// of the cost. Measured 2026-09-01 against a real server over a 159-directory tree — 527 entries,
/// identical both ways — **160 invocations and 159 logins against 4 and 4**, and 11.264 s against
/// 0.404 s once the server is 50 ms away. On loopback it is 1.036 s against 0.149 s, and that is
/// the number to distrust: it removes the only cost this replaces.
///
/// Three consumers get it at once, which is why it was worth a slice of its own rather than a
/// footnote in search: ``SubtreeSearch``, ``DirectorySync`` and ``DirectorySizer`` all ask this seam
/// before walking, and FTP was the last connected backend still refusing them all.
public extension FTPBackend {
    func subtreeListing(at path: VFSPath, isCancelled: () -> Bool) throws -> VFSSubtreeListing? {
        try requireOwnBackend(path)
        guard !isCancelled() else { throw CancellationError() }

        var entries: [FileEntry] = []
        var level = [path]
        var isRootLevel = true

        while !level.isEmpty {
            guard !isCancelled() else { throw CancellationError() }

            // A transport failure is *not* propagated, for the reason the SFTP shortcut gives: it
            // means only that this route is unavailable, and the walk standing right behind it will
            // surface a real failure with a real error if there is one. Cancellation is the one
            // thing that must travel, since it is the caller's own instruction.
            let listings: [String?]
            do {
                listings = try transport.listDirectories(level.map(\.path), isCancelled: isCancelled)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return nil
            }
            // One answer per request, in order, is the whole contract; a transport that answered
            // some other number has told us nothing we can attribute, so there is no shortcut.
            guard listings.count == level.count else { return nil }

            var next: [VFSPath] = []
            for (directory, listing) in zip(level, listings) {
                guard let listing else {
                    // **The root is not a subdirectory.** A listing that fails there means there is
                    // no shortcut rather than a gap in one, so it goes back to the walk — which
                    // lists the root itself and *throws*, giving the caller the server's own reason.
                    // Answering an empty, complete subtree instead would report a folder nobody
                    // could read as a folder with nothing in it, which is the quiet direction and
                    // the exact failure `SubtreeSearch` documents at its own root listing.
                    if isRootLevel { return nil }
                    // Below the root an unreadable directory is skipped, never fatal: permission
                    // gaps are ordinary and everything found elsewhere is still a real answer. This
                    // is the walk's rule, and the two must agree or the shortcut would prune whole
                    // branches the walk reports.
                    continue
                }
                for parsed in FTPListingParser.parse(listing) {
                    entries.append(entry(from: parsed, in: directory))
                    // `kind == .directory`, never `isDirectoryLike` — the walk recurses on exactly
                    // this, so a symlink is a row and not a branch. That keeps the two routes
                    // indistinguishable and makes a cycle through a link back up the tree
                    // unreachable, which nothing here would otherwise bound.
                    if parsed.kind == .directory { next.append(directory.appending(parsed.name)) }
                }
            }

            if entries.count >= subtreeRowLimit {
                // Cut to the cap and say so. Claiming a capped slice is the whole subtree is what
                // ``VFSSubtreeListing/isComplete`` exists to prevent: a search would answer "here is
                // everything" about part of a tree, and the sizer would report a total that is
                // simply wrong — which is why it declines an incomplete listing outright.
                return VFSSubtreeListing(
                    entries: Array(entries.prefix(subtreeRowLimit)),
                    isComplete: false
                )
            }
            level = next
            isRootLevel = false
        }

        // Breadth-first by construction, so the entries arrive shallowest-first with no sort at all
        // — the one place this route is *simpler* than the other two, which each have to reorder
        // (`find` prints depth-first, and S3's flat listing is lexicographic).
        return VFSSubtreeListing(entries: entries, isComplete: true)
    }
}
