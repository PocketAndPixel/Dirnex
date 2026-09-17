import AppKit
import Quartz

/// Quick View's `QLPreviewView` backend: everything none of the in-process backends claims — a
/// binary, a font, a movie, an archive. Split from `QuickViewPreviewView` when the PDF backend
/// gained a find bar and took the class past SwiftLint's `type_body_length`, and split this way
/// because every other backend already lives in a file of its own.
///
/// It is the fallback rather than the default, and each in-process backend exists because of
/// something this one cannot do: Quick Look renders out of process, so the surface has to swallow
/// the mouse on its behalf (a click it declines is re-dispatched to the file table underneath —
/// docs/NOTES.md), which costs scrolling, selection and zoom. It is also the one surface View ▸
/// Filter cannot offer to find in, for the same reason: its text is in another process.
extension QuickViewPreviewView {
    /// Show `url` in the Quick Look backend, standing the others down.
    /// Internal: `QuickViewPreviewView+Text` falls back here for a file that isn't text after all.
    func showQuickLook(_ url: URL?) {
        guard let preview = ensureQuickLookPreview() else { return }
        standDownPDF()
        standDownImage()
        standDownText()
        standDownWeb()
        preview.isHidden = false
        preview.previewItem = url as NSURL?
    }

    // The stand-downs are internal for the same reason `showQuickLook` is: the text backend lives in
    // its own file and has to put the others away when it takes the surface.

    func standDownQuickLook() {
        previewView?.isHidden = true
        previewView?.previewItem = nil
    }

    /// Build the Quick Look backend on first use. `.compact` style drops Quick Look's
    /// title/controls chrome, which suits an always-on embedded preview. `init(frame:style:)` is
    /// failable, so this returns `nil` on the rare miss and the caller shows nothing.
    private func ensureQuickLookPreview() -> QLPreviewView? {
        if let preview = previewView { return preview }
        guard let preview = QLPreviewView(frame: .zero, style: .compact) else { return nil }
        // Closes automatically when the window goes away; this surface lives as long as the
        // window, so there is nothing to tear down by hand.
        preview.shouldCloseWithWindow = true
        pin(preview, inside: content)
        previewView = preview
        return preview
    }
}
