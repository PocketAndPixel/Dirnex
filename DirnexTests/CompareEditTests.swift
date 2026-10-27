import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Edit Left and Edit Right in the compare window (PLAN.md §M33 Slice 5): what the editor is handed,
/// the copy watched for its write-back, the save first, and the windows and sides that open nothing.
/// The editor and the copy watch are the rig's stand-ins; F4's own launch is the browser's.
@Suite("Compare window edits")
@MainActor
struct CompareEditTests {
    private static let server = VFSPath(backend: Handoff.remoteID, path: "/srv/right.txt")

    /// The key-down a real F4 sends.
    private static let f4: NSEvent = {
        let characters = String(Character(UnicodeScalar(UInt16(NSF4FunctionKey)) ?? " "))
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.function],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 118
        ) ?? NSEvent()
    }()

    @Test("Edit Left hands the editor the local file itself and watches no copy")
    func localFileIsHandedOver() async throws {
        let rig = try CompareSaveRig("a\nB\nc\n", "a\nb\nc\n")
        defer { rig.cleanup() }
        let pencil = rig.controller.leftPane.editButton
        #expect(!pencil.isHidden && pencil.isEnabled)

        pencil.sendAction(pencil.action, to: pencil.target)
        try await settleUntil { !rig.editor.opened.isEmpty }
        #expect(rig.editor.opened.map(\.path) == [rig.leftPath])
        #expect(rig.editor.watched.isEmpty, "a local file's save lands where it lives")
    }

    @Test("Edit Right on a server file hands over the copy read, watched for its write-back")
    func serverCopyIsWatched() async throws {
        let rig = try CompareSaveRig(
            Data("a\nB\nc\n".utf8),
            Data("a\nb\nc\n".utf8),
            rightOrigin: Self.server,
            rightWriteBack: .remoteFile(Self.server)
        )
        defer { rig.cleanup() }
        rig.controller.editFile(on: .right)
        try await settleUntil { !rig.editor.opened.isEmpty }
        #expect(rig.editor.opened.map(\.path) == [rig.rightPath])
        #expect(rig.editor.watched == [EditedFile(
            destination: .remoteFile(Self.server),
            temporaryURL: URL(fileURLWithPath: rig.rightPath),
            name: "right.txt"
        )])
        #expect(rig.writeBacks.calls.isEmpty, "the editor's save is offered back, not this press")
    }

    @Test("F4 edits the file in the pane holding the keyboard")
    func f4FollowsTheKeyboard() async throws {
        let rig = try CompareSaveRig("a\nB\nc\n", "a\nb\nc\n")
        defer { rig.cleanup() }
        #expect(rig.controller.handleKey(Self.f4))
        try await settleUntil { rig.editor.opened.count == 1 }
        #expect(rig.editor.opened.last?.path == rig.leftPath, "the left pane when neither has it")

        let window = try #require(rig.controller.window)
        #expect(window.makeFirstResponder(rig.controller.rightPane.textView))
        #expect(rig.controller.handleKey(Self.f4))
        try await settleUntil { rig.editor.opened.count == 2 }
        #expect(rig.editor.opened.last?.path == rig.rightPath)

        // Tab on to the toolbar: F4 still edits the file the keyboard was last in.
        #expect(window.makeFirstResponder(rig.controller.toolbar.whitespace))
        #expect(rig.controller.handleKey(Self.f4))
        try await settleUntil { rig.editor.opened.count == 3 }
        #expect(rig.editor.opened.last?.path == rig.rightPath)
    }

    @Test("Edit on a side with unsaved copies asks first, and Cancel saves and opens nothing")
    func unsavedCopiesAskFirst() async throws {
        let rig = try CompareSaveRig("a\nB\nc\n", "a\nb\nc\n")
        defer { rig.cleanup() }
        try await rig.copy(to: .right)

        rig.controller.editFile(on: .right)
        let sheet = try await rig.sheet()
        let texts = CompareSaveRig.texts(in: sheet.contentView)
        #expect(texts.contains("Save the changes to “right.txt” before editing it?"))
        #expect(CompareSaveRig.buttons(in: sheet.contentView).map(\.title).contains("Save and Edit"))
        try await rig.answer(.alertSecondButtonReturn)

        try await settleUntil { rig.controller.window?.attachedSheet == nil }
        #expect(rig.editor.opened.isEmpty)
        #expect(rig.contents(rig.rightPath) == "a\nb\nc\n")
        #expect(rig.controller.unsavedSides == [.right])
    }

    @Test("Save and Edit saves the copies, then hands over the file with them in it")
    func saveAndEdit() async throws {
        let rig = try CompareSaveRig("a\nB\nc\n", "a\nb\nc\n")
        defer { rig.cleanup() }
        try await rig.copy(to: .right)

        rig.controller.editFile(on: .right)
        try await rig.answer(.alertFirstButtonReturn)
        try await settleUntil { !rig.editor.opened.isEmpty }
        #expect(rig.editor.opened.map(\.path) == [rig.rightPath])
        #expect(
            String(bytes: rig.editor.openedBytes[0], encoding: .utf8) == "a\nB\nc\n",
            "saved before the editor had it"
        )
        #expect(rig.controller.unsavedSides.isEmpty)
    }

    @Test("a side with nowhere to save has its pencil grayed and opens nothing")
    func nowhereToSave() async throws {
        let member = VFSPath(
            backend: .archive(forArchiveAt: "/tmp/outer.zip/inner.zip"),
            path: "/r.txt"
        )
        let rig = try CompareSaveRig(
            Data("a\nB\nc\n".utf8),
            Data("a\nb\nc\n".utf8),
            rightOrigin: member
        )
        defer { rig.cleanup() }
        #expect(rig.controller.rightPane.editButton.isEnabled == false)
        #expect(rig.controller.leftPane.editButton.isEnabled)

        rig.controller.editFile(on: .right)
        rig.controller.editFile(on: .left)
        try await settleUntil { rig.editor.opened.count == 1 }
        #expect(
            rig.editor.opened.map(\.path) == [rig.leftPath],
            "only the left file, pressed second"
        )
    }

    @Test("the conflict dialog's window shows no pencils, and F4 opens nothing")
    func conflictWindowOpensNothing() throws {
        let rig = try CompareSaveRig(Data("a\nB\n".utf8), Data("a\nb\n".utf8), allowsCopies: false)
        defer { rig.cleanup() }
        #expect(rig.controller.leftPane.editButton.isHidden)
        #expect(rig.controller.rightPane.editButton.isHidden)
        #expect(!rig.controller.canEdit(.left) && !rig.controller.canEdit(.right))
        // Refused before anything starts, so nothing is still on its way to the stand-in.
        #expect(rig.controller.handleKey(Self.f4), "taken, and answered with a beep")
        #expect(rig.editor.opened.isEmpty)
    }

    @Test("with no editor to open, the window says so, as F4 does")
    func noEditor() async throws {
        let rig = try CompareSaveRig("a\nB\nc\n", "a\nb\nc\n")
        defer { rig.cleanup() }
        rig.editor.editor = nil
        rig.controller.editFile(on: .left)
        let sheet = try await rig.sheet()
        #expect(CompareSaveRig.texts(in: sheet.contentView).contains("No text editor found"))
        try await rig.answer(.alertFirstButtonReturn)
    }

    @Test("each pencil is named after its side and the editor it opens")
    func pencilTitles() {
        #expect(ComparePaneView.editTitle(.left) == "Edit Left")
        #expect(ComparePaneView.editTitle(.right, in: "BBEdit") == "Edit Right in BBEdit")
        let pane = ComparePaneView(side: .right)
        #expect(pane.editButton.image?.accessibilityDescription == "Edit Right")
    }
}
