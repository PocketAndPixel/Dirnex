import AppKit
import DirnexCore

/// The keyboard and mouse faces of **Places** (PLAN.md §M20 Slice 3) — ⌘G, and the path bar's
/// leading glyph.
///
/// Both drop the *same* menu `PlacesMenu` fills for the menu bar, under this pane's path bar: the
/// list is one definition with three renderings, which is the whole point of the milestone. This is
/// structurally `showFavorites` one level up — Favorites is one section of what this shows — and it
/// lives on the pane for the reason that popup does: the menu is dropped from *this* pane's path
/// bar, and the place has to open in the pane the user was looking at.
extension PanelViewController {
    /// ⌘G — every sidebar destination, under the path bar.
    ///
    /// No field-editor carve-out, and neither has the ⌘F popup beside it since the pair moved off
    /// the ⌃-letter layer: Cocoa's `StandardKeyBinding.dict` binds `^d` to `deleteForward:` — which
    /// is what the old ⌃D favorites chord had to step aside for — while nothing in the text system
    /// claims a ⌘ letter, so both keys can mean one thing everywhere.
    @objc func showPlaces(_ sender: Any?) {
        // The pane the menu is dropped from is the pane the place must open in — `activate(_:)`
        // resolves to the window's *active* panel, and a click on the inactive pane's path-bar
        // glyph arrives without ever moving first responder.
        host?.panelDidBecomeActive(self)
        let menu = PlacesMenu.shared.makeMenu()
        // Drop it from the path bar's bottom edge whatever its flip orientation, as ⌘F does.
        let origin = NSPoint(x: 8, y: pathBar.isFlipped ? pathBar.bounds.maxY : 0)
        menu.popUp(positioning: nil, at: origin, in: pathBar)
    }
}
