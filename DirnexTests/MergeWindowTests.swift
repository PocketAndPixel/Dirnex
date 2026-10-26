import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// A merge window over three texts, its result saved into a real file in a temporary folder
/// (PLAN.md §M34 Slice 3). The file starts as `target`, yours' bytes unless a test says otherwise,
/// as an editor's copy of a server file would; a conflicted working-tree file would hold markers.
///
/// The window is prepared on the spot rather than through `present`, so nothing joins the app's
/// list of open windows.
@MainActor
struct MergeRig {
    let directory: URL
    let controller: MergeWindowController
    /// What the window's saves filed with the browser window's journal.
    let journal: CompareSaveRig.JournalBox

    /// Two conflicts, at `b` and at `i`, with a change only yours made between them (`e`) and one
    /// only theirs made (`g`).
    static let base = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n"
    static let yours = "a\nY\nc\nd\nE\nf\ng\nh\nI\nj\n"
    static let theirs = "a\nT\nc\nd\ne\nf\nG\nh\nK\nj\n"

    init(
        base: Data = Data(MergeRig.base.utf8),
        yours: Data = Data(MergeRig.yours.utf8),
        theirs: Data = Data(MergeRig.theirs.utf8),
        target: Data? = nil,
        store: ArchiveUndoStore? = nil,
        carry: (@MainActor (NSWindow?) async -> Void)? = nil,
        closed: @escaping @MainActor () -> Void = {}
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("notes.txt").path
        try (target ?? yours).write(to: URL(fileURLWithPath: path))
        let input = try MergeInput(
            name: "notes.txt",
            base: MergeVersion(detail: "as downloaded", document: ComparedDocument.decode(base)),
            yours: MergeVersion(detail: "your edit", document: ComparedDocument.decode(yours)),
            theirs: MergeVersion(detail: "on the server", document: ComparedDocument.decode(theirs)),
            target: .reading(path),
            resultDetail: path,
            language: nil
        )
        let journal = CompareSaveRig.JournalBox()
        self.journal = journal
        controller = MergeWindowController(
            input: input,
            saving: MergeSaving(
                undo: { ArchiveUndoStorage.Request(store: store, live: []) },
                journal: { journal.records.append($0) },
                carry: carry,
                closed: closed
            )
        )
        let merge = TextMerge(
            base: input.base.document,
            yours: input.yours.document,
            theirs: input.theirs.document
        )
        controller.load(
            merge,
            prepared: MergePrepared.prepare(
                merge,
                language: nil,
                coloringLimit: CompareTextStyle.syntaxColoringLimit
            )
        )
        Self.retained.append(controller)
    }

    /// Every window a rig built, kept for the life of the test host: tearing down a window whose
    /// sheet is still settling crashes a later test (docs/NOTES.md ▸ Testing).
    private static var retained: [MergeWindowController] = []

    var path: String { directory.appendingPathComponent("notes.txt").path }

    var contents: String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? "<none>"
    }

    /// Wait for the screen to show every choice made so far.
    func landed() async throws {
        try await settleUntil { controller.shownChoices == controller.choicesMade }
    }

    /// The sheet on the window once it is up.
    func sheet() async throws -> NSWindow {
        try await settleUntil { controller.window?.attachedSheet != nil }
        return try #require(controller.window?.attachedSheet)
    }

    func answer(_ response: NSApplication.ModalResponse) async throws {
        try controller.window?.endSheet(await sheet(), returnCode: response)
    }

    func cleanup() {
        if let window = controller.window, let sheet = window.attachedSheet {
            window.endSheet(sheet)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    /// The key-down a real arrow with `modifiers` sends.
    static func arrow(
        _ special: NSEvent.SpecialKey,
        keyCode: UInt16,
        _ modifiers: NSEvent.ModifierFlags
    ) -> NSEvent {
        let characters = String(Character(UnicodeScalar(UInt16(special.rawValue)) ?? " "))
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers.union([.numericPad, .function]),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) ?? NSEvent()
    }

    /// The key-down a letter with `modifiers` sends.
    static func letter(_ character: String, keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        ) ?? NSEvent()
    }

    static let takeYours = arrow(.rightArrow, keyCode: 124, [.option, .command])
    static let takeTheirs = arrow(.leftArrow, keyCode: 123, [.option, .command])
    static let takeYoursFirst = arrow(.rightArrow, keyCode: 124, [.shift, .option, .command])
    static let takeTheirsFirst = arrow(.leftArrow, keyCode: 123, [.shift, .option, .command])
    static let nextConflict = arrow(.downArrow, keyCode: 125, [.option, .command])
    static let previousConflict = arrow(.upArrow, keyCode: 126, [.option, .command])
    static let showBase = letter("b", keyCode: 11, [.option, .command])
    static let commandS = letter("s", keyCode: 1, [.command])
    static let commandW = letter("w", keyCode: 13, [.command])
}

/// The merge window, on the app side (PLAN.md §M34 Slice 3). What a merge *is* is `DirnexCore`'s
/// and tested there; these pin what the window shows of it: the panes level by row, what each row
/// is colored as, the marks, Show Base, and the counter and the banner.
@Suite("Merge window")
@MainActor
struct MergeWindowTests {
    @Test(
        "Yours, Result and Theirs show their rows level, and the result has a gap at each conflict"
    )
    func panesShowTheirRows() throws {
        let rig = try MergeRig()
        defer { rig.cleanup() }
        let controller = rig.controller
        #expect(controller.yoursPane.textView.string == "a\nY\nc\nd\nE\nf\ng\nh\nI\nj\n")
        #expect(controller.resultPane.textView.string == "a\n\nc\nd\nE\nf\nG\nh\n\nj\n")
        #expect(controller.theirsPane.textView.string == "a\nT\nc\nd\ne\nf\nG\nh\nK\nj\n")
        #expect(controller.basePane.textView.string == "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n")
        #expect(controller.basePane.isHidden)
        #expect(!controller.isBaseShown)
        #expect(controller.window?.title == "Merge of “notes.txt”")
        #expect(controller.yoursPane.nameLabel.stringValue == "Yours")
        #expect(controller.resultPane.nameLabel.stringValue == "Result")
        #expect(controller.theirsPane.nameLabel.stringValue == "Theirs")
        for (_, pane) in controller.panes {
            #expect(pane.editButton.isHidden)
            #expect(pane.textView.textLayoutManager?.delegate is CompareRowColoring)
        }
        #expect(controller.currentConflict == 0, "a merge opens on its first conflict")
        #expect(controller.toolbar.counter.stringValue == "Conflict 1 of 2")
        #expect(
            controller.banner.stringValue
                == "2 conflicts are still open. The result can be saved once each has a choice."
        )
        #expect(!controller.toolbar.save.isEnabled)
        #expect(controller.window?.isDocumentEdited == false)
    }

    @Test("each column colors a merged change where it shows, and a conflict in every column")
    func rowFills() throws {
        let rig = try MergeRig()
        defer { rig.cleanup() }
        let prepared = try #require(rig.controller.shown)
        func fills(_ column: MergeRow.Column) -> [AlignedRowFill]? {
            prepared.panes[column]?.fills
        }
        // Rows: a, the conflict at b, c, d, yours' e, f, theirs' g, h, the conflict at i, j.
        #expect(fills(.yours) == [
            .same, .conflict, .same, .same, .changed, .same, .same, .same, .conflict, .same
        ])
        #expect(fills(.theirs) == [
            .same, .conflict, .same, .same, .same, .same, .changed, .same, .conflict, .same
        ])
        // The result's empty rows at an open conflict are where its lines will go.
        #expect(fills(.result) == [
            .same, .conflict, .same, .same, .changed, .same, .changed, .same, .conflict, .same
        ])
        #expect(fills(.base) == [
            .same, .conflict, .same, .same, .changed, .same, .changed, .same, .conflict, .same
        ])
        #expect(prepared.markRows == [1..<2, 4..<5, 6..<7, 8..<9])
        #expect(prepared.markKinds == [.conflict, .change, .change, .conflict])
        #expect(prepared.conflictMarks == [0, 3])
        #expect(rig.controller.yoursBand.current == 0)
        #expect(rig.controller.overview.kinds == prepared.markKinds)

        // The fragments TextKit draws carry the fills.
        var drawn: [Bool] = []
        rig.controller.resultPane.textView.textLayoutManager?.enumerateTextLayoutFragments(
            from: nil,
            options: [.ensuresLayout]
        ) { fragment in
            drawn.append((fragment as? CompareRowFragment)?.fill != nil)
            return true
        }
        #expect(drawn == fills(.result)?.map { $0 != .same })
    }

    @Test("a chosen conflict is colored as chosen, and its gaps as gaps")
    func chosenFills() {
        let row = MergeRow(region: 0, yours: 3, result: nil, theirs: nil, base: 2)
        #expect(MergePrepared.fill(.result, of: row, kind: .conflict, isChosen: false) == .conflict)
        #expect(MergePrepared.fill(.result, of: row, kind: .conflict, isChosen: true) == .gap)
        #expect(MergePrepared.fill(.yours, of: row, kind: .conflict, isChosen: true) == .resolved)
        #expect(MergePrepared.fill(.theirs, of: row, kind: .conflict, isChosen: false) == .gap)
        #expect(MergePrepared.fill(.base, of: row, kind: .theirs, isChosen: false) == .changed)
        #expect(MergePrepared.fill(.yours, of: row, kind: .theirs, isChosen: false) == .same)
        #expect(MergePrepared.fill(.theirs, of: row, kind: .same, isChosen: false) == .gap)
    }

    @Test("⌥⌘B shows the base at the left edge, level and in the Tab order, and hides it again")
    func showBase() throws {
        let rig = try MergeRig()
        defer { rig.cleanup() }
        let controller = rig.controller
        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(controller.yoursPane.frame.minX == 0)
        #expect(controller.yoursPane.textView.nextKeyView === controller.resultPane.textView)
        #expect(controller.theirsPane.textView.nextKeyView === controller.yoursPane.textView)

        #expect(controller.handleKey(MergeRig.showBase))
        #expect(controller.isBaseShown)
        #expect(controller.toolbar.showBase.state == .on)
        #expect(!controller.baseBand.isHidden)
        #expect(controller.basePane.frame.minX == 0)
        #expect(controller.yoursPane.frame.minX > controller.basePane.frame.maxX)
        #expect(abs(controller.basePane.frame.width - controller.resultPane.frame.width) < 0.5)
        #expect(controller.theirsPane.textView.nextKeyView === controller.basePane.textView)
        #expect(controller.basePane.textView.nextKeyView === controller.yoursPane.textView)

        controller.toolbar.showBase.performClick(nil)
        #expect(!controller.isBaseShown)
        #expect(controller.basePane.isHidden)
        #expect(controller.yoursPane.frame.minX == 0)
        #expect(controller.theirsPane.textView.nextKeyView === controller.yoursPane.textView)
    }

    @Test("far into a large merge, every pane shown has the same row at the top, the base included")
    func panesStayLevel() async throws {
        // Lines of different lengths in each version, so TextKit's estimates of where a far row is
        // disagree between the documents, and a conflict near the end.
        let count = 6000
        func text(_ change: (Int) -> String) -> Data {
            Data(((0..<count).map(change).joined(separator: "\n") + "\n").utf8)
        }
        let rig = try MergeRig(
            base: text { "\($0)" + String(repeating: "b", count: $0 % 40) },
            yours: text { $0 == 5000 ? "mine" : "\($0)" + String(repeating: "b", count: $0 % 40) },
            theirs: text { $0 == 5000 ? "other" : "\($0)" + String(repeating: "b", count: $0 % 40) }
        )
        defer { rig.cleanup() }
        let controller = rig.controller
        controller.setBaseShown(true)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        for row in [4800, 300, 5000] {
            controller.yoursPane.textView.scroll(toRow: row, offset: 0, x: 0)
            for (_, pane) in controller.panes {
                pane.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
            }
            try await Task.sleep(for: .milliseconds(30))
            let top = controller.yoursPane.textView.rowAtTop()
            #expect(top?.row == row)
            for pane in [controller.resultPane, controller.theirsPane, controller.basePane] {
                #expect(pane.textView.rowAtTop()?.row == top?.row)
            }
        }
    }

    @Test("⌥⌘↓ and ⌥⌘↑ go from conflict to conflict, and a click in the overview picks its conflict")
    func navigation() throws {
        let rig = try MergeRig()
        defer { rig.cleanup() }
        let controller = rig.controller
        #expect(controller.handleKey(MergeRig.nextConflict))
        #expect(controller.currentConflict == 1)
        #expect(controller.toolbar.counter.stringValue == "Conflict 2 of 2")
        #expect(controller.yoursBand.current == 3, "the second conflict is the fourth mark")
        #expect(controller.handleKey(MergeRig.nextConflict), "the last: a beep, and it stays")
        #expect(controller.currentConflict == 1)
        #expect(controller.handleKey(MergeRig.previousConflict))
        #expect(controller.currentConflict == 0)

        controller.jump(toRow: 5)
        #expect(controller.currentConflict == nil)
        #expect(controller.toolbar.counter.stringValue == "2 conflicts")
        #expect(!controller.toolbar.take.isEnabled(forSegment: 0))
        controller.jump(toRow: 8)
        #expect(controller.currentConflict == 1)
        #expect(controller.toolbar.take.isEnabled(forSegment: 0))
    }

    @Test("the counter and the banner name the conflicts, and the overview lets a conflict win")
    func counterBannerAndOverview() {
        #expect(MergeToolbar.counterText(current: nil, count: 0) == "No conflicts")
        #expect(MergeToolbar.counterText(current: 1, count: 5) == "Conflict 2 of 5")
        #expect(MergeToolbar.counterText(current: nil, count: 1) == "1 conflict")
        #expect(MergeWindowController.bannerText(conflicts: 0, open: 0)
            == "Every change merged without a conflict.")
        #expect(MergeWindowController.bannerText(conflicts: 3, open: 1)
            == "1 conflict is still open. The result can be saved once it has a choice.")
        #expect(MergeWindowController.bannerText(conflicts: 3, open: 0) == nil)
        let buckets = CompareOverviewView.buckets(
            height: 10,
            rowCount: 10,
            changes: [0..<2, 1..<3, 5..<6, 5..<7],
            kinds: [.change, .conflict, .change, .resolved]
        )
        #expect(buckets[1] == .conflict)
        #expect(buckets[5] == .resolved)
        #expect(CompareChangeKind.removal.combined(with: .insertion) == .change)
    }

    @Test("before the merge is computed the counter says nothing, and nothing can be taken or saved")
    func beforeTheMerge() throws {
        let version = try MergeVersion(
            detail: "",
            document: ComparedDocument.decode(Data("a\n".utf8))
        )
        let controller = MergeWindowController(
            input: MergeInput(
                name: "notes.txt",
                base: version,
                yours: version,
                theirs: version,
                target: ComparedFileSave.Target(path: "/nonexistent/notes.txt", witness: nil),
                resultDetail: "",
                language: nil
            ),
            saving: .none
        )
        #expect(controller.merge == nil)
        #expect(controller.toolbar.counter.stringValue.isEmpty)
        #expect(!controller.toolbar.navigation.isEnabled(forSegment: 1))
        #expect(!controller.toolbar.take.isEnabled(forSegment: 0))
        #expect(!controller.toolbar.save.isEnabled)
        #expect(controller.handleKey(MergeRig.commandS), "taken, and a beep")
        #expect(!controller.isSaving)
    }

    @Test("a merge with no conflict says so, takes nothing, and can be saved at once")
    func cleanMerge() throws {
        let rig = try MergeRig(theirs: Data("a\nb\nc\nd\ne\nf\nG\nh\ni\nj\n".utf8))
        defer { rig.cleanup() }
        let controller = rig.controller
        #expect(controller.currentConflict == nil)
        #expect(controller.toolbar.counter.stringValue == "No conflicts")
        #expect(controller.banner.stringValue == "Every change merged without a conflict.")
        #expect(controller.resultPane.textView.string == "a\nY\nc\nd\nE\nf\nG\nh\nI\nj\n")
        #expect(controller.toolbar.save.isEnabled)
        #expect(!controller.toolbar.navigation.isEnabled(forSegment: 1))
        #expect(controller.handleKey(MergeRig.takeYours), "taken, and a beep")
        #expect(controller.edits.canUndo == false)
        #expect(controller.window?.isDocumentEdited == false, "no choice to lose by closing")
    }
}
