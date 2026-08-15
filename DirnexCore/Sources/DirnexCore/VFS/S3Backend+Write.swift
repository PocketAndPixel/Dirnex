import Foundation

/// The write half of ``S3Backend`` (PLAN.md §M21) — the part S3 shares with no other backend in
/// this project.
///
/// `RemoteTransportBackend`'s four verbs were shaped for FTP and SFTP, where `MKD`, `RNFR`/`RNTO`
/// and `DELE` are genuine filesystem operations on a genuine filesystem. A bucket has none of them.
/// What it has instead:
///
/// - **A folder is a query convention**, so `createDirectory` writes a zero-byte marker and nothing
///   else happens on the server. Making one is not how a folder starts existing — putting a key
///   under a prefix is — so the marker's only job is to let an *empty* folder be visible at all.
/// - **A rename is a copy and a delete**, server-side for one object and a whole recursive walk for
///   a prefix. Nothing about it is atomic.
/// - **There is no `rm -r`**, so removing a folder means enumerating every key beneath it. That is
///   what makes the batched `DeleteObjects` worth its parser: one request per 1000 keys instead of
///   one per key, on a verb where every request is billed.
///
/// The recursive cases deliberately do **not** live here. `moveItem` answers `EXDEV` for a prefix
/// and `CopyEngine` then runs the walk it already implements — on the operation queue, with
/// progress, cancellation, conflict policy and a per-item failure report — rather than this backend
/// growing a second, blinder copy of all of that. That is the same signal `RemoteTransportBackend`
/// sends for a cross-backend move, used here for a cross-*shape* one: the operation is expressible,
/// it simply is not a rename.
public extension S3Backend {
    // MARK: - Creating

    /// Create a folder by writing its zero-byte marker at `key/`.
    ///
    /// The trailing slash is the whole content of the operation, and it is why this cannot go
    /// through the upload path: `curl -T` against a URL ending in `/` appends the local file's
    /// basename (measured), so a marker written that way lands under a name nobody chose.
    /// ``S3ProcessArguments/putEmptyObject(session:key:)`` has no such behavior.
    ///
    /// Nothing checks whether the folder is already there first. A marker is idempotent by
    /// construction — writing the same zero bytes to the same key twice leaves one object — and a
    /// prefix that already has files under it needs no marker at all, so the extra listing would
    /// bill a request to prevent nothing.
    func createDirectory(at path: VFSPath) throws {
        try requireOwnBackend(path)
        let prefix = S3Key.listingPrefix(for: path)
        guard !prefix.isEmpty else { throw VFSError.alreadyExists(path) }
        _ = try write(at: path) { try transport.putEmptyObject(key: prefix) }
    }

    /// Create an empty object at `path`.
    ///
    /// Unlike ``createDirectory(at:)`` this **does** check first, and the asymmetry is the point: a
    /// marker cannot destroy anything, where an empty PUT over an existing key replaces a real file
    /// with nothing. S3 has no create-if-absent — no `O_EXCL`, no conditional PUT in the base API —
    /// so the check is a stat and the race between it and the write is unavoidable and accepted.
    /// It is the difference between "two people creating a file at once" and "F7 silently truncated
    /// a file that was already there".
    func createFile(at path: VFSPath) throws {
        try requireOwnBackend(path)
        let key = S3Key.key(for: path)
        guard !key.isEmpty else { throw VFSError.alreadyExists(path) }
        if (try? stat(at: path)) != nil { throw VFSError.alreadyExists(path) }
        _ = try write(at: path) { try transport.putEmptyObject(key: key) }
    }

    // MARK: - Moving

    /// Rename one object inside this bucket: a server-side copy followed by a delete of the source.
    ///
    /// **A folder throws `EXDEV`**, which is not a failure — it is the request to do it the long
    /// way. `CopyEngine.perform` catches exactly that and falls back to a recursive copy-then-delete
    /// that reports progress, honors cancellation, applies the conflict policy and collects
    /// per-item failures. A prefix move is N copies and N deletes with no atomicity available at
    /// any layer, so it belongs in the machinery built for long operations rather than in a
    /// backend call that would block with no way to stop it and no way to say how far it got.
    ///
    /// A destination on another backend takes the same exit, for the reason
    /// `RemoteTransportBackend` documents: an upload-then-delete is not a remote rename.
    ///
    /// The order — copy, verify, then delete — is what keeps a failure survivable. If the delete
    /// fails the user has the file twice, which is visible and fixable; the other order loses it.
    func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        try requireOwnBackend(source)
        guard destination.backend == id else {
            throw VFSError.io(path: source, code: EXDEV)
        }
        let sourceKey = S3Key.key(for: source)
        let destinationKey = S3Key.key(for: destination)
        guard !sourceKey.isEmpty, !destinationKey.isEmpty else {
            throw VFSError.unsupported(.deleteConnectionRoot)
        }
        guard try isSingleObject(key: sourceKey, at: source) else {
            throw VFSError.io(path: source, code: EXDEV)
        }
        _ = try write(at: source) {
            try transport.copyObject(from: sourceKey, to: destinationKey)
        }
        _ = try write(at: source) { try transport.deleteObject(key: sourceKey) }
    }

    // MARK: - Removing

    /// Permanently remove `path` — one object, or every key under a prefix.
    ///
    /// A folder is deleted in batches of ``S3DeleteBatch/maximumKeys``, which is where the bulk verb
    /// earns its parser: a 200 can still carry per-key `<Error>` rows, so the **body** is the
    /// outcome and a caller reading only the status would report a folder as deleted while files
    /// the bucket policy protects are still in it. The first such row is raised as the failure.
    ///
    /// The marker is included in the sweep rather than deleted separately: an empty folder's only
    /// key *is* its marker, and a recursive enumeration with no delimiter returns it like any other
    /// object. So an empty folder and a full one take the same path.
    func removeItem(at path: VFSPath) throws {
        try requireOwnBackend(path)
        let key = S3Key.key(for: path)
        guard !key.isEmpty else { throw VFSError.unsupported(.deleteConnectionRoot) }

        if try isSingleObject(key: key, at: path) {
            _ = try write(at: path) { try transport.deleteObject(key: key) }
            return
        }
        let keys = try allKeys(under: S3Key.listingPrefix(for: path), at: path)
        guard !keys.isEmpty else { throw VFSError.notFound(path) }
        for batch in S3DeleteBatch.chunks(of: keys) {
            let response = try write(at: path) { try transport.deleteObjects(keys: batch) }
            let result = S3DeleteResult.parse(response.body)
            guard result.errors.isEmpty else {
                throw Self.failure(result.errors[0], under: path)
            }
        }
    }

    // MARK: - Transfer

    /// Whether `key` names an object of its own, as opposed to a prefix (or nothing).
    ///
    /// The exactness is the rule that bites, and it is `stat`'s rule reused rather than re-derived:
    /// listing with `prefix=README` comes back holding `README.crams` and friends and *no*
    /// `README`, so anything reading the first row decides the shape of an operation from a
    /// sibling's name. Here that would send a single-object rename down the recursive path, or —
    /// worse — a recursive delete down the single-object one.
    private func isSingleObject(key: String, at path: VFSPath) throws -> Bool {
        guard let entry = try? stat(at: path) else { return false }
        return entry.kind != .directory
    }

    /// Every key under `prefix`, across as many pages as it takes.
    ///
    /// `delimiter: nil` is what makes it recursive: with no delimiter the server groups nothing into
    /// `CommonPrefixes` and returns each key at every depth, which is exactly the flat list a batch
    /// delete wants. The page ceiling and the repeated-token guard come from
    /// ``S3Backend/enumeratePages(prefix:delimiter:at:isCancelled:body:)`` — literally, since a
    /// partial enumeration here would report a folder as deleted while leaving most of it in place,
    /// and a rule that important is not one to keep a second copy of.
    private func allKeys(under prefix: String, at path: VFSPath) throws -> [String] {
        var keys: [String] = []
        try enumeratePages(prefix: prefix, delimiter: nil, at: path) { page in
            keys += page.objects.map(\.key)
        }
        return keys
    }

    /// One write request: issue it, map a transport throw onto the shared vocabulary, and turn the
    /// server's refusal into a `VFSError` — the same three steps every read path takes, so a write
    /// cannot classify a 403 differently from a listing that hit the same policy.
    ///
    /// Internal rather than file-private: `copyFile` lives in the main file and goes through this
    /// same funnel, and Swift's `private` does not cross files.
    func write(at path: VFSPath, _ body: () throws -> S3Response) throws -> S3Response {
        let response = try mapping(path, body)
        if let service = Self.serviceError(from: response) {
            throw service.vfsError(for: path)
        }
        return response
    }

    /// The `VFSError` for one key a batch delete refused.
    ///
    /// `AccessDenied` on a single key inside an otherwise-permitted prefix is the case that actually
    /// happens, so it maps to `permissionDenied` on **that key's** path rather than on the folder —
    /// naming the folder would send the user to check permissions on something that is fine.
    private static func failure(_ error: S3DeleteFailure, under path: VFSPath) -> VFSError {
        let target = VFSPath(backend: path.backend, path: "/\(error.key)")
        switch error.code {
        case "AccessDenied": return .permissionDenied(target)
        case "NoSuchKey": return .notFound(target)
        default: return .io(path: target, code: EIO)
        }
    }
}
