import Foundation

/// A name typed into F7's or ⇧F4's field that may pass through folders on the way:
/// `Folder A/sub folder A` makes `Folder A` and then `sub folder A` inside it, and
/// `Folder A/test.txt` makes the folder and then the file (asked 2026-11-18; Total Commander's F7
/// has always taken a path).
///
/// The parse is the whole of what the two dialogs check before a backend is asked anything, and it
/// is the same everywhere, so this Mac, a server and a browsed archive refuse the same spellings
/// with the same sentence. ``NestedCreation`` makes what it names.
///
/// **A name is taken as typed between the slashes.** The dialog trims the ends of the whole field,
/// as it always has, and a space beside a `/` stays part of its name, as it would in Finder or in
/// `mkdir -p`. Repeated slashes collapse, as they do in any path.
public struct NestedName: Sendable, Equatable {
    /// What the name makes at its end.
    public enum Leaf: Sendable {
        /// F7: the last name is a folder too, so a trailing `/` changes nothing.
        case folder
        /// ⇧F4: the last name is the file.
        case file
    }

    /// Why typed text names nothing a create could make.
    public enum Problem: Error, Sendable, Equatable {
        /// Nothing was typed. The dialogs read this as a cancel, as they always have.
        case empty
        /// A leading `/`. Everything is made inside the folder the dialog names, so a path from a
        /// root would have to guess which root, and on a server or inside an archive there are two.
        case startsAtRoot
        /// A `.` or `..` on the way. Neither names a new folder: `..` would climb out of the folder
        /// the dialog names, which is where the user was told the item goes. Carries the name.
        case reserved(String)
        /// ⇧F4 with a `/` at the end, which leaves the file without a name of its own.
        case endsInSlash
    }

    /// Every name along the way, outermost first. The last is the item itself. Never empty.
    public let components: [String]

    /// Parse `typed` as a name, or a path of names, for a create of `leaf`.
    public init(parsing typed: String, as leaf: Leaf) throws(Problem) {
        guard !typed.isEmpty else { throw .empty }
        guard !typed.hasPrefix("/") else { throw .startsAtRoot }
        if leaf == .file, typed.hasSuffix("/") { throw .endsInSlash }
        let components = typed.split(separator: "/", omittingEmptySubsequences: true).map(
            String.init
        )
        if let reserved = components.first(where: { $0 == "." || $0 == ".." }) {
            throw .reserved(reserved)
        }
        // Not reachable after the two guards above (a non-empty string that does not start with a
        // slash has a first component), kept so the "never empty" promise does not rest on them.
        guard !components.isEmpty else { throw .empty }
        self.components = components
    }

    /// The item's own name: the last component.
    public var name: String {
        components[components.count - 1]
    }

    /// Whether the name passes through a folder on the way.
    public var isNested: Bool {
        components.count > 1
    }

    /// The names joined back with single slashes, for a sentence about what was typed.
    public var displayPath: String {
        components.joined(separator: "/")
    }

    /// Where the item lands, below `directory`.
    public func target(in directory: VFSPath) -> VFSPath {
        components.reduce(directory) { $0.appending($1) }
    }

    /// The folders on the way to the item, outermost first, without the item itself. Empty for a
    /// plain name.
    public func folders(in directory: VFSPath) -> [VFSPath] {
        var path = directory
        return components.dropLast().map { component in
            path = path.appending(component)
            return path
        }
    }

    /// The row a create puts the cursor on: the outermost name, which is the one the pane's own
    /// listing of `directory` shows. For a plain name it is the item itself.
    public func outermost(in directory: VFSPath) -> VFSPath {
        directory.appending(components[0])
    }
}
