import AppKit
import Foundation
import Testing

@testable import Dirnex

/// The sidebar's half of the user's palette (PLAN.md §M15 Slice 2) — split out of
/// `PanelPaletteTests` when it grew a second pushed colour, because the sidebar's row is the one
/// surface that has to serve *three* selection states rather than the panes' two.
///
/// The claim worth pinning is the split itself: the glyph carries the cursor colour and the label
/// does not, so an install with a colour set draws the same text an untouched one does.
@Suite("Sidebar palette")
@MainActor
struct SidebarPaletteTests {
    /// The sidebar's row is the pane's row with one extra state to serve. A source list draws its
    /// *unfocused* selection's glyph in the accent — that is the second place the cursor colour
    /// belongs — and the cell cannot work it out for itself, since `backgroundStyle` reads `.normal`
    /// for a selected-but-unfocused row exactly as it does for an ordinary one. So the push from the
    /// row view is the mechanism, and this is what pins it.
    @Test("the sidebar row hands its cell a glyph foreground for each selection state")
    func sidebarRowPushesTheForeground() {
        let row = SidebarRowView()
        let cell = SidebarCellView()
        row.addSubview(cell)

        // Untouched: nothing of ours reaches the cell, so AppKit keeps drawing what it always drew.
        row.isSelected = true
        row.isEmphasized = true
        #expect(cell.glyphForeground == nil)

        // The cursor: derived against the fill, like the pane's own row.
        row.cursorColor = .systemYellow
        #expect(cell.glyphForeground == .black)

        // Focus moved to a pane — the row keeps AppKit's grey pill and takes the colour into its
        // glyph, which is what the accent was doing there before.
        row.isEmphasized = false
        #expect(cell.glyphForeground == .systemYellow)

        // An ordinary row is never tinted, whatever the palette says.
        row.isSelected = false
        #expect(cell.glyphForeground == nil)
    }

    /// The label is the half the palette deliberately does *not* own. On the filled pill it has to
    /// take a legible foreground — that colour is derived from the cursor, not the cursor itself —
    /// and in every other state it is left to AppKit, so the sidebar's text reads identically whether
    /// or not a colour is set. That is the whole distinction between the two pushed values.
    @Test("the sidebar label takes a colour only on the filled pill, never the cursor's own")
    func sidebarLabelStaysOutOfThePalette() {
        let row = SidebarRowView()
        let cell = SidebarCellView()
        row.addSubview(cell)
        row.cursorColor = .systemYellow

        // The cursor row: the fill is the cursor colour, so the name needs the derived foreground.
        row.isSelected = true
        row.isEmphasized = true
        #expect(cell.labelForeground == .black)
        #expect(cell.textField?.textColor == .black)

        // Focus moved to a pane: the glyph keeps the colour, the name hands back to AppKit.
        row.isEmphasized = false
        #expect(cell.glyphForeground == .systemYellow)
        #expect(cell.labelForeground == nil)

        row.isSelected = false
        #expect(cell.labelForeground == nil)
    }

    /// The glyph beside the label, which is the half that cannot go through `contentTintColor`: an
    /// emphasized `NSTableCellView` draws a *template* image white whatever tint the image view
    /// carries (probed), so a pale cursor colour left a white house next to a black name. The tell
    /// that the colour was baked in rather than requested is that the image stops being a template.
    @Test("a tinted sidebar glyph stops being a template, and an untinted one is untouched")
    func sidebarGlyphIsBakedNotTinted() throws {
        let cell = SidebarCellView()
        let glyph = SidebarViewController.templateSymbol("house", pointSize: 15)
        cell.configure(name: "Home", image: glyph, canEject: false, tooltip: nil)

        // Untouched: the very image the row builder handed over, template and all.
        #expect(cell.imageView?.image === glyph)
        #expect(try #require(cell.imageView?.image).isTemplate)

        cell.glyphForeground = .black
        let tinted = try #require(cell.imageView?.image)
        #expect(tinted !== glyph)
        #expect(!tinted.isTemplate)
        #expect(tinted.size == glyph.size)

        // Back to Follow System: the original, not a tinted copy of a tinted copy.
        cell.glyphForeground = nil
        #expect(cell.imageView?.image === glyph)
    }
}
