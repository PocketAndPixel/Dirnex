import AppKit

/// A scroll view that keeps whatever holds keyboard focus inside it on screen.
///
/// AppKit does not do this for a key-view change. Measured live 2026-09-13 in Get Info ▸ Sharing:
/// Tab walked onto the "folders inherit" and "inherit only" checkboxes below the pane's fold and
/// left the pane where it was, so two presses landed on controls nobody could see — the order was
/// right and the focus was invisible. It only became reachable once Tab could reach checkboxes at
/// all (``KeyboardReachableControls``), which is why nothing had needed it before.
///
/// **It watches its window's first responder rather than being told**, so every way focus arrives —
/// Tab, Shift-Tab, a panel moving focus itself, a text field's field editor taking over — scrolls
/// the same way, with nothing for a caller to remember. A focus change outside this scroll view's
/// document leaves it alone. A field editor is traced back to the field it edits, since the editor
/// itself lives outside the document.
///
/// The focused control is revealed with ``focusMargin`` to spare, so the focus ring AppKit draws
/// outside a control's frame comes on screen with it.
@MainActor
final class FocusFollowingScrollView: NSScrollView {
    /// Room kept around a focused control when it is scrolled into sight.
    static let focusMargin: CGFloat = 8

    private var responderObservation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        responderObservation = window?.observe(\.firstResponder) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.revealFocus() }
        }
    }

    /// Scroll the focused view into sight, if it lives in this scroll view's document.
    func revealFocus() {
        guard let document = documentView,
              let focused = focusedView,
              focused !== document,
              focused.isDescendant(of: document) else { return }
        let margin = Self.focusMargin
        let rect = focused.convert(focused.bounds, to: document).insetBy(dx: -margin, dy: -margin)
        document.scrollToVisible(rect)
    }

    /// The view holding focus, with a field editor traced back to the field it is editing.
    private var focusedView: NSView? {
        let responder = window?.firstResponder
        if let editor = responder as? NSTextView, editor.isFieldEditor,
           let field = editor.delegate as? NSView {
            return field
        }
        return responder as? NSView
    }
}
