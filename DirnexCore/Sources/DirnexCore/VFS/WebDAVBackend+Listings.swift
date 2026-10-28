import Foundation

/// WebDAV's answers to the two listing seams, ``VFSBackend/subtreeListing(at:isCancelled:)`` and
/// ``VFSBackend/listDirectories(at:isCancelled:)`` (PLAN.md §M32 Slice 5).
///
/// FTP's shape rather than S3's or SFTP's. WebDAV has a recursive listing, `Depth: infinity`, and it
/// is not used: the NAS refuses it (403), and where a server allows it the answer is one unbounded
/// document parsed whole (PLAN.md §M32's decisions). So a tree still costs one `Depth: 1` PROPFIND
/// per folder, and what the batch removes is the `curl` around each one: a whole **level** goes in
/// one run over one connection (``WebDAVProcessArguments/listings(session:requests:credentials:)``).
///
/// The consumers are FTP's: ``SubtreeSearch``, ``DirectorySync`` and ``DirectorySizer`` ask for the
/// subtree before walking, and a tree refresh re-lists every open folder at once.
public extension WebDAVBackend {
    /// Every entry beneath `path`, a level at a time, breadth-first.
    ///
    /// The rules are FTP's (``FTPBackend/subtreeListing(at:isCancelled:)``), each of which keeps
    /// this indistinguishable from the walk standing behind it. A root that cannot be listed is no
    /// shortcut, so the walk lists it and throws the server's own reason. A folder below it that the
    /// server refuses is skipped, as the walk skips it. Only `.directory` rows are descended into.
    ///
    /// One rule is this backend's own: **a level that did not all get answered is no shortcut
    /// either.** A section that got no answer, or a run that stopped on a refused login, says
    /// nothing about those folders, so skipping them would return a subtree short of whole branches
    /// that still claimed to be complete. The walk meets the same failure and reports it.
    func subtreeListing(at path: VFSPath, isCancelled: () -> Bool) throws -> VFSSubtreeListing? {
        try requireOwnBackend(path)
        guard !isCancelled() else { throw CancellationError() }

        var entries: [FileEntry] = []
        var level = [path]
        var isRootLevel = true

        while !level.isEmpty {
            let answered: WebDAVLevelListing
            do {
                answered = try listLevel(level, isCancelled: isCancelled)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return nil
            }
            guard answered.isWhole else { return nil }

            var next: [VFSPath] = []
            for listing in answered.listings {
                guard let listing else {
                    if isRootLevel { return nil }
                    continue
                }
                for entry in listing {
                    entries.append(entry)
                    if entry.kind == .directory { next.append(entry.path) }
                }
            }

            if entries.count >= subtreeRowLimit {
                return VFSSubtreeListing(
                    entries: Array(entries.prefix(subtreeRowLimit)),
                    isComplete: false
                )
            }
            level = next
            isRootLevel = false
        }
        return VFSSubtreeListing(entries: entries, isComplete: true)
    }

    /// Several folders over one connection: what a tree refresh asks for every open folder.
    ///
    /// One folder goes the ordinary way, as list mode does, since a batch of one saves nothing. A
    /// folder whose section got no answer, or was never sent, is `nil`, which keeps its last good
    /// rows; so is one the server refused.
    func listDirectories(at paths: [VFSPath], isCancelled: () -> Bool) throws -> [[FileEntry]?] {
        for path in paths {
            try requireOwnBackend(path)
        }
        guard paths.count > 1 else {
            return try paths.map { path in
                guard !isCancelled() else { throw CancellationError() }
                return try? listDirectory(at: path)
            }
        }
        do {
            return try listLevel(paths, isCancelled: isCancelled).listings
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return Array(repeating: nil, count: paths.count)
        }
    }
}

extension WebDAVBackend {
    /// List `directories` in as few runs as the answers allow: one per ``WebDAVProcessArguments/listingBatchLimit``
    /// folders, plus one for each time the first section of a run was refused.
    ///
    /// That refusal ends the run (`fail` with `--fail-early`), and what it means decides what comes
    /// next. A **401** is the account, so the same login would be refused for every folder after it
    /// and is not tried again: one failed login, where a run without the guard spent one a folder.
    /// Any other status is that folder's own answer, a 404 for a folder deleted since it was
    /// listed, so the rest go out in the next run. A section that got no answer ends the level the
    /// same way a 401 does: a server that did not answer one request will not answer the next.
    func listLevel(
        _ directories: [VFSPath],
        isCancelled: () -> Bool
    ) throws -> WebDAVLevelListing {
        var listings: [[FileEntry]?] = []
        listings.reserveCapacity(directories.count)
        var isWhole = true
        var rest = directories[...]

        while !rest.isEmpty {
            guard !isCancelled() else { throw CancellationError() }
            let chunk = Array(rest.prefix(WebDAVProcessArguments.listingBatchLimit))
            let answers = try transport.propfindBatch(chunk.map(\.path), isCancelled: isCancelled)
            // One answer per request is the whole contract; any other number cannot be attributed.
            guard answers.count == chunk.count else {
                return WebDAVLevelListing(
                    listings: listings + Array(repeating: nil, count: rest.count),
                    isWhole: false
                )
            }

            var sent = 0
            var stoppedOn: WebDAVBatchAnswer?
            for (directory, answer) in zip(chunk, answers) {
                if answer == .notSent { break }
                sent += 1
                stoppedOn = answer
                if case let .response(response) = answer {
                    listings.append(folderEntries(directory, from: response))
                } else {
                    listings.append(nil)
                    isWhole = false
                }
            }
            rest = rest.dropFirst(sent)
            guard sent < chunk.count else { continue }

            // The run stopped short. Send the rest again only when it stopped on a folder's own
            // refusal; see the doc comment for why a login or a silence is not sent again.
            guard sent > 0, case let .response(response)? = stoppedOn, response.status != 401 else {
                listings += Array(repeating: nil, count: rest.count)
                return WebDAVLevelListing(listings: listings, isWhole: false)
            }
        }
        return WebDAVLevelListing(listings: listings, isWhole: isWhole)
    }

    /// One section's answer as the folder's rows, or `nil` when it was a refusal, a page that is
    /// not a multistatus, or a listing of something that is not a folder.
    private func folderEntries(
        _ directory: VFSPath,
        from response: WebDAVHTTPResponse
    ) -> [FileEntry]? {
        guard let listing = try? listing(of: directory, from: response),
              listing.folder.isCollection
        else { return nil }
        return listing.entries(in: directory)
    }
}

/// A level's listings, one per folder in the order asked, and whether every folder got an answer
/// from the server — a refusal counts as one, a silence or a section never sent does not.
struct WebDAVLevelListing {
    let listings: [[FileEntry]?]
    let isWhole: Bool
}
