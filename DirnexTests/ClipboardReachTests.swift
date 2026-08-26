import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Which panes ⌘C and ⌘V reach (PLAN.md §M23 Slice 2).
///
/// The gates are the surface no headless test used to drive, and this project's most repeated bug is
/// a rule with two spellings — so what is pinned here is the **pane's own answer**, not a restatement
/// of the rule. `canCopyToClipboard` was `!isArchive && !isRemoteConnection && !selectionTargets()
/// .isEmpty`, which is why ⌘C on a server was gray *and* dead; `canReceiveFiles` is new and exists
/// because `canWriteHere` says yes to a place a file cannot go.
///
/// Rows are seeded straight into the pane's `Panel` — a pure value type — so nothing here loads a
/// view, lists a directory or touches the network.
@MainActor
@Suite("Clipboard reach")
struct ClipboardReachTests {
    private static let bucket = S3Location(
        host: "127.0.0.1",
        port: 9599,
        bucket: "probe",
        region: "us-east-1",
        accessKeyID: "AKIAPROBEKEYEXAMPLE",
        addressing: .path,
        usesTLS: false
    )
    private static let bucketID = VFSBackendID.s3(bucket)
    private static let accountID = VFSBackendID.s3Account(bucket.account)

    /// A backend that answers capabilities and nothing else — every gate under test is a question
    /// about *locations*, so a listing would only be scenery.
    private struct StubBackend: VFSBackend {
        let id: VFSBackendID
        let capabilities: VFSCapabilities

        func listDirectory(at path: VFSPath) throws -> [FileEntry] { [] }
        func stat(at path: VFSPath) throws -> FileEntry { throw VFSError.notFound(path) }
    }

    private func pane(
        at path: VFSPath,
        capabilities: VFSCapabilities = [.read, .write],
        rows: [FileEntry] = []
    ) -> PanelViewController {
        let pane = PanelViewController(
            backend: StubBackend(id: path.backend, capabilities: capabilities),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        if !rows.isEmpty {
            pane.panel.setModel(
                DirectoryModel(listing: DirectoryListing(path: path, entries: rows))
            )
            pane.panel.moveCursor(to: 0)
        }
        return pane
    }

    private func entry(_ path: VFSPath) -> FileEntry {
        FileEntry(
            path: path,
            name: path.lastComponent,
            kind: .file,
            byteSize: 128,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 11
        )
    }

    // MARK: - ⌘C

    @Test("⌘C reaches a row on a server — the gesture that was dead on every connected account")
    func copyReachesARemoteRow() {
        let object = VFSPath(backend: Self.bucketID, path: "/report.pdf")
        let pane = pane(at: VFSPath(backend: Self.bucketID, path: "/"), rows: [entry(object)])

        #expect(pane.canCopyToClipboard)
        #expect(pane.clipboardTargets().map(\.path) == [object])
    }

    @Test("⌘C still reaches an ordinary local row")
    func copyReachesALocalRow() {
        let file = VFSPath.local("/tmp/a.txt")
        let pane = pane(at: .local("/tmp"), rows: [entry(file)])

        #expect(pane.canCopyToClipboard)
        #expect(pane.clipboardTargets().map(\.path) == [file])
    }

    @Test("⌘C with nothing under the cursor has nothing to place")
    func copyNeedsATarget() {
        let pane = pane(at: .local("/tmp"))
        #expect(!pane.canCopyToClipboard)
        #expect(pane.clipboardTargets().isEmpty)
    }

    // MARK: - ⌘V

    @Test("a bucket can receive a paste")
    func bucketReceivesFiles() {
        let pane = pane(at: VFSPath(backend: Self.bucketID, path: "/prefix"))
        #expect(pane.canReceiveFiles)
        #expect(pane.pasteDestination == VFSPath(backend: Self.bucketID, path: "/prefix"))
    }

    @Test("an S3 account pane cannot — it is writable, and a file has nowhere to go in it")
    func accountPaneRefusesAPaste() {
        // The case `canWriteHere` gets wrong: F7 there creates a *bucket*, so `.write` and
        // `creationDirectory` both say yes while a pasted file would fail inside the queue.
        let pane = pane(at: VFSPath(backend: Self.accountID, path: "/"))
        #expect(pane.canReceiveFiles == false)
        #expect(pane.pasteDestination == nil)
    }

    @Test("a read-only pane cannot receive a paste")
    func readOnlyPaneRefusesAPaste() {
        let pane = pane(at: VFSPath(backend: Self.bucketID, path: "/"), capabilities: .read)
        #expect(!pane.canReceiveFiles)
    }

    @Test("a local folder still receives a paste")
    func localFolderReceivesFiles() {
        let pane = pane(at: .local("/tmp"))
        #expect(pane.canReceiveFiles)
        #expect(pane.pasteDestination == .local("/tmp"))
    }

    @Test("a results listing has no directory, so nothing can land in it")
    func resultsListingReceivesNothing() {
        let pane = pane(at: VFSPath(backend: .search, path: "/results"))
        #expect(!pane.canReceiveFiles)
    }

    // MARK: - ⌥⌘V, through the real validator

    /// Snapshot the general pasteboard's items so a test can seed it and put it back.
    ///
    /// The suite runs *in the app*, on the developer's own Mac, so leaving their clipboard holding
    /// a fixture is the same rudeness as the S3 suites deleting a Keychain item they had merely
    /// overwritten (docs/NOTES.md ▸ curl for S3). Seeding it is unavoidable here: the validator
    /// reads `NSPasteboard.general`, and a test whose answer depends on what the user happened to
    /// copy is not a test.
    ///
    /// Only data that can be *read back* survives — a flavor another app promised lazily is not
    /// reconstructible from outside it. That is the one thing this can degrade, and it is why the
    /// seeding is confined to the two tests that cannot be written without it.
    private func snapshotGeneralBoard() -> [[NSPasteboard.PasteboardType: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var flavors: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { flavors[type] = data }
            }
            return flavors
        }
    }

    private func restoreGeneralBoard(_ snapshot: [[NSPasteboard.PasteboardType: Data]]) {
        NSPasteboard.general.clearContents()
        let items = snapshot.map { flavors -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in flavors { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { NSPasteboard.general.writeObjects(items) }
    }

    private func menuItem(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    @Test("⌥⌘V is gray where files cannot land, even with a full clipboard")
    func pasteMoveIsGrayWhereFilesCannotLand() {
        // The account pane again, this time through `validateMenuItem` itself rather than through
        // the property it reads — the validator is the surface no headless test used to drive, and
        // a rule with two spellings is how a working command ends up gray (or a dead one enabled).
        let saved = snapshotGeneralBoard()
        defer { restoreGeneralBoard(saved) }
        #expect(PanelPasteboard.write([entry(.local("/tmp/seed.txt"))], to: .general))

        let account = pane(at: VFSPath(backend: Self.accountID, path: "/"))
        account.loadViewIfNeeded()
        NotificationCenter.default.removeObserver(account)
        #expect(!account.validateMenuItem(menuItem(
            #selector(PanelViewController.pasteAndMoveFromClipboard(_:))
        )))
    }

    @Test("⌥⌘V follows ⌘V on every backend rather than carrying its own copy of the rule")
    func pasteMoveTracksPaste() {
        let saved = snapshotGeneralBoard()
        defer { restoreGeneralBoard(saved) }
        #expect(PanelPasteboard.write([entry(.local("/tmp/seed.txt"))], to: .general))

        // Not an archive anywhere here: ⌘V alone also accepts a writable archive (add-into), which
        // ⌥⌘V deliberately does not, so that is the one pane where the two are allowed to differ.
        let places: [(String, VFSPath)] = [
            ("local", .local("/tmp")),
            ("bucket", VFSPath(backend: Self.bucketID, path: "/prefix")),
            ("account", VFSPath(backend: Self.accountID, path: "/")),
            ("results", VFSPath(backend: .search, path: "/results"))
        ]
        for (name, path) in places {
            let pane = pane(at: path)
            pane.loadViewIfNeeded()
            NotificationCenter.default.removeObserver(pane)
            let paste = pane.validateMenuItem(menuItem(#selector(PanelViewController.paste(_:))))
            let move = pane.validateMenuItem(menuItem(
                #selector(PanelViewController.pasteAndMoveFromClipboard(_:))
            ))
            #expect(paste == move, "⌘V and ⌥⌘V disagree in a \(name) pane")
        }
    }

    @Test("⌥⌘V is enabled on a bucket — the half the gray test cannot show")
    func pasteMoveReachesABucket() {
        let saved = snapshotGeneralBoard()
        defer { restoreGeneralBoard(saved) }
        #expect(PanelPasteboard.write([entry(.local("/tmp/seed.txt"))], to: .general))

        let bucket = pane(at: VFSPath(backend: Self.bucketID, path: "/prefix"))
        bucket.loadViewIfNeeded()
        NotificationCenter.default.removeObserver(bucket)
        #expect(bucket.validateMenuItem(menuItem(
            #selector(PanelViewController.pasteAndMoveFromClipboard(_:))
        )))
    }
}
