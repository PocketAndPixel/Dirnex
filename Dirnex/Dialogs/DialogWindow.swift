import AppKit
import DirnexCore

/// How Dirnex presents its own view-controller dialogs — the report, the two Get Info panels, the
/// Multi-Rename tool, Find Files, Synchronize, and the two organizers.
///
/// They used to be sheets, and a sheet is nailed to the window it hangs from: a verification report
/// listing forty files, or a Get Info panel the user wants to read *against* the pane behind it,
/// cannot be moved aside. `presentAsModalWindow(_:)` is AppKit's own answer and needs no window
/// plumbing of ours. Probed on a live window before this was written, because none of it is
/// documented:
///
/// - The window comes up `[.titled, .closable, .resizable]` with `isMovable == true`, so it drags by
///   its title bar and closes by its red button — which ends the presentation properly
///   (`presentedViewControllers` drops to 0, the modal state clears), so `dismiss(_:)`, the Done
///   button and `EscapeDismissingView` all keep working exactly as they did under a sheet.
/// - **It does not block the caller.** The call returns immediately, and main-queue work and
///   default-mode timers keep firing while the dialog is up — so the operation queue, the FSEvents
///   refreshes and a running checksum job are unaffected. This is the fact that made the move
///   affordable; a nested `NSApp.runModal` would not have been.
/// - It is nonetheless genuinely app-modal (`NSApp.modalWindow` is it), which costs nothing here:
///   `AppDelegate` opens exactly one `BrowserWindowController` and there is no New Window command,
///   so "app-modal" and "window-modal" name the same set of windows. An `NSAlert` raised *from* one
///   of these dialogs still attaches to it as a sheet and still runs its completion handler — the
///   attributes editors' "discard changes?" confirmations depend on that.
///
/// The one thing it gets wrong for us is the resize corner: every one of these controllers pins its
/// container to a fixed width *and* height, and the localization work behind them (measured label
/// columns, a checkbox grid budgeted against all 14 languages) is sized to exactly those numbers.
/// A window advertising a resize corner that Auto Layout then refuses to honour is a worse lie than
/// no corner at all, so `.resizable` comes straight back off.
extension NSViewController {
    /// Present `controller` as a movable, app-modal window — the sheet replacement.
    ///
    /// Give the controller a `title` before calling: the window draws its content view controller's
    /// title, and a `nil` one renders as the literal word "Untitled".
    func presentAsMovableWindow(_ controller: NSViewController) {
        presentAsModalWindow(controller)
        // Reachable synchronously — the animator has already installed and ordered in the window by
        // the time the call returns (probed), so there is nothing to defer.
        guard let window = controller.view.window else { return }
        window.styleMask.remove(.resizable)
        // Keyed by the controller's own type: one remembered position per kind of dialog, which is
        // what "where I left the report" means. A renamed class forgets its position once, which is
        // the cheapest possible consequence.
        DialogWindowPlacement.place(
            window,
            key: String(describing: type(of: controller)),
            centeredOver: view.window
        )
    }
}

/// Where a dialog window opens: where the user last dragged it, else centred on the app's own
/// window.
///
/// Centring on the *app* rather than the screen is the point — on a large display a screen-centred
/// dialog can land nowhere near the window that raised it. AppKit's `NSWindow` frame autosave does
/// the remembering, so there is nothing to observe and nothing to tear down; that matters here
/// because a modal-window presentation **posts no `willCloseNotification`** (probed), so the obvious
/// save-on-close design would silently never save.
///
/// The one ordering rule: `.resizable` must already be off. Probed on a non-resizable window,
/// `setFrameUsingName` restores the saved *position* alone — it keeps the window's current size and
/// preserves the **top-left** while doing it (a frame saved at 400×332 restored a 640×512 window
/// with both tops at y=587). So a size saved by an older build can never come back, and none of that
/// arithmetic has to be written by hand. On a resizable window the same call would restore the stale
/// size too.
enum DialogWindowPlacement {
    /// Restore `window` to its remembered position under `key`, or centre it over `parent` when
    /// there is nothing remembered — or when what is remembered is on a display the app is no longer
    /// using. Registers the autosave either way, so wherever the user drags it next is what returns.
    static func place(_ window: NSWindow, key: String, centeredOver parent: NSWindow?) {
        let name = NSWindow.FrameAutosaveName("Dialog.\(key)")
        if !window.setFrameUsingName(name) || !isNear(parent, window) {
            center(window, over: parent)
        }
        window.setFrameAutosaveName(name)
    }

    /// Whether a restored position is still on the screen the app's window is on.
    ///
    /// A remembered position is *absolute*, so plugging in an external display and moving the main
    /// window over to it would otherwise leave every dialog opening back on the laptop screen —
    /// far from the window that raised it, with nothing on screen to explain why. AppKit's own
    /// constraining cannot catch this: the saved frame is perfectly valid, just somewhere else. The
    /// test is the window's centre rather than an intersection, so a dialog straddling two displays
    /// counts as being on the one it mostly occupies.
    private static func isNear(_ parent: NSWindow?, _ window: NSWindow) -> Bool {
        guard let visible = parent?.screen?.visibleFrame else { return true }
        return visible.contains(NSPoint(x: window.frame.midX, y: window.frame.midY))
    }

    /// Dead centre of `parent`, or of the screen when there is no window to centre on.
    ///
    /// Dead centre rather than AppKit's `center()`, which biases above the midpoint — the same
    /// choice `centerOnScreen` makes, for the same reason. No screen clamping: probed,
    /// `setFrameOrigin` and `setFrame(_:display:)` both constrain the result onto a screen
    /// themselves, keeping the title bar reachable, so a hand-rolled clamp would only second-guess
    /// AppKit on the one case (a display that went away) it already handles.
    private static func center(_ window: NSWindow, over parent: NSWindow?) {
        guard let parent, parent !== window else {
            window.centerOnScreen()
            return
        }
        let host = parent.frame
        window.setFrameOrigin(NSPoint(
            x: host.midX - window.frame.width / 2,
            y: host.midY - window.frame.height / 2
        ))
    }
}

/// Window titles for those dialogs.
///
/// Every one of them is already named somewhere the user has read — the command registry entry the
/// menu and the palette draw, or the menu item that opens it — so the title bar reuses that string
/// rather than authoring a second one. A display string that exists twice gets localized once
/// (docs/NOTES.md), and here the duplicate would be a *window title*, the least likely surface to be
/// noticed missing in a translated build.
enum DialogTitle {
    /// The registry title of `commandID`, translated, as a window title.
    ///
    /// Falls back to an empty title — a blank title bar the user can still drag — rather than to a
    /// raw id, on the same principle as `LocalizedCatalog`'s English fallback: the dialog itself
    /// says what it is, so a name that failed to resolve should be absent, not wrong.
    static func ofCommand(_ commandID: String) -> String {
        guard let command = LocalizedCatalog.command(for: commandID) else { return "" }
        return withoutEllipsis(command.title)
    }

    /// The same trim for a name that lives outside the registry (a menu item's own literal).
    ///
    /// A menu title's trailing ellipsis is a promise that choosing it opens something; the thing it
    /// opened has no promise left to make, so the title bar drops it. Both spellings are trimmed —
    /// a translation may carry either, and neither belongs in a window title.
    static func withoutEllipsis(_ title: String) -> String {
        for suffix in ["…", "..."] where title.hasSuffix(suffix) {
            return String(title.dropLast(suffix.count))
        }
        return title
    }
}

/// The body layout every one of those dialogs builds in its `loadView()`: a vertical stack of rows,
/// inset from the container by the standard margin and pinned to all four of its edges.
///
/// Six controllers spelled this out identically — the same insets, the same four anchors — and the
/// margin is exactly the kind of number that drifts when it lives in six places. What stays at the
/// call site is the part that genuinely differs: which rows, and the container's own fixed size.
enum DialogLayout {
    /// The margin between the container's edge and the content, on all four sides.
    static let inset: CGFloat = 20

    /// The gap between rows. The search sheet wants a looser 16; everything else takes this.
    static let spacing: CGFloat = 12

    /// Fill `container` with `rows` stacked vertically, and return the stack for a caller that needs
    /// to constrain something to it.
    ///
    /// Nothing here sizes the container: a dialog states its own width (and usually height) at the
    /// call site, because those are decisions about that dialog. Note what the fixed height buys —
    /// an `NSStackView` that cannot fit its arranged views *compresses* them rather than overflowing,
    /// which is how a whole row once went missing from the attributes panel (docs/NOTES.md), so a
    /// dialog that grows a row must grow its height too rather than trusting the stack.
    @discardableResult
    static func fill(
        _ container: NSView,
        with rows: [NSView],
        spacing: CGFloat = Self.spacing
    ) -> NSStackView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.spacing = spacing
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return stack
    }
}
