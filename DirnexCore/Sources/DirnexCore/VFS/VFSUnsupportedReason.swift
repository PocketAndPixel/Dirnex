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
    /// state with a plain reason, not a failure to report as one.
    case archiveUndoCopyUnavailable(archive: String)
    /// ⌘Z on an archive rewrite whose archive is no longer the file the rewrite produced: something
    /// else has updated it since, and putting the old container back would discard that.
    case archiveChangedSinceRewrite(archive: String)

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
        case .objectTooLargeForStore: return "objectTooLargeForStore"
        case .bucketNotEmpty: return "bucketNotEmpty"
        case .bucketNameNotValid: return "bucketNameNotValid"
        case .remoteFileChangedSinceFetch: return "remoteFileChangedSinceFetch"
        case .remoteFileGoneSinceFetch: return "remoteFileGoneSinceFetch"
        case .objectNotRestored: return "objectNotRestored"
        case .bucketOperationInProgress: return "bucketOperationInProgress"
        case .bucketNameTakenGlobally: return "bucketNameTakenGlobally"
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
        }
    }
}

public extension VFSUnsupportedReason {
    /// The English sentence — the fallback the app shows when a translation is missing, and the
    /// only presentation a resource-free `swift test` ever sees.
    var sentence: String {
        let template = template
        guard !template.arguments.isEmpty else { return template.format }
        return String(format: template.format, arguments: template.arguments)
    }

    /// The English format, with `%@` placeholders in ``arguments`` order. What the catalog's English
    /// value must match, so a translator sees the same sentence the fallback renders.
    var englishFormat: String { template.format }

    /// The values to splice into ``englishFormat`` — or into its translation, which may reorder them
    /// with positional specifiers (`%1$@`).
    var arguments: [String] { template.arguments }

    /// Format and arguments together, so the two can never drift apart. The tool names (`bsdtar`)
    /// stay in the English as the same technical vocabulary `SFTP`/`SMB` are.
    private var template: (format: String, arguments: [String]) {
        switch self {
        case .createDirectory:
            return ("This location doesn’t support creating folders.", [])
        case .createFile:
            return ("This location doesn’t support creating files.", [])
        case .moveItem:
            return ("This location doesn’t support moving items.", [])
        case .removeItem:
            return ("This location doesn’t support deleting items.", [])
        case .trash:
            return ("This location doesn’t have a Trash.", [])
        case .copyFile:
            return ("This location doesn’t support copying files.", [])
        case .symbolicLink:
            return ("This location doesn’t support symbolic links.", [])
        case .deleteConnectionRoot:
            return ("Can’t delete the connection root.", [])
        case .remoteToRemoteCopy:
            return ("Copying directly between remote locations isn’t supported.", [])
        case let .symbolicLinkTargetUnreadable(name):
            return ("Can’t copy the link “%@” — this server can’t say what it points at.", [name])
        case let .pathOutsideConnection(path, connection):
            return ("Path %@ does not belong to %@.", [path, connection])
        case let .pathOutsideArchive(path, archive):
            return ("Path %@ does not belong to archive %@.", [path, archive])
        case let .alreadyInTrash(name):
            return ("“%@” is already in the Trash.", [name])
        case .contentComparisonNeedsLocalFiles:
            return ("Content comparison is only available for local files.", [])
        case .contentComparisonNeedsRegularFile:
            return ("Only regular files can be compared by content.", [])
        case let .contentComparisonWouldDownload(name):
            return (
                "“%@” isn’t downloaded yet. Comparing it by content would download it first.",
                [name]
            )
        case .tagsNeedLocalFile:
            return ("Only local files carry Finder tags.", [])
        case .cloudStatusNeedsLocalFile:
            return ("Only local files can be cloud-provider items.", [])
        case let .attributeRestoreNeedsAdministrator(name):
            return (
                "Only an administrator can put back the previous owner, group or system flags of %@.",
                [name]
            )
        case let .attributeChangeNeedsAdministrator(name):
            return ("Only an administrator can change “%@”.", [name])
        case let .attributesNeedLocalItem(name):
            return ("“%@” isn’t on this Mac, so it has no permissions to change.", [name])
        case let .attributeChangeNeedsConnection(name):
            return ("“%@” can’t be changed from here. Its server doesn’t offer that.", [name])
        case let .objectTooLargeForStore(name):
            return ("“%@” is too large for this storage service to hold.", [name])
        case let .bucketNotEmpty(name):
            return ("“%@” still has files in it. Empty it first, then delete it.", [name])
        case let .bucketNameNotValid(name):
            return (
                """
                “%@” isn’t a valid bucket name. Use 3–63 characters: lowercase letters, \
                digits, dots and hyphens, starting and ending with a letter or digit.
                """,
                [name]
            )
        case let .remoteFileChangedSinceFetch(name):
            return (
                """
                “%@” has been changed on the server since you opened it. \
                Saving now would overwrite that newer version.
                """,
                [name]
            )
        case let .remoteFileGoneSinceFetch(name):
            return ("“%@” is no longer on the server. It was deleted after you opened it.", [name])
        case let .objectNotRestored(name):
            return (
                """
                “%@” is archived on the service and has to be restored there \
                before it can be read.
                """,
                [name]
            )
        case let .bucketOperationInProgress(name):
            return ("Another operation on “%@” is still finishing. Try again in a moment.", [name])
        case let .bucketNameTakenGlobally(name):
            return (
                """
                The name “%@” is already taken. Bucket names are shared across the whole \
                of S3, so it may belong to somebody else’s account.
                """,
                [name]
            )
        case let .noBackendForPath(path):
            return ("No backend can handle %@.", [path])
        case let .serverNotConnected(server):
            return ("Not connected to %@. Reconnect to the server.", [server])
        case .archiveToolUnavailableForRead:
            return ("Couldn’t run bsdtar to open the archive.", [])
        case .archiveToolUnavailableForCreate:
            return ("Couldn’t run bsdtar to create the archive.", [])
        case .archiveToolUnavailableForExtract:
            return ("Couldn’t run bsdtar to extract from the archive.", [])
        case let .archiveUnreadable(archive):
            return ("Couldn’t read the archive “%@”.", [archive])
        case let .archiveCreateFailed(archive):
            return ("Couldn’t create the archive “%@”.", [archive])
        case let .archiveExtractFailed(archive):
            return ("Couldn’t extract from the archive “%@”.", [archive])
        case let .archiveAddFailed(item, archive):
            return ("Couldn’t add “%@” to the archive “%@”.", [item, archive])
        case let .archiveRewriteFailed(archive):
            return ("Couldn’t rewrite the archive “%@”.", [archive])
        case let .archiveUpdateFailed(archive):
            return ("Couldn’t update the archive “%@”.", [archive])
        case let .archiveUndoCopyUnavailable(archive):
            return ("Dirnex no longer keeps the copy of “%@” that Undo needs.", [archive])
        case let .archiveChangedSinceRewrite(archive):
            return (
                "“%@” has changed since then — undoing would discard the newer version.",
                [archive]
            )
        }
    }

    /// Every reason, with placeholder arguments where a case takes them — the coverage test's input.
    /// `CaseIterable` cannot be synthesized for an enum with associated values, and the ``key`` does
    /// not depend on them, so a representative value per case is exactly enough.
    static var allCases: [VFSUnsupportedReason] {
        [
            .createDirectory,
            .createFile,
            .moveItem,
            .removeItem,
            .trash,
            .copyFile,
            .symbolicLink,
            .deleteConnectionRoot,
            .remoteToRemoteCopy,
            .symbolicLinkTargetUnreadable(name: ""),
            .pathOutsideConnection(path: "", connection: ""),
            .pathOutsideArchive(path: "", archive: ""),
            .alreadyInTrash(name: ""),
            .contentComparisonNeedsLocalFiles,
            .contentComparisonNeedsRegularFile,
            .contentComparisonWouldDownload(name: ""),
            .tagsNeedLocalFile,
            .cloudStatusNeedsLocalFile,
            .attributeRestoreNeedsAdministrator(name: ""),
            .attributeChangeNeedsAdministrator(name: ""),
            .attributesNeedLocalItem(name: ""),
            .attributeChangeNeedsConnection(name: ""),
            .objectTooLargeForStore(name: ""),
            .bucketNotEmpty(name: ""),
            .bucketNameNotValid(name: ""),
            .remoteFileChangedSinceFetch(name: ""),
            .remoteFileGoneSinceFetch(name: ""),
            .objectNotRestored(name: ""),
            .bucketOperationInProgress(name: ""),
            .bucketNameTakenGlobally(name: ""),
            .noBackendForPath(path: ""),
            .serverNotConnected(server: ""),
            .archiveToolUnavailableForRead,
            .archiveToolUnavailableForCreate,
            .archiveToolUnavailableForExtract,
            .archiveUnreadable(archive: ""),
            .archiveCreateFailed(archive: ""),
            .archiveExtractFailed(archive: ""),
            .archiveAddFailed(item: "", archive: ""),
            .archiveRewriteFailed(archive: ""),
            .archiveUpdateFailed(archive: ""),
            .archiveUndoCopyUnavailable(archive: ""),
            .archiveChangedSinceRewrite(archive: "")
        ]
    }
}
