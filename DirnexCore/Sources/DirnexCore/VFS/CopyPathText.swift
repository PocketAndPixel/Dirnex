import Foundation

/// The text "Copy Path" writes for a location.
///
/// For most backends that is ``VFSPath/path`` as it stands. A browsed archive is the exception:
/// its path is *inner* to the archive, so the archive's own root is `/` and a member at its top
/// level is `/name` — which is what every Copy Path inside an archive used to produce, with
/// nothing to say which archive, or that an archive was involved at all. The honest text is the
/// trail the path bar draws, written as one path: the archive file where it really lives, then the
/// path inside it (`/Users/me/Downloads/pkg.zip/docs/readme.txt`). That is Total Commander's own
/// spelling for a location inside an archive, and it reads back to anybody who has seen the
/// crumbs.
///
/// A **nested** archive is browsed from a temp extraction, so its own on-disk path is somewhere
/// nobody asked to see. `archiveAncestry` is the chain ``NestedArchiveMap/ancestry(ofMountOnDiskPath:)``
/// answers — the enclosing members outermost-first — and each enclosing member's inner path goes
/// into the text in its turn, so the temp directory never appears. An archive **on a server** is a
/// temp copy of the whole file, and the chain then opens with the server path it was fetched from;
/// that one is a container rather than a frame (the same distinction `PathBarView.archiveCrumbs`
/// draws), and it is written the way a row on that server would be.
///
/// The ancestry may be the chain of the location's own mount or of any archive nested *inside* it,
/// which is what lets a path-bar crumb in an outer frame use the chain of the innermost mount on
/// screen: the location's frame is the enclosing member whose backend it carries, and the innermost
/// one when it carries none of theirs.
public enum CopyPathText {
    public static func text(for location: VFSPath, archiveAncestry: [VFSPath] = []) -> String {
        guard location.backend.isArchive else { return location.path }
        // A non-archive first link can only be the outermost archive's origin on a server: the map
        // stops walking the moment an origin has no enclosing archive.
        let container = archiveAncestry.first.flatMap { $0.backend.isArchive ? nil : $0 }
        let frames = container == nil ? archiveAncestry : Array(archiveAncestry.dropFirst())
        let depth = frames.firstIndex { $0.backend == location.backend } ?? frames.count

        let outermost = container.map { text(for: $0) }
            ?? frames.first?.backend.archivePath
            ?? location.backend.archivePath
            ?? ""
        let enclosing = frames.prefix(depth).map(\.path).joined()
        return outermost + enclosing + (location.isRoot ? "" : location.path)
    }
}
