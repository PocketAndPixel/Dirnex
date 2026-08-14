import AppKit

/// Where the keyboard and the mouse *are* inside a Quick View surface — a separate concept from
/// what that surface draws, and split out of `QuickViewPreviewView` when the placeholder card's
/// second button took the file past SwiftLint's 500-line ceiling.
///
/// The two answers here are opposite halves of one question and are worth reading together: a
/// surface takes the mouse for everything except the few parts that handle it in-process
/// (`isInteractiveQuickViewBackend`), and it is those same parts that can then be holding first
/// responder when a key the file list owns arrives (`hasFocus`).
extension QuickViewPreviewView {
    /// Whether `responder` is focus sitting *inside* one of `surfaces` — the state in which a key
    /// the file list owns has gone to a preview backend instead.
    ///
    /// The in-process backends take first responder the moment the user clicks into one: the text
    /// view to select a line, `PDFView` to scroll a document. From there they consume the arrows the
    /// mode navigates with, which is what `BrowserWindowController`'s key monitor asks this before
    /// undoing. Every surface is offered rather than the current mode's alone — a mode change hides
    /// a surface without moving focus out of it.
    static func hasFocus(_ responder: NSResponder?, among surfaces: [QuickViewPreviewView?]) -> Bool {
        guard let focused = responder as? NSView else { return false }
        return surfaces.contains { surface in
            guard let surface else { return false }
            return focused.isDescendant(of: surface)
        }
    }
}

extension NSView {
    /// Whether this hit belongs to one of the Quick View parts that should keep the mouse — a
    /// backend that handles it in-process, the surface's own header, or one of the placeholder
    /// card's two buttons.
    ///
    /// Internal rather than `private` only because the split above put its one caller in another
    /// file, and Swift's `private` does not cross files (docs/NOTES.md ▸ Lint ceilings).
    func isInteractiveQuickViewBackend(among parts: [NSView?]) -> Bool {
        parts.contains { part in
            guard let part, !part.isHidden else { return false }
            return isDescendant(of: part)
        }
    }
}
