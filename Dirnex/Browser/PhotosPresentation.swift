import DirnexCore
import Foundation

/// How the system Photos library is named and drawn wherever the app shows it (PLAN.md §M28): the
/// sidebar row, the tab title, the path bar's crumbs and the folder of undated photos.
///
/// One place, because four surfaces need the same two strings and the lesson this project keeps
/// relearning is that a display string that exists twice gets translated once (docs/NOTES.md ▸
/// Localization).
enum PhotosPresentation {
    /// The library's name — the one the Photos app has in the running language.
    static var libraryTitle: String {
        String(
            localized: "Photos",
            comment: "Photos library name (sidebar row, tab title, path bar root). Use the Photos app's own name."
        )
    }

    /// The folder of photos and videos that have no capture date.
    ///
    /// A title drawn over a path that stays `/Undated`, since a path is an identity and must not change
    /// with the language (``PhotosLayout/undatedFolderName``).
    static var undatedTitle: String {
        String(
            localized: "Undated",
            comment: "Folder in the Photos library holding the photos and videos that have no capture date."
        )
    }

    /// The glyph the sidebar row and the path bar share.
    static let symbolName = "photo.on.rectangle.angled"

    /// What a location inside the library is called where a person reads it: the library's name at
    /// the root, the translated title for the undated folder, and the path component — a year or a
    /// month, which read the same in every language — everywhere else.
    static func title(for path: VFSPath) -> String {
        if path.isRoot { return libraryTitle }
        if path.path == "/" + PhotosLayout.undatedFolderName { return undatedTitle }
        return path.lastComponent
    }
}
