import Foundation

/// Why an operation is unsupported — the payload of ``VFSError/unsupported(_:)``, and the one
/// `VFSError` case whose text a user actually reads.
///
/// It is an enum rather than a `String` for the reason `UndoActionLabel` is: the sentence reaches
/// the screen through a *return value* (`VFSErrorText.sentence(for:)`), not through an assignment,
/// so a bare literal here is invisible to every extraction sweep and to Xcode's extractor alike —
/// it renders English under a translated title, exactly when something has gone wrong. Naming the
/// vocabulary makes a missing translation a test failure and a mistyped one a compile error.
///
/// The core ships no resources, so — like `SidebarSection`, `SearchKind` and `UndoActionLabel` —
/// the English ``sentence`` is *data* and the fallback, keyed for translation by the stable
/// ``key`` (see `LocalizationKey.vfsUnsupported(_:)`). The app joins the two through
/// `LocalizedCatalog.sentence(for:)`.
///
/// Two origins meet here, as they do in `UndoActionLabel`. Most reasons are authored in the core by
/// the backends themselves; the archive and routing reasons (``archiveUnreadable(archive:)``…)
/// belong to app-side code, because non-hermetic subprocess I/O lives in the app (PLAN.md §2). The
/// vocabulary is finite either way, and naming all of it in one place is what lets a single
/// coverage test prove every sentence is translated.
///
/// The ``key`` is the stable translation key and never changes: renaming a case orphans its
/// translations in every language, which `LocalizationCoverageTests` catches.
public enum VFSUnsupportedReason: Sendable, Equatable {
    // MARK: Capability defaults — a backend that does not implement a write primitive

    case createDirectory
    case createFile
    case moveItem
    case removeItem
    case trash
    case copyFile
    case symbolicLink

    // MARK: Backend-specific refusals

    /// `sftp` has no path above the connection root to delete.
    case deleteConnectionRoot
    /// This backend's transfer is a *direction* — an upload or a download — so a pair of ends that
    /// does not include the local disk has no verb here at all. Neither `sftp` nor `curl`'s FTP
    /// side has a copy, so this covers a second account *and* a duplicate within this one.
    ///
    /// A caller holding **both** connections has an answer the backend does not (``RelayCopy``:
    /// download, upload, delete the staged copy), which is what the app's composite backend does
    /// with such a pair. So this refusal is what a backend driven on its own reports, and it is no
    /// longer what the user meets on F5 — kept, rather than deleted, because the backend's own
    /// contract is unchanged and answering `.copyFile`'s vaguer sentence instead would say less.
    case remoteToRemoteCopy
    /// A symbolic link could not be copied because this connection cannot say what it points at.
    ///
    /// `sftp` has no verb that reads a link's target — its `ls -la` prints no ` -> target`, and
    /// `ls -la` of the link *follows* it — so the target comes from the SSH **exec** channel, which
    /// an account confined to the `sftp` subsystem does not have (PLAN.md §M25 Slice 4). Where it
    /// cannot be read the copy is refused rather than approximated, because `CopyEngine` recreates a
    /// link from that text and `symlink(2)` **accepts an empty target** on macOS — measured: it
    /// returns 0 and leaves a 0-byte dangling link. So the alternative to this sentence is a copy
    /// that reports success and silently produces a broken link.
    ///
    /// It is per item and never per operation: the rest of a tree copies normally, and the report
    /// names the links that did not.
    case symbolicLinkTargetUnreadable(name: String)
    /// A path handed to the wrong backend. `connection` is the location's descriptor.
    case pathOutsideConnection(path: String, connection: String)
    /// A path handed to an archive backend that does not own it.
    case pathOutsideArchive(path: String, archive: String)
    /// `FileManager.trashItem` on an item already in a trash reports success and does nothing
    /// (docs/NOTES.md), so `LocalBackend` refuses the call outright rather than lying.
    case alreadyInTrash(name: String)
    case contentComparisonNeedsLocalFiles
    case contentComparisonNeedsRegularFile
    /// The file's bytes are not on this disk (`SF_DATALESS`): reading one to compare it would make
    /// the cloud provider materialize the whole file and block until it lands (docs/NOTES.md,
    /// measured 1.1 s for 200 KB). Named rather than silently downloaded, so a caller acting on a
    /// file the user pointed at can ask, and a caller sweeping a tree can stop.
    case contentComparisonWouldDownload(name: String)
    case tagsNeedLocalFile
    case cloudStatusNeedsLocalFile
    /// Undoing an attribute change would need root, so the item cannot be put back.
    ///
    /// The case that makes this reachable is not obvious and was found only by undoing a real edit:
    /// the group picker offers the groups the user belongs to **plus whatever group the item is in
    /// now**, so moving a file *out of* a foreign group (a `wheel` file into `staff`) is a perfectly
    /// legal one-way door — `chgrp` back to `wheel` is `EPERM`. The same holds for a `chown` or an
    /// `SF_*` flag an administrator applied. Named rather than left as a bare `EPERM`, which the app
    /// renders as "Dirnex may need Full Disk Access" — true of the errno, wrong about the cause, and
    /// pointing the user at a System Settings pane that cannot help.
    case attributeRestoreNeedsAdministrator(name: String)
    /// One item inside a recursive apply belongs to someone else, or its change needs root.
    ///
    /// A recursion crosses items the user never saw and may not own, so this is a *per-item* refusal
    /// the run collects and carries past — unlike the flat sheet, which pre-flights the whole
    /// selection and refuses before touching anything. Stopping a tree walk at the first foreign
    /// file would leave it half-changed with nothing to say where it got to.
    case attributeChangeNeedsAdministrator(name: String)
    /// A recursive apply was pointed at something that is not on this disk. Mode bits, a BSD flags
    /// word and an ACL are things a real inode has; an archive member and a server listing have none.
    case attributesNeedLocalItem(name: String)
    /// Get Info was asked to change an item that is not on this Mac, through a backend with no verb
    /// for it (PLAN.md §M25 Slice 5).
    ///
    /// Distinct from ``attributesNeedLocalItem(name:)``, which is about a *recursive* apply over a
    /// tree: this one is a single remote row whose backend — an archive, an object store, a
    /// connection that has refused the verb — cannot write what was asked. The panel does not offer
    /// the control in that state, so reaching here means something changed between the panel opening
    /// and Save; naming the item is what makes that legible instead of a bare failure.
    case attributeChangeNeedsConnection(name: String)
    /// ⌘Z sent a remote item's previous mode or modification time back and the server did not store
    /// it (PLAN.md §4 ▸ *Still open*, taken 2026-09-01).
    ///
    /// An undo here is a *second write*, not a rewind: it asks the server to take the old values,
    /// and a server free to refuse the first change is free to refuse this one — a `chmod` whose
    /// set-group-ID bit the account cannot set, an `MFMT` the connection has since withdrawn. It is
    /// read back and weighed exactly as the forward save is (``RemoteAttributeVerdict``), so this
    /// names the case where the reversal was attempted and the item still does not carry what it
    /// carried before. Saying so is the whole point: an undo that reported success on a clean exit
    /// code would claim a reversal it did not have.
    case remoteAttributeRestoreRefused(name: String)
    /// The file is larger than the object store can hold at all — S3's ceiling is 5 TiB, which no
    /// number of parts moves.
    ///
    /// Named rather than left to the server, because the server's refusal arrives *after* the whole
    /// file has been offered: this is a limit worth stating up front, in a sentence that says which
    /// file and that the store is the constraint, instead of an `EntityTooLarge` at the end of a
    /// long upload.
    case objectTooLargeForStore(name: String)
    /// A bucket cannot be deleted while anything is still in it — S3 answers `409 BucketNotEmpty`
    /// (measured against a real endpoint 2026-08-13).
    ///
    /// Named rather than mapped, because the generic mapping is actively wrong here: a 409 becomes
    /// `alreadyExists`, which for a *delete* reads as "this already exists" — a sentence about the
    /// opposite operation. And this is the refusal the user meets most, since emptying a bucket is
    /// a separate job they have to go and do.
    ///
    /// It is deliberately a refusal and never a prompt to sweep the contents: S3 has no `rm -r`, so
    /// "delete anyway" would mean enumerating and billing an unbounded number of keys behind one
    /// keystroke. The service's own rule is the guard rail, and this sentence hands it over.
    case bucketNotEmpty(name: String)
    /// A bucket name that breaks S3's naming rules, refused before the request goes out.
    ///
    /// The refusal is local because **the server's is useless**: measured 2026-08-13, an uppercase
    /// letter, a two-character name, an underscore, an IP-shaped name and a 64-character name all
    /// came back as one `400 InvalidBucketName` — "The specified bucket is not valid" — with
    /// nothing to say which rule broke. This sentence at least names the shape of a legal name;
    /// ``S3BucketNameProblem`` carries the specific rule for a form that can show it inline.
    case bucketNameNotValid(name: String)
    /// A conditional save was refused because the object no longer carries the entity tag it had
    /// when its bytes were fetched — somebody else has written it in between
    /// (``S3WriteCondition/ifMatches(entityTag:)``).
    ///
    /// Named rather than mapped, because the generic mapping is `.io(code: EIO)` — "The system
    /// reported an error (code 5)" — which is the raw-errno shape this milestone already had to
    /// name once, for `EXDEV` on a folder rename. It is also the one refusal here that is not a
    /// fault: nothing is broken, two people edited one file, and the sentence has to say that
    /// rather than describe a malfunction.
    case remoteFileChangedSinceFetch(name: String)
    /// A conditional save was refused because the object is not there any more — the `If-Match`
    /// had nothing to compare against.
    ///
    /// Separate from ``remoteFileChangedSinceFetch(name:)`` because the user's options differ:
    /// there is no newer version to look at and nothing to merge with, so the honest offer is to
    /// upload it as a new object rather than to compare.
    case remoteFileGoneSinceFetch(name: String)
    /// A WebDAV write was refused because somebody else holds a lock on the item — the server's
    /// **423 Locked**, or a **424 Failed Dependency** whose body names the locked member of a folder
    /// being deleted or moved (measured on the NAS 2026-10-22, PLAN.md §M32). `name` is the locked
    /// item's own, which for a folder is the member, not the folder.
    ///
    /// Named because the mapping it replaces said nothing true: `EBUSY` reads as a system error with
    /// a number. Nothing is broken and nothing is wrong with the account; another program has the
    /// file open (Finder and Office both lock around an edit), and the answer is to wait. Only a
    /// write can meet it: reading, listing and copying *from* a locked file all pass (Slice 1).
    case lockedOnServer(name: String)
    /// A save into a local file was not made because an app with the file open did not let go of it
    /// (`CoordinatedFileWrite`, PLAN.md §M33 Slice 5). The file is as it was.
    ///
    /// The local twin of ``lockedOnServer(name:)``: nothing is broken, another program has the file,
    /// and the answer is to save or close it there and try again. Named for the same reason, since
    /// the generic mapping would read as a system error with a number.
    case fileHeldByAnotherApp(name: String)

    /// A read was refused because the object sits in an archival storage class and has not been
    /// restored — S3 answers `403 InvalidObjectState` (measured against real AWS 2026-08-18).
    ///
    /// Named rather than mapped, because the generic mapping is the worst answer available: a 403
    /// becomes `permissionDenied`, whose sentence recommends **Full Disk Access** — a macOS grant,
    /// for an object on somebody else's servers, when nothing is wrong with the credentials and the
    /// real remedy is a restore request on the service. It is also invisible until the bytes are
    /// wanted: `HEAD` answers 200 and the listing draws an ordinary row with a real size and date,
    /// so the file looks perfectly normal right up until F5 or a preview.
    case objectNotRestored(name: String)
    /// A bucket write was refused because another conditional operation on that name is still
    /// settling — S3 answers `409 OperationAborted` (measured 2026-08-18, creating a bucket moments
    /// after deleting one of the same name).
    ///
    /// Named for the same reason ``bucketNotEmpty(name:)`` is: the shared 409 mapping is
    /// `alreadyExists`, which sends the user off to choose a different name when the service has
    /// said the opposite — the name is fine, and the answer is to try it again shortly.
    case bucketOperationInProgress(name: String)
    /// A bucket could not be created because **another account already holds that name** — S3
    /// answers `409 BucketAlreadyExists` (measured against real AWS 2026-08-19: *"The requested
    /// bucket name is not available. The bucket namespace is shared by all users of the system."*).
    ///
    /// The third refusal on this verb that the shared 409 mapping gets wrong, and the one whose
    /// wrongness is hardest to see: `alreadyExists` renders as "an item with that name already
    /// exists **here**", in a pane listing the account's own buckets, where the name is not present
    /// and never will be. So the user looks, does not find it, and tries again. What the sentence
    /// has to carry is the fact the pane cannot show — a bucket name is global to all of S3, not
    /// scoped to this account.
    ///
    /// Unreachable with a key scoped to its own buckets, which is how these are ordinarily issued:
    /// IAM is evaluated before the name registry, so such a key gets `403 AccessDenied` for a name
    /// somebody else owns and never learns that it was taken (measured the same day, on three
    /// well-known names).
    case bucketNameTakenGlobally(name: String)

    /// A request was refused because the account's policy does not allow the action it needed —
    /// S3 answers `403 AccessDenied` (measured against real AWS 2026-09-02, `s3:CreateBucket` on a
    /// key scoped to one bucket).
    ///
    /// Named because the generic mapping is not wrong here so much as **useless at the only moment
    /// it is read**: 403 becomes `permissionDenied`, whose remote sentence says the account "may
    /// not have permission for it" and stops exactly where the answer starts. The account holder
    /// can do nothing with that; they can paste ``S3Action/iamName`` straight into a policy.
    ///
    /// Deliberately keyed on `AccessDenied` alone, never on the 403 itself. The same status carries
    /// `InvalidAccessKeyId` and `SignatureDoesNotMatch`, which are a key the user *retypes* — and
    /// telling them a permission is missing would send them to edit a policy that is fine.
    case s3ActionNotPermitted(action: S3Action)

    // MARK: Routing and archives — authored in the app, named here

    case noBackendForPath(path: String)
    /// A server tab whose connection has gone away; `server` is the backend's descriptor.
    case serverNotConnected(server: String)
    case archiveToolUnavailableForRead
    case archiveToolUnavailableForCreate
    case archiveToolUnavailableForExtract
    case archiveUnreadable(archive: String)
    case archiveCreateFailed(archive: String)
    case archiveExtractFailed(archive: String)
    case archiveAddFailed(item: String, archive: String)
    case archiveRewriteFailed(archive: String)
    case archiveUpdateFailed(archive: String)
    /// ⌘Z on an archive rewrite whose snapshot is no longer in the store. It is evictable by
    /// construction (``ArchiveUndoBudget``), so a record can outlive the bytes it needs — a real
    /// state with a plain reason, not a failure to report as one. A text file saved from the
    /// compare window says the same (PLAN.md §M33 Slice 3): the sentence names no archive.
    case archiveUndoCopyUnavailable(archive: String)
    /// ⌘Z on an archive rewrite whose archive is no longer the file the rewrite produced: something
    /// else has updated it since, and putting the old container back would discard that. Also a
    /// saved text file changed since its save.
    case archiveChangedSinceRewrite(archive: String)
    /// A write into a Windows self-extractor, whose repack would drop the program (``SelfExtractingArchive``).
    case selfExtractingArchiveReadOnly(archive: String)

    /// The stable translation key token — the case name, spelled once, never derived.
    public var key: String {
        switch self {
        case .createDirectory: return "createDirectory"
        case .createFile: return "createFile"
        case .moveItem: return "moveItem"
        case .removeItem: return "removeItem"
        case .trash: return "trash"
        case .copyFile: return "copyFile"
        case .symbolicLink: return "symbolicLink"
        case .deleteConnectionRoot: return "deleteConnectionRoot"
        case .remoteToRemoteCopy: return "remoteToRemoteCopy"
        case .symbolicLinkTargetUnreadable: return "symbolicLinkTargetUnreadable"
        case .pathOutsideConnection: return "pathOutsideConnection"
        case .pathOutsideArchive: return "pathOutsideArchive"
        case .alreadyInTrash: return "alreadyInTrash"
        case .contentComparisonNeedsLocalFiles: return "contentComparisonNeedsLocalFiles"
        case .contentComparisonNeedsRegularFile: return "contentComparisonNeedsRegularFile"
        case .contentComparisonWouldDownload: return "contentComparisonWouldDownload"
        case .tagsNeedLocalFile: return "tagsNeedLocalFile"
        case .cloudStatusNeedsLocalFile: return "cloudStatusNeedsLocalFile"
        case .attributeRestoreNeedsAdministrator: return "attributeRestoreNeedsAdministrator"
        case .attributeChangeNeedsAdministrator: return "attributeChangeNeedsAdministrator"
        case .attributesNeedLocalItem: return "attributesNeedLocalItem"
        case .attributeChangeNeedsConnection: return "attributeChangeNeedsConnection"
        case .remoteAttributeRestoreRefused: return "remoteAttributeRestoreRefused"
        case .objectTooLargeForStore: return "objectTooLargeForStore"
        case .bucketNotEmpty: return "bucketNotEmpty"
        case .bucketNameNotValid: return "bucketNameNotValid"
        case .remoteFileChangedSinceFetch: return "remoteFileChangedSinceFetch"
        case .remoteFileGoneSinceFetch: return "remoteFileGoneSinceFetch"
        case .lockedOnServer: return "lockedOnServer"
        case .fileHeldByAnotherApp: return "fileHeldByAnotherApp"
        case .objectNotRestored: return "objectNotRestored"
        case .bucketOperationInProgress: return "bucketOperationInProgress"
        case .bucketNameTakenGlobally: return "bucketNameTakenGlobally"
        case .s3ActionNotPermitted: return "s3ActionNotPermitted"
        case .noBackendForPath: return "noBackendForPath"
        case .serverNotConnected: return "serverNotConnected"
        case .archiveToolUnavailableForRead: return "archiveToolUnavailableForRead"
        case .archiveToolUnavailableForCreate: return "archiveToolUnavailableForCreate"
        case .archiveToolUnavailableForExtract: return "archiveToolUnavailableForExtract"
        case .archiveUnreadable: return "archiveUnreadable"
        case .archiveCreateFailed: return "archiveCreateFailed"
        case .archiveExtractFailed: return "archiveExtractFailed"
        case .archiveAddFailed: return "archiveAddFailed"
        case .archiveRewriteFailed: return "archiveRewriteFailed"
        case .archiveUpdateFailed: return "archiveUpdateFailed"
        case .archiveUndoCopyUnavailable: return "archiveUndoCopyUnavailable"
        case .archiveChangedSinceRewrite: return "archiveChangedSinceRewrite"
        case .selfExtractingArchiveReadOnly: return "selfExtractingArchiveReadOnly"
        }
    }
}
