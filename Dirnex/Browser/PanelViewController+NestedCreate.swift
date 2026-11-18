import AppKit
import DirnexCore

/// What F7 and ⇧F4 say about a typed path (2026-11-18): the refusals of a name that names nothing a
/// create could make, and the sentence for a file standing where a folder on the way would go. One
/// place, so the two dialogs and every backend they reach say the same thing about the same text.
extension PanelViewController {
    /// Parse what F7's or ⇧F4's field holds, saying what is wrong when it names nothing that can be
    /// made. `nil` for a refusal, and for an empty field, which is a silent cancel as it always was.
    func nestedName(_ typed: String, as leaf: NestedName.Leaf) -> NestedName? {
        do {
            return try NestedName(parsing: typed, as: leaf)
        } catch {
            guard error != .empty else { return nil }
            presentOperationFailure(
                message: leaf == .folder
                    ? String(
                        localized: "Can’t create the folder",
                        comment: "New Folder failure title for an invalid name."
                    )
                    : String(
                        localized: "Can’t create the file",
                        comment: "Create-file failure title for an invalid name."
                    ),
                detail: Self.sentence(for: error)
            )
            return nil
        }
    }

    /// The sentence under a failed create of `target`.
    ///
    /// A file (or anything but a folder) where a folder on the way would go is named, since
    /// `NestedCreation` and the archive's stage both throw `notADirectory` with *its* path: the
    /// generic "That item isn’t a folder." would leave the user guessing which of the names it means.
    /// The target itself is never the culprit of that sentence, so its own `notADirectory`, if a
    /// backend ever answers one, keeps the generic wording.
    func describeCreateFailure(_ error: Error, making target: VFSPath) -> String {
        if case let .notADirectory(blocker)? = error as? VFSError, blocker != target {
            return String(
                localized: "“\(blocker.lastComponent)” isn’t a folder, so nothing can be made inside it.",
                comment: """
                Failure detail of New Folder or Edit File for a typed path such as “A/B”: something \
                on the way is a file; %@ is its name.
                """
            )
        }
        return describe(error)
    }

    private static func sentence(for problem: NestedName.Problem) -> String {
        switch problem {
        case .empty:
            // Never shown: `nestedName` reads it as a cancel. Kept a sentence so the switch stays
            // exhaustive without a `default` that would swallow the next case added.
            ""
        case .startsAtRoot:
            String(
                localized: """
                A name can’t start with “/”. To make folders on the way, type a path from here, \
                such as “Folder/Subfolder”.
                """,
                comment: """
                Failure detail of New Folder or Edit File: the typed name starts with a slash. \
                “Folder/Subfolder” is an example path: translate both folder names, keep the “/”.
                """
            )
        case let .reserved(component):
            String(
                localized: "“\(component)” can’t be used as a name.",
                comment: """
                Failure detail of New Folder or Edit File: the typed path holds “.” or “..”; %@ is \
                that part of it.
                """
            )
        case .endsInSlash:
            String(
                localized: "Type the file’s name after the last “/”.",
                comment: "Edit File failure detail: the typed path ends with a slash, so it names no file."
            )
        }
    }
}
