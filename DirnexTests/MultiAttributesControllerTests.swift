import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The app-specific half of the multi-selection attributes sheet (PLAN.md §M14 Slice 4): turning
/// tri-state checkboxes into an ``AttributePatch``. The byte-touching pipeline the patch feeds is
/// already proven against the OS in `DirnexCore` (`AttributePatchTests`, `AttributeBatchTests`); what
/// is left here, and where the app could get it wrong, is the *mapping* — a box the items agree on
/// versus one they disagree on, and which of those the user has to move before anything is written.
@Suite("MultiAttributesController")
@MainActor
struct MultiAttributesControllerTests {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    /// An item owned by the running user, so ``MultiAttributesController/canEdit`` is true and the
    /// controls are live.
    private func item(name: String, mode: UInt16, flags: BSDFileFlags = []) -> MultiAttributesController.Item {
        let attributes = FileAttributes(
            permissions: POSIXPermissions(rawValue: mode),
            flags: flags,
            ownerID: getuid(),
            groupID: getgid(),
            accessDate: epoch,
            modificationDate: epoch,
            creationDate: epoch
        )
        let entry = FileEntry(
            path: .local("/test/\(name)"),
            name: name,
            kind: .file,
            byteSize: 0,
            modificationDate: epoch,
            creationDate: epoch,
            isHidden: false,
            permissions: mode,
            inode: 0
        )
        return .init(
            entry: entry,
            attributes: attributes,
            isSymlink: false,
            hasAccessControlList: false
        )
    }

    /// Builds a loaded controller (its view forces the controls to exist) over two items.
    private func controller(
        _ items: [MultiAttributesController.Item]
    ) -> MultiAttributesController {
        let controller = MultiAttributesController(items: items)
        _ = controller.view // triggers loadView, which builds every box
        return controller
    }

    private func modeBox(
        _ controller: MultiAttributesController,
        _ cls: POSIXPermissions.Class,
        _ access: POSIXPermissions.Access
    ) -> NSButton {
        controller.modeBoxes.first { $0.cls == cls && $0.access == access }!.box
    }

    // MARK: - Initial tri-state

    @Test("a bit the items agree on is definite; one they disagree on is mixed")
    func initialTriState() {
        // item1 0o600 (owner rw), item2 0o644 (owner rw, group r, other r).
        let controller = controller([item(name: "a", mode: 0o600), item(name: "b", mode: 0o644)])

        #expect(modeBox(controller, .owner, .read).state == .on) // both on
        #expect(modeBox(controller, .owner, .write).state == .on) // both on
        #expect(modeBox(controller, .owner, .execute).state == .off) // both off
        #expect(modeBox(controller, .group, .read).state == .mixed) // disagree
        #expect(modeBox(controller, .other, .read).state == .mixed) // disagree
        #expect(modeBox(controller, .group, .write).state == .off) // both off

        // A unanimous box does not offer the mixed state; a disagreeing one does.
        #expect(!modeBox(controller, .owner, .read).allowsMixedState)
        #expect(modeBox(controller, .group, .read).allowsMixedState)
    }

    @Test("with nothing touched the patch is empty and Save is off")
    func untouchedIsEmpty() {
        let controller = controller([item(name: "a", mode: 0o600), item(name: "b", mode: 0o644)])
        #expect(controller.buildPatch().isEmpty)
        controller.refreshSaveEnabled()
        #expect(controller.saveButton?.isEnabled == false)
    }

    // MARK: - The mapping to a patch

    @Test("a mixed box left mixed is not written; moved to a definite state it is")
    func mixedBoxMapping() {
        let controller = controller([item(name: "a", mode: 0o600), item(name: "b", mode: 0o644)])

        // Left mixed → the bit is absent from the patch.
        #expect(controller.buildPatch().permissionMask[.group, .read] == false)

        // Set the disagreeing group-read box on → it enters the mask, forced on.
        modeBox(controller, .group, .read).state = .on
        let patch = controller.buildPatch()
        #expect(patch.permissionMask[.group, .read])
        #expect(patch.permissionValues[.group, .read])
        // A neighbour the user never touched stays out of the mask.
        #expect(patch.permissionMask[.other, .read] == false)
    }

    @Test("toggling a unanimous box writes exactly that bit")
    func unanimousBoxMapping() {
        let controller = controller([item(name: "a", mode: 0o644), item(name: "b", mode: 0o644)])

        modeBox(controller, .owner, .write).state = .off // both were on
        let patch = controller.buildPatch()
        #expect(patch.permissionMask[.owner, .write])
        #expect(patch.permissionValues[.owner, .write] == false)
        #expect(!patch.isEmpty)

        controller.refreshSaveEnabled()
        #expect(controller.saveButton?.isEnabled == true)
    }

    @Test("a flag the items disagree on writes only when moved off mixed")
    func flagMapping() {
        // item1 has UF_HIDDEN, item2 does not → the Hidden box starts mixed.
        let controller = controller([
            item(name: "a", mode: 0o644, flags: [.hidden]),
            item(name: "b", mode: 0o644)
        ])
        let hiddenBox = controller.flagBoxes.first { $0.flag == .hidden }!.box
        #expect(hiddenBox.state == .mixed)
        #expect(controller.buildPatch().flagsToSet.contains(.hidden) == false)
        #expect(controller.buildPatch().flagsToClear.contains(.hidden) == false)

        hiddenBox.state = .off // force it off on both
        #expect(controller.buildPatch().flagsToClear.contains(.hidden))
    }

    // MARK: - Group and dates

    @Test("the group popup defaults to Leave unchanged and writes nothing")
    func groupDefault() {
        let controller = controller([item(name: "a", mode: 0o644), item(name: "b", mode: 0o644)])
        #expect(
            controller.groupPopup?.selectedItem?.tag == MultiAttributesController.leaveGroupUnchanged
        )
        #expect(controller.buildPatch().groupID == nil)
    }

    @Test("a date is written only once its Change box is ticked")
    func dateOptIn() {
        let controller = controller([item(name: "a", mode: 0o644), item(name: "b", mode: 0o644)])
        #expect(controller.buildPatch().modificationDate == nil) // all Change boxes off

        let row = controller.dateRows.first { $0.kind == .modification }!
        row.enable.state = .on
        row.picker.dateValue = epoch.addingTimeInterval(3600)
        #expect(controller.buildPatch().modificationDate == epoch.addingTimeInterval(3600))
    }

    // MARK: - Not owned

    @Test("a selection with a foreign-owned item is read-only")
    func foreignOwnedIsReadOnly() {
        var foreign = item(name: "x", mode: 0o644)
        foreign = .init(
            entry: foreign.entry,
            attributes: FileAttributes(
                permissions: foreign.attributes.permissions,
                flags: foreign.attributes.flags,
                ownerID: getuid() == 0 ? 1 : 0, // someone who is not the (non-root) caller
                groupID: foreign.attributes.groupID,
                accessDate: epoch, modificationDate: epoch, creationDate: epoch
            ),
            isSymlink: false,
            hasAccessControlList: false
        )
        let controller = controller([item(name: "a", mode: 0o644), foreign])
        // Root owns everything, so this claim only holds for a normal user.
        if !UserContext.current().isSuperUser {
            #expect(!controller.canEdit)
            #expect(controller.saveButton == nil) // read-only footer has Done, no Save
            #expect(modeBox(controller, .owner, .read).isEnabled == false)
        }
    }
}
