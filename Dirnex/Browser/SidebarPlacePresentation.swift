import AppKit
import DirnexCore

/// What a place is **called** and what glyph stands for it — once, for every surface that draws one
/// (PLAN.md §M20).
///
/// The sidebar row and the Go ▸ Places menu item are two renderings of the same destination, so a
/// name or a symbol chosen in only one of them is a name the two can come to disagree about. That
/// matters most for the three whose title is a *literal*: "Recents", "Trash" and "iCloud Drive" are
/// translated strings, and a display string that exists twice gets localized once (docs/NOTES.md).
///
/// Only the *naming* lives here. How the glyph is finally drawn stays with each renderer, because a
/// 32 pt source-list row and a menu item genuinely want different renderings — point size, template
/// tinting, an eject button beside it — and collapsing those into one would make the sidebar worse
/// to buy a symmetry nobody sees.
@MainActor
enum SidebarPlacePresentation {
    /// The place's label.
    static func title(for place: SidebarPlace) -> String {
        switch place {
        case .recents:
            String(localized: "Recents", comment: "Sidebar row: recently used files.")
        case .trash:
            String(localized: "Trash", comment: "Sidebar row and section for deleted items.")
        case .iCloudDrive:
            String(
                localized: "iCloud Drive",
                comment: "Apple's iCloud Drive: the sidebar row, the tab title, and the path bar's root crumb."
            )
        case let .savedSearch(search): search.name
        case let .favorite(entry): entry.name
        case let .cloudMount(mount): mount.name
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
        case .recents: "clock"
        case .trash: "trash"
        case .iCloudDrive: "icloud"
        case .savedSearch: "magnifyingglass"
        case let .favorite(entry): favoriteSymbolName(for: entry.path)
        case let .cloudMount(mount): mount.symbolName
        case let .volume(volume): volume.symbolName
        case let .vault(vault):
            vaultSymbolName(isUnlocked: unlockedVaults.contains(vault.resolvedImagePath))
        case let .server(server): serverSymbolName(for: server.kind)
        case .tag: nil
        }
    }

    /// An open or shut padlock — the one distinction a vault row exists to draw, and the one a user
    /// reads without looking. Exposed on its own because the sidebar's cell already knows the answer
    /// (it holds `vaultMountPoints`) and would otherwise have to build a `SidebarPlace` just to ask.
    static func vaultSymbolName(isUnlocked: Bool) -> String {
        isUnlocked ? "lock.open.fill" : "lock.fill"
    }

    /// The glyph for a pinned folder: its standard-place symbol when the path is one of the
    /// well-known folders, otherwise a plain folder — or a protocol glyph for a pin that lives
    /// outside the local filesystem, so a remote or in-archive favorite doesn't pretend to be a
    /// local directory.
    private static func favoriteSymbolName(for path: VFSPath) -> String {
        if let kind = SidebarLocations.standardKind(for: path) {
            return standardPlaceSymbolName(for: kind)
        }
        guard path.backend == .local else {
            return path.backend.isArchive ? "doc.zipper" : "network"
        }
        return "folder"
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
        }
    }
}
