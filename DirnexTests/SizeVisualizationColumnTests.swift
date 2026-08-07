import DirnexCore
import Testing

@testable import Dirnex

/// The app layer's own decisions about size-visualization mode (PLAN.md §M6). What the bytes *mean*
/// is `DirnexCore`'s (`SizeVisualization`, `SizeBar.inkWidth`, `DirectorySizeCache`) and is tested
/// there; the walks and their cache are non-hermetic and are exercised live. What is left — and is
/// here — is the column contract, which is where a *contextual* column can go wrong: the Git gutter
/// got away with hardcoded bookkeeping precisely because it was the only one, and adding this column
/// beside it is what exposed that. The bar has since outlived the gutter — Git's status is a badge in
/// the name cell now (`GitBadgeView`) — so this is the only contextual column left.
@Suite("Size bar column")
@MainActor
struct SizeBarColumnTests {
    @Test("the size-bar column is contextual and the real columns are not")
    func contextual() {
        #expect(PanelViewController.Column.sizeBar.isContextual)
        for column in [PanelViewController.Column.name, .size, .date] {
            #expect(!column.isContextual)
        }
    }

    @Test("the default layout excludes every contextual column")
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
        // Deliberately *not* nil, unlike the Git gutter that used to sit beside it: the bar is a
        // picture of size, so the obvious meaning of clicking it is available, and it must agree with the Size header
        // rather than invent a second ordering.
        #expect(PanelViewController.Column.sizeBar.sortKey == .size)
        #expect(
            PanelViewController.Column.sizeBar.sortKey == PanelViewController.Column.size.sortKey
        )
    }

    @Test("the bar column is resizable")
    func resizable() {
        // This column is a chart:
        // how much room it gets changes how much it can say, so the user gets to decide.
        let column = PanelViewController.Column.sizeBar
        #expect(column.minWidth < column.defaultWidth)
    }

    @Test("the bar column still fits a track beside its percentage in the modes that show one")
    func widthFitsLabel() {
        // The column now defaults to the bar alone (`SizeVizDisplayMode.bar`), which reserves no
        // label — so its default width was narrowed to 0.7 of the old 120 pt = 84. That still clears
        // "100.0%" beside a comparable track for the Percentage and Both modes; below ~80 the track
        // would be shorter than the label and the bar would stop being a comparison, which is the
        // floor `minWidth` holds.
        #expect(PanelViewController.Column.sizeBar.defaultWidth == 84)
        #expect(PanelViewController.Column.sizeBar.minWidth >= 80)
    }
}
