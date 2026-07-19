import DirnexCore
import Testing

@testable import Dirnex

/// The app layer's own decisions about size-visualization mode (PLAN.md §M6). What the bytes *mean*
/// is `DirnexCore`'s (`SizeVisualization`, `SizeBar.inkWidth`, `DirectorySizeCache`) and is tested
/// there; the walks and their cache are non-hermetic and are exercised live. What is left — and is
/// here — is the column contract, which is where a second *contextual* column could go wrong: the
/// Git gutter got away with hardcoded bookkeeping precisely because it was the only one.
@Suite("Size bar column")
@MainActor
struct SizeBarColumnTests {
    @Test("the size-bar column is contextual, like the Git gutter and unlike the real columns")
    func contextual() {
        #expect(PanelViewController.Column.sizeBar.isContextual)
        #expect(PanelViewController.Column.git.isContextual)
        for column in [PanelViewController.Column.name, .size, .date] {
            #expect(!column.isContextual)
        }
    }

    @Test("the default layout excludes every contextual column, not just Git")
    func defaultLayoutOmitsContextualColumns() {
        // The reason the mode is free to come and go: a column that never enters a stored layout
        // cannot make toggling it look like the user rearranging their columns — and be persisted
        // as such. This is the assertion that catches a second contextual column leaking in.
        let ids = PanelViewController.defaultColumnLayout.map(\.id)
        #expect(ids == ["name", "size", "date"])
        #expect(!ids.contains(PanelViewController.Column.sizeBar.rawValue))
    }

    @Test("clicking the bar's header sorts by size — the quantity it draws")
    func sortsBySize() {
        // Deliberately *not* nil, unlike the Git gutter: the bar is a picture of size, so the
        // obvious meaning of clicking it is available, and it must agree with the Size header
        // rather than invent a second ordering.
        #expect(PanelViewController.Column.sizeBar.sortKey == .size)
        #expect(
            PanelViewController.Column.sizeBar.sortKey == PanelViewController.Column.size.sortKey
        )
    }

    @Test("the bar column is resizable, unlike the one-letter gutter")
    func resizable() {
        // The gutter is fixed because a letter needs no room to breathe. This column is a chart:
        // how much room it gets changes how much it can say, so the user gets to decide.
        let column = PanelViewController.Column.sizeBar
        #expect(column.minWidth < column.defaultWidth)
    }

    @Test("the bar column is wide enough for a track plus its percentage")
    func widthFitsLabel() {
        // Measured, not guessed: 86 of ~'s 93 rows floor to a stub, so the percentage beside the
        // bar is what actually carries them. A column that cannot fit "100.0%" alongside a track
        // long enough to compare would be a chart that says nothing at either end.
        #expect(PanelViewController.Column.sizeBar.defaultWidth >= 100)
    }
}
