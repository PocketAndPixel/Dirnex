import DirnexCore
import Foundation

/// How the system Photos library is named and drawn wherever the app shows it (PLAN.md §M28): the
/// sidebar row, the tab title, the path bar's crumbs and the folder of undated photos.
///
/// One place, because four surfaces need the same two strings and the lesson this project keeps
/// relearning is that a display string that exists twice gets translated once (docs/NOTES.md ▸
/// Localization).
enum PhotosPresentation {
    /// The library's name — the one the Photos app has in the running language. The **default**
    /// title: a surface naming the library reads `CloudPlaceTitle.photos`, which the user may have
    /// renamed.
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

    /// The folder of the albums and folders a person made.
    ///
    /// A title drawn over a path that stays `/Albums`, for the same reason as ``undatedTitle``
    /// (``PhotosLayout/albumsFolderName``). An album's own name is never translated: it is what the
    /// person typed.
    static var albumsTitle: String {
        String(
            localized: "Albums",
            comment: "Photos library folder holding the user's albums and album folders. Use the Photos app's word."
        )
    }

    /// The glyph the sidebar row and the path bar share.
    static let symbolName = "photo.on.rectangle.angled"

    /// What a location inside the library is called where a person reads it: the library's name at
    /// the root — or what the user renamed its sidebar row to (`CloudPlaceTitle`) — the translated
    /// titles for the undated and albums folders, and the path component — a year, a month or an
    /// album's own name, which read the same in every language — everywhere else.
    ///
    /// `names` is optional because only the root reads it, and a default argument would be evaluated
    /// for every crumb.
    static func title(for path: VFSPath, names: SidebarItemNames? = nil) -> String {
        if path.isRoot { return CloudPlaceTitle.photos(names: names ?? CloudPlaceNameStore.load()) }
        if path.path == "/" + PhotosLayout.undatedFolderName { return undatedTitle }
        if path.path == "/" + PhotosLayout.albumsFolderName { return albumsTitle }
        return path.lastComponent
    }
}
