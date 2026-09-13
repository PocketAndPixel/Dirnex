import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// ⌘-number tab switching in the multi-selection Get Info.
///
/// It needed no code of its own — ``TabShortcuts`` serves any dialog window holding a tab view — so
/// this pins that the panel stays one: its loaded view carries a tab view ``TabShortcuts`` finds, and
/// ⌘2, ⌘1 and a past-the-end ⌘3 go through the same number reading and tab picking the monitor uses.
///
/// **No window**, and that is measured rather than caution: the first version hosted the panel in a
/// real window, and `TrashlessVolumeFlowTests` then failed 2 full runs in 3 on a sheet wait, against
/// 3 green in 3 with this test skipped (docs/NOTES.md ▸ Testing — a real window in the test host
/// destabilizes its neighbours). The window-level rules are covered by `TabShortcutsTests`.
@Suite("Multi-selection Get Info tab shortcuts", .serialized)
@MainActor
struct MultiAttributesTabShortcutTests {
    private func item(_ name: String) -> MultiAttributesController.Item {
        let epoch = Date(timeIntervalSince1970: 1_000_000)
        return .init(
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

    private func commandKey(_ digit: String, code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: digit,
            charactersIgnoringModifiers: digit,
            isARepeat: false,
            keyCode: code
        ))
    }

    @Test("⌘2 opens Permissions and ⌘1 comes back to General, and ⌘3 is refused with only two tabs")
    func commandNumbersPickTheTabs() throws {
        let controller = MultiAttributesController(items: [item("a"), item("b")])
        controller.loadViewIfNeeded()
        let tabs = try #require(TabShortcuts.tabView(within: controller.view))
        #expect(tabs.numberOfTabViewItems == 2)
        func selected() throws -> Int { tabs.indexOfTabViewItem(
            try #require(tabs.selectedTabViewItem)
        ) }

        TabShortcuts.pick(
            try #require(TabShortcuts.tabNumber(for: try commandKey("2", code: 19))),
            in: tabs
        )
        #expect(try selected() == 1)
        TabShortcuts.pick(
            try #require(TabShortcuts.tabNumber(for: try commandKey("1", code: 18))),
            in: tabs
        )
        #expect(try selected() == 0)

        let saved = TabShortcuts.refuse
        defer { TabShortcuts.refuse = saved }
        var refused = 0
        TabShortcuts.refuse = { refused += 1 }
        TabShortcuts.pick(
            try #require(TabShortcuts.tabNumber(for: try commandKey("3", code: 20))),
            in: tabs
        )
        #expect(refused == 1)
        #expect(try selected() == 0)
    }
}
