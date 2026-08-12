import Foundation

/// A `VFSBackend` that browses one S3 bucket as a folder tree (PLAN.md §M21).
///
/// Everything that decides whether a listing is *correct* lives here and is tested: the key
/// translation, the pagination loop, the stat rule, the classification of a response, and the
/// resume decision. The only non-hermetic piece — the network — is an injected ``S3Transport``, so
/// the backend is exercised against the bytes real buckets sent and needs neither a server nor
/// credentials (PLAN.md §2).
///
/// **This is the read half.** The write verbs are the part S3 does not share with the other remote
/// backends: `createDirectory` has no operation behind it beyond writing a zero-byte marker, a
/// rename is copy-then-delete (O(size), and N copies for a "folder"), and there is no `rm -r`.
/// `RemoteTransportBackend`'s four shared verbs were shaped for FTP and SFTP, where they are
/// genuine filesystem operations, so S3 conforms to ``ConnectionScopedBackend`` — the guard all
/// three need — and nothing else. Until the writes land, `capabilities` says `.read` and the
/// panel grays out every operation that would need more, which is the M5 degradation path working
/// as designed rather than a gap.
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

    /// Read and write. No `.clone`, since a copy-on-write clone is a single-filesystem primitive
    /// and S3's server-side copy really does move the bytes (it is just S3 paying for it, not this
    /// machine) — advertising `.clone` would send `CopyEngine` down a path whose whole premise is
    /// that the copy is free and instant.
    ///
    /// No `.watch` either, and that one is permanent: S3 has no change notification, so an S3 pane
    /// re-lists on focus and on demand as the FTP and SFTP panes do.
    public var capabilities: VFSCapabilities { [.read, .write] }

    // MARK: - Listing

    /// List one "directory" — a `ListObjectsV2` query with `delimiter=/`, looped until the server
    /// stops handing back a continuation token.
    ///
    /// A listing is a **loop**, not a call, which no other backend in this project is. Two things
    /// bound it, and both are loud rather than quiet on purpose: a server that repeats a token it
    /// already gave is disagreeing with itself and would spin forever, and a folder past
    /// ``pageLimit`` is refused rather than silently truncated. A partial listing that looks
    /// complete is the failure that matters here — every write and every count downstream would be
    /// computed over rows that are not all the rows.
    public func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        try requireOwnBackend(path)
        let prefix = S3Key.listingPrefix(for: path)
        var entries: [FileEntry] = []
        var token: String?
        var pages = 0

        while true {
            let page = try listPage(prefix: prefix, continuationToken: token, at: path)
            entries += S3ListingParser.entries(from: page, in: path)
            pages += 1
            guard page.isTruncated, let next = page.nextContinuationToken else { return entries }
            guard next != token else { throw VFSError.io(path: path, code: EIO) }
            guard pages < pageLimit else { throw VFSError.io(path: path, code: EFBIG) }
            token = next
        }
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

        let page = try listPage(prefix: key, continuationToken: nil, at: path)
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
        let page = try listPage(prefix: "\(key)/", continuationToken: nil, at: path)
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

    private func listPage(
        prefix: String,
        continuationToken: String?,
        at path: VFSPath
    ) throws -> S3ListingPage {
        let response = try mapping(path) {
            try transport.listObjects(
                prefix: prefix,
                delimiter: "/",
                continuationToken: continuationToken
            )
        }
        let body = try succeed(response, at: path)
        guard let page = try? S3ListingParser.parse(body) else {
            // A 2xx whose body is not a `ListBucketResult` — a captive portal, or a proxy that
            // answered for the endpoint. There is nothing to classify, so it is plain I/O.
            throw VFSError.io(path: path, code: EIO)
        }
        return page
    }

    // MARK: - Transfer

    /// Copy one object's bytes, in whichever of the three directions this bucket can serve.
    ///
    /// - **Down** (this bucket → local disk): a `curl` download, resuming from a partial.
    /// - **Up** (local disk → this bucket): a streamed `--upload-file`. The stream is what makes it
    ///   affordable — see ``S3ProcessArguments/upload(session:key:localPath:)``, where a 512 MiB
    ///   file measured 5.3 MB resident streamed against 1.08 GB buffered.
    /// - **Sideways** (this bucket → itself): `x-amz-copy-source`, server-side. The bytes never
    ///   leave S3, so nothing is downloaded and re-uploaded to duplicate a file — and this is the
    ///   direction `CopyEngine` walks a folder move through, which is what keeps a recursive rename
    ///   from costing the user the whole tree's bandwidth twice.
    ///
    /// A copy to or from a *different* remote is refused rather than routed: it would have to land
    /// on this machine in between, which is two operations wearing one name and neither backend's
    /// to schedule.
    ///
    /// The whole object transfers as one `curl` invocation, so `progress` reports once with the
    /// byte count and `isCancelled` is honored at the file boundary, matching `FTPBackend`.
    public func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        if isCancelled() { throw CancellationError() }
        // Spelled as explicit comparisons rather than a `switch` over the pair: `case (id, .local)`
        // reads as a tuple pattern and is one missing `let` away from binding instead of matching,
        // which would route every direction to whichever arm came first.
        if source.backend == id, destination.backend == .local {
            let transferred = try downloadObject(
                key: S3Key.key(for: source),
                toLocal: destination.path,
                at: source
            )
            if isCancelled() { throw CancellationError() }
            progress(transferred)
        } else if source.backend == .local, destination.backend == id {
            // Reports its own deltas rather than returning a total for the tail below to report: a
            // multipart upload reports one per part, and a second report here would count every
            // byte of a large file twice.
            try uploadObject(
                localPath: source.path,
                key: S3Key.key(for: destination),
                at: destination,
                progress: progress,
                isCancelled: isCancelled
            )
        } else if source.backend == id, destination.backend == id {
            let transferred = try copyObjectServerSide(from: source, to: destination)
            if isCancelled() { throw CancellationError() }
            progress(transferred)
        } else {
            throw VFSError.unsupported(.copyFile)
        }
    }

    /// Upload `localPath` to `key` — in one `PUT` when it fits, in parts when it does not.
    ///
    /// The fork is ``S3MultipartPlan/isWorthwhile(totalSize:)`` and it is a *policy* threshold well
    /// below the 5 GiB the service forces, because multipart buys a retry unit smaller than the file
    /// and a progress bar that moves; the reasoning is argued at
    /// ``S3MultipartLimits/multipartThreshold``.
    ///
    /// On the single-`PUT` path the byte count comes from the write-out's upload counter rather than
    /// from the local file's size, so a short write is visible as a short write instead of being
    /// reported as whatever size the file happened to have on disk.
    private func uploadObject(
        localPath: String,
        key: String,
        at destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        guard !key.isEmpty else { throw VFSError.unsupported(.copyFile) }

        let size = localFileSize(localPath)
        if S3MultipartPlan.isWorthwhile(totalSize: size) {
            // No plan means no number of parts can hold it — S3 stops at 5 TiB. Refused here, by
            // name, rather than offering the whole file and letting the server say `EntityTooLarge`
            // at the end of it.
            guard let plan = S3MultipartPlan(totalSize: size) else {
                throw VFSError.unsupported(
                    .objectTooLargeForStore(name: destination.lastComponent)
                )
            }
            _ = try uploadInParts(
                S3MultipartRequest(
                    localPath: localPath,
                    key: key,
                    destination: destination,
                    plan: plan
                ),
                progress: progress,
                isCancelled: isCancelled
            )
            return
        }

        let response = try write(at: destination) {
            try transport.upload(localPath: localPath, to: key)
        }
        if isCancelled() { throw CancellationError() }
        progress(response.bytesTransferred)
    }

    /// Duplicate one object inside this bucket without the bytes leaving S3.
    ///
    /// **It reports 0 bytes moved, deliberately.** A `CopyObjectResult` carries an ETag and a
    /// timestamp, not a length, so the only way to report a real number is to ask for the object's
    /// size — one extra round trip per file. On a folder move that is one more request per object
    /// on top of the copy and the delete: negligible in money and about **25 minutes** of pure
    /// latency on a 50 000-file prefix at a typical round trip, spent entirely on advancing a
    /// progress bar. Reporting the size without measuring it would be inventing the number.
    ///
    /// What that costs is small and worth naming: this method is reached only from an F5 within one
    /// bucket and from `CopyEngine`'s recursive walk, and in both the engine already knows each
    /// entry's size from the listing it made. So the *item* counter advances normally and the byte
    /// counter does not move for these copies. A direct single-file move never comes here at all —
    /// `CopyEngine.perform` tallies `entry.byteSize` itself when `moveItem` succeeds.
    private func copyObjectServerSide(from source: VFSPath, to destination: VFSPath) throws -> Int64 {
        _ = try write(at: destination) {
            try transport.copyObject(
                from: S3Key.key(for: source),
                to: S3Key.key(for: destination)
            )
        }
        return 0
    }

    /// Download `key` to `localPath`, resuming from a local partial when one is a **proper**
    /// prefix of the object.
    ///
    /// The remote size is checked first rather than left to `curl -C -` to discover, and that is
    /// not caution: measured against a real bucket 2026-08-12, resuming onto an already-complete
    /// file answers **416 Range Not Satisfiable**, which this backend would correctly classify as
    /// a failed copy of a file that is in fact already there. `>` short-circuits, so a fresh
    /// download — the norm — never pays for the extra HEAD.
    private func downloadObject(key: String, toLocal localPath: String, at source: VFSPath) throws -> Int64 {
        let existingLocal = localFileSize(localPath)
        let resume = existingLocal > 0 && remoteSize(ofKey: key) > existingLocal
        let response = try mapping(source) {
            try transport.download(key: key, to: localPath, resume: resume)
        }
        _ = try succeed(response, at: source)
        return response.bytesTransferred
    }

    /// The size of a local regular file, or 0 when it is absent or unreadable — which reads as "no
    /// partial", i.e. a full transfer.
    private func localFileSize(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else { return 0 }
        return size
    }

    /// One object's size via a HEAD, or 0 when it cannot be read (missing or denied → no resumable
    /// partial, so the transfer starts from the beginning and reports the real failure itself).
    private func remoteSize(ofKey key: String) -> Int64 {
        guard let response = try? transport.head(key: key), response.isSuccess else { return 0 }
        return response.contentLength ?? 0
    }

    /// Everything in one bucket shares one endpoint and one credential, so all its jobs serialize
    /// (cheap, no I/O — as `VFSBackend.volumeIdentifier` requires).
    ///
    /// Conservative, and knowingly so: S3 is happy to serve many parallel requests, unlike an FTP
    /// server that caps logins. But the contract requires two paths on one "volume" to answer
    /// equal, and a bucket is the only unit this backend can name — so the choice is between
    /// serial-per-bucket and serial-for-everything (what `nil` means), and the former is the
    /// better of the two.
    public func volumeIdentifier(for path: VFSPath) -> String? {
        "s3://\(location.host):\(location.port)/\(location.bucket)"
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
    private func succeed(_ response: S3Response, at path: VFSPath) throws -> Data {
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
