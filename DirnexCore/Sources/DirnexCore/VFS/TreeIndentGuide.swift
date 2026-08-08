import Foundation

/// The indent guide a tree row's ancestry highlights: which level the line is drawn at, and the run
/// of rows it passes through (PLAN.md §M15 Slice 4).
///
/// A tree row draws one vertical line per ancestor — a guide for every level `0..<depth` — and
/// exactly one of them is the *active* one, drawn stronger so the folder the focused row belongs to
/// is legible without counting indentation. This says which, and where it starts and stops.
public struct TreeIndentGuide: Equatable, Sendable {
    /// The depth of the folder whose children the line runs beside. Only rows *deeper* than this
    /// draw a guide at this level at all, which is exactly the run `rows` covers.
    public let level: Int

    /// The rows the highlight covers: the folder's children and everything beneath them. Never the
    /// folder's own row — a row at depth `level` draws guides for `0..<level` and so has no line
    /// here to highlight.
    public let rows: Range<Int>

    public init(level: Int, rows: Range<Int>) {
        self.level = level
        self.rows = rows
    }
}

public extension TreeProjection {
    /// The guide to highlight when the focus — the cursor, or the row under the pointer — is at
    /// `index`.
    ///
    /// The rule is VS Code's, which is the one users arrive with: an **open folder** highlights the
    /// guide its own children stand beside, and everything else — a file, a closed folder — the
    /// guide of the folder it is *in*. So the answer is always "which folder does this row belong
    /// to", and pointing at an open folder answers it for what is about to be read rather than for
    /// where the folder itself lives.
    ///
    /// `nil` when there is no such line, in three cases that are all genuinely nothing to draw: a
    /// depth-0 row (the tree's root has no guide of its own — its children are the leftmost column),
    /// an open folder with no rows under it (empty, unlisted, or every child filtered out), and an
    /// index off the end.
    func activeGuide(forRow index: Int) -> TreeIndentGuide? {
        guard rows.indices.contains(index) else { return nil }
        let row = rows[index]

        // The folder whose children the line belongs to: this row itself when it is open, otherwise
        // this row's parent — the nearest row above it that is shallower, which for a depth-`d` row
        // is necessarily its own depth-`d-1` parent.
        let anchor: Int
        if row.entry.isDirectoryLike, isExpanded(row.entry.id) {
            anchor = index
        } else if let parent = rows[..<index].lastIndex(where: { $0.depth < row.depth }) {
            anchor = parent
        } else {
            return nil
        }

        let level = rows[anchor].depth
        var end = anchor + 1
        while end < rows.count, rows[end].depth > level { end += 1 }
        // An open folder showing nothing: there is no line under it to draw, and answering with an
        // empty range would make every caller check the same thing again.
        guard end > anchor + 1 else { return nil }
        return TreeIndentGuide(level: level, rows: (anchor + 1)..<end)
    }
}
