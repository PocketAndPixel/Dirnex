import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The single-item Get Info sheet's Save with "Apply to enclosed items" ticked and nothing edited
/// (PLAN.md §M14 Slice 4). The box alone is a request — make everything inside match this folder —
/// so it lights Save, and the job it hands over carries the folder's own mode. What that job then
/// writes is proven against real files in `DirnexCore` (`AttributeApplyJobTests`).
@Suite("AttributesController recursive Save")
@MainActor
struct AttributesRecursiveSaveTests {
    /// A real directory with mode 0700, owned by the running user so the footer row is offered.
    private func folderController() throws -> (AttributesController, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttributesRecursiveSave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        let entry = try LocalBackend().stat(at: .local(url.path))
        let controller = AttributesController(snapshot: try AttributesSnapshot.read(entry))
        _ = controller.view // builds the controls, the footer row included
        return (controller, url)
    }

    /// The footer's checkbox, found by the object it reports to rather than by its title, so the
    /// test reads the same in every language.
    private func recursiveBox(_ controller: AttributesController) throws -> NSButton {
        let options = try #require(controller.recursiveOptions)
        return try #require(buttons(in: controller.view).first { $0.target === options })
    }

    private func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { subview in
            ((subview as? NSButton).map { [$0] } ?? []) + buttons(in: subview)
        }
    }

    @Test("Ticking the box alone lights Save, and unticking it puts Save out again")
    func boxAloneEnablesSave() throws {
        let (controller, url) = try folderController()
        defer { try? FileManager.default.removeItem(at: url) }
        let box = try recursiveBox(controller)

        #expect(controller.saveButton?.isEnabled == false, "nothing to save yet")
        box.performClick(nil)
        #expect(controller.saveButton?.isEnabled == true)
        box.performClick(nil)
        #expect(controller.saveButton?.isEnabled == false)
    }

    @Test("The job an untouched sheet hands over carries the folder's own mode")
    func untouchedJobCarriesMode() throws {
        let (controller, url) = try folderController()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(controller.recursiveJob() == nil, "no job while the box is unticked")
        try recursiveBox(controller).performClick(nil)

        let job = try #require(controller.recursiveJob())
        #expect(job.patch.permissionMask.rawValue == 0o7777)
        #expect(job.patch.permissionValues.rawValue == 0o700)
        #expect(job.patch.flagsToSet.isEmpty && job.patch.flagsToClear.isEmpty)
        #expect(job.patch.groupID == nil)
        #expect(job.accessControlList == nil)
        #expect(job.target == .everything)
    }
}
