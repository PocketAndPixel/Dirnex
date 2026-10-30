import AppKit

extension NSAlert {
    /// Give an alert that tells the user Dirnex may need Full Disk Access the button that opens it,
    /// the same Open System Settings the onboarding sheets carry.
    ///
    /// The advice is one sentence (``VFSErrorText/fullDiskAccessAdvice``), and it reaches the screen
    /// through some fifteen presenters that each build their own lone-OK report, plus the copy's
    /// Retry / Skip / Abort dialog. So the test is the alert's **own text**, not the error behind it:
    /// whichever presenter built the alert, and whether the sentence stands alone or ends an "N items
    /// couldn't be put back: …" line, an alert that names the switch gets the way to it. Anything
    /// else is left exactly as it was, so a presenter that never shows the sentence pays nothing.
    ///
    /// The click opens the pane and then goes on to the alert's own action for the button, so the
    /// alert closes the way any of its buttons closes it, as a sheet or a modal. No presenter's
    /// completion handler changes: each reads only the buttons it added, and this one answers with a
    /// new response after them. `closesAlert: false` stops after the pane, for a dialog whose answer
    /// something is still waiting on.
    ///
    /// Call it last, after the text, the alert's own buttons and `enableEscapeToCancel()`. The new
    /// button goes after the others, which is where an alert's focus lands and where Escape goes by
    /// default (docs/NOTES.md ▸ Alerts, sheets and dialogs), so both are put back on the button that
    /// was last before it: the safe choice each caller's own `enableEscapeToCancel()` picked.
    func offerFullDiskAccessSettings(
        closesAlert: Bool = true,
        open: @escaping @MainActor () -> Void = FullDiskAccessOnboarding.openSystemSettings
    ) {
        guard informativeText.contains(VFSErrorText.fullDiskAccessAdvice),
              let safe = buttons.last,
              let content = window.contentView
        else { return }
        let button = addButton(withTitle: String(localized: "Open System Settings"))
        let opener = FullDiskAccessSettingsOpener(frame: .zero)
        opener.open = open
        if closesAlert, let action = button.action {
            opener.dismissal = (button.target, action)
        }
        content.addSubview(opener)
        button.target = opener
        button.action = #selector(FullDiskAccessSettingsOpener.press(_:))

        // `NSAlert` tags each button with the response it returns.
        enableEscapeToCancel(safe: NSApplication.ModalResponse(rawValue: safe.tag))
        window.initialFirstResponder = safe
    }
}

/// The target of an alert's Open System Settings button: the pane first, then the alert's own action.
///
/// A zero-size view in the alert's own content view, like `AlertKeyCatcher`, because a control
/// holds its target weakly and the view hierarchy keeps this alive exactly as long as the alert.
final class FullDiskAccessSettingsOpener: NSView {
    var open: @MainActor () -> Void = {}
    /// Where the alert sent the button before this took it over, or `nil` to leave the alert up.
    var dismissal: (target: AnyObject?, action: Selector)?

    @objc func press(_ sender: NSButton) {
        open()
        guard let dismissal else { return }
        NSApp.sendAction(dismissal.action, to: dismissal.target, from: sender)
    }
}
