import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The copy and move dialog's folder field (2026-11-19): it opens on the other pane's folder, an
/// untouched field hands over exactly that folder, a typed one is handed over as the pane will make
/// or use it, and a folder the pane refuses is said under the field with the dialog still asking.
///
/// Driven as `TransferDialogTests` drives the dialog: in a plain window, with Return sent through
/// `performKeyEquivalent`.
@MainActor
@Suite("Copy dialog: the folder field", .serialized)
struct TransferDialogFieldTests {
    @Test("the field opens on the other pane's folder, and OK untouched hands over that folder")
    func fieldOpensOnTheFolder() throws {
        let home = VFSPath.local(NSHomeDirectory()).appending("Dev")
        let fixture = DialogFixture(summary: TransferSummary(
            kind: .copy,
            sources: DialogFixture.summary.sources,
            destination: home
        ))
        let controller = fixture.dialog.controller
        #expect(controller.destinationField.stringValue == "~/Dev")
        #expect(controller.destinationField.isEditable)
        #expect(controller.locationLabel.isHidden, "a folder on this Mac names no server")
        try fixture.press("\r", code: 36)
        #expect(fixture.destinations == [home])
        #expect(controller.pathLabel.stringValue == "~/Dev")
        #expect(controller.destinationField.superview?.isHidden == true, "the progress has no field")
    }

    /// Asked 2026-11-19: typing adds to the path rather than replacing it. The control is the
    /// field's own default, which selects every character when it takes the keys.
    @Test("the field takes the keys with the insertion point after the path and nothing selected")
    func insertionPointAtTheEnd() throws {
        let fixture = DialogFixture()
        let controller = fixture.dialog.controller
        let field = controller.destinationField
        let length = (field.stringValue as NSString).length
        #expect(fixture.window.makeFirstResponder(field))
        #expect(field.currentEditor()?.selectedRange == NSRange(location: 0, length: length))

        controller.focusDestinationField()
        let editor = try #require(field.currentEditor())
        #expect(editor.selectedRange == NSRange(location: length, length: 0))
    }

    @Test("a typed folder is handed over, taken from the other pane's folder when it is relative")
    func typedFolderIsHandedOver() throws {
        let fixture = DialogFixture()
        let controller = fixture.dialog.controller
        controller.destinationField.stringValue = "new/deeper"
        try fixture.press("\r", code: 36)
        #expect(fixture.destinations == [.local("/dest/new/deeper")])
        #expect(controller.titleLabel.stringValue.contains("deeper"))
        #expect(controller.pathLabel.stringValue == "/dest/new/deeper")
    }

    /// A refusal leaves the question up with the sentence under the field, and an edit clears it.
    @Test("a folder the pane refuses is said under the field, and nothing starts")
    func refusalKeepsAsking() throws {
        var asked: [VFSPath] = []
        let fixture = DialogFixture(summary: TransferSummary(
            kind: .copy,
            sources: DialogFixture.summary.sources,
            destination: .local("/dest"),
            refusal: { typed in
                asked.append(typed)
                return typed == .local("/src") ? "no" : nil
            }
        ))
        let controller = fixture.dialog.controller
        controller.destinationField.stringValue = "/src"
        try fixture.press("\r", code: 36)
        #expect(fixture.starts == 0)
        #expect(controller.phase == .asking)
        #expect(!fixture.dialog.isClosed)
        #expect(!controller.refusalLabel.isHidden)
        #expect(controller.refusalLabel.stringValue == "no")

        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(controller.refusalLabel.isHidden)
        controller.destinationField.stringValue = "/elsewhere"
        try fixture.press("\r", code: 36)
        #expect(fixture.destinations == [.local("/elsewhere")])
        #expect(asked == [.local("/src"), .local("/elsewhere")])
    }

    /// The field holds the path on the server, and the server's name stands in front of it.
    @Test("a server's folder is its path, with the server named beside the field")
    func serverFolder() throws {
        let remote = VFSPath(backend: VFSBackendID("sftp://u@nas:22"), path: "/home/user")
        let fixture = DialogFixture(summary: TransferSummary(
            kind: .move,
            sources: DialogFixture.summary.sources,
            destination: remote
        ))
        let controller = fixture.dialog.controller
        #expect(controller.destinationField.stringValue == "/home/user")
        #expect(!controller.locationLabel.isHidden)
        #expect(controller.locationLabel.stringValue == "u@nas")
        controller.destinationField.stringValue = "~/x"
        try fixture.press("\r", code: 36)
        #expect(fixture.destinations == [VFSPath(backend: remote.backend, path: "/home/user/~/x")])
    }
}
