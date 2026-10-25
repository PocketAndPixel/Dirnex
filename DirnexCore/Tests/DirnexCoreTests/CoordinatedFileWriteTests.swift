import Foundation
import Testing

@testable import DirnexCore

/// A file presenter standing in for an editor that has the file open, as NSDocument registers one,
/// recording what the coordinator told it.
final class EditorStandIn: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private let lock = NSLock()
    private var heard: [String] = []
    private var pendingEdit: Data?
    private var stuck = false

    init(_ path: String) {
        presentedItemURL = URL(fileURLWithPath: path)
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }

    func leave() {
        NSFileCoordinator.removeFilePresenter(self)
    }

    /// An edit the editor has not saved, which it writes into the file when asked to save, as an
    /// editor answering a merging write does. Saved once, after which there is nothing unsaved.
    func holdUnsavedEdit(_ text: String) {
        lock.withLock { pendingEdit = Data(text.utf8) }
    }

    /// Never let go of the file when asked to, as an app that has stopped answering would.
    func stopAnswering() {
        lock.withLock { stuck = true }
    }

    func told() -> [String] {
        lock.withLock { heard }
    }

    func savePresentedItemChanges(completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        let edit = lock.withLock {
            heard.append("save")
            defer { pendingEdit = nil }
            return pendingEdit
        }
        if let edit, let url = presentedItemURL { try? edit.write(to: url) }
        completionHandler(nil)
    }

    func relinquishPresentedItem(
        toWriter writer: @escaping @Sendable ((@Sendable () -> Void)?) -> Void
    ) {
        let stuck = lock.withLock {
            heard.append("let go")
            return self.stuck
        }
        guard !stuck else { return }
        writer { [weak self] in self?.lock.withLock { self?.heard.append("took back") } }
    }

    func presentedItemDidChange() {
        lock.withLock { heard.append("changed") }
    }
}

/// A save from the compare window, and its ⌘Z, made through `NSFileCoordinator` (PLAN.md §M33
/// Slice 5): an editor with the file open is told and reads it again, an unsaved edit of its own is
/// saved first and never written over unasked, and an editor that never lets go fails the save by
/// name instead of holding it forever.
@Suite("CoordinatedFileWrite")
struct CoordinatedFileWriteTests {
    private typealias Fixture = SavedFileFixture

    private static let text = "one\ntwo\nthree\n"
    private static let editorsEdit = "one\ntwo\nthree\nthe editor's own edit\n"
    private let backend = LocalBackend()

    /// Wait up to ten seconds for the editor to have been told `event`.
    private func told(_ editor: EditorStandIn, _ event: String) async -> Bool {
        for _ in 0..<1000 {
            if editor.told().contains(event) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private static func save(
        over path: String,
        overwritingChanges: Bool = false,
        undo: ComparedFileSave.UndoCopy? = nil,
        patience: TimeInterval = CoordinatedFileWrite.patience
    ) throws -> ComparedFileSave.Saved {
        try ComparedFileSave.save(
            Fixture.edited(text, lastLine: "x"),
            to: .reading(path),
            overwritingChanges: overwritingChanges,
            undo: undo,
            writer: InPlaceFileWrite.writeAll,
            patience: patience
        )
    }

    private static func store(in tree: TempTree) throws -> ComparedFileSave.UndoCopy {
        try tree.makeDir("store")
        return .init(
            store: ArchiveUndoStore(root: URL(fileURLWithPath: tree.path("store"))),
            live: []
        )
    }

    @Test("a save tells an editor that has the file open, which then reads it again")
    func saveIsHeard() async throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = try tree.writeFile("a.txt", contents: Self.text)
        let editor = EditorStandIn(path)
        defer { editor.leave() }

        try Self.save(over: path)
        #expect(Fixture.read(path) == "one\ntwo\nx\n")
        #expect(await told(editor, "changed"))
        #expect(editor.told().contains("let go"))
    }

    @Test("an editor's unsaved edit is saved first, and the save refuses to write over it")
    func unsavedEditIsKept() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = try tree.writeFile("a.txt", contents: Self.text)
        let editor = EditorStandIn(path)
        defer { editor.leave() }
        editor.holdUnsavedEdit(Self.editorsEdit)

        #expect(throws: ComparedFileSave.Failure.changedSinceRead) { try Self.save(over: path) }
        #expect(Fixture.read(path) == Self.editorsEdit, "the edit is in the file, not lost")
        #expect(editor.told().contains("save"))
    }

    @Test("saving anyway after that writes over the edit, and the undo copy holds the edit")
    func savingAnywayKeepsTheEditForUndo() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = try tree.writeFile("a.txt", contents: Self.text)
        let editor = EditorStandIn(path)
        defer { editor.leave() }
        editor.holdUnsavedEdit(Self.editorsEdit)
        let undo = try Self.store(in: tree)
        #expect(throws: ComparedFileSave.Failure.changedSinceRead) {
            try Self.save(over: path, undo: undo)
        }

        let saved = try Self.save(over: path, overwritingChanges: true, undo: undo)
        #expect(Fixture.read(path) == "one\ntwo\nx\n")
        let record = try #require(saved.undo)
        let snapshot = try #require(record.archiveSnapshotPaths.first)
        #expect(Fixture.read(snapshot) == Self.editorsEdit)
    }

    @Test("an editor that never lets go fails the save by name, and the file is left alone")
    func stuckEditorFailsTheSave() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = try tree.writeFile("a.txt", contents: Self.text)
        let editor = EditorStandIn(path)
        defer { editor.leave() }
        editor.stopAnswering()

        let started = ContinuousClock.now
        #expect(throws: ComparedFileSave.Failure.failed(
            .unsupported(.fileHeldByAnotherApp(name: "a.txt"))
        )) {
            try Self.save(over: path, patience: 0.5)
        }
        #expect(ContinuousClock.now - started < .seconds(5), "gave up after its patience")
        #expect(Fixture.read(path) == Self.text)
    }

    @Test("⌘Z of a save tells the editor too")
    func undoIsHeard() async throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = try tree.writeFile("a.txt", contents: Self.text)
        let record = try #require(try Self.save(over: path, undo: Self.store(in: tree)).undo)
        let editor = EditorStandIn(path)
        defer { editor.leave() }

        #expect(UndoJournal.revert(record, using: backend).succeeded)
        #expect(Fixture.read(path) == Self.text)
        #expect(await told(editor, "changed"))
    }

    @Test("⌘Z refuses over an editor's unsaved edit, which the editor saved first")
    func undoKeepsUnsavedEdit() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = try tree.writeFile("a.txt", contents: Self.text)
        let record = try #require(try Self.save(over: path, undo: Self.store(in: tree)).undo)
        let editor = EditorStandIn(path)
        defer { editor.leave() }
        editor.holdUnsavedEdit(Self.editorsEdit)

        let report = UndoJournal.revert(record, using: backend)
        #expect(!report.succeeded)
        #expect(
            report.failures.first?.error == .unsupported(
                .archiveChangedSinceRewrite(archive: "a.txt")
            )
        )
        #expect(Fixture.read(path) == Self.editorsEdit)
    }
}
