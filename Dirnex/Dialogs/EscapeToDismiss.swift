import AppKit

/// Escape-to-close helpers for the app's dialogs, so a user is never trapped in a modal surface.
/// The first two ride the standard `performKeyEquivalent(with:)` path — the same one a "Cancel"
/// button's Escape key equivalent uses — so they fire regardless of which control holds focus.
///
/// The SwiftUI-hosted Settings window takes the third, `EscapeToCloseMonitor`, because a hosting
/// view can consume Escape before any of that runs. A **local key monitor runs ahead of responder
/// dispatch entirely** (docs/NOTES.md), so it sees the key whatever SwiftUI would do with it — which
/// is exactly why it then has to hand Escape *back* to the responders that legitimately own it.

/// A container view that dismisses its enclosing sheet when Escape is pressed and nothing focused
/// claims the key first — the reliable way to add Escape-to-close to a sheet that has no Cancel
/// button (e.g. the organizers, which auto-save and only offer "Done"). While a text field is being
/// edited (an inline rename), Escape is left to cancel that edit instead of closing the whole sheet.
final class EscapeDismissingView: NSView {
    /// Invoked when Escape closes the surface. Typically wired to the controller's dismiss/done.
    var onEscape: (() -> Void)?

    /// Close even while a text field holds focus. Default `false` suits a list whose only editing is
    /// a transient inline rename — there, Escape should revert the rename, not close over it. Set
    /// `true` for a sheet built as a *permanent* form (the scripts organizer), where a field owns the
    /// focus nearly the whole time, so bowing out would mean Escape almost never closes at all.
    var dismissesWhileEditing = false

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Let real key-equivalent responders (a Cancel/Done button, an inline field editor) win.
        if super.performKeyEquivalent(with: event) { return true }
        guard event.type == .keyDown,
              event.keyCode == 53,
              event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]),
              let onEscape else { return false }
        // A field editor owns Escape to revert the in-progress edit; don't close over it.
        if !dismissesWhileEditing, window?.firstResponder is NSText { return false }
        onEscape()
        return true
    }
}

/// A responder that owns Escape for itself, so the window-wide monitor must leave it alone.
///
/// A marker rather than a list of class names inside the monitor: the knowledge belongs with the
/// control that wants the key ("Escape cancels *my* recording"), not with the window that would
/// otherwise close over it. Anything added to Settings later opts in the same way.
@MainActor
protocol EscapeKeyConsuming: NSResponder {}

/// Escape-to-close for a window whose content is SwiftUI, where `EscapeDismissingView` cannot reach.
///
/// Scoped to one window and installed only while it is on screen. Three responders keep Escape:
/// a field editor mid-edit (it reverts the edit — the same carve-out `EscapeDismissingView` makes),
/// anything marked ``EscapeKeyConsuming``, and any window that is not this one.
@MainActor
final class EscapeToCloseMonitor {
    private var monitor: Any?

    /// Begin watching for Escape while `window` is key. Idempotent — a second call replaces the
    /// first, so re-presenting a shared window cannot stack monitors.
    func install(for window: NSWindow, onEscape: @escaping () -> Void) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard let window, window.isKeyWindow,
                  event.keyCode == 53,
                  event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift])
            else { return event }
            let focused = window.firstResponder
            if focused is NSText || focused is any EscapeKeyConsuming { return event }
            onEscape()
            return nil // handled — don't also deliver it to the responder chain
        }
    }

    /// Stop watching. Safe to call when nothing is installed.
    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension NSAlert {
    /// Ensure the Escape key dismisses this alert, bound to the choice that loses nothing.
    ///
    /// `NSAlert` does bind Escape itself — but it matches the **byte string "Cancel"**, not a
    /// localized one, so under any translation its binding silently stops happening: probed with the
    /// process pinned to `ru`, a button titled «Отмена» is given no key equivalent at all (and, added
    /// first, is given Return instead). Escape is therefore ours to assign in every language, and it
    /// cannot be assigned by reading a button's *title* for the same reason.
    ///
    /// `safe` names the choice in the vocabulary the caller already reads the result back in. It
    /// defaults to the **last** button, which is where a Cancel belongs and where all but one of
    /// Dirnex's alerts put theirs; pass it explicitly wherever the safe choice sits elsewhere
    /// (`Cancel` added first to make it the rightmost, `OK` ahead of an action button).
    ///
    /// A lone-button alert keeps Return as its button's default and answers Escape through a
    /// zero-size accessory that clicks it — one button can't carry two key equivalents at once.
    /// Call after adding every button and before running the alert.
    func enableEscapeToCancel(safe: NSApplication.ModalResponse? = nil) {
        if buttons.count > 1 {
            let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            let index = safe.map { Int($0.rawValue - first) }
            let named = index.flatMap { buttons.indices.contains($0) ? buttons[$0] : nil }
            guard let target = named ?? buttons.last else { return }
            // AppKit may have put Escape on an English "Cancel" that isn't the button we want, and
            // two buttons answering Escape is undefined — clear before assigning.
            for button in buttons where button !== target && button.keyEquivalent == "\u{1b}" {
                button.keyEquivalent = ""
            }
            target.keyEquivalent = "\u{1b}"
        } else if let only = buttons.first, accessoryView == nil {
            let catcher = EscapeDismissingView()
            catcher.onEscape = { [weak only] in only?.performClick(nil) }
            accessoryView = catcher
        }
    }
}
