import Foundation

/// A `VFSBackend` that lists one SMB server's shares as a single flat directory (PLAN.md §M35), the
/// way ``S3AccountBackend`` lists an account's buckets.
///
/// **Depth 0 and read-only, on purpose.** A share is not browsed here. Return on a row *mounts* it
/// through the OS, and the pane then stands on the mount point, a `.local` path, where every verb
/// works as it does on any volume (PLAN.md §M5, "SMB rides the OS mounter"). So this backend answers
/// for its root and its own rows and nothing deeper, and it offers no writes: SMB has no verb to
/// create, rename or delete a share, and nothing can be copied into a list of them.
///
/// Each listing is one session to the server, opened and closed by the ``SMBShareEnumerating`` it is
/// given, about a second on a LAN by NetBIOS name and more by a `.local` one (PLAN.md §M35).
public struct SMBServerBackend: ConnectionScopedBackend {
    /// The server whose shares this lists, with no share named.
    public let server: SMBLocation
    let enumerator: any SMBShareEnumerating

    /// - Parameter server: the server to list. A share in it is dropped, since the list is the
    ///   server's whichever share a location happened to name.
    public init(server: SMBLocation, enumerator: any SMBShareEnumerating) {
        self.server = server.server
        self.enumerator = enumerator
    }

    public var id: VFSBackendID { .smbServer(server) }

    /// The URL a person typed, account and all: the account matters, since it decides what the
    /// server lists.
    public var connectionDescriptor: String { server.url }

    /// Read-only, for the reasons above. No `.write`, so F7, F8, F6 and a paste are grayed rather
    /// than offered and refused.
    public var capabilities: VFSCapabilities { .read }

    // MARK: - Listing

    /// List the server's shares.
    ///
    /// Only the root has anything to list. A deeper path is a share, which is reached by mounting it,
    /// so it answers `notFound` rather than an empty listing that would read as an empty share.
    public func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        try requireOwnBackend(path)
        guard path.isRoot else { throw VFSError.notFound(path) }
        return try mapping(path) { try enumerator.shares() }.map { share in
            shareEntry(named: share.name, at: VFSPath(backend: path.backend, path: "/\(share.name)"))
        }
    }

    /// Stat the server's root, or one share in it.
    ///
    /// The root is answered without asking the server: it is a directory by construction. A share is
    /// answered from a listing, since a list of shares is the only thing this backend can ask for.
    public func stat(at path: VFSPath) throws -> FileEntry {
        try requireOwnBackend(path)
        guard !path.isRoot else { return rootEntry(at: path) }
        guard let parent = path.parent, parent.isRoot else { throw VFSError.notFound(path) }
        let name = path.lastComponent
        guard try listDirectory(at: parent).contains(where: { $0.name == name }) else {
            throw VFSError.notFound(path)
        }
        return shareEntry(named: name, at: path)
    }

    // MARK: - Entries

    /// One share as a row: a directory, since Return goes into it. It has no size and no dates of its
    /// own, so the columns draw the dash an unmeasured folder gets (``FileEntry/unknownDate``).
    private func shareEntry(named name: String, at path: VFSPath) -> FileEntry {
        FileEntry(
            path: path,
            name: name,
            kind: .directory,
            byteSize: 0,
            modificationDate: FileEntry.unknownDate,
            creationDate: FileEntry.unknownDate,
            isHidden: false,
            permissions: 0o755,
            inode: 0
        )
    }

    private func rootEntry(at path: VFSPath) -> FileEntry {
        FileEntry(
            path: path,
            name: server.host,
            kind: .directory,
            byteSize: 0,
            modificationDate: FileEntry.unknownDate,
            creationDate: FileEntry.unknownDate,
            isHidden: false,
            permissions: 0o755,
            inode: 0
        )
    }

    /// Put a failed listing into the shared `VFSError` vocabulary: an `errno` keeps its code, so a
    /// server that went away reads as one, and a NetFS OSStatus (negative) becomes `EIO`. The connect
    /// itself asks the enumerator directly and words the status with the mount's sentences; this is
    /// for a listing that fails later, on a refresh.
    private func mapping<T>(_ path: VFSPath, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as SMBShareListingError {
            throw VFSError.io(path: path, code: error.status > 0 ? error.status : EIO)
        }
    }
}
