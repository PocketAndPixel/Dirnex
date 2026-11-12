import Foundation
import UniformTypeIdentifiers

/// What the name column draws as a row's icon (2026-11-11). Decided from what the listing already
/// knows, with no I/O; the app turns the answer into an image.
///
/// Two measurements on this Mac (macOS 26) shaped it. A **file's** own icon is the same picture as
/// its type's: `NSWorkspace.icon(forFile:)` and `icon(for: UTType)` matched pixel for pixel on 47 of
/// 47 files in Downloads, so asking each file adds nothing, and what tells files apart is a picture
/// of the content, as Finder's list view draws. A **folder's** own icon is often not the generic one:
/// all 92 packages measured (applications, `.sparsebundle`, `.xcodeproj`) and Home's special folders
/// have their own, and the generic folder drawn for every one of them was simply wrong.
public enum RowIcon: Sendable, Hashable {
    /// The generic folder, for a folder that cannot be asked for its own icon.
    case folder
    /// The icon macOS draws for this type, one shared image per type.
    case type(UTType)
    /// The item's own icon, which only the item on disk can say: an application's, a bundle's, Home's
    /// special folders, a folder with a custom icon. Until it has loaded, a package is drawn with its
    /// type's icon and any other folder as ``folder``.
    case item(packageType: UTType?)
    /// A Quick Look picture of the content. Drawn as `.type(fallback)` until it arrives, and for good
    /// when Quick Look has none.
    case thumbnail(fallback: UTType)
}

public extension RowIcon {
    /// The icon for `entry`.
    ///
    /// The item's own icon and a picture of its content both need the item itself, so both are only
    /// for an item on **this Mac's** storage and with its bytes here:
    /// - Not over a remote backend or inside an archive, where reading the item is a transfer or an
    ///   extraction.
    /// - Not on a mounted share (`MNT_LOCAL` clear). A thumbnail there is a network read, and a share
    ///   whose server has gone away would hold the request for as long as it is gone.
    /// - Not a dataless cloud item, which a read would download (HISTORY.md §M15 measured 1.1 s to
    ///   materialize 200 KB).
    ///
    /// Anything else gets the type icon, as every row did before. A package keeps its type there too,
    /// so an application on a server is drawn as an application rather than as a folder.
    ///
    /// `mounts` is ``MountTable/current()``, read once by the caller for many rows. A path no mount
    /// contains means the table could not be read, and is treated as a share: unknown is not local.
    static func of(_ entry: FileEntry, mounts: [MountTableEntry], showsPreviews: Bool) -> RowIcon {
        let isHere = isOnThisMac(entry, mounts: mounts)
        switch entry.kind {
        case .directory:
            let package = packageType(of: entry.name)
            if isHere { return .item(packageType: package) }
            return package.map(RowIcon.type) ?? .folder
        case .symlink where entry.symlinkTargetKind == .directory:
            // Drawn and navigated as a folder (`isDirectoryLike`), and never followed for an icon.
            return .folder
        case .file:
            let type = fileType(of: entry.name)
            if showsPreviews, isHere, isPreviewed(type) { return .thumbnail(fallback: type) }
            return .type(type)
        case .symlink, .other:
            return .type(fileType(of: entry.name))
        }
    }

    /// Whether Quick Look's picture of a file of this type says more than its type icon at row size:
    /// images, video and PDFs.
    ///
    /// Not text, though Finder draws that too. At 16 pt a page of text is a white square with grey
    /// lines (seen 2026-11-11 for `.js`, `.json`, `.txt` and `.md` alike), which says less than the
    /// type icon it would replace. Not audio, whose picture is a note on a blank page.
    static func isPreviewed(_ type: UTType) -> Bool {
        type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .pdf)
    }

    /// The type a file of this name is, by its extension. Lowercased, as the icon cache has always
    /// keyed it; `.data` for a name with no extension.
    static func fileType(of name: String) -> UTType {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .data }
        return UTType(filenameExtension: ext) ?? .data
    }

    /// The package type a folder of this name is, or `nil` for a plain folder. Looked up with
    /// `.directory` as the supertype, for the reason ``RenameSelection`` records: with the default
    /// `.data`, `app` comes back as the flat-file `com.apple.application-file`.
    static func packageType(of name: String) -> UTType? {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext, conformingTo: .directory),
              type.conforms(to: .package) else { return nil }
        return type
    }

    private static func isOnThisMac(_ entry: FileEntry, mounts: [MountTableEntry]) -> Bool {
        guard entry.path.backend == .local, !entry.isDataless else { return false }
        return MountTable.entry(containing: entry.path.path, in: mounts)?.isLocal ?? false
    }
}
