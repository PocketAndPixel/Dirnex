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
    /// Ensure Escape **and** Return both answer this alert, with Escape bound to the choice that
    /// loses nothing.
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
    /// **Return is half the job, and it was the half missing.** A button cannot carry two key
    /// equivalents, so which key can live on the safe button depends on whether anything *else*
    /// answers Return — and when the safe choice occupies the default (first-added, rightmost) slot,
    /// nothing does. Measured on a live sheet 2026-08-20: `Cancel` added first comes back
    /// `Cancel[⎋] Trust[—]` with **`defaultButtonCell == nil`**, so Return and keypad Enter both fall
    /// through to the beep — and the control run with this method removed behaves identically, so it
    /// is AppKit's doing rather than ours. Hence the split below: Escape rides the safe button only
    /// while some other button is the default, and otherwise the safe button *is* the default and
    /// Escape rides ``EscapeDismissingView`` instead.
    ///
    /// The catcher goes in the alert window's own content view rather than the `accessoryView` slot,
    /// which is what makes this independent of when it is called. The slot version could not serve an
    /// alert that has a real accessory at all: with one button and an accessory the old method was a
    /// **no-op in both call orders** — `accessoryView == nil` fails when the accessory is set first,
    /// and the caller's own assignment throws the catcher away when it is set second. That is what
    /// left the three progress sheets (remote download, iCloud download, search) with no Escape at
    /// all — measured `performKeyEquivalent(⎋) == false`, sheet not dismissed. Realising `window`
    /// early is free: probed both orders, the alert lays out to the same 292×170 pt with the accessory
    /// on screen and inside the content bounds either way.
    ///
    /// Call after adding every button; the accessory may be set before or after.
    func enableEscapeToCancel(safe: NSApplication.ModalResponse? = nil) {
        guard let target = safeButton(named: safe) else { return }
        // AppKit may have put Escape on an English "Cancel" that isn't the button we want, and two
        // buttons answering Escape is undefined — clear before assigning.
        for button in buttons where button !== target && button.keyEquivalent == "\u{1b}" {
            button.keyEquivalent = ""
        }
        if buttons.contains(where: { $0 !== target && $0.keyEquivalent == "\r" }) {
            // Another button is the default and answers Return, so Escape can ride the safe one.
            // The ordinary confirmation (`Delete[⏎] Cancel[⎋]`) takes this branch and is unchanged.
            target.keyEquivalent = "\u{1b}"
        } else {
            // Nothing else answers Return — a lone-button alert, or one whose safe choice sits in the
            // default slot. Either way the safe choice is the right default, so it takes Return and
            // Escape goes to the catcher.
            target.keyEquivalent = "\r"
            installEscapeCatcher(clicking: target)
        }
    }

    /// The button `safe` names, or the last one — where a Cancel belongs.
    private func safeButton(named safe: NSApplication.ModalResponse?) -> NSButton? {
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let index = safe.map { Int($0.rawValue - first) }
        let named = index.flatMap { buttons.indices.contains($0) ? buttons[$0] : nil }
        return named ?? buttons.last
    }

    /// Give Escape to a zero-size responder in the alert's own content view, clicking `button`.
    ///
    /// Idempotent: a second call replaces the first, so an alert cannot end up with two catchers
    /// answering for different buttons.
    private func installEscapeCatcher(clicking button: NSButton) {
        guard let content = window.contentView else { return }
        for existing in content.subviews where existing is EscapeDismissingView {
            existing.removeFromSuperview()
        }
        let catcher = EscapeDismissingView(frame: .zero)
        // A field editor does not eat a button's Escape key equivalent (docs/NOTES.md), so the
        // button branch answers even with an accessory field focused; matching that here keeps the
        // two branches from differing on an alert that later grows a text field.
        catcher.dismissesWhileEditing = true
        catcher.onEscape = { [weak button] in button?.performClick(nil) }
        content.addSubview(catcher)
    }
}
