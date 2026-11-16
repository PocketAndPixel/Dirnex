import AppKit
import DirnexCore

/// What a place is **called** and what glyph stands for it — once, for every surface that draws one
/// (PLAN.md §M20).
///
/// The sidebar row and the Go ▸ Places menu item are two renderings of the same destination, so a
/// name or a symbol chosen in only one of them is a name the two can come to disagree about. That
/// matters most for the three whose title is a *literal*: "Recents", "Trash" and "iCloud Drive" are
/// translated strings, and a display string that exists twice gets localized once (docs/NOTES.md).
/// It matters as much for the Cloud rows, which the user may rename (`CloudPlaceTitle`): a name
/// applied in only one renderer would leave the menu calling the place what the sidebar no longer
/// does.
///
/// Only the *naming* lives here. How the glyph is finally drawn stays with each renderer, because a
/// 32 pt source-list row and a menu item genuinely want different renderings — point size, template
/// tinting, an eject button beside it — and collapsing those into one would make the sidebar worse
/// to buy a symmetry nobody sees.
@MainActor
enum SidebarPlacePresentation {
    /// The place's label. `names` is what the user called the Cloud rows, read once per call by
    /// default and handed in by a test.
    static func title(
        for place: SidebarPlace,
        names: SidebarItemNames = CloudPlaceNameStore.load()
    ) -> String {
        switch place {
        case .recents:
            String(localized: "Recents", comment: "Sidebar row: recently used files.")
        case .trash:
            String(localized: "Trash", comment: "Sidebar row and section for deleted items.")
        case .photos:
            CloudPlaceTitle.photos(names: names)
        case .iCloudDrive:
            CloudPlaceTitle.iCloudDrive(names: names)
        case let .savedSearch(search): search.name
        case let .favorite(entry): entry.name
        case let .cloudMount(mount): CloudPlaceTitle.mount(mount, names: names)
        case let .volume(volume): volume.name
        // The volume's name, not the image file's: that is what the user renamed, and what the pane
        // shows once the vault is open (PLAN.md §M19).
        case let .vault(vault): vault.volumeName
        case let .server(server): server.name
        case let .tag(tag): tag.name
        }
    }

    /// The SF Symbol standing for the place, or `nil` for a tag — whose mark is its **color**, drawn
    /// as a dot by `TagDotStyle` in the pane, the sidebar and the ⌃T menu alike, so there is no
    /// symbol to name and nothing here to keep in step.
    ///
    /// `unlockedVaults` is the set of resolved image paths currently attached, since an open padlock
    /// is the one thing a vault row exists to say and it cannot be read off the place itself — a
    /// `VaultLocation` is the saved entry, and whether it is mounted is `hdiutil`'s answer. Empty
    /// means "assume locked", which is the honest default for a caller that has not asked.
    static func symbolName(for place: SidebarPlace, unlockedVaults: Set<String> = []) -> String? {
        switch place {
        case .recents: symbolName(for: LocationSource.recents)
        case .trash: symbolName(for: LocationSource.trash)
        case .iCloudDrive: symbolName(for: LocationSource.iCloudDrive)
        case .photos: symbolName(for: LocationSource.photos)
        case .savedSearch: symbolName(for: LocationSource.search)
        case let .favorite(entry): favoriteSymbolName(for: entry.path)
        case let .cloudMount(mount): mount.symbolName
        case let .volume(volume): volume.symbolName
        case let .vault(vault):
            vaultSymbolName(isUnlocked: unlockedVaults.contains(vault.resolvedImagePath))
        case let .server(server): serverSymbolName(for: server.kind)
        case .tag: nil
        }
    }

    /// The glyph a tab chip draws for where its listing comes from — always one a sidebar row wears,
    /// so the strip and the sidebar name a kind of place with one mark.
    ///
    /// The rows above route their own symbols through here where the two are the same place, so
    /// each is spelled once. A **share** takes the SMB server row's connected drive rather than the
    /// external drive its Volumes row draws, because what tells it apart from a drive on the desk is
    /// the network; a **folder** takes the plain folder of a pin, not the standard-place symbol of
    /// Downloads or Home, because the chip names the source and the label already names the folder.
    static func symbolName(for source: LocationSource) -> String {
        switch source {
        case .folder: "folder"
        case .externalVolume: MountedVolume.externalSymbolName
        case .networkVolume: serverSymbolName(for: .smb)
        case .vault: vaultSymbolName(isUnlocked: true)
        case .cloudStorage: CloudStorageMount.symbolName
        case .iCloudDrive: "icloud"
        case .photos: PhotosPresentation.symbolName
        case .archive: "doc.zipper"
        case .sftp: serverSymbolName(for: .sftp)
        case .ftp: serverSymbolName(for: .ftp)
        case .s3: serverSymbolName(for: .s3)
        case .webdav: serverSymbolName(for: .webdav)
        case .trash: "trash"
        case .recents: "clock"
        case .search: "magnifyingglass"
        }
    }

    /// An open or shut padlock — the one distinction a vault row exists to draw, and the one a user
    /// reads without looking. Exposed on its own because the sidebar's cell already knows the answer
    /// (it holds `vaultMountPoints`) and would otherwise have to build a `SidebarPlace` just to ask.
    static func vaultSymbolName(isUnlocked: Bool) -> String {
        isUnlocked ? "lock.open.fill" : "lock.fill"
    }

    /// The glyph for a pinned folder: its standard-place symbol when the path is one of the
    /// well-known folders, the archive's zipper for a folder inside one, and otherwise a folder, which
    /// ``badgeSymbolName(for:in:)`` marks with where it lives when that is not this Mac's own disk.
    private static func favoriteSymbolName(for path: VFSPath) -> String {
        if let kind = SidebarLocations.standardKind(for: path) {
            return standardPlaceSymbolName(for: kind)
        }
        return path.backend.isArchive ? symbolName(for: LocationSource.archive) : "folder"
    }

    /// The mark in the corner of a pinned folder's glyph saying where the folder lives, or `nil` for
    /// every other place, a standard folder, a folder inside an archive, and one on this Mac's own
    /// disk.
    ///
    /// The well-known folders keep their own glyphs unmarked, since a house or a down arrow already
    /// says which folder it is. A folder in an archive keeps the zipper it has always worn: the
    /// zipper is too narrow to read as a badge.
    static func badgeSymbolName(for place: SidebarPlace, in context: PinBadgeContext) -> String? {
        guard case let .favorite(entry) = place,
              SidebarLocations.standardKind(for: entry.path) == nil,
              !entry.path.backend.isArchive
        else { return nil }
        let source = context.source(of: entry)
        let isUnlocked = source == .vault
            && VaultPrivacy.isInside(entry.path, mountPoints: context.vaultMountPoints)
        return badgeSymbolName(for: source, isUnlockedVault: isUnlocked)
    }

    /// The mark for a pin on `source`: the glyph that kind of place wears in the sidebar and on a
    /// tab chip, filled where SF Symbols has a filled form, since an outline at two thirds of the
    /// folder's size is too thin to read. WebDAV keeps the outline globe its server row wears,
    /// Oleg's call on 2026-11-17, which keeps it apart from SFTP's `network` once both are filled.
    /// A vault's padlock is open or shut, as its own row is.
    static func badgeSymbolName(for source: LocationSource, isUnlockedVault: Bool) -> String? {
        switch source {
        case .folder, .archive: nil
        case .externalVolume: "externaldrive.fill"
        case .networkVolume: "externaldrive.connected.to.line.below.fill"
        case .vault: vaultSymbolName(isUnlocked: isUnlockedVault)
        case .cloudStorage: "cloud.fill"
        case .iCloudDrive: "icloud.fill"
        case .photos: "photo.on.rectangle.angled.fill"
        case .sftp: serverSymbolName(for: .sftp)
        case .ftp: "arrow.up.arrow.down.circle.fill"
        case .s3: "shippingbox.fill"
        case .webdav: serverSymbolName(for: .webdav)
        case .trash: "trash.fill"
        case .recents: "clock.fill"
        case .search: "magnifyingglass"
        }
    }

    /// A monochrome SF Symbol standing in for each standard folder, so Documents, Downloads,
    /// Music and the rest read at a glance instead of all sharing the generic folder icon.
    private static func standardPlaceSymbolName(for kind: FavoritePlace.Kind) -> String {
        switch kind {
        case .home: "house"
        case .desktop: "menubar.dock.rectangle"
        case .documents: "doc"
        case .downloads: "arrow.down.circle"
        case .movies: "film"
        case .music: "music.note"
        case .pictures: "photo"
        case .applications: "square.grid.3x3.fill"
        }
    }

    /// A per-protocol SF Symbol so a saved server reads as remote at a glance: a globe-ish network
    /// glyph for SFTP, a connected-drive glyph for an SMB share, and an up/down transfer glyph for
    /// FTP — the protocol's own name, and unmistakable against the other two at 14 pt.
    ///
    /// Internal rather than private because the path bar's leading glyph asks it directly: browsing
    /// a connected server, that glyph must be the one the saved row that opened it wears, and the
    /// path bar has a `VFSPath` rather than a `ServerConnection` to build a `SidebarPlace` from.
    static func serverSymbolName(for kind: ServerKind) -> String {
        switch kind {
        case .smb: "externaldrive.connected.to.line.below"
        case .ftp: "arrow.up.arrow.down.circle"
        case .sftp: "network"
        // A bucket, which is what the thing actually is — and the one glyph here that is not about
        // a *machine*, which is the distinction worth drawing: the other three name a computer you
        // reach, this names a store you address.
        case .s3: "shippingbox"
        // A globe for the protocol that is HTTP underneath: what is reached is a web server, and the
        // other four glyphs are already taken by things that are not.
        case .webdav: "globe"
        }
    }
}

/// What a pin's badge is read against: the mount table and the saved vaults, read once for a whole
/// sidebar pass or menu open, since every pin in it asks the same questions.
struct PinBadgeContext {
    let mounts: [MountTableEntry]
    /// Where each unlocked vault is mounted, which only `hdiutil` knows, so it is handed in by the
    /// sidebar that has just asked.
    let vaultMountPoints: [String]
    /// The volume name of every saved vault, which is all a pin inside a *locked* one has to go on.
    let vaultVolumeNames: [String]

    /// Read now, safe on the main thread with a share that has stopped answering (`LocationSource.of`).
    static func current(vaults: [VaultLocation], vaultMountPoints: [String]) -> PinBadgeContext {
        PinBadgeContext(
            mounts: MountTable.current(),
            vaultMountPoints: vaultMountPoints,
            vaultVolumeNames: vaults.map(\.volumeName)
        )
    }

    func source(of entry: FavoriteEntry) -> LocationSource {
        LocationSource.ofPin(
            entry,
            mounts: mounts,
            vaultMountPoints: vaultMountPoints,
            vaultVolumeNames: vaultVolumeNames
        )
    }
}
