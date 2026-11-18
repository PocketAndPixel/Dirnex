import Foundation
import Testing

@testable import DirnexCore

/// The part of an undo that needs root (PLAN.md §M40 Slice 5), against real temp files.
///
/// No test can be root or type a password, so these take the two seams Slice 4's suites take: an
/// `actor` who owns none of the files, which makes every change need root, and the generated bodies
/// run by an unprivileged `/bin/sh`, which can make them because the tester does own the files. What
/// that leaves to the live run is only the password dialog.
@Suite("EscalatedUndo")
struct EscalatedUndoTests {
    private let backend = LocalBackend()
    /// Someone who owns nothing in the tree, so every change to it needs root.
    private let stranger = UserContext(userID: getuid() + 1, groupIDs: [])

    private func mode(_ path: VFSPath) throws -> UInt16 {
        try FileAttributeIO.read(at: path).attributes.permissions.rawValue & 0o7777
    }

    /// `names` written into `tree` at 0644 and changed to 0600 with one batch record, as a
    /// multi-selection Save journals them.
    private func changedToPrivate(_ names: [String], in tree: TempTree) throws -> (
        UndoRecord,
        [VFSPath]
    ) {
        var entries: [UndoRecord.AttributeBatchEntry] = []
        var paths: [VFSPath] = []
        for name in names {
            let path = VFSPath.local(try tree.writeFile(name, contents: name))
            chmod(path.path, 0o644)
            let old = try FileAttributeIO.read(at: path).attributes
            chmod(path.path, 0o600)
            let new = try FileAttributeIO.read(at: path).attributes
            entries.append(.init(path: path, actsOnLink: false, old: old, new: new))
            paths.append(path)
        }
        return (try #require(UndoRecord.attributeBatchChange(entries)), paths)
    }

    private func run(_ batch: EscalatedAttributeBatch) throws {
        for body in batch.bodies() {
            let result = try EscalatedBatchSupport.runShell(body)
            #expect(result.status == 0, "\(result.stderr)")
        }
    }

    // MARK: - What goes to root

    @Test("a record whose items are all the user's own asks nobody")
    func ownItemsNeedNoAdministrator() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let (record, _) = try changedToPrivate(["a.txt"], in: tree)
        #expect(record.changesLocalAttributes)
        #expect(EscalatedUndo(reverting: record, actor: .current()) == nil)
    }

    @Test("a record with no attribute step is never measured")
    func moveRecordChangesNoAttributes() {
        let record = UndoRecord(
            label: .move,
            steps: [.restore(from: .local("/tmp/x/a"), to: .local("/tmp/a"))]
        )
        #expect(!record.changesLocalAttributes)
        #expect(EscalatedUndo(reverting: record, actor: stranger) == nil)
    }

    @Test(
        "the items that need root go to the batch in the record's order, and every other step stays"
    )
    func partitionKeepsOrder() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let (batchRecord, paths) = try changedToPrivate(["a.txt", "b.txt"], in: tree)
        let move = UndoStep.restore(from: tree.vfsPath("moved"), to: tree.vfsPath("original"))
        // b's step first, then a move, then a's: the batch takes b then a, the move stays.
        let steps = [batchRecord.steps[1], move, batchRecord.steps[0]]
        let record = UndoRecord(label: .changeAttributes, steps: steps)

        let escalation = try #require(EscalatedUndo(reverting: record, actor: stranger))

        #expect(escalation.batch.items.map(\.path) == [paths[1], paths[0]])
        #expect(escalation.batch.items.allSatisfy {
            $0.diff.permissions?.rawValue == 0o644 && $0.diff.ownerID == nil
        })
        #expect(escalation.remainder.steps == [move])
        #expect(escalation.remainder.id == record.id)
        #expect(escalation.remainder.label == record.label)
    }

    @Test("an item's attributes and its list go to root together, as one item")
    func attributesAndListAreOneItem() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
        chmod(path.path, 0o644)
        let subject = ACLSubject(
            kind: .user,
            guid: try #require(ACLIdentity.guid(forUserID: getuid())),
            name: NSUserName(),
            numericID: getuid()
        )
        let oldList = AccessControlList()
        let newList = AccessControlList(entries: [
            ACLEntry(subject: subject, disposition: .deny, rights: [.delete])
        ])
        let old = try FileAttributeIO.read(at: path).attributes
        chmod(path.path, 0o600)
        try AccessControlListIO.write(newList, to: path)
        let new = try FileAttributeIO.read(at: path).attributes
        let record = try #require(UndoRecord.attributeChange(
            at: path, actsOnLink: false, from: old, to: new,
            accessControlList: (old: oldList, new: newList)
        ))
        #expect(record.steps.count == 2)

        let escalation = try #require(EscalatedUndo(reverting: record, actor: stranger))

        let item = try #require(escalation.batch.items.first)
        #expect(escalation.batch.items.count == 1)
        #expect(item.diff.permissions?.rawValue == 0o644)
        #expect(item.desiredACL == oldList)
        #expect(item.currentACL == newList)
        #expect(escalation.remainder.steps.isEmpty)
    }

    @Test("a Created date only root could set goes to the batch, which then has nothing to run")
    func creationDateAloneHasNoCommand() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
        let now = try FileAttributeIO.read(at: path).attributes
        var earlier = now
        earlier.creationDate = Date(timeIntervalSince1970: 1_000_000)
        let record = try #require(
            UndoRecord.attributeChange(at: path, actsOnLink: false, from: earlier, to: now)
        )

        let escalation = try #require(EscalatedUndo(reverting: record, actor: stranger))
        #expect(!escalation.batch.hasCommands)
        #expect(escalation.batch.omissions == [.creationDate])
    }

    @Test("an item that has gone stays in the remainder, where the executor reports it")
    func goneItemStaysForTheExecutor() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let (record, paths) = try changedToPrivate(["a.txt", "b.txt"], in: tree)
        try FileManager.default.removeItem(atPath: paths[0].path)

        let escalation = try #require(EscalatedUndo(reverting: record, actor: stranger))
        #expect(escalation.batch.items.map(\.path) == [paths[1]])
        #expect(escalation.remainder.steps == [record.steps[0]])

        let report = UndoJournal.revert(escalation.remainder, using: backend, actor: stranger)
        #expect(report.failures.map(\.path) == [paths[0]])
        #expect(report.failures.first?.error == .notFound(paths[0]))
    }

    // MARK: - The executor agrees

    /// Someone who ran the dialog's command in Terminal and pressed Cancel: the values are on disk and
    /// the step is still on the stack. The next ⌘Z must find nothing for root, and the executor must
    /// then take the step without refusing it, or the user meets a refusal for a change already made.
    @Test(
        "a value already on disk is not asked for, and the executor takes the step without refusing"
    )
    func valueAlreadyOnDiskAsksNobody() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let (record, paths) = try changedToPrivate(["a.txt"], in: tree)
        chmod(paths[0].path, 0o644)

        #expect(EscalatedUndo(reverting: record, actor: stranger) == nil)
        let report = UndoJournal.revert(record, using: backend, actor: stranger)
        #expect(report.succeeded, "\(report.failures)")
    }

    @Test("a list already on the item is not asked for either")
    func listAlreadyOnDiskAsksNobody() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
        let attributes = try FileAttributeIO.read(at: path).attributes
        let subject = ACLSubject(
            kind: .user,
            guid: try #require(ACLIdentity.guid(forUserID: getuid())),
            name: NSUserName(),
            numericID: getuid()
        )
        let list = AccessControlList(entries: [
            ACLEntry(subject: subject, disposition: .deny, rights: [.delete])
        ])
        let record = try #require(UndoRecord.attributeChange(
            at: path, actsOnLink: false, from: attributes, to: attributes,
            accessControlList: (old: AccessControlList(), new: list)
        ))

        try AccessControlListIO.write(list, to: path)
        #expect(EscalatedUndo(reverting: record, actor: stranger) != nil)
        try AccessControlListIO.write(AccessControlList(), to: path)
        #expect(EscalatedUndo(reverting: record, actor: stranger) == nil)
        #expect(UndoJournal.revert(record, using: backend, actor: stranger).succeeded)
    }

    // MARK: - Run as root, then the rest

    @Test("the batch's commands put every item back, and the remainder finishes without a refusal")
    func batchThenRemainderUndoesTheRecord() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let (batchRecord, paths) = try changedToPrivate(["a.txt", "b.txt"], in: tree)
        try tree.writeFile("moved.txt", contents: "m")
        let move = UndoStep.restore(from: tree.vfsPath("moved.txt"), to: tree.vfsPath("back.txt"))
        let record = UndoRecord(label: .changeAttributes, steps: batchRecord.steps + [move])

        let escalation = try #require(EscalatedUndo(reverting: record, actor: stranger))
        try run(escalation.batch)
        let report = UndoJournal.revert(escalation.remainder, using: backend, actor: stranger)

        #expect(report.succeeded, "\(report.failures)")
        #expect(try paths.map(mode) == [0o644, 0o644])
        #expect(FileManager.default.fileExists(atPath: tree.vfsPath("back.txt").path))
        #expect(escalation.batch.outcomeOnDisk().unchanged.isEmpty)
    }

    @Test("redo asks the same question of the inverted record, and re-applies the change")
    func redoEscalatesTheInvertedRecord() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let (record, paths) = try changedToPrivate(["a.txt", "b.txt"], in: tree)
        let undo = try #require(EscalatedUndo(reverting: record, actor: stranger))
        try run(undo.batch)
        #expect(try paths.map(mode) == [0o644, 0o644])

        let redo = try #require(EscalatedUndo(reverting: record.inverted, actor: stranger))
        #expect(redo.batch.items.map(\.path) == [paths[1], paths[0]])
        try run(redo.batch)
        #expect(try paths.map(mode) == [0o600, 0o600])
    }
}

/// Taking an entry by identity, for the undo that asks before it takes (PLAN.md §M40 Slice 5).
@Suite("UndoJournal ▸ taking a given entry")
struct UndoJournalTakeEntryTests {
    /// One record per name, the same one on every call: an entry is found by being equal, and a
    /// record minted twice has two ids.
    private static let ids = ["a": UUID(), "b": UUID()]

    private func entry(_ name: String) -> UndoEntry {
        .fileOperation(UndoRecord(
            id: Self.ids[name] ?? UUID(),
            label: .rename,
            date: Date(timeIntervalSince1970: 0),
            steps: [.restore(from: .local("/t/\(name)2"), to: .local("/t/\(name)"))]
        ))
    }

    /// Each entry's steps. An inverted record gets an id of its own every time it is made, so an
    /// entry on the redo stack equals only itself as stored, and these compare what it does.
    private func steps(_ entries: [UndoEntry]) -> [[UndoStep]] {
        entries.compactMap { $0.fileOperation?.steps }
    }

    private func inverseSteps(_ name: String) -> [[UndoStep]] {
        steps([entry(name).inverted])
    }

    @Test("an entry on top is taken exactly as ⌘Z takes the top")
    func topEntryMatchesTakeForUndo() {
        var byEntry = UndoJournal(records: [entry("a"), entry("b")])
        var byTop = byEntry
        byEntry.takeForUndo(entry("b"))
        _ = byTop.takeForUndo()
        #expect(byEntry.records == byTop.records)
        #expect(steps(byEntry.redoRecords) == steps(byTop.redoRecords))
        #expect(steps(byEntry.redoRecords) == inverseSteps("b"))
    }

    @Test("an entry under a newer one is taken from beneath it, and the newer one stays on top")
    func entryUnderANewerOne() {
        var journal = UndoJournal(records: [entry("a")])
        journal.record(entry("b"))
        journal.takeForUndo(entry("a"))
        #expect(journal.records == [entry("b")])
        #expect(steps(journal.redoRecords) == inverseSteps("a"))
    }

    @Test("redo by entry puts the original back on top of the undo stack")
    func redoByEntry() throws {
        var journal = UndoJournal(records: [entry("a")])
        _ = journal.takeForUndo()
        let redo = try #require(journal.redoTop)
        journal.takeForRedo(redo)
        #expect(steps(journal.records) == steps([entry("a")]))
        #expect(journal.redoRecords.isEmpty)
    }

    @Test("an entry no longer on the stack still leaves its inverse, since the reversal ran")
    func goneEntryStillLeavesItsInverse() {
        var journal = UndoJournal(records: [entry("b")])
        journal.takeForUndo(entry("a"))
        #expect(journal.records == [entry("b")])
        #expect(steps(journal.redoRecords) == inverseSteps("a"))
    }
}
