import AppKit
import DirnexCore

/// User-facing presentation of directory-load failures for a file pane. Split out so
/// the controller proper stays focused on the panel/table plumbing; nothing here
/// touches the `Panel` model, only the view and the error.
extension PanelViewController {
    func presentLoadFailure(_ error: Error, path: VFSPath) {
        let alert = NSAlert()
        alert.messageText = "Can’t open “\(path.lastComponent)”"
        alert.informativeText = describe(error)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.enableEscapeToCancel()
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
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
        guard let vfsError = error as? VFSError else { return error.localizedDescription }
        switch vfsError {
        case .permissionDenied:
            return "You don’t have permission. "
                + "Dirnex may need Full Disk Access in System Settings."
        case .notFound:
            return "The item no longer exists."
        case .notADirectory:
            return "That item isn’t a folder."
        case .alreadyExists:
            return "An item with that name already exists here."
        case let .io(_, code):
            return "The system reported an error (code \(code))."
        case let .unsupported(message):
            return message
        }
    }
}
