import Foundation

/// Where a real directory sits *inside* iCloud Drive, said the way the user got there
/// (PLAN.md §M9).
///
/// Stepping into a row of the merged listing lands in an ordinary local folder — which is the
/// point of the merge being a listing rather than a filesystem — but that folder's real path runs
/// through machinery nobody asked to see: `~/Library/Mobile Documents/com~apple~Pages/Documents`
/// for the row called "Pages", and `…/com~apple~CloudDocs/Car` for the row called "Car". Rendered
/// literally, the path bar spends six crumbs getting to the place the user clicked once.
///
/// So a location inside iCloud Drive gets the same treatment a Google Drive mount gets
/// (`CloudStorageMounts.mount(containing:)`): the trail is rooted at the merged listing and reads
/// `iCloud Drive › Pages › Drafts`. Every step is still a real directory, so the crumbs stay
/// honest and clickable; only the root crumb is virtual, and it navigates by re-gathering the
/// merge exactly as walking up out of one of these folders does.
public enum ICloudLocation {
    /// What the merged listing is called, in the sidebar row, the tab and the path bar's root crumb.
    public static let mergedName = "iCloud Drive"

    /// The synthetic location the merged listing installs as — the root crumb's target, and what
    /// `ResultsPresentation` builds the tab's path from.
    public static let mergedPath = VFSPath(backend: .icloud, path: "/" + mergedName)

    /// One crumb below the merged root: a real directory, wearing the name iCloud Drive shows it
    /// under. Name and path agree for every step except an app library's, where the folder is
    /// called `Documents` and the row is called "Pages" — the same disagreement
    /// `ICloudDrive.libraryRow(for:stat:)` renders in the listing itself.
    public struct Step: Sendable, Hashable {
        public let title: String
        public let directory: VFSPath

        public init(title: String, directory: VFSPath) {
            self.title = title
            self.directory = directory
        }
    }

    /// The steps from the merged listing down to `path`, or `nil` when `path` is not inside iCloud
    /// Drive at all. Empty means `path` *is* one of the folders the merge stands in front of.
    ///
    /// Cheap on the miss that every ordinary navigation is: two string containment tests reject a
    /// path outside `~/Library/Mobile Documents` before touching the disk. Only a location inside
    /// an app library reads anything — one cached metadata plist, to learn that `com~apple~Pages`
    /// is called "Pages".
    ///
    /// `fallbackName` is asked what the OS calls an app library's folder when the cached plist
    /// cannot be read — which is a real state on a build without Full Disk Access, where
    /// `~/Library/Application Support/CloudDocs` is refused while the container itself still lists
    /// (observed live). It is injected rather than called here because the only thing that answers
    /// it is `URLResourceValues.localizedName` on a real iCloud item, which no unit test can
    /// synthesize.
    public static func trail(
        for path: VFSPath,
        home: String = NSHomeDirectory(),
        languageCode: String? = Locale.current.language.languageCode?.identifier,
        fileManager: FileManager = .default,
        fallbackName: (VFSPath) -> String? = { _ in nil }
    ) -> [Step]? {
        guard path.backend == .local else { return nil }

        // The loose files: CloudDocs' children are shown *loose* at the merged root, so the
        // container itself is iCloud Drive and its children start the trail.
        let cloudDocs = ICloudDrive.cloudDocs(home: home)
        if path.isSelfOrDescendant(of: cloudDocs) {
            return steps(from: cloudDocs, to: path)
        }

        // An app library: the `Documents` folder is the row, and the one-child container above it
        // never appears.
        guard let documents = libraryDocuments(containing: path, home: home) else { return nil }
        let containerID = documents.parent?.lastComponent ?? ""
        let title = libraryName(
            forContainerID: containerID,
            home: home,
            languageCode: languageCode,
            fileManager: fileManager
        ) ?? fallbackName(documents) ?? containerID.replacingOccurrences(of: "~", with: ".")
        return [Step(title: title, directory: documents)] + steps(from: documents, to: path)
    }

    /// The row of the merged listing that leads to `path` — where the cursor should land when the
    /// root crumb is clicked, the same way walking up lands on the folder just left.
    public static func mergeRow(towards path: VFSPath, home: String = NSHomeDirectory()) -> VFSPath? {
        // Only the structure is wanted here, so the name lookup is skipped: the first step's
        // *directory* is the same whatever the container is called.
        let cloudDocs = ICloudDrive.cloudDocs(home: home)
        if path.isSelfOrDescendant(of: cloudDocs) {
            return cloudDocs.child(towards: path)
        }
        return libraryDocuments(containing: path, home: home)
    }

    /// The app library's `Documents` folder `path` is in or at, or `nil` anywhere else — including
    /// a bare container directory, which is machinery rather than a place inside iCloud Drive.
    private static func libraryDocuments(containing path: VFSPath, home: String) -> VFSPath? {
        let containers = ICloudDrive.mobileDocuments(home: home)
        guard let container = containers.child(towards: path) else { return nil }
        let documents = container.appending("Documents")
        return path.isSelfOrDescendant(of: documents) ? documents : nil
    }

    /// What iCloud Drive calls the container directory `containerID` — "Pages" for
    /// `com~apple~Pages`, read from the one metadata plist `bird` caches for it.
    ///
    /// The plist is named for the *bundle id*, which is the container id with its tildes back as
    /// dots, so this is a single direct read rather than the scan `ICloudDrive.appLibraries()`
    /// does. `nil` when there is no readable plist — the caller falls back, and the two reasons
    /// that happens are worth telling apart: a container this Mac has no metadata for at all, and
    /// a build that is not allowed to read the cache.
    private static func libraryName(
        forContainerID containerID: String,
        home: String,
        languageCode: String?,
        fileManager: FileManager
    ) -> String? {
        let bundleID = containerID.replacingOccurrences(of: "~", with: ".")
        let file = ICloudContainers.metadataDirectory(home: home).appending(bundleID + ".plist")
        guard let data = fileManager.contents(atPath: file.path),
              let metadata = ICloudContainers.parseMetadata(data, bundleID: bundleID)
        else { return nil }
        return metadata.name(for: languageCode)
    }

    /// The chain of directories strictly below `ancestor` down to `path`, each wearing its own name.
    private static func steps(from ancestor: VFSPath, to path: VFSPath) -> [Step] {
        path.ancestorsFromRoot
            .drop { $0 != ancestor }
            .dropFirst()
            .map { Step(title: $0.lastComponent, directory: $0) }
    }
}
