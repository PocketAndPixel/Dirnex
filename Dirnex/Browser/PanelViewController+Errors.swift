import AppKit
import DirnexCore

/// User-facing presentation of directory-load failures for a file pane. Split out so
/// the controller proper stays focused on the panel/table plumbing; nothing here
/// touches the `Panel` model, only the view and the error.
extension PanelViewController {
    /// Report a failed listing on the pane it happened in — and *only* there.
    ///
    /// This is an alert the app raises **unasked**: `viewDidLoad` → `activateTab()` → `navigate`
    /// lists a path nobody has just clicked, so a pane with no window has nobody to tell.
    /// ``NSAlert/beginSheetIfVisible(over:completionHandler:)`` is where that rule and the
    /// measurement behind it live; the failure is still reported wherever it can be seen.
    func presentLoadFailure(_ error: Error, path: VFSPath) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Can’t open “\(path.displayName)”")
        alert.informativeText = describe(error)
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK"))
        alert.enableEscapeToCancel()
        alert.beginSheetIfVisible(over: view.window)
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
