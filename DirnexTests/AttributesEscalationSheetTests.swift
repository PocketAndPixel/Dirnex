import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The Get Info sheets' half of the batch escalation (PLAN.md §M40 Slice 4): a selection holding
/// someone else's items is editable and splits at Save into the user's own items and one
/// administrator batch, and someone else's folder offers "Apply to enclosed items", since the run's
/// report can now escalate what it leaves. The dialog and the transport are
/// `AttributeBatchEscalationTests`.
@Suite("Attributes sheets with root-only items")
@MainActor
struct AttributesEscalationSheetTests {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    @Test("A selection holding someone else's item is editable, says Save will ask, and splits")
    func multiSelectionSplitsAtSave() throws {
        guard !UserContext.current().isSuperUser else { return }
        let mine = multiItem("mine", owner: getuid())
        let theirs = multiItem("theirs", owner: getuid() == 0 ? 1 : 0)
        let locked = multiItem("locked", owner: getuid(), flags: .systemImmutable)
        let controller = MultiAttributesController(items: [mine, theirs, locked])
        _ = controller.view

        #expect(controller.canEdit)
        #expect(!controller.ownsEveryItem)
        #expect(controller.saveButton != nil)

        var patch = AttributePatch()
        patch.permissionMask = POSIXPermissions(rawValue: 0o7777)
        patch.permissionValues = POSIXPermissions(rawValue: 0o600)
        let commit = controller.commit(for: patch)
        #expect(commit.own.map(\.item.entry.name) == ["mine"])
        #expect(commit.rootOnly.items.map(\.path.lastComponent) == ["theirs", "locked"])
        #expect(commit.rootOnly.items.allSatisfy { $0.diff.permissions?.rawValue == 0o600 })

        patch.permissionValues = POSIXPermissions(rawValue: 0o644)
        let matching = controller.commit(for: patch)
        #expect(
            matching.own.isEmpty && matching.rootOnly.items.isEmpty,
            "everything already matches"
        )
    }

    @Test("A selection of the user's own items shows no administrator note")
    func ownSelectionHasNoNote() {
        let controller = MultiAttributesController(items: [multiItem("a", owner: getuid())])
        _ = controller.view
        #expect(controller.ownsEveryItem)
    }

    @Test("Someone else's folder offers Apply to enclosed items, since the report can escalate")
    func foreignFolderOffersRecursion() throws {
        guard !UserContext.current().isSuperUser else { return }
        let entry = try LocalBackend().stat(at: .local("/Library"))
        let controller = AttributesController(snapshot: try AttributesSnapshot.read(entry))
        _ = controller.view
        #expect(!controller.ownsItem)
        #expect(controller.recursiveOptions != nil)
    }

    // MARK: - Fixtures

    private func attributes(owner: UInt32, flags: BSDFileFlags = []) -> FileAttributes {
        FileAttributes(
            permissions: POSIXPermissions(rawValue: 0o644),
            flags: flags,
            ownerID: owner,
            groupID: getgid(),
            accessDate: epoch,
            modificationDate: epoch,
            creationDate: epoch
        )
    }

    private func multiItem(
        _ name: String,
        owner: UInt32,
        flags: BSDFileFlags = []
    ) -> MultiAttributesController.Item {
        let entry = FileEntry(
            path: .local("/test/\(name)"),
            name: name,
            kind: .file,
            byteSize: 0,
            modificationDate: epoch,
            creationDate: epoch,
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )
        return .init(
            entry: entry,
            attributes: attributes(owner: owner, flags: flags),
            isSymlink: false,
            hasAccessControlList: false
        )
    }
}
