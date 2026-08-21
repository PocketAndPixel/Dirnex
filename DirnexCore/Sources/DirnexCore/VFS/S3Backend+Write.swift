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
    /// ``S3ProcessArguments/putEmptyObject(session:key:condition:)`` has no such behavior.
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
    /// with nothing. It is the difference between "two people creating a file at once" and "F7
    /// silently truncated a file that was already there".
    ///
    /// **The stat is no longer the only guard, 2026-08-16.** It used to be, and this comment used
    /// to say the race between it and the write was "unavoidable and accepted" because S3 had no
    /// create-if-absent — which stopped being true when conditional writes arrived, and a
    /// limitation stated in prose is a feature request with a date on it. `If-None-Match: *` now
    /// rides along, so on a server that honours it the check and the write are one atomic act.
    ///
    /// The stat **stays**, and that is not belt-and-braces: a server that ignores the header
    /// answers 200 and overwrites, indistinguishably from having honoured it, so the local check
    /// is what keeps the behaviour identical everywhere (``S3WriteConditionUnsupported``). What the
    /// header adds is the window between them, on the servers that can close it.
    func createFile(at path: VFSPath) throws {
        try requireOwnBackend(path)
        let key = S3Key.key(for: path)
        guard !key.isEmpty else { throw VFSError.alreadyExists(path) }
        if (try? stat(at: path)) != nil { throw VFSError.alreadyExists(path) }
        _ = try conditionallyWrite(at: path, condition: .ifAbsent) {
            try transport.putEmptyObject(key: key, condition: .ifAbsent)
        }
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
    ///
    /// **The keys are decoded, and this is the one enumeration that forgot to be** (fixed
    /// 2026-08-22). A page carries keys exactly as the wire spelled them, and under
    /// `encoding-type=url` that is `application/x-www-form-urlencoded` — so a folder holding
    /// `untitled folder/a.txt` enumerated as `untitled+folder/a.txt` and *that* is what went into
    /// `DeleteObjects`. S3's delete is idempotent, so every one of those keys came back in a
    /// `<Deleted>` row without ever having existed: the request succeeded, the parser found no
    /// `<Error>`, and the folder was still there. Two features failed on it, both silently — F8 on
    /// any folder holding a name with a space, and the *delete half* of a folder rename, which is
    /// how it was reported (a rename that left the folder under both names, docs/NOTES.md ▸ curl
    /// for S3).
    ///
    /// `S3ListingParser.decoder(for:)` rather than a decode of our own, for the reason its own
    /// comment gives: a second decoder is how two routes come to disagree about what a key is
    /// called. `S3SubtreeListing` already used it, and its comment claimed this delete "enumerates
    /// the same way and takes its keys from the same element" — true of the element and not of the
    /// decode, which is exactly the shape that hides.
    ///
    /// A key that does not decode **throws**, where the listing routes drop the row. The asymmetry
    /// is the point: a row nobody can name is one a listing is right to omit, and a key a delete
    /// omits is a file left behind under a folder reported as gone.
    private func allKeys(under prefix: String, at path: VFSPath) throws -> [String] {
        var keys: [String] = []
        try enumeratePages(prefix: prefix, delimiter: nil, at: path) { page in
            let decode = S3ListingParser.decoder(for: page)
            for object in page.objects {
                guard let key = decode(object.key) else {
                    throw VFSError.io(path: path, code: EILSEQ)
                }
                keys.append(key)
            }
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

    /// The same write, with the server's refusal read against the precondition that was sent
    /// (PLAN.md §M21 Slice 17).
    ///
    /// It exists because ``write(at:_:)`` cannot answer this: `vfsError(for:)` maps a status with
    /// no idea what was asked, and here one status means opposite things — a 412 against
    /// `.ifAbsent` is "there is already a file here", against `.ifMatches` it is "somebody else has
    /// written this since you downloaded it". Nothing in the response separates them, so the
    /// condition has to be in hand at the moment the status is read, which is what makes this a
    /// funnel rather than a wider `switch` inside the existing one.
    ///
    /// Everything the precondition did *not* cause travels on untouched. A 403 on a conditional
    /// upload is still a permissions problem, and reporting it as a conflict would send the user
    /// looking for an edit nobody made.
    @discardableResult
    func conditionallyWrite(
        at path: VFSPath,
        condition: S3WriteCondition,
        _ body: () throws -> S3Response
    ) throws -> S3Response {
        let response = try mapping(path, body)
        guard let service = Self.serviceError(from: response) else { return response }
        throw Self.refusalError(condition.refusal(for: service), or: service, at: path)
    }

    /// The `VFSError` a refused precondition becomes — or the server's own failure when the
    /// precondition was not what refused it.
    ///
    /// Its own function rather than a `switch` inside ``conditionallyWrite(at:condition:_:)``
    /// because a second caller reads a refusal that funnel structurally cannot see: a
    /// `CompleteMultipartUpload` may refuse **inside a 200**, where there is no service error to
    /// hand this at all until the body has been parsed (PLAN.md §M21 Slice 19). Two sites deciding
    /// what a refusal *means* is how the two would come to disagree about the sentence, which is
    /// this project's most repeated finding.
    static func refusalError(
        _ refusal: S3WriteConditionRefusal?,
        or service: S3ServiceError,
        at path: VFSPath
    ) -> VFSError {
        switch refusal {
        case .alreadyThere:
            return VFSError.alreadyExists(path)
        case .changedSince:
            return VFSError.unsupported(.remoteFileChangedSinceFetch(name: path.lastComponent))
        case .goneSince:
            return VFSError.unsupported(.remoteFileGoneSinceFetch(name: path.lastComponent))
        case .none:
            return service.vfsError(for: path)
        }
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
