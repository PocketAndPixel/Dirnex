import AppKit
import DirnexCore

/// View ▸ Zoom In / Zoom Out / Reset Zoom (⌘+, ⌘−, ⌘0) on the Quick View preview (2026-09-14).
///
/// The window's rather than a pane's, for the reason every Quick View command is: at full size the
/// preview is a sibling of the panes, so a pane-hosted selector finds no target the moment somebody
/// clicks into the document. And the keys are menu key equivalents rather than a key monitor's,
/// because a menu item is what makes them discoverable, rebindable and disabled when they would do
/// nothing — which a monitor would have to re-derive, for the same three facts.
extension BrowserWindowController {
    @objc func zoomInQuickView(_ sender: Any?) {
        visibleQuickViewSurface?.zoom(.larger)
    }

    @objc func zoomOutQuickView(_ sender: Any?) {
        visibleQuickViewSurface?.zoom(.smaller)
    }

    @objc func resetQuickViewZoom(_ sender: Any?) {
        visibleQuickViewSurface?.resetZoom()
    }

    /// The one question the three menu items and their actions all ask.
    func canPerformQuickViewZoom(_ action: Selector?) -> Bool {
        guard let surface = visibleQuickViewSurface else { return false }
        switch action {
        case #selector(zoomInQuickView(_:)): return surface.canZoom(.larger)
        case #selector(zoomOutQuickView(_:)): return surface.canZoom(.smaller)
        case #selector(resetQuickViewZoom(_:)): return surface.canResetZoom
        default: return false
        }
    }

    /// The surface the user is looking at: the *other* pane's in pane mode — where the preview of the
    /// focused pane's cursor is drawn — and the full-size one otherwise. `nil` with Quick View off.
    var visibleQuickViewSurface: QuickViewPreviewView? {
        let surface: QuickViewPreviewView? = switch quickViewMode {
        case .off: nil
        case .pane: counterpart(of: focusedPanel).quickViewPreview
        case .fullWindow, .fullScreen: activeFullSizePreview
        }
        guard let surface, !surface.isHidden else { return nil }
        return surface
    }
}
