import AppKit
import Foundation
import Testing

@testable import Dirnex

/// The panel that floats a truncated value whole, shared by the hover and the ⌘ hold.
///
/// What it looks like on screen was compared live against AppKit's own panel; no bitmap here would
/// prove it. What a test can reach is what the panel is handed to draw, which gesture owns it, and
/// whether it still counts as the right panel once a reload has replaced the row's cell.
@Suite("Expansion panel")
@MainActor
struct ExpansionPanelTests {
    static let longName = ExpansionTableFixture.longName

    /// The panel draws a copy, not the row's own cell, and the copy has to carry what the panel
    /// draws: the name, the font (bold for a marked row) and the resting ink rather than the cursor's.
    @Test("the floated copy carries the name, the font and the resting ink")
    func snapshotCarriesWhatThePanelDraws() throws {
        let cell = FileCellView(showsImage: true, identifier: NSUserInterfaceItemIdentifier("name"))
        cell.textField?.stringValue = Self.longName
        cell.marked = true
        cell.backgroundStyle = .emphasized
        cell.applyStyle()
        let label = try #require(cell.textField)

        let copy = ExpansionPanel.snapshot(of: label)
        #expect(copy.stringValue == Self.longName)
        #expect(copy.font == label.font)
        #expect(copy.expansionInk == cell.palette.resolvedMark)
        #expect(copy !== label.cell)
    }

    /// Releasing ⌘ must not take down a hover's panel, and the pointer leaving a value must not take
    /// down the hold's. Both directions, each with the case where the owner does take it down.
    @Test("each gesture takes down only its own panel")
    func eachGestureHidesOnlyItsOwn() throws {
        let fixture = ExpansionTableFixture(names: [Self.longName])
        defer { ExpansionPanel.hide() }
        let label = try #require(fixture.label(atRow: 0))

        #expect(ExpansionPanel.show(over: label, for: .hover))
        CursorNamePeek.hide()
        #expect(ExpansionPanel.owner == .hover)
        HoverExpansion.cancel()
        #expect(ExpansionPanel.shownPanel == nil)

        #expect(ExpansionPanel.show(over: label, for: .commandHold))
        HoverExpansion.cancel()
        #expect(ExpansionPanel.owner == .commandHold)
        CursorNamePeek.hide()
        #expect(ExpansionPanel.shownPanel == nil)
    }

    @Test("a value that fits leaves the panel already up alone")
    func fittingValueLeavesThePanel() throws {
        let fixture = ExpansionTableFixture(names: [Self.longName, "a.txt"])
        defer { ExpansionPanel.hide() }
        let long = try #require(fixture.label(atRow: 0))
        let short = try #require(fixture.label(atRow: 1))

        #expect(ExpansionPanel.show(over: long, for: .hover))
        #expect(!ExpansionPanel.show(over: short, for: .commandHold))
        #expect(ExpansionPanel.owner == .hover)
        #expect(ExpansionPanel.isShowing(long))
    }

    /// The pane reloads under a still pointer whenever its directory changes, and every row gets a
    /// new cell view. The same name in the same place is still the panel's row; a different name is not.
    @Test("a reload that hands the row a new cell keeps the panel for the same name")
    func reloadKeepsThePanelForTheSameName() throws {
        let fixture = ExpansionTableFixture(names: [Self.longName, Self.longName + ".part"])
        defer { ExpansionPanel.hide() }
        let before = try #require(fixture.label(atRow: 0))
        #expect(ExpansionPanel.show(over: before, for: .hover))

        fixture.settle()
        let after = try #require(fixture.label(atRow: 0))
        try #require(after !== before, "the reload has to replace the cell, or this proves nothing")
        #expect(ExpansionPanel.isShowing(after))
        #expect(!ExpansionPanel.isShowing(try #require(fixture.label(atRow: 1))))
    }

    /// The floated text has to land exactly on the row's own, or the name visibly drops a point when
    /// the panel comes up, and the panel has to sit evenly around it. Measured by ink, at a fixed 2×
    /// and composited over white for both: drawn into an unflipped view, the panel's text sat 1 pt
    /// below the row's at both of the pane's fonts, and AppKit's taller frame left 3 pt of panel below
    /// the label against 2 above.
    @Test("the floated text lands on the row's own text, in an even panel", arguments: [false, true])
    func floatedTextLandsOnTheRowText(bold: Bool) throws {
        let fixture = ExpansionTableFixture(names: [Self.longName])
        defer { ExpansionPanel.hide() }
        let label = try #require(fixture.label(atRow: 0))
        // Light, whatever the Mac is set to: the measurement looks for dark ink on a light panel.
        fixture.window.appearance = NSAppearance(named: .aqua)
        let size = NSFont.systemFontSize
        label.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        fixture.window.displayIfNeeded()

        #expect(ExpansionPanel.show(over: label, for: .hover))
        let panel = try #require(ExpansionPanel.shownPanel)
        let content = try #require(panel.contentView)
        let labelOnScreen = fixture.window.convertToScreen(label.convert(label.bounds, to: nil))
        let rowInk = try #require(Self.inkDepth(of: label))
        let panelInk = try #require(Self.inkDepth(of: content))
        #expect(labelOnScreen.maxY - rowInk == panel.frame.maxY - panelInk)

        let padding = ExpandingLabelCell.padding
        #expect(panel.frame.maxY - labelOnScreen.maxY == padding.height)
        #expect(labelOnScreen.minY - panel.frame.minY == padding.height)
    }

    /// How far below `view`'s top edge its first dark pixel row is, in points, rendered at 2× over
    /// white whatever the screen is.
    private static func inkDepth(of view: NSView) -> CGFloat? {
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width * scale),
            pixelsHigh: Int(view.bounds.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        for row in 0..<rep.pixelsHigh {
            for column in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { continue }
                let alpha = color.alphaComponent
                let channels = color.redComponent + color.greenComponent + color.blueComponent
                if channels * alpha + 3 * (1 - alpha) < 1.5 { return CGFloat(row) / scale }
            }
        }
        return nil
    }
}
