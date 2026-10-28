import Foundation

/// The write half of ``WebDAVBackend`` (PLAN.md §M32 Slice 4): one request per verb, in its safe
/// spelling (``WebDAVProcessArguments``).
///
/// WebDAV's verbs are richer than SFTP's and FTP's, and the backend is shaped by that rather than by
/// `RemoteTransportBackend`, which works around what those two lack:
///
/// - **A folder is deleted, moved and renamed in one request.** DELETE and MOVE act on the whole
///   tree on the server, so neither is a walk here. COPY is the exception, and only by choice: it is
///   sent for one file at a time, for the reason ``WebDAVProcessArguments/copy(session:backendPath:to:)``
///   gives.
/// - **There is a create-if-absent** (`If-None-Match: *`), which closes the window between a `stat`
///   and a write that the other two protocols leave open.
/// - **A refusal can be about a member.** A DELETE or MOVE of a folder holding a locked file answers
///   424 and names the file in its body, and a server may answer 207 with each member's own status.
///   Either way nothing was done to the folder, and the error names the member.
public extension WebDAVBackend {
    // MARK: - Creating

    /// Create one folder with MKCOL. A 405 is "something is already there", a 409 "the folder it
    /// goes in does not exist" (``WebDAVServiceError/vfsError(for:destination:)``).
    func createDirectory(at path: VFSPath) throws {
        try requireOwnBackend(path)
        guard !path.isRoot else { throw VFSError.alreadyExists(path) }
        try write(path, method: .mkcol) { try transport.mkcol(path.path) }
    }

    /// Create an empty file, **only if nothing is there** — one PUT with `If-None-Match: *`, so the
    /// check and the write are one act on the server and nothing is truncated (``VFSBackend/createFile(at:)``).
    ///
    /// No `stat` first, unlike S3: there, a server ignoring the header would overwrite, so the local
    /// check stays as the guard that works everywhere. WebDAV's servers measured honour it, and the
    /// `stat` comes *after* a refusal instead, because one status means two things. A 409 is a
    /// missing parent folder to RFC 4918, and a folder already at this name to Apache ("Cannot PUT
    /// to a collection", measured 2026-10-23). The second is `alreadyExists`, and only the server
    /// can say which it was.
    func createFile(at path: VFSPath) throws {
        try requireOwnBackend(path)
        guard !path.isRoot else { throw VFSError.alreadyExists(path) }
        let response = try mapping(path) { try transport.putEmpty(path.path, condition: .ifAbsent) }
        guard let refusal = Self.refusal(response, method: .put) else { return }
        if refusal.refusal(for: .ifAbsent) == .alreadyThere { throw VFSError.alreadyExists(path) }
        if refusal.status == 409, (try? stat(at: path)) != nil { throw VFSError.alreadyExists(path) }
        throw refusal.vfsError(for: path)
    }

    // MARK: - Moving and removing

    /// Rename or move `source` inside this account with one MOVE — a folder and everything in it
    /// included, on the server.
    ///
    /// **An occupied destination is refused, not replaced**, which is stricter than
    /// ``VFSBackend/moveItem(at:to:)`` promises and on the safe side of it: `Overwrite: F` answers
    /// 412, which is `alreadyExists`. Every caller already makes the destination free first.
    ///
    /// A destination on another backend is `EXDEV`, the engine's cue to copy and delete — a second
    /// root on the same server included, since its backend is another one.
    ///
    /// A rename that changes only the case of a name is refused on a server whose disk ignores case:
    /// macOS's Apache answered 412 with `Overwrite: F` and 403 "Source and Destination URIs are the
    /// same" with `T`, leaving the file as it was. The NAS's disk keeps case, and renames there.
    ///
    /// **A destination folder that does not exist is `notFound` for that folder**, which is what
    /// RFC 4918's 409 says and what Nextcloud sends. Apache does not: the NAS and macOS's Apache both
    /// answer a MOVE into a missing folder with **500** "Could not rename resource" (measured
    /// 2026-10-23 and 2026-10-24), which is `rename(2)` failing on the server and would otherwise
    /// read as an I/O error. So a 500 is followed by one stat of that folder, and only the server
    /// saying it is gone turns it into `notFound`. That is the answer Put Back waits for before it
    /// rebuilds a folder deleted since the item went into a share's `#recycle`.
    func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        try requireOwnBackend(source)
        guard destination.backend == id else { throw VFSError.io(path: source, code: EXDEV) }
        guard !source.isRoot, !destination.isRoot else {
            throw VFSError.unsupported(.deleteConnectionRoot)
        }
        let response = try mapping(source) { try transport.move(source.path, to: destination.path) }
        guard let refusal = Self.refusal(response, method: .move) else { return }
        if refusal.status == 500, let folder = destination.parent, isGone(folder) {
            throw VFSError.notFound(folder)
        }
        throw refusal.vfsError(for: source, destination: destination)
    }

    /// Permanently remove `path` with one DELETE, recursively for a folder. The protocol has no
    /// Trash. (The NAS keeps one of its own: a delete there lands in the share's `#recycle`.)
    ///
    /// The **body** is read, since a folder holding a locked file answers 424 and names it, and
    /// nothing was deleted (measured on the NAS).
    func removeItem(at path: VFSPath) throws {
        try requireOwnBackend(path)
        guard !path.isRoot else { throw VFSError.unsupported(.deleteConnectionRoot) }
        try write(path, method: .delete) { try transport.delete(path.path) }
    }

    // MARK: - The save-back

    /// Replace a file with local bytes, guarded by `condition` (PLAN.md §M32 Slice 4).
    ///
    /// `If-Match` with the tag the check just read, which a WebDAV listing carries as S3's does. What
    /// the app sends for a **weak** tag is no condition at all (``RemoteFileRevision/preconditionTag``):
    /// no spelling of one can pass `If-Match`.
    ///
    /// A 412 against `If-Match` is the file changed or the file gone, and Apache answers both with it
    /// (``WebDAVServiceError/refusal(for:)``), so the server is asked once which it was before the
    /// sentence is chosen.
    ///
    /// - Returns: whether the precondition went with the request, which is all a client can know.
    @discardableResult
    func writeBack(
        localPath: String,
        to destination: VFSPath,
        condition: S3WriteCondition,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Bool {
        try requireOwnBackend(destination)
        if isCancelled() { throw CancellationError() }
        // No date is asked for: the edited copy was written moments ago, and the server's own
        // stamp says the same thing.
        let response = try send(
            localPath,
            to: destination,
            headers: WebDAVPutHeaders(condition: condition),
            progress: progress,
            isCancelled: isCancelled
        )
        if let refusal = Self.refusal(response, method: .put) {
            throw conditionalError(refusal, condition: condition, at: destination)
        }
        return condition.isConditional
    }

    // MARK: - Copying on the server

    /// Whether a copy inside this account is worth trying as a COPY: both ends here, and the server
    /// has not answered COPY as a method it lacks. A refusal sends the copy through this disk.
    func mayAttemptInternalCopy(from source: VFSPath, to destination: VFSPath) -> Bool {
        source.backend == id && destination.backend == id && !serverSideCopy.isRefused
    }

    // MARK: - Metadata

    /// What this connection has failed to carry (PLAN.md §M25 Slice 5b). Zero for a path on
    /// another account, so a routing backend adding up two ends never counts this one twice.
    func metadataTally(at path: VFSPath) -> RemoteMetadataTally {
        path.backend == id ? metadata.tally : .zero
    }

    func copyMetadata(at source: VFSPath, to destination: VFSPath) throws {
        try copyMetadata(at: source, to: destination, sourceMetadata: nil)
    }

    /// Finish a folder the engine recreated: onto this disk, the server's date is carried with
    /// `utimes`; onto the server, nothing can be, and that is counted. MKCOL stamps a folder with
    /// the moment it was made.
    func copyMetadata(
        at source: VFSPath,
        to destination: VFSPath,
        sourceMetadata: RemoteSourceMetadata?
    ) throws {
        let hint: RemoteSourceMetadata
        if let sourceMetadata {
            hint = sourceMetadata
        } else if source.backend == .local {
            hint = .ofLocalFile(source.path)
        } else {
            hint = RemoteSourceMetadata(try stat(at: source))
                ?? RemoteSourceMetadata(permissions: nil, modificationTime: nil)
        }
        if destination.backend == .local {
            carryOntoLocal(hint, at: destination.path)
        } else if destination.backend == id {
            recordDateNotKept(hint)
        }
    }
}

// MARK: - Internals

extension WebDAVBackend {
    /// Upload one local file, unconditionally — what F5 into a server is. Every caller of
    /// `copyFile` has already made the destination free or means to replace it: the checksum
    /// manifest and the pack delivery both rely on an upload replacing (`ChecksumCreateRun`).
    ///
    /// The PUT asks for the source's date (``WebDAVModificationTime``), and the date counts as kept
    /// only when the server answers that it kept it. Everywhere else — Apache, the NAS — the server
    /// stamps the file with the moment it arrived, and the date is counted as not kept.
    func upload(
        _ source: VFSPath,
        to destination: VFSPath,
        hint: CopySourceHint,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        let metadata = hint.metadata ?? .ofLocalFile(source.path)
        let response = try send(
            source.path,
            to: destination,
            headers: WebDAVPutHeaders(modificationTime: metadata.modificationTime),
            progress: progress,
            isCancelled: isCancelled
        )
        if let refusal = Self.refusal(response, method: .put) {
            throw refusal.vfsError(for: destination)
        }
        if !WebDAVModificationTime.wasKept(by: response) { recordDateNotKept(metadata) }
    }

    /// Count `source`'s date as not kept, when it had one.
    ///
    /// Its date and nothing else. **A mode is not counted**, and that is not leniency: WebDAV has no
    /// permissions at all, so no row on the server shows one and there is nothing for a mode to be
    /// missing from — the reading S3 takes for both halves. A date is different, because every row
    /// shows one, and an upload's reads as the moment it arrived.
    func recordDateNotKept(_ source: RemoteSourceMetadata?) {
        guard let source else { return }
        let date = RemoteSourceMetadata(permissions: nil, modificationTime: source.modificationTime)
        metadata.record(dropped: metadata.planWithoutTransferFlag(for: date).dropped)
    }

    /// One PUT of a local file, with the bar settled on `curl`'s own count at the end. The answer is
    /// returned unread, since what a refusal means depends on what was asked.
    private func send(
        _ localPath: String,
        to destination: VFSPath,
        headers: WebDAVPutHeaders,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> WebDAVHTTPResponse {
        var tally = TransferProgressTally()
        let response = try mapping(destination) {
            try transport.upload(
                localPath: localPath,
                to: destination.path,
                headers: headers,
                progress: { delta in
                    tally.add(delta)
                    progress(delta)
                },
                isCancelled: isCancelled
            )
        }
        if isCancelled() { throw CancellationError() }
        if response.isSuccess, let remainder = tally.remainder(against: response.bytesUploaded) {
            progress(remainder)
        }
        return response
    }

    /// Duplicate one file with COPY, returning its size for the bar — nothing moves through here,
    /// and the queue's total counts the file.
    ///
    /// **A 501 or 405 latches**, as SFTP's missing `copy-data` does: either says the server does not
    /// do COPY at all, which is true of every later file. Anything else is about these two paths.
    /// Either way the copy throws and the app's router stages it through this disk.
    ///
    /// The copy is stamped with the moment it was made: Apache's COPY keeps the mode and not the
    /// date (measured 2026-10-23, a 2020 file copied as today), so the date is counted as not kept,
    /// as for SFTP's server-side `cp`. Nextcloud's COPY keeps it (measured 2026-10-24), and the
    /// answer says nothing either way, so there the count under-claims: the safe direction, and
    /// not worth a `stat` per copied file to tell.
    func duplicate(_ source: VFSPath, to destination: VFSPath, hint: CopySourceHint) throws -> Int64 {
        guard !serverSideCopy.isRefused else { throw VFSError.unsupported(.remoteToRemoteCopy) }
        let response = try mapping(source) { try transport.copy(source.path, to: destination.path) }
        if let refusal = Self.refusal(response, method: .copy) {
            if refusal.status == 501 || refusal.status == 405 {
                serverSideCopy.recordUnsupported()
                throw VFSError.unsupported(.remoteToRemoteCopy)
            }
            throw refusal.vfsError(for: source, destination: destination)
        }
        recordDateNotKept(hint.metadata)
        return hint.expectedSize ?? remoteSize(of: destination)
    }

    /// Finish a download on this disk with the server's date. Free: `utimes` on a local file.
    func carryOntoLocal(_ hint: RemoteSourceMetadata?, at localPath: String) {
        guard let hint else { return }
        let carry = hint.plan(with: .localDestination)
        var dropped = carry.dropped
        if !LocalMetadataWriter.apply(carry.steps, to: localPath).isEmpty {
            dropped.formUnion(carry.attemptedAspects)
        }
        metadata.record(dropped: dropped)
    }

    /// One write request, and the error its refusal was.
    @discardableResult
    func write(
        _ path: VFSPath,
        destination: VFSPath? = nil,
        method: WebDAVMethod,
        _ body: () throws -> WebDAVHTTPResponse
    ) throws -> WebDAVHTTPResponse {
        let response = try mapping(path, body)
        if let refusal = Self.refusal(response, method: method) {
            throw refusal.vfsError(for: path, destination: destination)
        }
        return response
    }

    /// The refusal in a write's answer, or `nil` when the write happened.
    ///
    /// **A 207 from a write is not a success.** RFC 4918 answers a DELETE, COPY or MOVE of a folder
    /// that failed for some members with a multistatus naming each one, and the operation did not
    /// happen as asked. So a 207 is read: no member refused, and it succeeded; a member refused, and
    /// that member's status is the error. A 207 whose body cannot be read is a failure too, since
    /// its outcome is unknown.
    static func refusal(_ response: WebDAVHTTPResponse, method: WebDAVMethod) -> WebDAVServiceError? {
        guard response.status == 207 else {
            return response.isSuccess ? nil : serviceError(response, method: method)
        }
        guard (try? WebDAVMultistatusParser.parse(response.body)) != nil else {
            return WebDAVServiceError(status: 207, method: method)
        }
        let refusal = serviceError(response, method: method)
        return refusal.members.isEmpty ? nil : refusal
    }

    /// The error a refused save-back is, read against the condition it carried.
    private func conditionalError(
        _ refusal: WebDAVServiceError,
        condition: S3WriteCondition,
        at path: VFSPath
    ) -> VFSError {
        switch refusal.refusal(for: condition) {
        case .alreadyThere:
            return .alreadyExists(path)
        case .changedSince, .goneSince:
            let name = path.lastComponent
            return isGone(path)
                ? .unsupported(.remoteFileGoneSinceFetch(name: name))
                : .unsupported(.remoteFileChangedSinceFetch(name: name))
        case nil:
            return refusal.vfsError(for: path)
        }
    }

    /// Whether the server says nothing is at `path` now. Any other answer, a failed stat included,
    /// is not "gone": of the two sentences, "it changed" is the one that sends nobody to look for a
    /// file that is still there.
    private func isGone(_ path: VFSPath) -> Bool {
        do {
            _ = try stat(at: path)
            return false
        } catch VFSError.notFound {
            return true
        } catch {
            return false
        }
    }
}
