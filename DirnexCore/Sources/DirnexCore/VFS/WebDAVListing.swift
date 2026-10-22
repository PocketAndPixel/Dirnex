import Foundation

/// A `Depth: 1` PROPFIND split into the folder that was listed and the rows inside it.
public struct WebDAVListing: Sendable, Equatable {
    /// The row for the folder itself. RFC 4918 puts it in every `Depth: 1` answer, and its
    /// `isCollection` is how a listing of a *file* is told apart from a listing of a folder.
    public let folder: WebDAVResponse
    /// The rows directly inside ``folder``, in the server's order.
    public let children: [WebDAVResponse]
    /// Hrefs the parser could not read (``WebDAVMultistatus/unreadableHrefCount``).
    public let unreadableCount: Int
}

public extension WebDAVMultistatus {
    /// Split a `Depth: 1` answer for `serverPath` into the folder and its children.
    ///
    /// The folder is the row whose path is `serverPath`, compared as decoded bytes
    /// (``WebDAVHref/samePath(_:_:)``) — never as the string that was sent, which the server echoes
    /// in different hex case (measured). When no row matches, the folder is the row every other
    /// row sits directly inside: a reverse proxy that serves the account under a prefix the server
    /// behind it does not know answers with hrefs that lack the prefix, and the listing is still
    /// coherent once the right row is anchored. A child's path is then rebuilt from the folder that
    /// was *asked for* and the child's name, so nothing downstream sees the server's spelling.
    ///
    /// Two kinds of row are left out. A second row for the folder itself — with and without its
    /// trailing slash — is the folder, not a child of it. And a row that is not directly inside the
    /// folder is not in this listing at all; that is what a server that ignores `Depth: 1` sends.
    /// Rows naming a status rather than properties are outcomes of an operation, not resources, and
    /// are not read here.
    func listing(of serverPath: String) throws -> WebDAVListing {
        let rows = responses.filter { $0.status == nil }
        guard let folder = rows.first(where: { WebDAVHref.samePath($0.path, serverPath) })
            ?? anchor(in: rows)
        else { throw WebDAVParseError.listingDoesNotNameItsFolder }

        var seenNames: Set<[UInt8]> = []
        let children = rows.filter { row in
            guard !WebDAVHref.samePath(row.path, folder.path),
                  let parent = WebDAVHref.parent(of: row.path),
                  WebDAVHref.samePath(parent, folder.path),
                  let name = WebDAVHref.name(of: row.path)
            else { return false }
            // By bytes, so `café` precomposed and decomposed stay two rows, as they are two files.
            return seenNames.insert(Array(name.utf8)).inserted
        }
        return WebDAVListing(
            folder: folder,
            children: children,
            unreadableCount: unreadableHrefCount
        )
    }

    /// The row every other row sits directly inside, or `nil` when there is no such row.
    private func anchor(in rows: [WebDAVResponse]) -> WebDAVResponse? {
        rows.first { candidate in
            rows.allSatisfy { row in
                if WebDAVHref.samePath(row.path, candidate.path) { return true }
                guard let parent = WebDAVHref.parent(of: row.path) else { return false }
                return WebDAVHref.samePath(parent, candidate.path)
            }
        }
    }
}

public extension WebDAVListing {
    /// The children as directory entries for `directory`, the folder the pane asked for.
    func entries(in directory: VFSPath) -> [FileEntry] {
        children.compactMap { child in
            guard let name = WebDAVHref.name(of: child.path) else { return nil }
            return child.entry(at: directory.appending(name), name: name)
        }
    }
}

public extension WebDAVResponse {
    /// This row as a directory entry at `path`.
    ///
    /// `name` defaults to the path's last component, which is what a stat by `Depth: 0` wants; a
    /// listing passes the decoded name it already has.
    func entry(at path: VFSPath, name: String? = nil) -> FileEntry {
        // A missing `getlastmodified` is `FileEntry.unknownDate`, for the reason
        // `S3ListingParser.entry` gives: a sort by date must not shuffle on every refresh, and the
        // renderer draws a dash for it. A missing `creationdate` falls back to the modification
        // date, which is what every other remote backend reports as both.
        let modified = modified ?? FileEntry.unknownDate
        let name = name ?? path.lastComponent
        return FileEntry(
            path: path,
            name: name,
            kind: isCollection ? .directory : .file,
            byteSize: isCollection ? 0 : byteSize ?? 0,
            modificationDate: modified,
            creationDate: created ?? modified,
            isHidden: name.hasPrefix("."),
            // WebDAV carries no POSIX mode, owner or group. Apache's `executable` property reads
            // `T` on every file the NAS stores, which says nothing a Get Info could honestly show.
            permissions: nil,
            inode: 0,
            entityTag: entityTag
        )
    }
}
