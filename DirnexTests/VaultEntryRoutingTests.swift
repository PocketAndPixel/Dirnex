import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Which images Enter routes to the unlock funnel (PLAN.md §M19, user-reported 2026-08-10).
///
/// A `.sparsebundle` is a *directory*, so without this rule Enter walked into it and showed `bands/`,
/// `Info.plist` and `token` — an unlocked vault reading as locked from the pane, with the sidebar the
/// only way in. The rule is deliberately narrower than the Unlock command's, and the narrowness is
/// the half worth pinning: Enter is pressed on everything, so an image Dirnex has no record of must
/// keep browsing as the directory it is rather than provoking a passphrase prompt.
///
/// The panes are headless (the view is never loaded) and the saved list is handed in, so nothing here
/// touches the real `Dirnex.vaults` — the sidebar the tester is looking at.
@Suite("Vault: what Enter opens")
@MainActor
struct VaultEntryRoutingTests {
    // MARK: - Fixtures

    private static let imagePath = "/Users/tester/Documents/SecDocs.sparsebundle"

    private static func entry(_ path: String, kind: FileEntry.Kind = .directory) -> FileEntry {
        FileEntry(
            path: .local(path),
            name: (path as NSString).lastPathComponent,
            kind: kind,
            byteSize: 0,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: false,
            permissions: 0o755,
            inode: 0
        )
    }

    private static func pane(at path: VFSPath = .local("/Users/tester/Documents")) -> PanelViewController {
        PanelViewController(
            backend: LocalBackend(),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
    }

    private static var saved: SavedVaults {
        SavedVaults(vaults: [VaultLocation(imagePath: imagePath, volumeName: "SecDocs")])
    }

    // MARK: - The rule

    @Test("a saved vault's image routes to the vault, carrying its stored volume name")
    func savedImageRoutes() throws {
        let vault = try #require(
            Self.pane().savedVault(for: Self.entry(Self.imagePath), in: Self.saved)
        )
        #expect(vault.imagePath == Self.imagePath)
        // The name the sidebar and the rename sheet show, not the file's own — a vault's file may be
        // deliberately unrevealing (`VaultLocation.volumeName`).
        #expect(vault.volumeName == "SecDocs")
    }

    @Test("the two spellings of one path are one vault")
    func resolvedSpelling() {
        // `/tmp` vs `/private/tmp`: the identity rule `SavedVaults` documents, reached through the
        // pane rather than asserted on the store, since this is the call that will meet it in anger.
        let saved = SavedVaults(
            vaults: [VaultLocation(imagePath: "/private/tmp/v.sparsebundle", volumeName: "V")]
        )
        #expect(Self.pane().savedVault(for: Self.entry("/tmp/v.sparsebundle"), in: saved) != nil)
    }

    @Test("an image Dirnex has no record of is not routed")
    func strangerIsNotRouted() {
        // The narrowness. Enter on a downloaded `.dmg` must keep launching it, not attach it, ask for
        // a passphrase and file it in the sidebar's Vaults section.
        let stranger = Self.entry("/Users/tester/Downloads/Installer.dmg", kind: .file)
        #expect(Self.pane().savedVault(for: stranger, in: Self.saved) == nil)
    }

    @Test("an ordinary folder is not routed")
    func folderIsNotRouted() {
        let folder = Self.entry("/Users/tester/Documents/SecDocs")
        #expect(Self.pane().savedVault(for: folder, in: Self.saved) == nil)
    }

    @Test("a hit in a results listing is not routed")
    func resultsListingIsNotRouted() {
        // A search tab lists rows from everywhere and routes an opened folder to the *other* pane
        // (`openResultDirectory`); mounting a volume in place would be that gesture answering a
        // different question. Same exclusion the Unlock command makes.
        let pane = Self.pane(at: VFSPath(backend: .search, path: "/Results for SecDocs"))
        #expect(pane.isVirtualDirectory)
        #expect(pane.savedVault(for: Self.entry(Self.imagePath), in: Self.saved) == nil)
    }
}
