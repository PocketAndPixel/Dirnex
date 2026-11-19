import AppKit
import DirnexCore

/// The folder F5 and F6 copy or move into when it is typed into the dialog's field rather than taken
/// from the other pane (asked 2026-11-19).
///
/// **A folder that is not there is made**, with every folder on its way, as soon as OK is pressed:
/// Oleg's call, where Export asks once first. They are made through `NestedCreation`, which takes
/// back what it made when a create fails, on the same location as the other pane, and they are
/// journaled as a New Folder of their own before the jobs are queued. So ⌘Z takes back the copy
/// first and then the folders, each only while empty, as Export's are.
///
/// What the dialog refuses, it refuses with the sentence under the field and the dialog still up:
/// the folder the items are in, and a folder inside one of them. A file standing where a folder
/// would go is only found by the create, so it is the create's failure alert.
extension PanelViewController {
    /// The marks that land in `destination`. Flat, one already in it would land on itself and is
    /// dropped; keeping folders cannot land one on itself, since each keeps its relative path.
    static func landing(
        _ sources: [FileEntry],
        keepingFolders: Bool,
        into destination: VFSPath
    ) -> [FileEntry] {
        keepingFolders ? sources : sources.filter { $0.path.parent != destination }
    }

    /// The first mark `destination` is, or lies inside: a copy of it would go into itself.
    static func looped(_ sources: [FileEntry], into destination: VFSPath) -> FileEntry? {
        sources.first { TransferAdmission.recurses(source: $0.path, into: destination) }
    }

    static func intoItselfSentence(_ kind: FileOperation.Kind, _ name: String) -> String {
        kind == .copy
            ? String(
                localized: "“\(name)” can’t be copied into itself.",
                comment: """
                Copy failure detail: the destination folder is a marked folder or inside one; %@ is \
                its name.
                """
            )
            : String(
                localized: "“\(name)” can’t be moved into itself.",
                comment: """
                Failure detail: a folder would be moved inside itself, by a rename to a path inside \
                it or a move into a folder inside it; %@ is its name.
                """
            )
    }

    /// Why the items cannot go into `destination`, typed into the dialog's field, or `nil`.
    func transferRefusal(
        kind: FileOperation.Kind,
        sources: [FileEntry],
        keepingFolders: Bool,
        into destination: VFSPath
    ) -> String? {
        if let looped = Self.looped(sources, into: destination) {
            return Self.intoItselfSentence(kind, looped.name)
        }
        let landing = Self.landing(sources, keepingFolders: keepingFolders, into: destination)
        guard destination == panel.path || landing.isEmpty else { return nil }
        return kind == .copy
            ? String(
                localized: "Can’t copy into the same folder",
                comment: "Copy failure title: source and destination are the same folder."
            )
            : String(
                localized: "Can’t move into the same folder",
                comment: "Move failure title: source and destination are the same folder."
            )
    }

    /// Make `folder` and the folders on its way that are not there, then `queue` the jobs into it.
    /// Nothing is queued when the create fails, so the dialog following the transfer is told there
    /// is nothing to wait for, and the marks stay for another try.
    func makeTransferFolder(
        _ folder: VFSPath,
        kind: FileOperation.Kind,
        tracker: TransferTracker,
        then queue: @escaping () -> Void
    ) {
        let backend = backend
        Task {
            do {
                let made = try await BlockingWork.run {
                    Result { try NestedCreation.makeFolders(upTo: folder, using: backend) }
                }.get()
                if let record = UndoRecord.newFolders(made) { host?.recordUndoableAction(record) }
            } catch {
                tracker.finish()
                presentOperationFailure(
                    message: transferFailureTitle(kind),
                    detail: describeCreateFailure(error, making: folder)
                )
                return
            }
            queue()
        }
    }
}
