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
    /// The rule is **declared public scope, and the folder is there**. The first half is Apple's
    /// own (`BRContainerIsDocumentScopePublic`, the cached form of the app's
    /// `NSUbiquitousContainers` declaration); the second is only "this Mac actually has the
    /// directory", the same "only what exists" rule the sidebar's other sections follow.
    ///
    /// Emptiness deliberately does **not** disqualify a container, and that is a reversal
    /// (decided 2026-07-21, second pass). Finder's exact rule is not derivable from anything
    /// public — this Mac declares 17 public containers and Finder shows 7, and nothing available
    /// separates them: not mtimes, not install state, not `bird`'s `client.db` item counts, and
    /// not emptiness, since three of the seven Finder shows are empty (Amadine, Numbers,
    /// TextEdit). Given a choice between two wrong sets, showing a folder Finder hides is the
    /// recoverable error and hiding a folder the user can see in Finder is not: the second reads
    /// as "Dirnex lost my files".
    ///
    /// So an empty `Documents` gets a row, and the ten containers Finder hides (GarageBand,
    /// iMovie, Keynote, QuickTime Player, Automator, Script Editor…) come along with them.
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
            switch reachability(of: documents, fileManager) {
            case .missing: continue
            case .denied:
                restricted = true
                continue
            case .readable:
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

    /// Whether `path` is a directory the merged listing stands in front of: the CloudDocs
    /// container whose children it shows loose, or any app library's `Documents` folder.
    ///
    /// This is what "up" means from inside iCloud Drive. The real parent of
    /// `com~apple~Pages/Documents` is `com~apple~Pages`, a one-child folder the user never asked
    /// to see, and the real parent of CloudDocs is `~/Library/Mobile Documents` itself — so a
    /// pane walking up out of either should land back in the merged listing, the way Finder's
    /// does, rather than in the machinery underneath it.
    ///
    /// Deliberately a shape test rather than a record of where the user came from: arriving at
    /// one of these folders by typing its path is the same situation, and a remembered entry
    /// point would be wrong the moment a tab is restored.
    public static func isMergedRoot(_ path: VFSPath, home: String = NSHomeDirectory()) -> Bool {
        guard path.backend == .local else { return false }
        let containers = mobileDocuments(home: home)
        if path == containers.appending(cloudDocsContainerID) { return true }
        return path.lastComponent == "Documents" && path.parent?.parent == containers
    }

    /// The container holding the loose files — the one leaf TCC carves out, and the only part of
    /// iCloud Drive M8 could show.
    public static let cloudDocsContainerID = "com~apple~CloudDocs"

    /// `~/Library/Mobile Documents/com~apple~CloudDocs`, the loose-files container itself.
    public static func cloudDocs(home: String = NSHomeDirectory()) -> VFSPath {
        mobileDocuments(home: home).appending(cloudDocsContainerID)
    }

    /// Whether walking up from `path` lands back in the merged listing rather than in `path`'s real
    /// parent directory.
    ///
    /// Two cases, and the asymmetry between them is the whole point:
    ///
    /// - The folders the listing *stands in front of* (`isMergedRoot`) — up from either is the
    ///   listing, since their real parents are container machinery.
    /// - **The CloudDocs container's own children**, because those are shown *loose*: "Car" is a row
    ///   in iCloud Drive, so iCloud Drive is what is above it. An app library's `Documents` is a row
    ///   too, which is exactly why its children are *not* here — up from `Pages/Documents/Drafts` is
    ///   the folder the "Pages" row itself opens, an ordinary directory, and short-circuiting that to
    ///   the merge would skip a level the user can see in front of them.
    public static func walksUpToMerge(from path: VFSPath, home: String = NSHomeDirectory()) -> Bool {
        isMergedRoot(path, home: home) || path.parent == cloudDocs(home: home)
    }

    /// The merged listing: CloudDocs' own children first, then the app libraries. The pane
    /// re-sorts by its own column, so this order only has to be deterministic.
    public static func merge(looseFiles: [FileEntry], libraryRows: [FileEntry]) -> [FileEntry] {
        looseFiles + libraryRows
    }

    /// Whether a container's `Documents` folder is there to open — read through an actual
    /// directory read rather than `fileExists`, because the *refusal* is the outcome that has to
    /// be told apart from the absence: a container the metadata cache knows about but that has no
    /// folder on this Mac is simply not here, while one we were not allowed to look at is a Full
    /// Disk Access problem the pane offers to fix.
    private static func reachability(of path: VFSPath, _ fileManager: FileManager) -> Reachability {
        do {
            _ = try fileManager.contentsOfDirectory(atPath: path.path)
            return .readable
        } catch {
            return isDenial(error) ? .denied : .missing
        }
    }

    private enum Reachability {
        case readable
        case missing
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
