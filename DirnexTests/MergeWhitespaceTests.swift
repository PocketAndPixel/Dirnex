import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// A conflict whitespace explains, in the merge window (PLAN.md §M37 Slice 5). What it is and what
/// the take puts in the result are `DirnexCore`'s and tested there; these pin the window's half: the
/// banner's sentence, the fifth take enabled and named only on such a conflict, ⌥⌘I, and the undo.
@Suite("Merge window whitespace")
@MainActor
struct MergeWhitespaceTests {
    /// Two conflicts: in the first yours only re-indented what theirs edited, and the second is an
    /// ordinary one.
    static let base = "f {\n  a\n  B\n  c\n}\nx\ny\nz\n"
    static let yours = "f {\n    a\n    B\n    c\n}\nx\nY\nz\n"
    static let theirs = "f {\n  a\n  B!\n  c\n}\nx\nT\nz\n"

    static func rig() throws -> MergeRig {
        try MergeRig(base: Data(base.utf8), yours: Data(yours.utf8), theirs: Data(theirs.utf8))
    }

    static let takeWithWhitespace = MergeRig.letter("i", keyCode: 34, [.option, .command])

    private static var segment: Int {
        MergeToolbar.takeChoices.firstIndex(of: .editWithWhitespace) ?? -1
    }

    @Test(
        "the banner names the conflict whitespace explains, and the fifth take is offered only there"
    )
    func bannerAndTake() throws {
        let rig = try Self.rig()
        defer { rig.cleanup() }
        let controller = rig.controller
        let toolbar = controller.toolbar
        #expect(controller.currentConflict == 0)
        #expect(controller.banner.stringValue == "Yours changed only whitespace in this conflict. "
            + "Take Theirs with Your Whitespace keeps both edits. "
            + "2 conflicts are still open. The result can be saved once each has a choice.")
        #expect(toolbar.take.isEnabled(forSegment: Self.segment))
        #expect(
            toolbar.take.toolTip(forSegment: Self.segment) == "Take Theirs with Your Whitespace (⌥⌘I)"
        )
        #expect(toolbar.take.image(forSegment: Self.segment)?.accessibilityDescription
            == "Take Theirs with Your Whitespace")

        controller.goToNextConflict()
        #expect(controller.currentConflict == 1)
        #expect(controller.banner.stringValue
            == "2 conflicts are still open. The result can be saved once each has a choice.")
        #expect(!toolbar.take.isEnabled(forSegment: Self.segment))
        #expect(toolbar.take.isEnabled(forSegment: 0), "the other takes are offered as ever")
        #expect(
            toolbar.take.toolTip(forSegment: Self.segment) == "Take One Side with the Other’s Whitespace (⌥⌘I)"
        )
    }

    @Test("⌥⌘I takes theirs with yours' whitespace, goes on, and Edit ▸ Undo names it")
    func takeByKey() async throws {
        let rig = try Self.rig()
        defer { rig.cleanup() }
        let controller = rig.controller
        #expect(controller.handleKey(Self.takeWithWhitespace))
        try await rig.landed()
        #expect(controller.merge?.choices == [.editWithWhitespace, nil])
        #expect(controller.resultPane.textView.string == "f {\n    a\n    B!\n    c\n}\nx\n\nz\n")
        #expect(controller.shown?.panes[.result]?.fills[2] == .resolved)
        #expect(controller.currentConflict == 1)
        #expect(controller.edits.undoMenuItemTitle == "Undo Take Theirs with Your Whitespace")

        // Not offered on the ordinary conflict: the key is taken, beeps, and changes nothing.
        let made = controller.choicesMade
        #expect(controller.handleKey(Self.takeWithWhitespace))
        #expect(controller.choicesMade == made)
        #expect(controller.merge?.choices == [.editWithWhitespace, nil])

        controller.edits.undo()
        try await rig.landed()
        #expect(controller.merge?.choices == [nil, nil])
        #expect(controller.currentConflict == 0)
    }

    @Test("the fifth segment makes the take, and Save writes both edits")
    func takeByButtonAndSave() async throws {
        let rig = try Self.rig()
        defer { rig.cleanup() }
        let controller = rig.controller
        try MergeTakeTests.press(segment: Self.segment, of: controller.toolbar.take)
        #expect(controller.choicesMade == 1, "the press reached the take")
        try await rig.landed()
        controller.take(.theirs)
        try await rig.landed()
        #expect(controller.toolbar.save.isEnabled)
        #expect(controller.handleKey(MergeRig.commandS))
        try await settleUntil { controller.savedChoices != nil && !controller.isSaving }
        #expect(rig.contents == "f {\n    a\n    B!\n    c\n}\nx\nT\nz\n")
    }

    @Test("the banner's sentence for each thing whitespace explains")
    func whitespaceSentences() {
        func text(_ kind: ConflictWhitespace.Kind, offered: Bool) -> String? {
            MergeWindowController.whitespaceText(
                ConflictWhitespace(kind: kind, combined: offered ? [] : nil)
            )
        }
        #expect(MergeWindowController.whitespaceText(nil) == nil)
        #expect(text(.yoursOnlyWhitespace, offered: false)
            == "Yours changed only whitespace in this conflict, on lines theirs changed too.")
        #expect(text(.theirsOnlyWhitespace, offered: true)
            == "Theirs changed only whitespace in this conflict. Take Yours with Their Whitespace keeps both edits.")
        #expect(text(.theirsOnlyWhitespace, offered: false)
            == "Theirs changed only whitespace in this conflict, on lines yours changed too.")
        #expect(text(.sidesDifferOnlyInWhitespace, offered: false)
            == "The two sides differ only in whitespace in this conflict.")
        #expect(
            MergeToolbar.takeTitle(.editWithWhitespace, editSide: .yours) == "Take Yours with Their Whitespace"
        )
    }
}
