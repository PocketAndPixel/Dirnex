import AppKit
import DirnexCore

/// What a compare window's saves need besides the file (PLAN.md §M33 Slice 3): the undo store, the
/// browser window whose journal ⌘Z in a pane reads, and the write-back that carries a copy of a
/// server file or an archive member back where it came from (Slice 4). Edit Left and Edit Right
/// hand a file to the user's editor and watch a copy for its save, as F4 does (Slice 5).
///
/// Handed in with no default, as `ArchiveWriter` takes its undo request: the app test target runs
/// inside the app, so a window a test builds must not file copies into the developer's own store or
/// records into their journal, nor upload anything, nor open an editor.
struct CompareSaving {
    /// The store and the snapshots the journal still names, read at each save.
    let undo: @MainActor () -> ArchiveUndoStorage.Request
    /// Files a save's undo record with the browser window the comparison came from.
    let journal: @MainActor (UndoRecord) -> Void
    /// Carries a copy the window has written back where it came from, asking over the window
    /// given, and answers whether it landed (`BrowserWindowController.writeBack(_:askingOver:)`).
    let writeBack: @MainActor (EditedFile, NSWindow?) async -> Bool
    /// Opens a file in the user's editor, then answers with the editor, `nil` when there is none,
    /// and the launch's failure (`ExternalTextEditorLauncher.edit`).
    let openInEditor: @MainActor (URL, @escaping (ApplicationRef?, (any Error)?) -> Void) -> Void
    /// Watches a copy handed to the editor, so its save is offered back as F4's is
    /// (`EditedFileRegistry.watch`).
    let watchCopy: @MainActor (EditedFile) -> Void

    /// For a window whose saves keep no undo and carry nothing back: a test's, or the conflict
    /// dialog's, which saves nothing.
    static var none: CompareSaving {
        CompareSaving(
            undo: { .none },
            journal: { _ in },
            writeBack: { _, _ in false },
            openInEditor: { _, done in done(nil, nil) },
            watchCopy: { _ in }
        )
    }
}

/// Saving the compare window's files (PLAN.md §M33 Slices 3 and 4): ⌘S, the question when a file
/// changed since it was read, and the one when an edited window closes or the app quits.
///
/// A side saves when its file can be reached (`CompareSource.target`). A local file read as itself
/// is written in place, and its undo record goes to the browser window. A server file or an archive
/// member is written into the copy the window read, which F4's write-back then carries where it
/// came from, with its own check and question; the side counts as saved once that lands. The bytes
/// are the core's `ComparedFileSave`, off the main thread; this asks the questions.
extension CompareWindowController {
    /// The answers to the question asked before edits would be lost.
    enum CloseAnswer {
        case save, discard, cancel
    }

    /// The sides whose lines differ from their file and that a save can write.
    var unsavedSides: [ComparisonPaneText.Side] {
        Self.sides.filter { source(on: $0).target != nil && source(on: $0).document.isEdited }
    }

    /// ⌘S: save every edited side, or beep when there is nothing to save.
    func saveFromKey() {
        guard !isSaving, !unsavedSides.isEmpty else { return NSSound.beep() }
        Task { await saveEditedSides() }
    }

    /// Save each edited side, the left one first. `true` when every one was saved. A refusal, a
    /// failure or a Cancel stops there, and what was saved before it stays saved.
    @discardableResult
    func saveEditedSides() async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        for id in unsavedSides.map({ source(on: $0).id }) {
            guard await saveFile(id) else { return false }
        }
        return true
    }

    /// Save only the file `id` names, before Edit opens it (`+Edit`). `false` when another save is
    /// running or this one did not happen.
    func saveOnly(_ id: UUID) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        return await saveFile(id)
    }

    /// Save the file `id` names, wherever Swap Sides has put it, asking first when the file changed
    /// since it was read. `true` when it was saved.
    func saveFile(_ id: UUID) async -> Bool {
        guard let side = side(ofFile: id), let target = source(on: side).target else { return false }
        let document = source(on: side).document
        let name = source(on: side).name
        let carried = source(on: side).writeBack.map {
            EditedFile(destination: $0, temporaryURL: URL(fileURLWithPath: target.path), name: name)
        }
        // A copy carried elsewhere keeps no undo here. An upload has none, and an archive's rewrite
        // journals its own.
        let request = carried == nil ? saving.undo() : .none
        let undo = request.store.map { ComparedFileSave.UndoCopy(store: $0, live: request.live) }
        var overwriting = false
        while true {
            let answer = overwriting
            let result = await BlockingWork.run {
                Result { () throws(ComparedFileSave.Failure) in
                    try ComparedFileSave.save(
                        document,
                        to: target,
                        overwritingChanges: answer,
                        undo: undo
                    )
                }
            }
            switch result {
            case let .success(saved):
                if let carried {
                    // The copy holds these lines whether or not they get any further, so the next
                    // save is checked against it as it now stands.
                    keep(saved.target, inFile: id)
                    guard await saving.writeBack(carried, window) else { return false }
                }
                land(saved, of: document, inFile: id)
                return true
            case .failure(.changedSinceRead):
                guard await Self.askToSaveAnyway(name, over: window) else { return false }
                overwriting = true
            case let .failure(.unencodable(line, character)):
                await Self.reportSaveFailure(
                    name,
                    detail: Self.unencodableDetail(character, line: line, in: document.encoding),
                    over: window
                )
                return false
            case let .failure(.failed(error)):
                await Self.reportSaveFailure(
                    name,
                    detail: VFSErrorText.sentence(for: error),
                    over: window
                )
                return false
            }
        }
    }

    /// The file holds `document`'s lines now: they are what the side is compared with for its
    /// edited mark, and the next save is checked against the file as it now stands. A Synchronize
    /// window showing the file is told, and compares its row again.
    private func land(
        _ saved: ComparedFileSave.Saved,
        of document: ComparedDocument,
        inFile id: UUID
    ) {
        keep(saved.target, inFile: id)
        let origin: VFSPath
        switch side(ofFile: id) {
        case .left?:
            left.document.markSaved(document.lines)
            origin = left.origin
        case .right?:
            right.document.markSaved(document.lines)
            origin = right.origin
        case nil:
            return
        }
        savesLanded += 1
        if let record = saved.undo { saving.journal(record) }
        refreshEditedMarks()
        Self.announceSave(of: origin)
    }

    /// The file `id` names now looks like `target`, which the next save is checked against.
    private func keep(_ target: ComparedFileSave.Target, inFile id: UUID) {
        switch side(ofFile: id) {
        case .left?: left.target = target
        case .right?: right.target = target
        case nil: break
        }
    }

    // MARK: - Telling the Synchronize window

    /// Posted on the main thread once a save has landed, naming the file where it lives
    /// (``savedOrigin(in:)``). The Synchronize window compares the row showing that file again
    /// (PLAN.md §M33 Slice 4), so the row the window was opened from stops offering to copy over the
    /// edit just saved. A notification rather than a handler passed down, because any compare window
    /// open on the file counts, not only one opened from that row.
    nonisolated static let fileSaved = Notification.Name("DirnexCompareWindowFileSaved")
    private nonisolated static let originKey = "origin"

    static func announceSave(of origin: VFSPath) {
        NotificationCenter.default.post(name: fileSaved, object: nil, userInfo: [originKey: origin])
    }

    /// The file a ``fileSaved`` notification names. Read where the notification is delivered,
    /// before it is handed to the main actor.
    nonisolated static func savedOrigin(in notification: Notification) -> VFSPath? {
        notification.userInfo?[originKey] as? VFSPath
    }

    /// Mark each side edited or not as it stands, after a save. Worked out off the main thread,
    /// and dropped if a copy lands meanwhile, since that copy's comparison marks both sides.
    func refreshEditedMarks() {
        let revision = sidesRevision
        let left = left.document
        let right = right.document
        Task { [weak self] in
            let edited = await BlockingWork.run { (left.isEdited, right.isEdited) }
            guard let self, revision == sidesRevision else { return }
            showTitles(edited: edited)
        }
    }

    // MARK: - Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !unsavedSides.isEmpty else { return true }
        // A second ⌘W or ⎋ while the question is up asks nothing more.
        guard sender.attachedSheet == nil, !isSaving else { return false }
        Task { await closeAfterAsking() }
        return false
    }

    /// Ask about the unsaved sides, then close unless the answer was Cancel or a save failed.
    func closeAfterAsking() async {
        switch await askAboutUnsavedSides() {
        case .save:
            guard await saveEditedSides() else { return }
            window?.close()
        case .discard:
            // `close` does not ask the delegate again, as `performClose` would.
            window?.close()
        case .cancel:
            break
        }
    }

    /// Whether any open window has edits a save could keep, which quitting would lose.
    static var anyUnsaved: Bool {
        open.contains { !$0.unsavedSides.isEmpty }
    }

    /// Ask each window with unsaved edits in turn before the app quits. `false` when the user
    /// cancelled, or a save they asked for did not happen.
    static func confirmQuit() async -> Bool {
        for controller in open where !controller.unsavedSides.isEmpty {
            controller.showWindow(nil)
            switch await controller.askAboutUnsavedSides() {
            case .save:
                guard await controller.saveEditedSides() else { return false }
            case .discard:
                continue
            case .cancel:
                return false
            }
        }
        return true
    }
}
