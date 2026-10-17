import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Unlock Vault in the right-click menu, under Open (2026-10-17).
///
/// What the window does with the vault is Go ▸ Unlock Vault's funnel and is not re-tested here. What
/// is pinned is the menu's half: the item is there over exactly one image and nowhere else, it sits
/// right under Open, and it hands over the vault the *clicked* row names — which is the reason it
/// captures the row rather than dispatching like the Go menu's item, since a click inside a marked set
/// leaves the cursor somewhere else.
@MainActor
@Suite("Context menu ▸ Unlock Vault")
struct ContextMenuUnlockVaultTests {
    private let vault = Handoff.local("/tmp/probe/Secrets.sparsebundle", kind: .directory)
    private let installer = Handoff.local("/tmp/probe/Installer.dmg")
    private let notes = Handoff.local("/tmp/probe/notes.txt")

    /// Found by action rather than title, so the test reads the same in every language.
    private func unlockItem(in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.action == NSSelectorFromString("unlockContextVault:") }
    }

    private func row(of entry: FileEntry, in pane: PanelViewController) throws -> Int {
        let index = try #require(pane.panel.displayedEntries.firstIndex { $0.path == entry.path })
        return pane.row(forEntryIndex: index)
    }

    private func fire(_ item: NSMenuItem) {
        _ = (item.target as AnyObject).perform(item.action, with: item)
    }

    @Test("a right-click on a sparse bundle offers Unlock Vault right under Open")
    func sparseBundle() throws {
        let hosted = windowedPane(showing: [vault, notes], at: .local("/tmp/probe"))
        let pane = hosted.pane

        let menu = pane.contextMenu(forRow: try row(of: vault, in: pane))

        let item = try #require(unlockItem(in: menu))
        let open = try #require(
            menu.items.firstIndex { $0.action == NSSelectorFromString("openContextEntry:") }
        )
        #expect(menu.index(of: item) == open + 1)
        #expect(item.title == LocalizedCatalog.command(for: "go.unlockVault")?.title)
        #expect(item.target === pane)
        #expect(pane.validateMenuItem(item))

        fire(item)
        // The file's name stands in for the volume's until an attach reports the real one — the same
        // vault the Go menu's command builds from the same row.
        #expect(hosted.host.vaultOpenRequests == [
            VaultLocation(imagePath: "/tmp/probe/Secrets.sparsebundle", volumeName: "Secrets")
        ])
    }

    /// The Go menu's rule takes any image, not only a saved vault, and so does this.
    @Test("a plain disk image is offered too")
    func diskImage() throws {
        let hosted = windowedPane(showing: [installer, notes], at: .local("/tmp/probe"))
        let pane = hosted.pane

        let menu = pane.contextMenu(forRow: try row(of: installer, in: pane))

        fire(try #require(unlockItem(in: menu)))
        #expect(hosted.host.vaultOpenRequests.map(\.imagePath) == ["/tmp/probe/Installer.dmg"])
    }

    @Test("an ordinary file has no Unlock Vault")
    func ordinaryFile() throws {
        let hosted = windowedPane(showing: [vault, notes], at: .local("/tmp/probe"))
        let pane = hosted.pane

        let menu = pane.contextMenu(forRow: try row(of: notes, in: pane))

        #expect(unlockItem(in: menu) == nil)
    }

    /// The menu is about the set, and one vault among several things is not "this vault".
    @Test("an image inside a larger marked set has no Unlock Vault")
    func markedSet() throws {
        let hosted = windowedPane(showing: [vault, notes], at: .local("/tmp/probe"))
        let pane = hosted.pane
        pane.panel.setSelection([vault.path, notes.path])

        let menu = pane.contextMenu(forRow: try row(of: vault, in: pane))

        #expect(unlockItem(in: menu) == nil)
    }

    /// The case that makes the item capture its row. Right-clicking a marked row leaves the cursor
    /// where it was — here on the text file — so dispatching on the cursor, as the Go menu's item
    /// does, would find no image and quietly do nothing.
    @Test("a marked image is the one unlocked, wherever the cursor is")
    func markedImageWithCursorElsewhere() throws {
        let hosted = windowedPane(showing: [vault, notes], at: .local("/tmp/probe"))
        let pane = hosted.pane
        pane.panel.moveCursor(
            to: try #require(pane.panel.displayedEntries.firstIndex { $0 == notes })
        )
        pane.panel.setSelection([vault.path])

        let menu = pane.contextMenu(forRow: try row(of: vault, in: pane))

        #expect(pane.panel.currentEntry == notes)
        fire(try #require(unlockItem(in: menu)))
        #expect(hosted.host.vaultOpenRequests.map(\.imagePath) == [vault.path.path])
    }

    /// A results tab routes what it opens elsewhere, and the Go menu's command is grayed there.
    @Test("a search-results tab has no Unlock Vault")
    func resultsTab() throws {
        let hosted = windowedPane(showing: [vault], at: VFSPath(backend: .search, path: "/Results"))
        let pane = hosted.pane

        let menu = pane.contextMenu(forRow: try row(of: vault, in: pane))

        #expect(unlockItem(in: menu) == nil)
    }
}
