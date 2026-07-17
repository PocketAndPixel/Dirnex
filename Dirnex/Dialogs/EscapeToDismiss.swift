import AppKit

/// Escape-to-close helpers for the app's AppKit dialogs, so a user is never trapped in a modal
/// surface. Both ride the standard `performKeyEquivalent(with:)` path — the same one a "Cancel"
/// button's Escape key equivalent uses — so they fire regardless of which control holds focus.
///
/// The SwiftUI-hosted Settings window is deliberately out of scope: its hosting view swallows Escape
/// before any AppKit handler can see it, so it keeps the standard ⌘W / red-button close.

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

extension NSAlert {
    /// Ensure the Escape key dismisses this alert. `NSAlert` already binds Escape to a button titled
    /// "Cancel"; this fills the gaps. A multi-button alert with no Cancel (Retry/Skip/Abort,
    /// Remove/Keep) gets Escape bound to its safest choice. A lone "OK" alert keeps Return as its
    /// button's default and answers Escape through a zero-size accessory that clicks the button —
    /// the button can't carry two key equivalents at once. Call after adding every button and before
    /// running the alert.
    func enableEscapeToCancel() {
        // A button already answers Escape (an NSAlert "Cancel") — nothing to add.
        guard !buttons.contains(where: { $0.keyEquivalent == "\u{1b}" }) else { return }
        if buttons.count > 1 {
            let safeTitles: Set<String> = [
                "Cancel",
                "Keep",
                "Abort",
                "No",
                "Don't Save",
                "Don’t Save"
            ]
            let target = buttons.first { safeTitles.contains($0.title) } ?? buttons.last
            target?.keyEquivalent = "\u{1b}"
        } else if let only = buttons.first, accessoryView == nil {
            let catcher = EscapeDismissingView()
            catcher.onEscape = { [weak only] in only?.performClick(nil) }
            accessoryView = catcher
        }
    }
}
