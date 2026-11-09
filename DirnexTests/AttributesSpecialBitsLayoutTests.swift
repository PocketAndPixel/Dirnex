import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Set-UID, set-GID and sticky stand under the Owner, Group and Everyone columns of the mode grid,
/// in Get Info for one item and for several.
///
/// **Asked of the structure rather than of a position, because English cannot tell.** "Set-UID" and
/// "Execute" are within a point of each other, so a separate row of the three lined up by luck and
/// a test measuring it passed. In Russian "Выполнение" is 103 pt wide and the row is 30 pt off by
/// the last column. A bit that is inside its class's own column is under it in every language.
@Suite("Get Info ▸ special bits stand in the columns")
@MainActor
struct AttributesSpecialBitsLayoutTests {
    private func expectInColumns(_ pairs: [(read: NSView, special: NSView)]) {
        for pair in pairs {
            #expect(pair.read.superview != nil)
            #expect(pair.special.superview === pair.read.superview)
        }
    }

    @Test("for one item")
    func singleItem() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpecialBitsLayout-\(UUID().uuidString)")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let entry = try LocalBackend().stat(at: .local(url.path))
        let controller = AttributesController(snapshot: try AttributesSnapshot.read(entry))
        _ = controller.makePermissionsTab()

        func read(_ cls: POSIXPermissions.Class) throws -> NSView {
            try #require(controller.modeBoxes.first { $0.cls == cls && $0.access == .read }).box
        }
        expectInColumns([
            (try read(.owner), try #require(controller.setUserIDBox)),
            (try read(.group), try #require(controller.setGroupIDBox)),
            (try read(.other), try #require(controller.stickyBox))
        ])
    }

    @Test("for several items")
    func severalItems() throws {
        let epoch = Date(timeIntervalSince1970: 1_000_000)
        let items = ["a", "b"].map { name in
            MultiAttributesController.Item(
                entry: FileEntry(
                    path: .local("/test/\(name)"),
                    name: name,
                    kind: .file,
                    byteSize: 0,
                    modificationDate: epoch,
                    creationDate: epoch,
                    isHidden: false,
                    permissions: 0o644,
                    inode: 0
                ),
                attributes: FileAttributes(
                    permissions: POSIXPermissions(rawValue: 0o644),
                    flags: [],
                    ownerID: getuid(),
                    groupID: getgid(),
                    accessDate: epoch,
                    modificationDate: epoch,
                    creationDate: epoch
                ),
                isSymlink: false,
                hasAccessControlList: false
            )
        }
        let controller = MultiAttributesController(items: items)
        _ = controller.makePermissionsTab()

        func read(_ cls: POSIXPermissions.Class) throws -> NSView {
            try #require(controller.modeBoxes.first { $0.cls == cls && $0.access == .read }).box
        }
        func special(_ kind: MultiAttributesController.SpecialKind) throws -> NSView {
            try #require(controller.specialBoxes.first { $0.kind == kind }).box
        }
        expectInColumns([
            (try read(.owner), try special(.setUserID)),
            (try read(.group), try special(.setGroupID)),
            (try read(.other), try special(.sticky))
        ])
    }
}
