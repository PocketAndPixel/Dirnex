import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The tree's indent guides as they are actually drawn (PLAN.md §M15 Slice 4) — which columns carry
/// ink, and whether the active line is genuinely stronger than the rest.
///
/// **These read the rendered bitmap rather than the properties**, because the properties were never
/// in doubt: what a screenshot cannot settle is whether a 1 pt hairline landed where it should and
/// whether the two grays are distinguishable at all. docs/NOTES.md records the same class of bug
/// being called *fixed* off a computer-use screenshot when the ink was provably the wrong color —
/// the capture is downsampled below 1×, so a couple of points of ink is not resolvable. A bitmap is.
@Suite("Tree indent guides — rendering")
@MainActor
struct TreeIndentGuideRenderingTests {
    private func cell(depth: Int, active: Int?, tree: Bool = true) -> FileCellView {
        let view = FileCellView(showsImage: true, identifier: NSUserInterfaceItemIdentifier("name"))
        // A light appearance so the two label grays resolve to something; the assertions are all
        // relative, so they hold in either.
        view.appearance = NSAppearance(named: .aqua)
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 22)
        view.isTreeRow = tree
        view.treeDepth = depth
        view.activeTreeGuideLevel = active
        view.applyTreeLayout()
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// The strongest alpha found in each 1 pt column of the rendered cell. The bitmap starts fully
    /// transparent (a cell paints no background of its own), so any alpha at all is ink the guides
    /// put there — and its *value* is the color's own alpha, which is what makes "is the active one
    /// stronger" a measurable question rather than an opinion.
    ///
    /// Iterates the rep's own pixel dimensions, not point space: in a window the rep comes back at
    /// the backing scale, and a point-space scan silently reads the wrong columns.
    private func inkByColumn(_ view: FileCellView) -> [Int: CGFloat] {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [:] }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        var ink: [Int: CGFloat] = [:]
        for px in 0..<rep.pixelsWide {
            let column = Int((CGFloat(px) / scale).rounded(.down))
            for py in 0..<rep.pixelsHigh {
                guard let alpha = rep.colorAt(x: px, y: py)?.alphaComponent, alpha > 0.01 else { continue }
                ink[column] = max(ink[column] ?? 0, alpha)
            }
        }
        return ink
    }

    private func column(_ level: Int) -> Int {
        Int(FileCellView.treeGuideX(forLevel: level))
    }

    // MARK: - Where the lines land

    @Test("a row draws one guide per ancestor level and none of its own")
    func oneGuidePerAncestor() {
        let ink = inkByColumn(cell(depth: 3, active: nil))
        for level in 0..<3 {
            #expect(ink[column(level)] != nil, "no ink in the level-\(level) guide column")
        }
        // The row's *own* level is where its disclosure triangle goes, not a line: nothing there.
        #expect(ink[column(3)] == nil)
    }

    @Test("the guides sit one indent apart, centered on each ancestor's disclosure slot")
    func guideSpacing() {
        // The arithmetic the drawing and `TreeProjection`'s levels have to agree on.
        #expect(column(1) - column(0) == Int(FileCellView.treeIndentPerLevel))
        #expect(column(2) - column(1) == Int(FileCellView.treeIndentPerLevel))
        // Centered in the slot the ancestor's chevron occupies, within the half point the rounding
        // to a whole (crisp) point can cost.
        let slotCenter = FileCellView.treeLeadingInset + FileCellView.treeDisclosureSlot / 2
        #expect(abs(CGFloat(column(0)) + FileCellView.treeGuideWidth / 2 - slotCenter) <= 0.5)
    }

    @Test("a depth-0 row draws nothing, and neither does a list-mode row")
    func nothingToDraw() {
        #expect(inkByColumn(cell(depth: 0, active: nil)).isEmpty)
        // A cell recycled out of a tree keeps its depth until the render resets it; `isTreeRow`
        // alone must be enough to stop the drawing, or list mode would inherit the last tree's lines.
        #expect(inkByColumn(cell(depth: 3, active: 1, tree: false)).isEmpty)
    }

    // MARK: - Whether the highlight is visible

    /// The assertion a screenshot could not make. Both grays are faint by design, so "the active one
    /// is stronger" is a claim about a difference of a few percent of alpha — invisible in a
    /// downsampled capture and unmissable here.
    @Test("the active guide is drawn stronger than the inactive ones")
    func activeIsStronger() {
        let ink = inkByColumn(cell(depth: 3, active: 1))
        let active = try? #require(ink[column(1)])
        let inactive = try? #require(ink[column(0)])
        #expect((active ?? 0) > (inactive ?? 1))
        // …and the *other* inactive line matches the first, so only one level is ever highlighted.
        #expect(ink[column(2)] == inactive)
    }

    @Test("moving the highlight moves which column is strongest, not how many are drawn")
    func highlightMoves() {
        let atZero = inkByColumn(cell(depth: 3, active: 0))
        let atTwo = inkByColumn(cell(depth: 3, active: 2))
        #expect(atZero.keys.sorted() == atTwo.keys.sorted())
        #expect((atZero[column(0)] ?? 0) > (atZero[column(2)] ?? 1))
        #expect((atTwo[column(2)] ?? 0) > (atTwo[column(0)] ?? 1))
    }

    @Test("a level outside the row's own depth highlights nothing on it")
    func highlightBeyondDepth() {
        // A row shallower than the guide's level is not in the guide's run — the projection never
        // asks for this, and the drawing must not invent a line to satisfy it.
        let ink = inkByColumn(cell(depth: 2, active: 5))
        #expect(ink.keys.sorted() == [column(0), column(1)].sorted())
        #expect(ink[column(0)] == ink[column(1)])
    }
}
