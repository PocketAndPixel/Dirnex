import Foundation

/// What each reason says. Split from `VFSUnsupportedReason.swift` when that file reached SwiftLint's
/// 500-line ceiling (PLAN.md §M32 Slice 4), along the seam it already had: there, the vocabulary and
/// its keys; here, the English every key stands for.
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
        case let .remoteAttributeRestoreRefused(name):
            return ("The server wouldn’t put “%@” back the way it was.", [name])
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
        case let .lockedOnServer(name):
            return (
                """
                “%@” is locked on the server, usually because someone has it open. \
                Try again once they have closed it.
                """,
                [name]
            )
        case let .fileHeldByAnotherApp(name):
            return (
                """
                “%@” is open in another app that didn’t let Dirnex write to it. \
                Save or close it there, then try again.
                """,
                [name]
            )
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
        case let .s3ActionNotPermitted(action):
            return (
                "The server refused that. This account doesn’t have the %@ permission.",
                [action.iamName]
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
        case let .selfExtractingArchiveReadOnly(archive):
            return (
                "“%@” is a self-extracting Windows program, so it can be opened but not changed.",
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
            .remoteAttributeRestoreRefused(name: ""),
            .objectTooLargeForStore(name: ""),
            .bucketNotEmpty(name: ""),
            .bucketNameNotValid(name: ""),
            .remoteFileChangedSinceFetch(name: ""),
            .remoteFileGoneSinceFetch(name: ""),
            .lockedOnServer(name: ""),
            .fileHeldByAnotherApp(name: ""),
            .objectNotRestored(name: ""),
            .bucketOperationInProgress(name: ""),
            .bucketNameTakenGlobally(name: ""),
            .s3ActionNotPermitted(action: .createBucket),
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
            .archiveChangedSinceRewrite(archive: ""),
            .selfExtractingArchiveReadOnly(archive: "")
        ]
    }
}
