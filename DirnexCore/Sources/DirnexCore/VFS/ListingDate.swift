import Foundation

/// Which date a listing's Date column holds, and so what sorting by that column orders on (PLAN.md
/// §M40 Slice 2).
///
/// Every listing shows when each item was modified but one: Recents shows when each was last opened,
/// since that is what makes an item recent there, and Finder's Recents shows the same. It stays one
/// column either way, with one header that sorts it and one ``FileSort/Key/modified`` that a tab
/// persists, so it is the **listing** that says which date the column holds, never the sort.
///
/// That was chosen over a sort key of Recents' own. A tab carries its sort from listing to listing:
/// into a folder opened from a Recents hit, into the Trash shown over Recents, into the restored
/// session. A `lastOpened` key would arrive in each of them naming a date no row there has, which is
/// the leak docs/NOTES.md ▸ Virtual listings records for `showHidden`: an override one listing makes
/// reaches every listing that inherits it. Read off the listing's path, the date cannot travel,
/// because no other listing has that path.
public enum ListingDate: Sendable, Equatable {
    /// When each item was last modified: every listing but Recents.
    case modified
    /// When each item was last opened (``FileEntry/lastUsedDate``): Recents.
    case lastOpened

    /// The date the listing at `path` shows.
    public init(listing path: VFSPath) {
        self = path == SidebarPlaceLocator.recentsPath ? .lastOpened : .modified
    }

    /// The date `entry` shows in this listing, or `nil` when it has none to show: a backend that
    /// keeps no timestamp (``FileEntry/unknownDate``), or a row read without a last-opened date.
    public func date(of entry: FileEntry) -> Date? {
        switch self {
        case .modified: entry.hasModificationDate ? entry.modificationDate : nil
        case .lastOpened: entry.lastUsedDate
        }
    }
}
