import Foundation

/// A `VFSBackend` for one WebDAV account (PLAN.md §M32). Here: list, stat by `Depth: 0`, and the
/// byte copies in all three directions. The other write verbs are in `WebDAVBackend+Write.swift`.
///
/// Everything that decides whether an answer is *correct* lives here or below it in the core: the
/// URL a path becomes, which row of a multistatus is the folder, what each row is, the resume
/// decision and the error a status maps to. The network is an injected ``WebDAVTransport``.
public struct WebDAVBackend: ConnectionScopedBackend {
    /// The account this backend is rooted at — its identity.
    public let location: WebDAVLocation
    let transport: any WebDAVTransport
    /// What this connection has failed to carry. It offers nothing: the one time property is
    /// read-only (PLAN.md §M32), so every upload, COPY and recreated folder counts its date as not
    /// kept, and the app says so in the status line (``recordDateNotKept(_:)``).
    let metadata = RemoteMetadataSupport(offering: [])
    /// Whether this server has answered COPY as a method it does not have, so the next duplicate is
    /// staged through this disk without asking again.
    let serverSideCopy = ServerSideCopySupport()

    public init(location: WebDAVLocation, transport: any WebDAVTransport) {
        self.location = location
        self.transport = transport
    }

    public var id: VFSBackendID { location.backendID }
    public var connectionDescriptor: String { location.descriptor }

    /// Readable, writable, and renamed in place by MOVE. Not `.internalCopy`: COPY is attempted
    /// rather than promised (``mayAttemptInternalCopy(from:to:)``). No `.trash`, since the protocol
    /// has none, so F8 is a confirmed permanent delete. No `.watch`, permanently — WebDAV has no
    /// change notification, so a pane re-lists on focus and on demand as the other remotes do.
    public var capabilities: VFSCapabilities { [.read, .write, .rename] }

    // MARK: - Listing

    /// List one folder with a single `Depth: 1` PROPFIND.
    ///
    /// The request names the path as a collection, with its trailing slash, which is how a pane
    /// asks for a folder. If what is there is a **file**, Apache does not answer with the file:
    /// measured on the NAS 2026-10-23, a `Depth: 1` PROPFIND of `photo.jpg/` answers **400 Bad
    /// Request**, an HTML page that says nothing about why. So a 400, 404 or 409 from a listing is
    /// followed by a stat without the slash, and a file there is reported as `notADirectory` — what
    /// a pane needs to hear for a typed path or a restored tab that has become a file. The second
    /// request is paid only on a failure.
    public func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        try requireOwnBackend(path)
        let response = try mapping(path) {
            try transport.propfind(path.path, depth: .one, isCollection: true)
        }
        if Self.mayNameAFile(response.status), !path.isRoot,
           let entry = try? stat(at: path), entry.kind != .directory {
            throw VFSError.notADirectory(path)
        }
        let listing = try listing(of: path, from: response)
        guard listing.folder.isCollection else { throw VFSError.notADirectory(path) }
        return listing.entries(in: path)
    }

    /// The statuses a server may answer a listing with when the path names a file — Apache's 400
    /// (measured), and the 404 or 409 a server reading the slash as "a folder by this name" would.
    static func mayNameAFile(_ status: Int) -> Bool {
        status == 400 || status == 404 || status == 409
    }

    /// Stat one path with a single `Depth: 0` PROPFIND, naming it **without** a trailing slash,
    /// since a stat does not know whether it is asking about a file or a folder. Apache answers a
    /// folder named that way with the folder (the `noslash` fixture), and `<resourcetype>` says
    /// which it is.
    ///
    /// The root is answered without asking, as FTP and S3 answer theirs: it is a folder by
    /// construction, the connect probe has already checked it is one, and a root that has stopped
    /// answering fails at `listDirectory` with an error that says why.
    public func stat(at path: VFSPath) throws -> FileEntry {
        try requireOwnBackend(path)
        guard !path.isRoot else { return rootEntry(at: path) }
        let response = try mapping(path) {
            try transport.propfind(path.path, depth: .zero, isCollection: false)
        }
        return try listing(of: path, from: response).folder.entry(at: path)
    }

    /// A PROPFIND's answer as a listing of `path`, or the error it was.
    ///
    /// A 2xx that is not a multistatus — a web page, an empty body — is an I/O failure rather than
    /// an empty folder: a server answering PROPFIND with something else is not answering the
    /// question, and an empty listing would show a folder that is not empty as empty.
    private func listing(of path: VFSPath, from response: WebDAVHTTPResponse) throws -> WebDAVListing {
        guard response.isSuccess else {
            throw Self.serviceError(response, method: .propfind).vfsError(for: path)
        }
        let serverPath = location.serverPath(forBackendPath: path.path)
        guard let multistatus = try? WebDAVMultistatusParser.parse(response.body),
              let listing = try? multistatus.listing(of: serverPath)
        else { throw VFSError.io(path: path, code: EIO) }
        return listing
    }

    /// The root as a `FileEntry`, named after the host as FTP's is.
    private func rootEntry(at path: VFSPath) -> FileEntry {
        FileEntry(
            path: path,
            name: location.host,
            kind: .directory,
            byteSize: 0,
            modificationDate: FileEntry.unknownDate,
            creationDate: FileEntry.unknownDate,
            isHidden: false,
            permissions: nil,
            inode: 0,
            symlinkDestination: nil,
            symlinkTargetKind: nil
        )
    }

    // MARK: - Moving bytes

    public func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        try copyFile(
            at: source,
            to: destination,
            hint: .none,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    /// Copy one file: a download, an upload, or a COPY on the server, decided by which ends are
    /// here. Any other pair is two accounts, which the app's router stages through this disk.
    ///
    /// The hint's metadata is what a download carries onto the local copy (the server's date, as
    /// FTP and SFTP carry theirs), and what an upload or a COPY counts as not kept. Its size is what
    /// a COPY reports, since no bytes move through here.
    public func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        hint: CopySourceHint,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        if isCancelled() { throw CancellationError() }
        if source.backend == id, destination.backend == .local {
            try download(source, to: destination, progress: progress, isCancelled: isCancelled)
            carryOntoLocal(hint.metadata, at: destination.path)
        } else if source.backend == .local, destination.backend == id {
            try upload(
                source,
                to: destination,
                hint: hint,
                progress: progress,
                isCancelled: isCancelled
            )
        } else if source.backend == id, destination.backend == id {
            let size = try duplicate(source, to: destination, hint: hint)
            if isCancelled() { throw CancellationError() }
            progress(size)
        } else {
            throw VFSError.unsupported(.remoteToRemoteCopy)
        }
    }

    /// Download one file to the local disk.
    ///
    /// A partial file already at the destination is resumed only when the server's copy is larger,
    /// which costs a `Depth: 0` stat and is asked only when there is a partial: resuming onto a
    /// complete file answers 416 (measured on the NAS), which would read as a failed copy of a file
    /// that is in fact all there. Otherwise the download starts over, and `--output` replaces what
    /// was there.
    ///
    /// What streams while the bytes move is the destination growing; what the run reports at the
    /// end is exact. The tail reports the difference, so the bar settles on `curl`'s own count.
    private func download(
        _ source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        let existing = localFileSize(destination.path)
        let resume = existing > 0 && remoteSize(of: source) > existing

        var tally = TransferProgressTally()
        let response = try mapping(source) {
            try transport.download(
                source.path,
                to: destination.path,
                resume: resume,
                progress: { delta in
                    tally.add(delta)
                    progress(delta)
                },
                isCancelled: isCancelled
            )
        }
        guard response.isSuccess else {
            throw Self.serviceError(response, method: .get).vfsError(for: source)
        }
        if isCancelled() { throw CancellationError() }
        if let remainder = tally.remainder(against: response.bytesDownloaded) { progress(remainder) }
    }

    /// The server's size for `path`, or 0 when it cannot be read — which reads as "nothing to
    /// resume onto", so the download starts over and reports any real failure itself.
    func remoteSize(of path: VFSPath) -> Int64 {
        guard let entry = try? stat(at: path), entry.kind == .file else { return 0 }
        return entry.byteSize
    }

    /// The size of a local file, or 0 when there is none.
    private func localFileSize(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else { return 0 }
        return size
    }

    /// Everything on one server shares one origin, so its jobs serialize — two roots on one server
    /// included, since they are one machine and usually one account.
    public func volumeIdentifier(for path: VFSPath) -> String? {
        location.origin()
    }

    // MARK: - Classification

    /// A refusal, read from the response.
    static func serviceError(_ response: WebDAVHTTPResponse, method: WebDAVMethod) -> WebDAVServiceError {
        WebDAVServiceError.parse(response.body, status: response.status, method: method)
    }

    /// Run a transport call, mapping a request that got no answer onto the shared vocabulary as
    /// FTP's and S3's do: an I/O failure at `path`. The certificate cases belong to the connect
    /// probe, where the app can act on them; meeting one down here means the server changed
    /// mid-session.
    func mapping<T>(_ path: VFSPath, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as WebDAVResponseError {
            switch error {
            case .transport:
                throw VFSError.io(path: path, code: EIO)
            case let .service(service):
                throw service.vfsError(for: path)
            }
        }
    }
}
