import Foundation

/// One app's public document folder as it appears inside iCloud Drive — Finder's "Pages",
/// "Shortcuts", "Curve" rows (PLAN.md §M9 "the merged app-container view").
///
/// The row is a *real* directory: `~/Library/Mobile Documents/<container>/Documents`. Only
/// its name is synthetic, which is what keeps the merge a listing rather than a filesystem —
/// stepping into it lands in an ordinary local folder that every existing operation already
/// handles, exactly as the merged Trash does with each volume's trash.
public struct ICloudAppLibrary: Sendable, Hashable, Identifiable {
    /// The directory name under `~/Library/Mobile Documents`, e.g. `com~apple~Pages`.
    public let containerID: String
    /// The bundle identifier, which is also the cached icon directory's name.
    public let bundleID: String
    /// What the row is called: "Pages", not "Documents" and not `com~apple~Pages`.
    public let name: String
    /// The real folder the row browses into.
    public let documents: VFSPath
    /// Base names of the cached icons available for this container, for
    /// `ICloudContainers.bestIconName(from:pointSize:scale:)`. Often empty.
    public let iconNames: [String]

    public init(
        containerID: String,
        bundleID: String,
        name: String,
        documents: VFSPath,
        iconNames: [String] = []
    ) {
        self.containerID = containerID
        self.bundleID = bundleID
        self.name = name
        self.documents = documents
        self.iconNames = iconNames
    }

    public var id: VFSPath { documents }
}

/// What one scan of the app containers produced.
///
/// `isRestricted` is the difference between "this Mac has no app libraries" and "I was not
/// allowed to look", and it exists because the two must not render alike: the first is a
/// short iCloud Drive, the second is a short iCloud Drive *plus* an offer to grant Full Disk
/// Access. M9 degrades to the loose-files view without the grant rather than showing an
/// error, so the pane needs the fact without the failure.
public struct ICloudLibraryScan: Sendable, Hashable {
    public let libraries: [ICloudAppLibrary]
    public let isRestricted: Bool

    public init(libraries: [ICloudAppLibrary], isRestricted: Bool) {
        self.libraries = libraries
        self.isRestricted = isRestricted
    }
}

/// Assembles iCloud Drive the way Finder presents it: the `com~apple~CloudDocs` container's
/// own files merged with every iCloud-enabled app's public `Documents` folder, which live as
/// *siblings* of CloudDocs under `~/Library/Mobile Documents` rather than inside it
/// (probed 2026-07-21).
public enum ICloudDrive {
    /// `~/Library/Mobile Documents`, the parent of every container. Needs Full Disk Access to
    /// enumerate — only the `com~apple~CloudDocs` leaf is TCC-carved-out, which is why the M8
    /// row could browse without the grant and this merge cannot.
    public static func mobileDocuments(home: String = NSHomeDirectory()) -> VFSPath {
        VFSPath.local(home).appending("Library").appending("Mobile Documents")
    }

    /// Every app container whose `Documents` folder belongs in iCloud Drive right now.
    ///
    /// The rule is **declared public scope, and not empty**. The first half is Apple's own
    /// (`BRContainerIsDocumentScopePublic`, the cached form of the app's
    /// `NSUbiquitousContainers` declaration); the second half is ours, and it is an
    /// approximation of Finder's — deliberately, because Finder's exact rule is not derivable
    /// from anything public. Probed 2026-07-21: this Mac declares 17 public containers and
    /// Finder shows 7 of them, and nothing separates the two sets — not directory mtimes, not
    /// emptiness, not install state, not `bird`'s own `client.db` item counts. Two of the
    /// seven are empty folders, so "not empty" misses those; the alternative, showing all 17,
    /// puts ten app folders in iCloud Drive that Finder deliberately hides. Missing an empty
    /// folder is the smaller lie.
    ///
    /// `.DS_Store` does not count as content — it is Finder's bookkeeping and appears in
    /// containers the user has never touched, the same reason the M8 Empty Trash confirmation
    /// doesn't count it. Any other dotfile does count: `Shortcuts` and `Curve` hold nothing
    /// but a marker file, and Finder lists them both.
    public static func appLibraries(
        home: String = NSHomeDirectory(),
        languageCode: String? = Locale.current.language.languageCode?.identifier,
        fileManager: FileManager = .default
    ) -> ICloudLibraryScan {
        let metadataDirectory = ICloudContainers.metadataDirectory(home: home)
        var restricted = false

        let files: [String]
        do {
            files = try fileManager.contentsOfDirectory(atPath: metadataDirectory.path)
        } catch {
            // No metadata cache at all is indistinguishable from one we may not read, and
            // both mean the same thing to the pane: it cannot offer the app libraries.
            return ICloudLibraryScan(libraries: [], isRestricted: isDenial(error))
        }

        var libraries: [ICloudAppLibrary] = []
        for file in files where (file as NSString).pathExtension == "plist" {
            let bundleID = (file as NSString).deletingPathExtension
            guard let data = fileManager.contents(atPath: metadataDirectory.appending(file).path),
                  let metadata = ICloudContainers.parseMetadata(data, bundleID: bundleID),
                  metadata.isDocumentScopePublic else { continue }

            let documents = mobileDocuments(home: home)
                .appending(metadata.containerID)
                .appending("Documents")
            switch hasContent(at: documents, fileManager) {
            case .empty: continue
            case .denied:
                restricted = true
                continue
            case .hasContent:
                libraries.append(
                    ICloudAppLibrary(
                        containerID: metadata.containerID,
                        bundleID: bundleID,
                        name: metadata.name(for: languageCode),
                        documents: documents,
                        iconNames: metadata.iconNames
                    )
                )
            }
        }

        libraries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return ICloudLibraryScan(libraries: libraries, isRestricted: restricted)
    }

    /// The row an app library contributes to the merged listing: the real `Documents`
    /// directory's own stat, wearing the app's name.
    ///
    /// Name and path deliberately disagree here — this is the one place in the codebase where
    /// they do, and it is why the merged root is a virtual listing rather than a directory.
    /// Sorting and type-to-filter follow the name, which is what the user sees; navigation and
    /// every file operation follow the path, which is what exists.
    public static func libraryRow(for library: ICloudAppLibrary, stat entry: FileEntry) -> FileEntry {
        FileEntry(
            path: library.documents,
            name: library.name,
            kind: entry.kind,
            byteSize: entry.byteSize,
            modificationDate: entry.modificationDate,
            creationDate: entry.creationDate,
            // A `Documents` folder is never hidden in this view, whatever the container's own
            // flags say: it is the row the user came here for.
            isHidden: false,
            permissions: entry.permissions,
            inode: entry.inode,
            symlinkDestination: entry.symlinkDestination,
            symlinkTargetKind: entry.symlinkTargetKind,
            isDataless: entry.isDataless
        )
    }

    /// The merged listing: CloudDocs' own children first, then the app libraries. The pane
    /// re-sorts by its own column, so this order only has to be deterministic.
    public static func merge(looseFiles: [FileEntry], libraryRows: [FileEntry]) -> [FileEntry] {
        looseFiles + libraryRows
    }

    /// Whether a container's `Documents` holds anything worth showing a row for.
    private static func hasContent(at path: VFSPath, _ fileManager: FileManager) -> Content {
        do {
            let names = try fileManager.contentsOfDirectory(atPath: path.path)
            return names.contains { $0 != ".DS_Store" } ? .hasContent : .empty
        } catch {
            // A container that exists in the metadata cache but has no folder on this Mac is
            // simply empty; only a refusal is worth reporting as a restriction.
            return isDenial(error) ? .denied : .empty
        }
    }

    private enum Content {
        case hasContent
        case empty
        case denied
    }

    /// Whether a `FileManager` failure is TCC (or POSIX) saying no, rather than "not there".
    /// Both domains are checked because the same denial surfaces as Cocoa's
    /// `NSFileReadNoPermissionError` (257 — what a TCC refusal produces) or, when the failure
    /// comes back raw, as `EPERM`/`EACCES` under `NSPOSIXErrorDomain`.
    private static func isDenial(_ error: any Error) -> Bool {
        let error = error as NSError
        switch error.domain {
        case NSCocoaErrorDomain: return error.code == NSFileReadNoPermissionError
        case NSPOSIXErrorDomain: return error.code == Int(EPERM) || error.code == Int(EACCES)
        default: return false
        }
    }
}
