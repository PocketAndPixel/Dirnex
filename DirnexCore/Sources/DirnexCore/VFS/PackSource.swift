import Foundation

/// One thing a pack was asked to put in the archive: where its bytes are on this disk right now,
/// and what it is called (PLAN.md §M24 Slice 6).
///
/// **A pair rather than a bare name, because the set is no longer one directory's worth of rows.**
/// Every earlier pack came from a flat listing of a real local folder, so `bsdtar -C <dir> <name>…`
/// covered all of it and the directory was a property of the *gesture*. Two things broke that. A
/// row that is not on this disk is staged by `MaterializeRunner`, which gives each copy its own
/// directory so two objects called `report.pdf` from different prefixes cannot collide — so a
/// staged set is N directories of one file each. And a **tree** can mark a row inside an expanded
/// folder, which is a second directory in the *local* case and has been wrong since trees shipped:
/// `bsdtar` was handed a bare name that is not in the pane's own folder, so the pack failed, and the
/// encrypted walk skipped the missing name and wrote a smaller archive without saying so.
///
/// Both writers already wanted this and only their entry points did not. `ArchiveSourceItem` has
/// split the absolute `onDiskPath` from the relative `archivePath` since M19, and `bsdtar` accepts
/// `-C` **interleaved** with the names it creates (measured against libarchive 3.7.4:
/// `-c -f out.zip -C /a alpha.txt -C /b beta.txt` writes both members correctly). So neither writer
/// needs a staging directory, a hardlink trick, or a second copy of anybody's bytes.
public struct PackSource: Sendable, Hashable {
    /// The absolute local directory holding the bytes — the pane's own folder for an ordinary row,
    /// and the private directory `MaterializeRunner` put the copy in for a staged one.
    public let directory: String

    /// The bare name, which is both what the file is called in ``directory`` and what the recipient
    /// sees inside the archive.
    ///
    /// **One field rather than two**, deliberately: `MaterializeRunner` keeps a downloaded object's
    /// real name inside its private directory precisely so that every later reader — an editor's
    /// title bar, a write-back watcher, and now an archive's member list — shows what the user
    /// marked. Letting the two drift here would be the one place that spends that.
    public let name: String

    public init(directory: String, name: String) {
        self.directory = directory
        self.name = name
    }

    /// The absolute path to the bytes.
    public var onDiskPath: String {
        (directory as NSString).appendingPathComponent(name)
    }

    /// `names` as they were before this type existed: all of them in one directory.
    ///
    /// The ordinary local pack, and the shape every non-M24 caller has — an archive rewrite works
    /// from one extracted tree, and a flat listing is one folder by definition. It is a convenience
    /// on the value rather than a second `packingArguments` overload, so there is one definition of
    /// what a pack's argv looks like.
    public static func all(inDirectory directory: String, names: [String]) -> [PackSource] {
        names.map { PackSource(directory: directory, name: $0) }
    }
}
