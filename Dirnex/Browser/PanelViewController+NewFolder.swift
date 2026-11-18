import AppKit
import DirnexCore

/// F7 New Folder: the dialog and the create, out of `+FileOps` since 2026-11-18, when a typed path
/// made the create bigger than that file's ceiling had room for.
///
/// **The name may be a path** (asked 2026-11-18): `folder A/sub folder A` makes `folder A` and then
/// `sub folder A` inside it, as Total Commander's F7 does, here and on every backend F7 reaches —
/// this Mac, a cloud mount, a server, a bucket, and a browsed archive by its own rewrite. The parse
/// is `NestedName` and the walk `NestedCreation`, both in the core; ⇧F4 shares them
/// (`+Edit`), and the refusals and the sentence for a file in the way are `+NestedCreate`'s.
///
/// The cursor lands on the **outermost** new row, which is the one the pane's own listing shows,
/// and one ⌘Z takes back everything one F7 made (`UndoRecord.newFolders`).
extension PanelViewController {
    // MARK: - The dialog

    /// Internal because the key and the menu item that raise it are in `+FileOps`.
    func promptForNewFolder() {
        // The cursor decides the target in a tree, and the table's selection is the live cursor
        // (`PanelViewController+CreateTarget`).
        reconcileCursorFromTable()
        // `creationDirectory` is `nil` wherever there is no real directory to create into — and, for
        // the merged iCloud listing, the CloudDocs container the merge is built on (PLAN.md §M9). In
        // a tree it is the folder the cursor's row lives in, so the new folder appears as a sibling
        // right where the cursor is rather than back at the root. Inside a writable archive it is the
        // folder the cursor is in there (`archiveCreationDirectory`), and the create is a rewrite.
        guard let target = createTarget else { return }
        // An S3 account pane's rows are **buckets**, so F7 there creates one (PLAN.md §M21
        // Slice 9). Not a naming quibble: an account has no folders to make, and a bucket's name
        // has to keep rules a folder's does not — which is why the prefilled default goes away
        // below rather than arriving as a value that cannot be used.
        let createsBucket = target.backend.isS3Account
        let alert = NSAlert()
        alert.messageText = createsBucket
            ? String(
                localized: "New Bucket",
                comment: "Title of the New Folder dialog when the pane lists an S3 account's buckets."
            )
            : String(
                localized: "New Folder",
                comment: "Title of the New Folder dialog."
            )
        // Named for what the pane shows, not for the directory underneath: "iCloud Drive", not
        // "com~apple~CloudDocs", which is a folder the user has never heard of. A tree is the
        // exception `creationDirectoryName` exists for — it really is drawing the deeper folder.
        alert.informativeText = createsBucket
            ? String(
                localized: "Create a bucket on “\(creationDirectoryName)”.",
                comment: "New Bucket dialog body; %@ is the S3 account the pane is listing."
            )
            : String(
                localized: "Create a folder in “\(creationDirectoryName)”.",
                comment: "New Folder dialog body; %@ is the containing folder name."
            )
        alert.addButton(
            withTitle: String(
                localized: "Create",
                comment: "Confirm button of the New Folder dialog."
            )
        )
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Dismiss button."))
        alert.enableEscapeToCancel()

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.keepToOneLine()
        // A bucket starts blank. "untitled folder" is not a legal bucket name — a space and a
        // capital would each break a rule — so prefilling it would hand the user a default that
        // earns a refusal about a rule they never chose to break.
        field.stringValue = createsBucket ? "" : String(
            localized: "untitled folder",
            comment: "Default name prefilled in the New Folder dialog."
        )
        field.placeholderString = createsBucket
            ? String(
                localized: "Bucket name",
                comment: "Placeholder in the New Bucket name field (the New Folder dialog on an S3 account)."
            )
            : String(
                localized: "Folder name",
                comment: "Placeholder in the New Folder name field."
            )
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { await self.createFolder(named: name, in: target) }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: apply)
            field.selectText(nil)
        } else {
            apply(alert.runModal())
        }
    }

    // MARK: - The create

    /// Make the folder `typed` names in `directory`, and the folders on the way to it.
    ///
    /// Internal, not private: `NestedCreateRouteTests` drives it, because the dialog above it is an
    /// `NSAlert` and a test host that presents one waits for a human (docs/NOTES.md ▸ Testing).
    func createFolder(named typed: String, in directory: VFSPath) async {
        guard !typed.isEmpty else { return } // an empty name is a silent cancel
        let backend = backend
        let target: VFSPath
        let shown: String
        let landing: VFSPath
        let make: @Sendable () throws -> [VFSPath]
        if directory.backend.isS3Account {
            // An account pane's rows are buckets, and F7 there makes one. A bucket's rules are the
            // service's, and `S3BucketName` is what says *which* one broke — a slash lands on "use
            // lowercase letters, digits, dots and hyphens", which is the sentence that helps. So the
            // name goes to it whole, never split into folders a bucket cannot have.
            target = directory.appending(typed)
            shown = typed
            landing = target
            make = {
                try backend.createDirectory(at: target)
                return [target]
            }
        } else {
            guard let name = nestedName(typed, as: .folder) else { return }
            target = name.target(in: directory)
            shown = name.displayPath
            landing = name.outermost(in: directory)
            if target.backend.isArchive {
                createArchiveMember(.folder, at: target, shown: shown, landing: landing)
                return
            }
            make = { try NestedCreation.makeFolder(name, in: directory, using: backend) }
        }
        do {
            let made = try await BlockingWork.run { Result { try make() } }.get()
            refreshCurrentDirectory(selecting: landing)
            focusTable()
            if let record = UndoRecord.newFolders(made) { host?.recordUndoableAction(record) }
        } catch {
            presentOperationFailure(
                message: String(
                    localized: "Can’t create “\(shown)”",
                    comment: "New Folder failure title; %@ is the folder name."
                ),
                detail: describeCreateFailure(error, making: target)
            )
        }
    }
}
