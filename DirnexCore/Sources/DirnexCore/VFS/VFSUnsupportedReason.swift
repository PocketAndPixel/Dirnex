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
    /// Every remote transfer goes through the local side; server-to-server has no `sftp` verb.
    case remoteToRemoteCopy
    /// A path handed to the wrong backend. `connection` is the location's descriptor.
    case pathOutsideConnection(path: String, connection: String)
    /// A path handed to an archive backend that does not own it.
    case pathOutsideArchive(path: String, archive: String)
    /// `FileManager.trashItem` on an item already in a trash reports success and does nothing
    /// (docs/NOTES.md), so `LocalBackend` refuses the call outright rather than lying.
    case alreadyInTrash(name: String)
    case contentComparisonNeedsLocalFiles
    case contentComparisonNeedsRegularFile
    case tagsNeedLocalFile
    case cloudStatusNeedsLocalFile

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
        case .pathOutsideConnection: return "pathOutsideConnection"
        case .pathOutsideArchive: return "pathOutsideArchive"
        case .alreadyInTrash: return "alreadyInTrash"
        case .contentComparisonNeedsLocalFiles: return "contentComparisonNeedsLocalFiles"
        case .contentComparisonNeedsRegularFile: return "contentComparisonNeedsRegularFile"
        case .tagsNeedLocalFile: return "tagsNeedLocalFile"
        case .cloudStatusNeedsLocalFile: return "cloudStatusNeedsLocalFile"
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
        case .tagsNeedLocalFile:
            return ("Only local files carry Finder tags.", [])
        case .cloudStatusNeedsLocalFile:
            return ("Only local files can be cloud-provider items.", [])
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
            .pathOutsideConnection(path: "", connection: ""),
            .pathOutsideArchive(path: "", archive: ""),
            .alreadyInTrash(name: ""),
            .contentComparisonNeedsLocalFiles,
            .contentComparisonNeedsRegularFile,
            .tagsNeedLocalFile,
            .cloudStatusNeedsLocalFile,
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
            .archiveUpdateFailed(archive: "")
        ]
    }
}
