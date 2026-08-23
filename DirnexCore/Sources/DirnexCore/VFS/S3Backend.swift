import Foundation

/// A `VFSBackend` that browses one S3 bucket as a folder tree (PLAN.md §M21).
///
/// Everything that decides whether a listing is *correct* lives here and is tested: the key
/// translation, the pagination loop, the stat rule, the classification of a response, and the
/// resume decision. The only non-hermetic piece — the network — is an injected ``S3Transport``, so
/// the backend is exercised against the bytes real buckets sent and needs neither a server nor
/// credentials (PLAN.md §2).
///
/// **The write verbs live next door, in `S3Backend+Write.swift`**, because they are the part S3 does
/// not share with the other remote backends: `createDirectory` has no operation behind it beyond
/// writing a zero-byte marker, a rename is copy-then-delete (O(size), and N copies for a "folder"),
/// and there is no `rm -r`. `RemoteTransportBackend`'s four shared verbs were shaped for FTP and
/// SFTP, where they are genuine filesystem operations, so S3 conforms to ``ConnectionScopedBackend``
/// — the guard all three need — and answers the four itself.
public struct S3Backend: ConnectionScopedBackend {
    /// The bucket this backend is rooted at — its identity.
    public let location: S3Location
    // Internal rather than private: the write verbs live in `S3Backend+Write.swift`, and Swift's
    // `private` does not cross files (NOTES.md ▸ file splitting).
    let transport: any S3Transport
    let pageLimit: Int

    /// - Parameter pageLimit: how many `ListObjectsV2` pages one listing may fetch before it gives
    ///   up. S3 pages at 1000 keys whatever `max-keys` asks for, so the default allows a folder of
    ///   a million objects — far past anything a person browses, and low enough that a runaway
    ///   listing fails instead of billing indefinitely.
    public init(location: S3Location, transport: any S3Transport, pageLimit: Int = 1000) {
        self.location = location
        self.transport = transport
        self.pageLimit = pageLimit
    }

    public var id: VFSBackendID { .s3(location) }
    public var connectionDescriptor: String { location.connectionDescriptor }

    /// Read, write and rename. No `.clone`, since a copy-on-write clone is a single-filesystem
    /// primitive and S3's server-side copy really does move the bytes (it is just S3 paying for it,
    /// not this machine) — advertising `.clone` would send `CopyEngine` down a path whose whole
    /// premise is that the copy is free and instant.
    ///
    /// No `.watch` either, and that one is permanent: S3 has no change notification, so an S3 pane
    /// re-lists on focus and on demand as the FTP and SFTP panes do.
    ///
    /// `.rename` was missing until 2026-08-14 and its absence was the *inconsistent* half of a
    /// two-spellings bug, not a decision: ``S3Backend/moveItem(at:to:)`` has always renamed an
    /// object with a server-side copy and a delete, and the live bucket carries a file renamed
    /// through the UI. What the pane did with `[.read, .write]` was gray File ▸ Rename… while F2
    /// went on working, because the key asked the *composite's* backend-wide capabilities (the local
    /// backend's) and the validator asked this per-path set — the one-rule-several-spellings family
    /// (docs/NOTES.md ▸ AppKit). Both sites now ask this one.
    ///
    /// A **folder** is the stated caveat rather than a counter-argument: `moveItem` answers `EXDEV`
    /// for a prefix, which is the request to run it as a recursive copy-then-delete, and the inline
    /// rename does not have that machinery — it calls the primitive directly. So F2 on a prefix
    /// reports an error where it used to report the same error one gesture later. That is unchanged
    /// by this capability, which decides only whether the *menu item* agrees with the key.
    ///
    /// `.internalCopy` is the one thing here the other two remote backends cannot claim: a copy
    /// with both ends in this bucket is `x-amz-copy-source`, so the bytes never leave S3 and never
    /// touch this disk. It is what keeps a router from staging a same-bucket duplicate through a
    /// temporary file (``RelayCopy``), which is what SFTP and FTP have no alternative to.
    public var capabilities: VFSCapabilities { [.read, .write, .rename, .internalCopy] }

    // MARK: - Listing

    /// List one "directory" — a `ListObjectsV2` query with `delimiter=/`, looped until the server
    /// stops handing back a continuation token.
    ///
    /// A listing is a **loop**, not a call, which no other backend in this project is. What bounds
    /// it lives in ``enumeratePages(prefix:delimiter:at:isCancelled:body:)``, which every
    /// enumeration this backend makes goes through.
    public func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        try requireOwnBackend(path)
        var entries: [FileEntry] = []
        try enumeratePages(prefix: S3Key.listingPrefix(for: path), delimiter: "/", at: path) { page in
            entries += S3ListingParser.entries(from: page, in: path)
        }
        return entries
    }

    /// Stat one path in a **single** request, by listing with `prefix=` its own key.
    ///
    /// That one answer separates all three outcomes: a `Contents` row whose key is exactly this one
    /// is a file, a `CommonPrefixes` entry of `key/` is a folder, and neither is a path that isn't
    /// there. `S3ListingParser.entry(forKey:in:at:)` holds the exactness rule, which is the part
    /// that bites — a prefix matches siblings too.
    ///
    /// The bucket root is answered directly. It is a directory by construction, and asking the
    /// server about it would only make the root unnavigable when the bucket is empty.
    public func stat(at path: VFSPath) throws -> FileEntry {
        try requireOwnBackend(path)
        let key = S3Key.key(for: path)
        guard !key.isEmpty else { return rootEntry(at: path) }

        let page = try listPage(prefix: key, delimiter: "/", continuationToken: nil, at: path)
        if let entry = S3ListingParser.entry(forKey: key, in: page, at: path) { return entry }
        guard page.isTruncated, try isFolder(key: key, at: path) else {
            throw VFSError.notFound(path)
        }
        return folderEntry(at: path)
    }

    /// Whether anything at all lives under `key/`, asked only when the first page could not answer.
    ///
    /// That page can only fail to answer in one direction, and the asymmetry is worth stating
    /// because it is what keeps the ordinary stat to a single request. S3 returns keys in
    /// lexicographic order and a string sorts before every string it prefixes, so the object named
    /// **exactly** `key` — if there is one — is always the first row of the first page: a *file*
    /// stat cannot be missed by paging. A *folder* can, in principle: `/` is 0x2F, so a sibling
    /// like `docs.txt` or `docs-old` sorts ahead of the `docs/` group, and a thousand of them would
    /// fill the page before the prefix appears. Vanishingly unlikely, and one extra request settles
    /// it exactly rather than leaving a folder that reports "not found".
    private func isFolder(key: String, at path: VFSPath) throws -> Bool {
        let page = try listPage(
            prefix: "\(key)/",
            delimiter: "/",
            continuationToken: nil,
            at: path
        )
        return !page.objects.isEmpty || !page.commonPrefixes.isEmpty
    }

    private func folderEntry(at path: VFSPath) -> FileEntry {
        FileEntry(
            path: path,
            name: path.lastComponent,
            kind: .directory,
            byteSize: 0,
            modificationDate: FileEntry.unknownDate,
            creationDate: FileEntry.unknownDate,
            isHidden: path.lastComponent.hasPrefix("."),
            permissions: 0o755,
            inode: 0,
            symlinkDestination: nil,
            symlinkTargetKind: nil
        )
    }

    /// The bucket root as a `FileEntry`, named after the bucket. Nothing is asked of the server: a
    /// root that cannot be listed fails at `listDirectory`, with an error that says why.
    private func rootEntry(at path: VFSPath) -> FileEntry {
        FileEntry(
            path: path,
            name: location.bucket,
            kind: .directory,
            byteSize: 0,
            modificationDate: FileEntry.unknownDate,
            creationDate: FileEntry.unknownDate,
            isHidden: false,
            permissions: 0o755,
            inode: 0,
            symlinkDestination: nil,
            symlinkTargetKind: nil
        )
    }

    // MARK: - Classification

    /// The server's refusal, or `nil` when it did not refuse.
    ///
    /// Public because the *connect* flow needs it before any backend exists: a 301 carries the
    /// region that would have worked, so the connect form can correct a mistyped region instead of
    /// reporting a failure the user cannot diagnose.
    public static func serviceError(from response: S3Response) -> S3ServiceError? {
        guard !response.isSuccess else { return nil }
        return S3ServiceError.parse(
            response.body,
            status: response.status,
            bucketRegion: response.bucketRegion
        )
    }

    /// The body of a successful response, or the mapped failure of an unsuccessful one.
    ///
    /// Internal rather than file-private because the pagination loop reads its pages through it
    /// (`S3Backend+Pages.swift`), and Swift's `private` does not cross files.
    func succeed(_ response: S3Response, at path: VFSPath) throws -> Data {
        guard let service = Self.serviceError(from: response) else { return response.body }
        throw service.vfsError(for: path)
    }

    /// Normalize a transport failure onto the shared `VFSError` vocabulary, attaching the `VFSPath`
    /// the transport (which only knows a key) couldn't.
    ///
    /// Only ``S3ResponseError/transport(_:)`` can arrive here — a server's *refusal* is a returned
    /// response, not a throw (see ``S3Transport``) — but the service case is mapped too rather than
    /// left to a `default`, so a transport that ever throws one is handled instead of crashing the
    /// switch's exhaustiveness the next time a case is added.
    func mapping<T>(_ path: VFSPath, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as S3ResponseError {
            switch error {
            case .transport:
                throw VFSError.io(path: path, code: EIO)
            case let .service(service):
                throw service.vfsError(for: path)
            }
        }
    }
}
