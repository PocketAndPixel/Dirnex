import Foundation

/// An album or a folder as a row of the folder that holds it: the name it is listed under, and what
/// it stands for.
public struct PhotosNamedCollection: Sendable, Hashable {
    public let name: String
    public let collection: PhotosCollection

    public init(name: String, collection: PhotosCollection) {
        self.name = name
        self.collection = collection
    }
}

/// What the rows of the library's view are called (PLAN.md §M28): an original by the file name it was
/// imported with, and an album or a folder by its title — each made into a usable path component and
/// numbered where it collides.
public extension PhotosLayout {
    /// The rows one level of albums and folders lists, in the order they were given.
    ///
    /// The order is the library's, which is the Photos sidebar's, and it decides who keeps a contested
    /// title: the album a person sees first in Photos keeps `Rainbow`, the next is `Rainbow (2)`, and
    /// dragging one above the other there renumbers them here. An album and a folder share one set of
    /// names, since both are folders in this view and Photos lets a folder `Trips` sit beside an album
    /// `Trips` (measured 2026-09-13).
    func named(_ collections: [PhotosCollection]) -> [PhotosNamedCollection] {
        var taken: Set<String> = []
        return collections.map { collection in
            PhotosNamedCollection(
                name: Self.numbered(
                    Self.rowName(for: collection.title),
                    avoiding: &taken,
                    splittingExtension: false
                ),
                collection: collection
            )
        }
    }

    /// A name from the library made into a usable path component.
    ///
    /// Nothing promises it is one — a file name came from whatever imported the file, and an album
    /// title is whatever a person typed: a `/` would split the path (Photos stores `Summer/Beach`
    /// verbatim), and `..` would climb out of it. A slash becomes `:`, which is how Finder spells a
    /// slash on disk.
    internal static func rowName(for originalFilename: String) -> String {
        let name = originalFilename.replacingOccurrences(of: "/", with: ":")
        switch name {
        case "": return "Untitled"
        case ".", "..": return "_" + name
        default: return name
        }
    }

    /// `name`, or the first `name (2)`, `name (3)`, … not already in `taken`, which it then joins.
    ///
    /// Compared case- and normalization-insensitively, as APFS compares names: two rows a copy out
    /// would land on one file are two rows with one name. A file's number goes before its extension;
    /// a title has none, so `Mr. Smith` becomes `Mr. Smith (2)` rather than `Mr (2). Smith`.
    internal static func numbered(
        _ name: String,
        avoiding taken: inout Set<String>,
        splittingExtension: Bool = true
    ) -> String {
        let extensionPart = splittingExtension ? (name as NSString).pathExtension : ""
        let stem = extensionPart.isEmpty ? name : (name as NSString).deletingPathExtension
        var candidate = name
        var counter = 2
        while taken.contains(collisionKey(candidate)) {
            candidate = extensionPart.isEmpty
                ? "\(stem) (\(counter))"
                : "\(stem) (\(counter)).\(extensionPart)"
            counter += 1
        }
        taken.insert(collisionKey(candidate))
        return candidate
    }

    private static func collisionKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }
}
