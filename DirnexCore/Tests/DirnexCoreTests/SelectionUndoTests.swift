import Foundation
import Testing

@testable import DirnexCore

/// Selection changes on the unified undo timeline (PLAN.md §M2). A mark change is reverted by
/// swapping a pane's marks, not by touching bytes, so these pin the pure parts: the change's
/// inverse, `Panel.setSelection`, and that the journal interleaves selection and file-operation
/// entries in one ordered history the way Cmd+Z expects.
@Suite("SelectionUndo")
struct SelectionUndoTests {
    private func change(
        prior: Set<String>,
        new: Set<String>,
        pane: PaneSide = .left,
        label: String = "Mark"
    ) -> SelectionChange {
        SelectionChange(
            pane: pane,
            directory: .local("/dir"),
            priorSelection: Set(prior.map { VFSPath.local("/dir/\($0)") }),
            newSelection: Set(new.map { VFSPath.local("/dir/\($0)") }),
            label: label
        )
    }

    // MARK: - The change model

    @Test("applying a change installs the pre-gesture marks; its inverse installs the new ones")
    func applyAndInverse() {
        let sel = change(prior: ["a"], new: ["a", "b"])
        #expect(sel.selectionToApply == sel.priorSelection)
        #expect(sel.inverse.selectionToApply == sel.newSelection)
        // Inverting twice is the identity — the property Redo leans on.
        #expect(sel.inverse.inverse == sel)
    }

    @Test("inverse preserves pane, directory, and label")
    func inverseKeepsRouting() {
        let sel = change(prior: [], new: ["x"], pane: .right, label: "Select All")
        #expect(sel.inverse.pane == .right)
        #expect(sel.inverse.directory == .local("/dir"))
        #expect(sel.inverse.label == "Select All")
    }

    private func entry(_ name: String) -> FileEntry {
        FileEntry(
            path: .local("/dir/\(name)"),
            name: name,
            kind: .file,
            byteSize: 0,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )
    }

    private func panel(_ names: [String]) -> Panel {
        Panel(model: DirectoryModel(
            listing: DirectoryListing(path: .local("/dir"), entries: names.map(entry)),
            sort: FileSort(key: .name, ascending: true, directoriesFirst: false)
        ))
    }

    // MARK: - Panel.setSelection

    @Test("setSelection keeps marks on present entries and drops vanished ones")
    func setSelectionPrunes() {
        var subject = panel(["a", "b"])
        subject.setSelection([.local("/dir/a"), .local("/dir/ghost")])
        #expect(subject.selection == [.local("/dir/a")]) // ghost pruned, a kept
    }

    @Test("setSelection keeps a mark on an entry that is only filtered out of view")
    func setSelectionKeepsFilteredMark() {
        var subject = panel(["apple", "banana"])
        subject.setFilter("banana") // apple is present but hidden from view
        subject.setSelection([.local("/dir/apple")])
        #expect(subject.selection == [.local("/dir/apple")]) // still present in the listing
        #expect(subject.selectedEntries.isEmpty) // but not among the visible rows
    }

    // MARK: - Journal interleaving

    @Test("a selection entry and a file op share one ordered timeline")
    func mixedTimeline() {
        var journal = UndoJournal()
        journal.record(.newFolder(at: .local("/dir/new")))
        journal.record(.selection(change(prior: [], new: ["a"], label: "Select All")))

        // Cmd+Z reverses the most recent action first — the selection change.
        let first = journal.takeForUndo()
        #expect(first?.selection?.label == "Select All")
        // Then the file op underneath it.
        #expect(journal.top?.fileOperation?.label == "New Folder")
    }

    @Test("undo then redo of a selection change round-trips the marks")
    func selectionRedoRoundTrip() {
        var journal = UndoJournal()
        journal.record(.selection(change(prior: ["a"], new: ["a", "b"])))

        let undone = journal.takeForUndo()?.selection
        #expect(undone?.selectionToApply == Set([VFSPath.local("/dir/a")])) // back to prior

        let redone = journal.takeForRedo()?.selection
        #expect(redone?.selectionToApply == Set([.local("/dir/a"), .local("/dir/b")])) // forward again
    }

    @Test("recording a fresh mark change clears a pending selection redo")
    func freshMarkClearsRedo() {
        var journal = UndoJournal()
        journal.record(.selection(change(prior: [], new: ["a"])))
        _ = journal.takeForUndo() // stage a redo
        #expect(journal.canRedo)
        journal.record(.selection(change(prior: [], new: ["b"])))
        #expect(!journal.canRedo)
    }
}
