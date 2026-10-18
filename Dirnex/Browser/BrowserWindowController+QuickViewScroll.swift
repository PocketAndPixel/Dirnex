import AppKit
import DirnexCore

/// ⇧↑ / ⇧↓, ⇧Page Up / ⇧Page Down and ⇧← / ⇧→ on a Quick View preview (2026-10-18): scrolling the
/// document while the cursor stays in the file list.
///
/// The keys arrive from the focused pane's `FileTableView`, not from a menu item or the Quick View key
/// monitor, and that is the design. A menu key equivalent is searched before a field editor's
/// `keyDown:`, so ⇧-arrows bound there would stop extending the selection in every text field in the
/// app (docs/NOTES.md ▸ Key equivalents). The monitor runs whatever holds focus, which is wrong the
/// other way: a click into the preview's text hands it the focus precisely so ⇧-arrows can extend
/// *that* selection (docs/NOTES.md ▸ Keyboard focus, "bare arrows only"). The file table is exactly where these keys mean "scroll", so the
/// table is where they are caught.
extension BrowserWindowController {
    func scrollQuickView(_ move: QuickViewScroll) -> Bool {
        guard let surface = visibleQuickViewSurface else { return false }
        surface.scrollContent(move)
        return true
    }
}
