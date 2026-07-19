import Foundation
import Testing

@testable import DirnexCore

/// `SizeBar.inkWidth` — the minimum-ink rule.
///
/// Split from `SizeVisualizationTests` (which is at its type-body limit) along the seam the two
/// actually have: that suite covers the *directory-wide* projection — the two denominators, what is
/// visible, what is still pending — while this one covers a *single bar's* projection onto a column
/// of a given width. The `PanelSizeTests` split in pass 9 set the precedent.
@Suite("SizeBar ink")
struct SizeBarTests {
    private func bar(bytes: Int64, fraction: Double, share: Double = 0) -> SizeBar {
        SizeBar(bytes: bytes, fraction: fraction, share: share)
    }

    // MARK: - The floor

    @Test("a row with bytes never draws nothing, however small its fraction")
    func tinyRowStillDrawsInk() {
        // The measured worst case: ~'s smallest dotfiles against a 1 TB Movies. Their fraction
        // rounds to zero at six decimal places, and at an 80 pt bar they compute to 0.000 pt.
        let sliver = bar(bytes: 4096, fraction: 0.000_000_4)
        #expect(sliver.inkWidth(in: 80, minimum: 2) == 2)
    }

    @Test("the measured 17 GB folder beside a 1 TB one draws its floor, not nothing")
    func realWorldSliverDrawsFloor() {
        // Dev: 16,981 MB against Movies' 1,027,840 MB — fraction 0.0165, which is 1.32 pt at an
        // 80 pt bar. Real, and under the floor.
        let dev = bar(bytes: 16981 * 1_048_576, fraction: 0.016_526)
        #expect(dev.inkWidth(in: 80, minimum: 2) == 2)
    }

    @Test("zero bytes draws zero ink — empty is not negligible")
    func emptyDirectoryDrawsNothing() {
        // The one row for which nothing *is* the honest picture, and the reason the floor keys off
        // bytes rather than off fraction.
        #expect(bar(bytes: 0, fraction: 0).inkWidth(in: 80, minimum: 2) == 0)
    }

    @Test("a negative total cannot conjure ink")
    func negativeBytesDrawNothing() {
        // SFTPListingParser builds sizes out of text; nothing downstream may trust the sign.
        #expect(bar(bytes: -5, fraction: 0.5).inkWidth(in: 80, minimum: 2) == 0)
    }

    // MARK: - The proportion

    @Test("above the floor the bar is strictly proportional to its fraction")
    func proportionalAboveTheFloor() {
        #expect(bar(bytes: 100, fraction: 0.5).inkWidth(in: 80, minimum: 2) == 40)
        #expect(bar(bytes: 100, fraction: 0.25).inkWidth(in: 80, minimum: 2) == 20)
        // The heaviest row always fills the column — that is what `fraction`'s denominator is for.
        #expect(bar(bytes: 100, fraction: 1.0).inkWidth(in: 80, minimum: 2) == 80)
    }

    @Test("ink never exceeds the column, even if a fraction arrives out of range")
    func inkIsClampedToTheColumn() {
        #expect(bar(bytes: 100, fraction: 1.5).inkWidth(in: 80, minimum: 2) == 80)
    }

    @Test("the floor yields to an even narrower column rather than overflowing it")
    func floorNeverOverflowsANarrowColumn() {
        // A pane dragged down to a sliver of a column must not draw a 2 pt bar in 1 pt of space.
        #expect(bar(bytes: 100, fraction: 0.000_1).inkWidth(in: 1, minimum: 2) == 1)
    }

    @Test("a zero-width column draws nothing at all")
    func zeroWidthColumnDrawsNothing() {
        #expect(bar(bytes: 100, fraction: 1.0).inkWidth(in: 0, minimum: 2) == 0)
    }

    // MARK: - What the floor costs, stated honestly

    @Test("the floor compresses the tail: distinct tiny rows become indistinguishable")
    func flooredRowsAreIndistinguishable() {
        // The accepted, documented price. A row 400x heavier than another draws the same stub once
        // both are under the floor — which reads correctly as "both are noise", and the size column
        // beside them carries the actual difference. This is pinned as a test because it is a
        // deliberate trade, not an oversight: anyone tempted to "fix" it with a log scale should
        // have to delete an assertion that says so.
        let small = bar(bytes: 1000, fraction: 0.000_01)
        let smaller = bar(bytes: 4, fraction: 0.000_000_025)
        #expect(small.inkWidth(in: 80, minimum: 2) == smaller.inkWidth(in: 80, minimum: 2))
    }
}
