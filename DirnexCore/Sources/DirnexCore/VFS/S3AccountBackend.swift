import Foundation

/// The non-hermetic boundary beneath an ``S3AccountBackend`` — the four requests that are about an
/// *account* rather than a bucket.
///
/// Separate from ``S3Transport`` rather than bolted onto it, because that protocol is a connection
/// to one bucket and every one of these exists precisely where there is no bucket yet. The app's
/// implementation shares all of the process plumbing through `S3CurlRunner`, so the split costs a
/// protocol and no duplicated code.
///
/// The same contract as `S3Transport` in the one place that matters: **a refusal by the server is a
/// returned value, not a throw.** A method throws only when nothing answered at all.
public protocol S3AccountTransport: Sendable {
    /// One page of `ListAllMyBuckets`.
    func listBuckets(continuationToken: String?) throws -> S3Response
    /// Create a bucket in this account's region.
    func createBucket(name: String) throws -> S3Response
    /// Delete an **empty** bucket. S3 refuses a bucket with anything in it.
    func deleteBucket(name: String) throws -> S3Response
    /// Whether the bucket exists, and which region it answers for
    /// (``S3Response/bucketRegion``, when the server names one).
    func headBucket(name: String) throws -> S3Response
}

/// A `VFSBackend` that browses one S3 **account** as a single flat directory of buckets
/// (PLAN.md §M21) — so creating and deleting a bucket are F7 and F8 on an ordinary pane rather
/// than a dialog of their own.
///
/// **It is a second root, never the only one, and that is what answers the objection this project
/// recorded against account-rooted browsing.** `S3Location`'s doc comment declines to root a
/// connection at an account because a key scoped to one bucket — the ordinary way these are issued
/// — cannot call `ListAllMyBuckets` at all, so an account-rooted design fails for exactly the users
/// whose credentials are set up properly. That argument rules the account out as *the* root and
/// says nothing about it as an *option*: a key that cannot ask loses nothing it never had, and the
/// bucket-rooted connection it already uses is untouched. The same reasoning made the connect
/// sheet's bucket picker safe (Slice 7); this is that assist grown a pane.
///
/// **Depth 0 only, on purpose.** A bucket row is entered by *connecting to it* — the caller builds
/// an ``S3Location`` with ``S3Account/bucketLocation(named:region:)`` and navigates onto the
/// `S3Backend` that already ships — so everything below a bucket is the code five slices verified
/// against real endpoints, not a second listing path grown here. What that costs is one rule the
/// caller has to keep: this backend answers for its root and its own rows and nothing deeper.
///
/// Three things a bucket is not, each of which decided a verb:
///
/// - **A bucket cannot be renamed.** S3 has no such operation at any level, so `moveItem` is left
///   to the protocol default and refuses by name rather than being faked as a copy — which for a
///   bucket would mean re-uploading every object in it.
/// - **A bucket cannot be deleted while it holds anything**, and the refusal is handed over as
///   ``VFSUnsupportedReason/bucketNotEmpty(name:)`` rather than swept. S3 has no `rm -r`; a
///   "delete anyway" would bill an unbounded enumeration behind one keystroke.
/// - **Creating one that already exists does not fail.** Measured 2026-08-13 against a real
///   S3-compatible endpoint: a second `CreateBucket` on a name it already holds answers **200**,
///   silently, changing nothing. So the check has to be ours (``createDirectory(at:)``) — without
///   it, F7 on a taken name reports success and does nothing, which is the quiet direction. What
///   that check may *rest* on is its own finding, and `HeadBucket` alone is not it.
public struct S3AccountBackend: ConnectionScopedBackend {
    /// The account this backend lists — its identity.
    public let account: S3Account
    let transport: any S3AccountTransport
    let pageLimit: Int

    /// - Parameter pageLimit: how many `ListAllMyBuckets` pages one listing may fetch. Small where
    ///   the object listing's is 1000, for the reason ``S3BucketEnumeration`` gives: this response
    ///   is not paginated at all unless `max-buckets` is sent, and it deliberately is not.
    public init(account: S3Account, transport: any S3AccountTransport, pageLimit: Int = 20) {
        self.account = account
        self.transport = transport
        self.pageLimit = pageLimit
    }

    public var id: VFSBackendID { .s3Account(account) }
    public var connectionDescriptor: String { account.connectionDescriptor }

    /// Read and write — the same Trash-less, clone-less, watch-less shape a bucket has.
    ///
    /// `.rename` is absent and that absence is load-bearing rather than an oversight: S3 cannot
    /// rename a bucket, so advertising it would light up F2 on a row that can only refuse.
    public var capabilities: VFSCapabilities { [.read, .write] }

    // MARK: - Listing

    /// List the account's buckets.
    ///
    /// Only the root has anything to list. A deeper path is not a directory this backend knows
    /// about — it is a bucket, which is reached by connecting to it — so it answers `notFound`
    /// rather than inventing an empty listing that would read as an empty bucket.
    public func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        try requireOwnBackend(path)
        guard path.isRoot else { throw VFSError.notFound(path) }

        let buckets = try mapping(path) {
            try S3BucketEnumeration.allBuckets(pageLimit: pageLimit) { token in
                let response = try transport.listBuckets(continuationToken: token)
                guard response.isSuccess else {
                    throw S3ResponseError.service(
                        S3ServiceError.parse(
                            response.body,
                            status: response.status,
                            bucketRegion: response.bucketRegion
                        )
                    )
                }
                return try S3BucketListParser.parse(response.body)
            }
        }
        return buckets.map { entry(for: $0, under: path) }
    }

    /// Stat the account root, or one bucket in it.
    ///
    /// The root is answered directly — it is a directory by construction, and asking the service
    /// would make an account with no buckets unnavigable, the same reasoning
    /// ``S3Backend/stat(at:)`` applies to a bucket root.
    public func stat(at path: VFSPath) throws -> FileEntry {
        try requireOwnBackend(path)
        guard !path.isRoot else { return rootEntry(at: path) }

        let name = path.lastComponent
        let response = try mapping(path) { try transport.headBucket(name: name) }
        guard response.isSuccess else {
            throw S3Backend.serviceError(from: response)?.vfsError(for: path)
                ?? VFSError.notFound(path)
        }
        return bucketEntry(named: name, at: path)
    }

    /// Which region a bucket answers for, or `nil` when the service did not say.
    ///
    /// The one piece of account knowledge that is not a `VFSBackend` verb, and it is here because
    /// it is what makes *entering* a bucket correct: a bucket list spans regions while a connection
    /// is signed for one, so the row the user pressed Enter on may not live where the account does.
    ///
    /// `nil` is an ordinary answer and not a failure — measured 2026-08-13, a real S3-compatible
    /// endpoint sends `x-amz-bucket-region` on no response at all. The caller then keeps the
    /// account's own region, which is right for exactly that kind of server (it does not validate
    /// regions), and the existing 301 correction covers the rest.
    public func region(ofBucketNamed name: String) throws -> String? {
        let path = VFSPath(backend: id, path: "/\(name)")
        let response = try mapping(path) { try transport.headBucket(name: name) }
        guard response.isSuccess else {
            throw S3Backend.serviceError(from: response)?.vfsError(for: path)
                ?? VFSError.notFound(path)
        }
        return response.bucketRegion
    }

    // MARK: - Writing

    /// Create a bucket.
    ///
    /// Two guards, and neither is defensive generality — each replaces a server answer that is
    /// useless or actively misleading (both measured 2026-08-13 against a real endpoint):
    ///
    /// - **The name is validated locally**, because every broken rule comes back as one
    ///   indistinguishable `400 InvalidBucketName`. ``S3BucketName`` says which rule; the server
    ///   never will.
    /// - **Existence is checked first**, because creating a bucket that already exists answers
    ///   **200** and changes nothing. Relying on the service means F7 on a taken name reports
    ///   success — and on AWS, which *does* refuse, the same code path still works, so the check is
    ///   the only behaviour that is correct on both.
    ///
    /// **What the existence check may rest on is a third measurement, and it cost a user a bug
    /// report before it was taken.** The check was one `HeadBucket`, which is stale: it goes on
    /// answering **200 for a bucket this account has deleted**, intermittently and for longer than
    /// a session — measured 2026-08-20 on real AWS, polling straight after a `DELETE` returned 204,
    /// `404 404 200 200 200 200 200 200 404 200 404 404`, against `ListAllMyBuckets` reading the
    /// same name as absent 12 times out of 12 and a *settled* bucket's head answering 200 all 30
    /// times. So F7 refused a name that was not there, sometimes, while the pane's own listing
    /// quite correctly did not show it — a refusal contradicting the thing the user is looking at,
    /// which is the shape that reads as the app being confused rather than the service.
    ///
    /// So a refusal now needs both: the cheap head to raise the question, and the **listing** — the
    /// half that does not go stale, and the one the pane is drawing — to answer it. A free name
    /// still costs one `HeadBucket` and nothing more; only a name about to be refused pays for the
    /// listing. The opposite flap (a 404 for a bucket that is there) needs nothing: the create goes
    /// out and AWS refuses it with the 409 this code already maps.
    ///
    /// The race between the check and the create is real and accepted, exactly as
    /// ``S3Backend/createFile(at:)`` accepts it: S3 offers no create-if-absent, and the choice is
    /// between this window and silently reporting success over somebody else's bucket.
    public func createDirectory(at path: VFSPath) throws {
        try requireOwnBackend(path)
        guard !path.isRoot else { throw VFSError.alreadyExists(path) }
        let name = path.lastComponent
        guard S3BucketName.isValid(name) else {
            throw VFSError.unsupported(.bucketNameNotValid(name: name))
        }
        if (try? stat(at: path)) != nil, listingHolds(name, under: path) ?? true {
            throw VFSError.alreadyExists(path)
        }

        let response = try mapping(path) { try transport.createBucket(name: name) }
        guard response.isSuccess else {
            throw S3Backend.serviceError(from: response)?.vfsError(for: path)
                ?? VFSError.io(path: path, code: EIO)
        }
    }

    /// Whether the account's **listing** shows `name` — `nil` when it could not be asked.
    ///
    /// `ListAllMyBuckets` is the half of S3 that does not go stale about a bucket's existence, and
    /// it is what the pane is drawing, so a refusal resting on it can never contradict what the
    /// user is looking at. Measured against the flapping head in the same run: absent 12 times out
    /// of 12 for a name that had just been deleted.
    ///
    /// `nil` rather than `false` when the listing throws, because the two mean opposite things to
    /// the caller: "the name is free" would send a create at a service that may answer 200 and do
    /// nothing, while "cannot tell" keeps the old, cautious behaviour.
    private func listingHolds(_ name: String, under path: VFSPath) -> Bool? {
        guard let root = path.parent, let entries = try? listDirectory(at: root) else { return nil }
        return entries.contains { $0.name == name }
    }

    /// Delete an empty bucket.
    ///
    /// The one refusal worth its own sentence is `409 BucketNotEmpty`, and it is worth it because
    /// the generic mapping is *wrong*: `S3ServiceError.vfsError(for:)` turns any 409 into
    /// `alreadyExists`, which reads as "this already exists" in answer to a delete. It is also the
    /// refusal the user meets most often, since emptying a bucket is a separate job.
    public func removeItem(at path: VFSPath) throws {
        try requireOwnBackend(path)
        // There is no path above the account to delete — the same guard `sftp` needs at its
        // connection root, and here it would otherwise send `DELETE /` to the service itself.
        guard !path.isRoot else { throw VFSError.unsupported(.deleteConnectionRoot) }

        let name = path.lastComponent
        let response = try mapping(path) { try transport.deleteBucket(name: name) }
        guard response.isSuccess else {
            let service = S3Backend.serviceError(from: response)
            if service?.code == "BucketNotEmpty" {
                throw VFSError.unsupported(.bucketNotEmpty(name: name))
            }
            throw service?.vfsError(for: path) ?? VFSError.io(path: path, code: EIO)
        }
    }

    // MARK: - Entries

    private func entry(for bucket: S3Bucket, under path: VFSPath) -> FileEntry {
        bucketEntry(
            named: bucket.name,
            at: VFSPath(backend: path.backend, path: "/\(bucket.name)"),
            created: bucket.creationDate
        )
    }

    /// One bucket as a row.
    ///
    /// A **directory**, because that is what it behaves like everywhere it matters: Enter walks
    /// into it, F8 deletes it, and it has no size of its own. `byteSize` is 0 and the dates fall
    /// back to ``FileEntry/unknownDate`` — which the Date column draws as the same dash an
    /// unmeasured folder's size gets, rather than as the `01.01.1` a sentinel rendered before
    /// Slice 3 named it. A creation date is used when the service sent one, which AWS and this
    /// project's probed third-party endpoint both do.
    private func bucketEntry(
        named name: String,
        at path: VFSPath,
        created: Date? = nil
    ) -> FileEntry {
        FileEntry(
            path: path,
            name: name,
            kind: .directory,
            byteSize: 0,
            modificationDate: created ?? FileEntry.unknownDate,
            creationDate: created ?? FileEntry.unknownDate,
            isHidden: false,
            permissions: 0o755,
            inode: 0
        )
    }

    private func rootEntry(at path: VFSPath) -> FileEntry {
        FileEntry(
            path: path,
            name: account.host,
            kind: .directory,
            byteSize: 0,
            modificationDate: FileEntry.unknownDate,
            creationDate: FileEntry.unknownDate,
            isHidden: false,
            permissions: 0o755,
            inode: 0
        )
    }

    /// Normalize a transport failure onto the shared `VFSError` vocabulary — the same shape
    /// ``S3Backend/mapping(_:_:)`` has, and it exists twice because the two backends share no
    /// transport.
    private func mapping<T>(_ path: VFSPath, _ body: () throws -> T) throws -> T {
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
