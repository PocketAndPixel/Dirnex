import Foundation
import UniformTypeIdentifiers

/// What inline rename (F2) preselects in the name field, so that typing replaces the part a rename
/// usually means to change.
///
/// A file keeps its extension out of the selection, Finder-style: everything before the last dot,
/// or the whole name when there is no dot or only a leading one (`.zshrc`).
///
/// **A folder is selected whole**, because a dot in a folder's name is not an extension:
/// `aaa.bbb.ccc` is one name, and cutting at the last dot preselected `aaa.bbb` as though `.ccc`
/// were a type (reported 2026-10-13). Total Commander and Finder both select a folder whole.
///
/// **A package is the exception, and it is treated as a file.** `Foo.app` or `Notes.rtfd` is a
/// folder on disk, but its extension is what makes it a package, so selecting it whole invites a
/// rename that types the extension away. Bundles that are not packages (`.framework`, `.xcassets`)
/// read as folders everywhere, and are selected whole like any other.
public enum RenameSelection {
    /// The range to preselect in `name`, in UTF-16 units, ready for `NSText.selectedRange`.
    ///
    /// `isDirectory` should be the row's directory-likeness rather than its literal kind: a symlink
    /// to a folder is drawn and navigated as a folder, and it renames as one too.
    public static func range(forName name: String, isDirectory: Bool) -> NSRange {
        let ns = name as NSString
        let whole = NSRange(location: 0, length: ns.length)
        if isDirectory, !isPackageName(name) { return whole }
        let dot = ns.range(of: ".", options: .backwards)
        guard dot.location != NSNotFound, dot.location > 0 else { return whole }
        return NSRange(location: 0, length: dot.location)
    }

    /// Whether a directory with this name is a package, judged from the extension alone.
    ///
    /// A name lookup rather than `NSWorkspace.isFilePackage(atPath:)`, so it answers for a row on a
    /// server or inside an archive as readily as for a local one, and costs no I/O. The supertype
    /// has to be `.directory`: with the default `.data`, the lookup skips every declared package
    /// type and mints a dynamic one, so `app` came back `com.apple.application-file` and `bundle`,
    /// `rtfd` and `xcodeproj` came back dynamic (probed 2026-10-13). An unknown extension such as
    /// `ccc` still gets a dynamic type, which conforms to nothing.
    static func isPackageName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return false }
        return UTType(filenameExtension: ext, conformingTo: .directory)?.conforms(to: .package) == true
    }
}
