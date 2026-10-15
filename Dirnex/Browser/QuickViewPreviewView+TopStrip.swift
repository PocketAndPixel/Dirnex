import AppKit

/// The strip across the top of the full-screen surface, and why a document starts below it.
///
/// Two things come down over the top of the screen in full screen, and both take the mouse. The
/// floating header fades in at every movement of the pointer and goes on answering clicks once it
/// has faded, since a view at zero alpha is still hit-tested. The system's own title bar drops in
/// under the menu bar when the pointer reaches the top edge, and stays while it is there. Over a
/// photograph neither matters, as there is nothing up there to click. Over a document they cover
/// the first line, which then cannot be selected, and the find bar, which cannot be clicked into.
/// Reported 2026-10-15 on a text file.
///
/// So a document starts below the header's 30 pt, and the strip above it is the surface's backing,
/// where the header and the title bar ride over nothing. The title bar is 32 pt, and its last 2 pt
/// land in the document's own top margin (8 pt for source text) rather than on a line, so 30 was
/// picked over 32 on 2026-10-15. Where the menu bar comes down over the window too, it pushes
/// the title bar down by its own height, and the strip deepens by as much. A picture still runs to
/// the top edge under all of it: a viewing surface that letterboxed a photograph to keep room for
/// chrome it does not need would be giving up the mode's point.
///
/// Decided by what the file *is* rather than by which backend ends up drawing it. Half the routes
/// pick their backend asynchronously (a page is built, a file is read, a converted document lands),
/// and the strip has to be settled before the new file slides in. A file sent on to Quick Look
/// after a read keeps the strip, which costs it nothing.
extension QuickViewPreviewView {
    /// How far below the surface's top edge a document starts. Zero for a picture, and for any
    /// surface without a floating header: a pinned header takes a strip of its own.
    var documentTopClearance: CGFloat {
        guard contentTop != nil, !showsPicture else { return 0 }
        return QuickViewHeaderView.height + menuBarOverlap
    }

    func updateContentTop() {
        contentTop?.constant = documentTopClearance
    }
}
