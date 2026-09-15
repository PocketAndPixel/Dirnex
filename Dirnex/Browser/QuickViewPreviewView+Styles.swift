import Foundation

/// Which files Quick View can draw two ways, and which family each belongs to — split out of
/// `QuickViewPreviewView` when JSON became the third family and the class reached SwiftLint's body
/// ceiling (2026-09-15).
extension QuickViewPreviewView {
    /// Whether `url` is a file Quick View can honestly draw two ways — the one predicate behind the
    /// `1` / `2` keys, the header's hint, and the routing in `show` (PLAN.md §M18 ▸ Slice 3).
    ///
    /// One place, deliberately. Until this milestone the same question was spelled `isRenderableHTML`
    /// at three sites, and adding a second dual-style type meant finding all three by hand with the
    /// compiler checking none of them — the trap docs/NOTES.md names for a new VFS backend, in a
    /// different shape. The failure available here is quiet: `2` doing nothing on a `.md` while the
    /// header says it should, or the digit being swallowed on a file that has one rendering.
    static func offersBothStyles(_ url: URL) -> Bool {
        dualStyleKind(of: url) != nil
    }

    /// Which family of dual-style file `url` is, which names its rendered style and decides which
    /// remembered choice it follows — `nil` for a file with one rendering.
    static func dualStyleKind(of url: URL) -> QuickViewDualStyleKind? {
        if isDelimitedTable(url) { return .table }
        if isJSON(url) { return .json }
        return isRenderableHTML(url) || isRenderableMarkdown(url) ? .page : nil
    }
}
