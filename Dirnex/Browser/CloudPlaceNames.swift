import DirnexCore
import Foundation

/// App-wide persistence for the names the user gave the sidebar's **Cloud** rows — iCloud Drive, the
/// Photos library and each provider mount (``SidebarItemNames``). Boring JSON in `UserDefaults`, like
/// `CloudSectionOrderStore` beside it, and keyed by the same identities (``CloudPlaceIdentity``).
///
/// Nonisolated on purpose: a name is read by ``VFSPath/displayName``, which is not main-actor bound,
/// and `UserDefaults` is safe to read from anywhere.
enum CloudPlaceNameStore {
    private static let key = "Dirnex.cloudPlaceNames"

    /// Posted after a `save`, with the defaults domain written to as its `object`.
    ///
    /// The object is what keeps a test's scratch domain from waking the app: every sidebar and pane
    /// observes `UserDefaults.standard` specifically, so a save anywhere else changes nothing on
    /// screen (docs/NOTES.md ▸ Testing — a preference write in one suite repaints every live pane
    /// in the test host).
    static let didChangeNotification = Notification.Name("Dirnex.cloudPlaceNamesDidChange")

    static func load(from defaults: UserDefaults = .standard) -> SidebarItemNames {
        guard let data = defaults.data(forKey: key),
              let names = try? JSONDecoder().decode(SidebarItemNames.self, from: data) else {
            return SidebarItemNames()
        }
        return names
    }

    /// Store `names`. The domain is required rather than defaulted, so a test cannot reach the
    /// developer's own sidebar by forgetting to pass one (docs/NOTES.md ▸ Testing).
    @MainActor
    static func save(_ names: SidebarItemNames, to defaults: UserDefaults) {
        if names.names.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(names) {
            defaults.set(data, forKey: key)
        } else {
            return
        }
        NotificationCenter.default.post(name: didChangeNotification, object: defaults)
    }
}

/// What each Cloud place is **called** — the user's name when they gave one, the app's otherwise —
/// for every surface that names one: the sidebar row, the Go ▸ Places item, the path bar's root crumb
/// and the tab chip (PLAN.md §M20).
///
/// Those surfaces already drew one invented label per place — a mount's folder is
/// `GoogleDrive-someone@gmail.com`, and "iCloud Drive" is a merge of several directories — so a
/// rename changes that label wherever it appears rather than only in the sidebar. Otherwise the row
/// would say "Work" over a path bar saying "Google Drive", about the same place.
///
/// The defaults live here too, once: "iCloud Drive" was a translated literal written out at three
/// sites with a comment kept identical by hand (docs/NOTES.md ▸ Localization).
enum CloudPlaceTitle {
    /// iCloud Drive's own name, in the running language.
    static var iCloudDriveDefault: String {
        String(
            localized: "iCloud Drive",
            comment: "Apple's iCloud Drive: the sidebar row, the tab title, and the path bar's root crumb."
        )
    }

    static func iCloudDrive(names: SidebarItemNames = CloudPlaceNameStore.load()) -> String {
        names.title(for: CloudPlaceIdentity.iCloudDrive, default: iCloudDriveDefault)
    }

    static func photos(names: SidebarItemNames = CloudPlaceNameStore.load()) -> String {
        names.title(for: CloudPlaceIdentity.photos, default: PhotosPresentation.libraryTitle)
    }

    static func mount(
        _ mount: CloudStorageMount,
        names: SidebarItemNames = CloudPlaceNameStore.load()
    ) -> String {
        names.title(
            for: CloudPlaceIdentity.mount(directoryName: mount.directoryName),
            default: mount.name
        )
    }

    /// What `place` is called when nobody renamed it, or `nil` for a place outside the Cloud section.
    static func defaultTitle(for place: SidebarPlace) -> String? {
        switch place {
        case .iCloudDrive: iCloudDriveDefault
        case .photos: PhotosPresentation.libraryTitle
        case let .cloudMount(mount): mount.name
        default: nil
        }
    }

    /// What `place` is called now, or `nil` for a place outside the Cloud section.
    static func title(
        for place: SidebarPlace,
        names: SidebarItemNames = CloudPlaceNameStore.load()
    ) -> String? {
        guard let identity = CloudPlaceIdentity.of(place),
              let defaultTitle = defaultTitle(for: place) else { return nil }
        return names.title(for: identity, default: defaultTitle)
    }

    /// The name of the provider mount `path` **is**, or `nil` for any other path — what a tab parked
    /// at a mount's root is called.
    ///
    /// Only the root: below it the folder has a name of its own. A pure string test turns away
    /// everything but a direct child of `~/Library/CloudStorage` before anything is read, so an
    /// ordinary path pays nothing; a hit costs the one `readdir` of `CloudStorage` the path bar
    /// already pays for the same location (``CloudStorageMounts/mount(containing:home:fileManager:)``).
    /// `names` is optional for the same reason: a default argument is evaluated on every call, and
    /// this is asked of every path a sentence names.
    ///
    /// A direct child of `CloudStorage` that lies in a mount can only *be* that mount, since every
    /// mount is itself a direct child, so the lookup needs no second comparison.
    static func mountRoot(
        _ path: VFSPath,
        home: String = NSHomeDirectory(),
        names: SidebarItemNames? = nil
    ) -> String? {
        guard path.backend == .local,
              path.parent == CloudStorageMounts.cloudStorage(home: home),
              let mount = CloudStorageMounts.mount(containing: path, home: home) else { return nil }
        return self.mount(mount, names: names ?? CloudPlaceNameStore.load())
    }

    /// iCloud Drive's name when `path` **is** the CloudDocs container, or `nil` for any other path —
    /// what a tab parked there is called.
    ///
    /// The container is what the merged listing shows loose, so it is iCloud Drive itself: the path
    /// bar draws it as the root crumb and nothing more (`ICloudLocation.trail` answers no steps), while
    /// a tab chip or a sentence called it `com~apple~CloudDocs`, a folder the user has never heard of.
    /// Only the container: its children have names of their own, and an app library beside it is
    /// named for its app (`ICloudLocation.libraryTitle(of:)`). A pure comparison, so an ordinary path
    /// pays nothing, and `names` is optional for the reason ``mountRoot(_:home:names:)`` gives.
    static func iCloudContainer(
        _ path: VFSPath,
        home: String = NSHomeDirectory(),
        names: SidebarItemNames? = nil
    ) -> String? {
        guard path == ICloudDrive.cloudDocs(home: home) else { return nil }
        return iCloudDrive(names: names ?? CloudPlaceNameStore.load())
    }
}
