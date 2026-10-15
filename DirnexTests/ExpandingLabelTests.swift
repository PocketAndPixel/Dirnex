import AppKit
import Foundation
import Testing

@testable import Dirnex

/// The cell that sizes and draws the panel a file row floats when its column is too narrow for the
/// name (`ExpansionPanel`).
///
/// Presentation, so it is tested here rather than in `DirnexCore`, like `PanelPaletteTests` and
/// `RowDensityTests`. What a headless test *can* reach is the part that fails quietly: the
/// mechanism that installs the custom cell, and the color pushed into it. The drawing itself was
/// verified against the live pane in both appearances — no bitmap here would prove it, since the
/// panel is painted into a window that exists only while it is up.
@Suite("Expansion tooltip")
@MainActor
struct ExpandingLabelTests {
    /// `NSTextField.labelWithString(_:)` is a factory, so whether it honors a subclass's
    /// `cellClass` is AppKit's business rather than ours. Pinned because the whole fix rides on it
    /// and the failure is silent: a stock `NSTextFieldCell` draws a perfectly good panel, in the
    /// colors this cell exists to override.
    @Test("the label's factory installs the cell that owns the panel")
    func labelFactoryKeepsTheCustomCell() {
        let label = ExpandingLabel(labelWithString: "name.txt")
        #expect(label.cell is ExpandingLabelCell)
    }

    /// The padding is added around AppKit's own width at the label's own height, measured against a
    /// stock label of the same string and width. AppKit's frame is a point taller than the label, all
    /// of it below, which hung the panel a point low; the stock height here keeps that visible. The
    /// empty case matters more than the padded one: AppKit answers an empty frame for a value that
    /// fits, and padding that would float a panel over every row.
    @Test("a truncated value floats in a padded panel, and one that fits floats nothing")
    func expansionFrameIsPaddedOnlyWhenTruncated() throws {
        let name = "WestWorld.S01E09.The.Well-Tempered.Clavier.mkv"
        let label = ExpandingLabel(labelWithString: name)
        let stock = NSTextField(labelWithString: name)
        let cell = try #require(label.cell)
        let stockCell = try #require(stock.cell)

        // At its natural height, as the row lays it out: AppKit's extra point is relative to that.
        for field in [label, stock] {
            field.frame = NSRect(x: 0, y: 0, width: 120, height: field.intrinsicContentSize.height)
        }
        let stockFrame = stockCell.expansionFrame(withFrame: stock.bounds, in: stock)
        #expect(!stockFrame.isEmpty)
        #expect(stockFrame.height > stock.bounds.height)
        let padding = ExpandingLabelCell.padding
        let atLabelHeight = NSRect(
            x: stockFrame.minX,
            y: label.bounds.minY,
            width: stockFrame.width,
            height: label.bounds.height
        )
        #expect(
            cell.expansionFrame(withFrame: label.bounds, in: label)
                == atLabelHeight.insetBy(dx: -padding.width, dy: -padding.height)
        )

        label.frame.size.width = 1000
        #expect(cell.expansionFrame(withFrame: label.bounds, in: label).isEmpty)
    }

    /// Every column floats a truncated value through the custom cell — a Date narrowed past its
    /// content truncates the same way a name does — and none through AppKit's own tooltip, whose
    /// panel looks different from the ⌘ hold's (`ExpansionPanel`). Both at once would float two.
    @Test("every file cell floats through the custom cell, never AppKit's own tooltip")
    func fileCellsUseTheCustomPanel() {
        for showsImage in [true, false] {
            let cell = FileCellView(
                showsImage: showsImage,
                identifier: NSUserInterfaceItemIdentifier("test")
            )
            let field = try? #require(cell.textField)
            #expect(field is ExpandingLabel)
            #expect(field?.cell is ExpandingLabelCell)
            #expect(field?.allowsExpansionToolTips == false)
        }
    }

    /// The regression that would put the bug back. The panel is filled with
    /// `.textBackgroundColor` and knows nothing of the cursor's fill, so the ink it is handed must
    /// be the row's **resting** color — not `PanelPalette.cursorForeground`, which is derived from
    /// that fill and, for a pale cursor color, is black on a dark panel.
    ///
    /// Asserted on an *emphasized* cell specifically: on an ordinary row the two colors coincide,
    /// so a cell that pushed the wrong one would pass anyway.
    @Test("the cursor row floats its resting color, not the cursor's foreground")
    func emphasizedRowPushesTheRestingInk() throws {
        let cell = FileCellView(showsImage: true, identifier: NSUserInterfaceItemIdentifier("name"))
        // A pale cursor color is what makes the two colors differ enough to tell apart: the
        // derived foreground goes black, where the resting color stays `.labelColor`.
        let paleYellow = NSColor(srgbRed: 0.96, green: 0.89, blue: 0.48, alpha: 1)
        cell.palette = PanelPalette(cursor: paleYellow)
        cell.backgroundStyle = .emphasized
        cell.applyStyle()

        let labelCell = try #require(cell.textField?.cell as? ExpandingLabelCell)
        #expect(cell.textField?.textColor == cell.palette.cursorForeground)
        #expect(labelCell.expansionInk == .labelColor)
        #expect(labelCell.expansionInk != cell.palette.cursorForeground)
    }

    /// The mark and a file-type rule are both authored against `.textBackgroundColor` — what the
    /// panel is filled with — so they travel into it unchanged rather than being neutralized.
    /// Marked *and* the cursor is the case that decides it: the ink follows the mark even though
    /// the row's own text is drawn in the cursor's foreground.
    @Test("a marked or type-colored name keeps its color in the panel")
    func restingInkFollowsMarkAndTypeColor() throws {
        let cell = FileCellView(showsImage: true, identifier: NSUserInterfaceItemIdentifier("name"))
        let labelCell = try #require(cell.textField?.cell as? ExpandingLabelCell)

        cell.typeColor = .systemTeal
        cell.applyStyle()
        #expect(labelCell.expansionInk == .systemTeal)

        cell.marked = true
        cell.backgroundStyle = .emphasized
        cell.applyStyle()
        #expect(labelCell.expansionInk == cell.palette.resolvedMark)

        // And it is re-pushed on every style pass — cells come out of a reuse pool, so a stale ink
        // would float the previous row's color over this name.
        cell.marked = false
        cell.typeColor = nil
        cell.applyStyle()
        #expect(labelCell.expansionInk == .labelColor)
    }
}
