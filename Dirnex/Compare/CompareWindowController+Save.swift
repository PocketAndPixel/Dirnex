import AppKit
import DirnexCore

/// What a compare window's saves need besides the file (PLAN.md §M33 Slice 3): the undo store, and
/// the browser window whose journal ⌘Z in a pane reads.
///
/// Handed in with no default, as `ArchiveWriter` takes its undo request: the app test target runs
/// inside the app, so a window a test builds must not file copies into the developer's own store or
/// records into their journal.
struct CompareSaving {
    /// The store and the snapshots the journal still names, read at each save.
    let undo: @MainActor () -> ArchiveUndoStorage.Request
    /// Files a save's undo record with the browser window the comparison came from.
    let journal: @MainActor (UndoRecord) -> Void

    /// For a window whose saves keep no undo: a test's, or the conflict dialog's, which saves
    /// nothing.
    static var none: CompareSaving {
        CompareSaving(undo: { .none }, journal: { _ in })
    }
}

/// Saving the compare window's files (PLAN.md §M33 Slice 3): ⌘S, the question when a file changed
/// since it was read, and the one when an edited window closes or the app quits.
///
/// A side saves when its file is a local file read as itself (`CompareSource.target`). A server file
/// or an archive member is Slice 4's, and until then its copies are not saved, as in Slice 2. The
/// bytes are the core's `ComparedFileSave`, off the main thread; this asks the questions and hands
/// the undo record to the browser window.
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

    /// Save the file `id` names, wherever Swap Sides has put it, asking first when the file changed
    /// since it was read. `true` when it was saved.
    func saveFile(_ id: UUID) async -> Bool {
        guard let side = side(ofFile: id), let target = source(on: side).target else { return false }
        let document = source(on: side).document
        let name = source(on: side).name
        let request = saving.undo()
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
                land(saved, of: document, inFile: id)
                return true
            case .failure(.changedSinceRead):
                guard await askToSaveAnyway(name) else { return false }
                overwriting = true
            case let .failure(.unencodable(line, character)):
                await reportSaveFailure(
                    name,
                    detail: Self.unencodableDetail(character, line: line, in: document.encoding)
                )
                return false
            case let .failure(.failed(error)):
                await reportSaveFailure(name, detail: VFSErrorText.sentence(for: error))
                return false
            }
        }
    }

    /// The file holds `document`'s lines now: they are what the side is compared with for its
    /// edited mark, and the next save is checked against the file as it now stands.
    private func land(
        _ saved: ComparedFileSave.Saved,
        of document: ComparedDocument,
        inFile id: UUID
    ) {
        switch side(ofFile: id) {
        case .left?:
            left.target = saved.target
            left.document.markSaved(document.lines)
        case .right?:
            right.target = saved.target
            right.document.markSaved(document.lines)
        case nil:
            return
        }
        savesLanded += 1
        if let record = saved.undo { saving.journal(record) }
        refreshEditedMarks()
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
