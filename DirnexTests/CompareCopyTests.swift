import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Copying changes across in the compare window (PLAN.md §M33 Slice 2). What a copy does to the
/// lines is `DirnexCore`'s and tested there; these pin the window's half: the keys and buttons, the
/// comparison again after each copy and the change it lands on, the window's undo under Edit ▸ Undo,
/// the edited marks, Swap Sides, and the windows and sides that take no copy.
@Suite("Compare window copies")
@MainActor
struct CompareCopyTests {
    private func source(_ name: String, _ bytes: Data) throws -> CompareSource {
        try CompareSource(
            name: name,
            detail: "/tmp/\(name)",
            document: ComparedDocument.decode(bytes),
            language: nil
        )
    }

    /// A window showing `left` against `right`, computed on the spot rather than through `present`,
    /// so nothing joins the app's list of open windows.
    private func window(
        _ left: String,
        _ right: String,
        rightBytes: Data? = nil,
        allowsCopies: Bool = true
    ) throws -> CompareWindowController {
        let leftSource = try source("left.txt", Data(left.utf8))
        let rightSource = try source("right.txt", rightBytes ?? Data(right.utf8))
        let controller = CompareWindowController(
            left: leftSource,
            right: rightSource,
            allowsCopies: allowsCopies,
            saving: .none
        )
        controller.show(CompareWindowController.prepare(
            left: leftSource,
            right: rightSource,
            options: LineDiffOptions(),
            coloringLimit: CompareTextStyle.syntaxColoringLimit
        ))
        return controller
    }

    /// Wait for the comparison a copy or an undo started to land.
    private func landed(_ controller: CompareWindowController) async throws {
        try await settleUntil { controller.comparedRevision == controller.sidesRevision }
    }

    private func text(_ source: CompareSource) -> String {
        source.document.text(ofFirstLines: .max)
    }

    private func copyKey(_ special: NSEvent.SpecialKey, keyCode: UInt16) -> NSEvent {
        let characters = String(Character(UnicodeScalar(UInt16(special.rawValue)) ?? " "))
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option, .command, .numericPad, .function],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) ?? NSEvent()
    }

    @Test("⌥⌘→ copies the current change to the right, compares again and goes to the next")
    func copyToRight() async throws {
        let controller = try window("a\nB\nc\nD\ne\n", "a\nb\nc\nd\ne\n")
        #expect(controller.currentChange == 0)
        #expect(controller.canCopy(to: .right))
        #expect(controller.handleKey(copyKey(.rightArrow, keyCode: 124)))
        try await landed(controller)
        #expect(text(controller.right) == "a\nB\nc\nd\ne\n")
        #expect(text(controller.left) == "a\nB\nc\nD\ne\n")
        #expect(controller.comparison?.changeRows.count == 1)
        // The change below the copied lines, now the first and only one.
        #expect(controller.currentChange == 0)
        #expect(controller.rightPane.textView.string == "a\nB\nc\nd\ne\n")
        #expect(controller.window?.isDocumentEdited == true)
        #expect(controller.rightPane.nameLabel.stringValue == "right.txt — Edited")
        #expect(controller.leftPane.nameLabel.stringValue == "left.txt")
    }

    /// Press one segment the way VoiceOver does. A momentary control keeps no selection set from
    /// code (`selectedSegment` reads -1 straight after), so setting one and sending the action
    /// reaches the action with no segment at all. The segments are read through `NSObject`
    /// (docs/NOTES.md ▸ Windows).
    private func press(segment: Int, of control: NSSegmentedControl) throws {
        let cell = try #require(control.accessibilityChildren()?.first as? NSObject)
        let segments = try #require(cell.value(forKey: "accessibilityChildren") as? [NSObject])
        try #require(segments.count > segment)
        _ = segments[segment].perform(#selector(NSAccessibilityElement.accessibilityPerformPress))
    }

    @Test("the toolbar's left arrow copies to the left file, and the last copy leaves no change")
    func copyToLeftWithTheButton() async throws {
        let controller = try window("a\nold\nc\n", "a\nnew\nc\n")
        try press(segment: 0, of: controller.toolbar.copy)
        #expect(controller.sidesRevision == 1, "the press reached the copy")
        try await landed(controller)
        #expect(text(controller.left) == "a\nnew\nc\n")
        #expect(controller.comparison?.diff.isIdentical == true)
        #expect(controller.currentChange == nil)
        #expect(!controller.toolbar.copy.isEnabled(forSegment: 0))
        #expect(!controller.toolbar.copy.isEnabled(forSegment: 1))
        #expect(controller.toolbar.counter.stringValue == "No differences")
    }

    @Test("Edit ▸ Undo reaches the window's undo, names the copy, and lands on the change again")
    func undoAndRedo() async throws {
        // Three changes, the middle one copied, so the change an undo lands on is not the one a
        // copy would go on to.
        let controller = try window("a\nB\nc\nD\ne\nF\ng\n", "a\nb\nc\nd\ne\nf\ng\n")
        let window = try #require(controller.window)
        controller.goToChange(1)
        controller.copyCurrentChange(to: .right)
        try await landed(controller)
        #expect(text(controller.right) == "a\nb\nc\nD\ne\nf\ng\n")
        #expect(controller.currentChange == 1, "the change below, now the second of two")

        // The route the menu item takes: a pane does not answer `undo:`, so it reaches the window,
        // whose manager is the controller's.
        #expect(!controller.leftPane.textView.responds(to: Selector(("undo:"))))
        #expect(window.undoManager === controller.edits)
        #expect(controller.edits.undoMenuItemTitle == "Undo Copy to Right")

        #expect(window.tryToPerform(Selector(("undo:")), with: nil))
        try await landed(controller)
        #expect(text(controller.right) == "a\nb\nc\nd\ne\nf\ng\n")
        #expect(controller.currentChange == 1, "the change the copy took away, not the one after")
        #expect(window.isDocumentEdited == false)
        #expect(controller.rightPane.nameLabel.stringValue == "right.txt")
        #expect(controller.edits.redoMenuItemTitle == "Redo Copy to Right")

        #expect(window.tryToPerform(Selector(("redo:")), with: nil))
        try await landed(controller)
        #expect(text(controller.right) == "a\nb\nc\nD\ne\nf\ng\n")
        #expect(controller.currentChange == 1, "a redo is a copy again: the change below")
        #expect(window.isDocumentEdited == true)
    }

    @Test("a copy of the last change leaves the last one left current")
    func copyOfTheLastChange() async throws {
        let controller = try window("a\nB\nc\nD\ne\n", "a\nb\nc\nd\ne\n")
        controller.goToChange(1)
        controller.copyCurrentChange(to: .right)
        try await landed(controller)
        #expect(controller.currentChange == 0)
        #expect(controller.canCopy(to: .right))
    }

    @Test("Swap Sides takes each file's copies with it, and undo still finds the file")
    func swapCarriesEdits() async throws {
        let controller = try window("a\nB\nc\n", "a\nb\nc\nextra\n")
        controller.copyCurrentChange(to: .right)
        try await landed(controller)
        #expect(text(controller.right) == "a\nB\nc\nextra\n")

        controller.swapSides()
        try await landed(controller)
        #expect(controller.left.name == "right.txt")
        #expect(text(controller.left) == "a\nB\nc\nextra\n")
        #expect(controller.leftPane.nameLabel.stringValue == "right.txt — Edited")
        #expect(controller.rightPane.nameLabel.stringValue == "left.txt")

        controller.edits.undo()
        try await landed(controller)
        #expect(text(controller.left) == "a\nb\nc\nextra\n", "undone on the left, where it now is")
        #expect(text(controller.right) == "a\nB\nc\n")
        #expect(controller.window?.isDocumentEdited == false)
    }

    @Test("a copy waits for the comparison of the files as they stand")
    func noCopyOnAStaleComparison() async throws {
        let controller = try window("a\nB\nc\nD\ne\n", "a\nb\nc\nd\ne\n")
        controller.copyCurrentChange(to: .right)
        // The new comparison has not landed: the change still named is the old one's.
        #expect(!controller.canCopy(to: .right))
        #expect(!controller.canCopy(to: .left))
        controller.copyCurrentChange(to: .right)
        #expect(text(controller.right) == "a\nB\nc\nd\ne\n", "one copy, not two")
        try await landed(controller)
        #expect(controller.canCopy(to: .right))
    }

    @Test("a window that takes no copies hides the arrows and changes neither file")
    func windowWithoutCopies() throws {
        let controller = try window("a\nB\n", "a\nb\n", allowsCopies: false)
        #expect(controller.toolbar.copy.isHidden)
        #expect(controller.handleKey(copyKey(.rightArrow, keyCode: 124)))
        #expect(controller.handleKey(copyKey(.leftArrow, keyCode: 123)))
        #expect(text(controller.right) == "a\nb\n")
        #expect(text(controller.left) == "a\nB\n")
        #expect(controller.edits.canUndo == false)
    }

    @Test("a file that would not come back byte for byte takes no copy, and the banner says why")
    func readOnlySide() throws {
        // Two UTF-8 marks: Foundation drops the second, so the file cannot be written back as read.
        let doubled = Data([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF] + Array("a\nb\n".utf8))
        let controller = try window("a\nB\n", "", rightBytes: doubled)
        #expect(!controller.canCopy(to: .right))
        #expect(controller.canCopy(to: .left))
        #expect(!controller.toolbar.copy.isEnabled(forSegment: 1))
        #expect(controller.toolbar.copy.isEnabled(forSegment: 0))
        #expect(controller.banner.stringValue.hasSuffix(
            "The right file is read-only here: Dirnex can’t write it back exactly as it was read."
        ))
        // The control: the same text with one mark takes copies, and the banner says nothing of it.
        let single = try window("a\nB\n", "", rightBytes: Data(doubled.dropFirst(3)))
        #expect(single.canCopy(to: .right))
        #expect(!single.banner.stringValue.contains("read-only"))
    }

    @Test("after a copy the next change is current, after an undo the restored one")
    func changeToShow() throws {
        let left = try ComparedDocument.decode(Data("a\nX\nb\nY\nc\nZ\n".utf8))
        let right = try ComparedDocument.decode(Data("a\nx\nb\ny\nc\nz\n".utf8))
        let comparison = TextComparison(left, right)
        #expect(comparison.diff.changes.count == 3)
        func shown(_ edited: Range<Int>, undoing: Bool) -> Int? {
            CompareWindowController.changeToShow(
                after: edited,
                on: .right,
                in: comparison,
                undoing: undoing
            )
        }
        #expect(shown(1..<2, undoing: false) == 1)
        #expect(shown(3..<4, undoing: true) == 1)
        #expect(shown(5..<6, undoing: false) == 2, "none below: the last")
        #expect(shown(2..<2, undoing: false) == 1, "a deletion: the change after where it was")
        let none = TextComparison(left, left)
        #expect(CompareWindowController.changeToShow(
            after: 0..<1,
            on: .left,
            in: none,
            undoing: true
        ) == nil)
    }

    /// `+Copy` answers the delegate's undo-manager question a file away from the conformance, and
    /// AppKit asks only if the runtime can see the answer.
    @Test("the window's delegate hands AppKit the window's undo manager")
    func undoManagerReachesTheRuntime() throws {
        let controller = try window("a\n", "b\n")
        #expect(controller.responds(to: #selector(NSWindowDelegate.windowWillReturnUndoManager(_:))))
        #expect(controller.window?.undoManager === controller.edits)
    }
}
