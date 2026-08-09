import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// F2 on a selected vault row (PLAN.md §M19).
///
/// The whole mechanism is a **selector**: the Rename menu item carries a nil target, so AppKit walks
/// the responder chain from whatever holds focus, and a focused sidebar has to answer the same
/// `renameSelection:` a focused pane answers. Nothing about that is checked at build time — a Swift
/// signature that drifts simply stops being the witness and the key goes quietly dead, which is the
/// trap docs/NOTES.md records for Sparkle's callback and for `WKNavigationDelegate`.
///
/// So the assertions below are by **selector string**, not `#selector(SidebarViewController.…)`: the
/// latter would keep resolving to the right selector after the class stopped implementing it, which
/// is precisely the state this suite exists to catch.
@Suite("Sidebar vault rename")
@MainActor
struct SidebarVaultRenameTests {
    private func loadedSidebar() -> SidebarViewController {
        let sidebar = SidebarViewController()
        sidebar.loadView()
        return sidebar
    }

    @Test("a focused sidebar answers the same F2 selector a focused pane does")
    func sidebarIsTheF2Target() {
        let sidebar = loadedSidebar()
        // The one spelling that matters, written out rather than derived: this is the string AppKit
        // dispatches, and it is `PanelViewController`'s F2 selector.
        #expect(sidebar.responds(to: NSSelectorFromString("renameSelection:")))
        #expect(
            CommandBinding.selector(for: "file.rename") == NSSelectorFromString("renameSelection:"),
            "F2's registry binding no longer names the selector the sidebar implements"
        )
    }

    @Test("F2 is offered only on a vault row")
    func f2IsValidatedAgainstTheSelectedRow() {
        let sidebar = loadedSidebar()
        let item = NSMenuItem(
            title: "Rename",
            action: NSSelectorFromString("renameSelection:"),
            keyEquivalent: ""
        )
        // Nothing selected: the sidebar has no subject, so the key must gray out rather than act on
        // whatever row happened to be right-clicked last.
        #expect(sidebar.selectedVault == nil)
        #expect(sidebar.validateMenuItem(item) == false)

        // Every other selector is left alone — the sidebar is only ever *asked* about the one it
        // implements, and answering false for the rest would gray items it does not own.
        let unrelated = NSMenuItem(
            title: "Copy",
            action: NSSelectorFromString("copy:"),
            keyEquivalent: ""
        )
        #expect(sidebar.validateMenuItem(unrelated))
    }

    @Test("a vault row's menu offers Rename between its state items and Remove")
    func vaultMenuCarriesRename() {
        let sidebar = loadedSidebar()
        let vault = VaultLocation(imagePath: "/tmp/Probe.sparsebundle", volumeName: "Probe")
        let menu = NSMenu()
        sidebar.buildVaultMenu(menu, for: vault)

        let actions = menu.items.map { $0.action.map(NSStringFromSelector) ?? "-" }
        #expect(actions.contains("renameVaultItem:"))
        // Order is the claim, not merely presence: Rename sits with Remove below the separator, so
        // the destructive item is never the neighbour of the one that opens the vault.
        let separator = try? #require(menu.items.firstIndex { $0.isSeparatorItem })
        let rename = try? #require(actions.firstIndex(of: "renameVaultItem:"))
        let remove = try? #require(actions.firstIndex(of: "removeVaultItem:"))
        #expect(separator ?? 0 < rename ?? 0)
        #expect(rename ?? 0 < remove ?? 0)
    }
}
