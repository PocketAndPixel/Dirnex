import AppKit
import DirnexCore

/// User-facing presentation of directory-load failures for a file pane. Split out so
/// the controller proper stays focused on the panel/table plumbing; nothing here
/// touches the `Panel` model, only the view and the error.
extension PanelViewController {
    /// Report a failed listing on the pane it happened in — and *only* there.
    ///
    /// A pane with no window has nobody to tell, and the `runModal` fallback every other alert in
    /// this app keeps (docs/NOTES.md ▸ AppKit: a sheet needs a window) is actively harmful here,
    /// because this is the one alert that fires **unasked**: a navigation the app performs on its
    /// own, including the one `viewDidLoad` starts. In the app's own test host that put a modal
    /// alert on screen for every pane a suite built on a path that cannot list — six of them in one
    /// run, each blocking the whole process until a human clicked OK, which is what made the live S3
    /// suite look like it was timing out (found 2026-08-14; the user was the instrument). The same
    /// shape is reachable in the app during launch restoration, before `showWindow`, where an alert
    /// would come up in front of no window at all.
    ///
    /// So: no window, no alert. The failure is not swallowed anywhere it can be seen — a pane on
    /// screen still gets its sheet — and a test that wants to assert on the failure should drive the
    /// load, not the presentation.
    func presentLoadFailure(_ error: Error, path: VFSPath) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Can’t open “\(path.displayName)”")
        alert.informativeText = describe(error)
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK"))
        alert.enableEscapeToCancel()
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window)
    }

    /// A human-readable sentence for an error. Internal (not private) so the file-op
    /// presenters in `PanelViewController+FileOps` can reuse the same phrasing.
    func describe(_ error: Error) -> String { VFSErrorText.sentence(for: error) }
}

/// The single source of truth for turning a `VFSError` into a user-facing sentence, shared
/// by the pane's load/op error sheets, the queue's failure summary, and the per-file error
/// dialog (`ErrorDialog`). Free of any view state so it can run on any actor.
enum VFSErrorText {
    static func sentence(for error: Error) -> String {
        // The encrypted-archive vocabulary reaches the screen through the same `describe(_:)` calls
        // a `VFSError` does, and its `localizedDescription` is the useless synthesized one
        // ("…error 1."). Joined here, once, so no call site has to know which family it caught.
        if let archiveError = error as? EncryptedArchiveError {
            return LocalizedCatalog.sentence(for: archiveError)
        }
        guard let vfsError = error as? VFSError else { return error.localizedDescription }
        switch vfsError {
        case .permissionDenied:
            return String(localized: """
            You don’t have permission. Dirnex may need Full Disk Access in System Settings.
            """)
        case .notFound:
            return String(localized: "The item no longer exists.")
        case .notADirectory:
            return String(localized: "That item isn’t a folder.")
        case .alreadyExists:
            return String(localized: "An item with that name already exists here.")
        case let .io(_, code):
            return String(localized: "The system reported an error (code \(code)).")
        case let .unsupported(reason):
            // The one case whose text the core authors. It is a named reason, not a string, so it
            // can be looked up here rather than passed through in English (PLAN.md §M12 Slice 11).
            return LocalizedCatalog.sentence(for: reason)
        }
    }
}
