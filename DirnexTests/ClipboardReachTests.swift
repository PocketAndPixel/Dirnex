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

    @Test("⌘C inside an archive stays gray — the payload can name a member, nothing reads one yet")
    func copyStillRefusesArchiveMembers() {
        let archive = VFSBackendID.archive(forArchiveAt: "/tmp/pkg.zip")
        let member = VFSPath(backend: archive, path: "/docs/x.md")
        let pane = pane(
            at: VFSPath(backend: archive, path: "/docs"),
            capabilities: .read,
            rows: [entry(member)]
        )

        #expect(!pane.canCopyToClipboard)
        #expect(pane.clipboardTargets().isEmpty)
    }

    @Test("a mixed results tab copies what it can rather than refusing wholesale")
    func copyFiltersPerRowNotPerPane() {
        // A search inside an archive lands its hits in a `search:` tab beside local and remote ones,
        // so the pane's own backend answers for none of them (the M22 results-tab family).
        let archive = VFSBackendID.archive(forArchiveAt: "/tmp/pkg.zip")
        let rows = [
            entry(.local("/tmp/hit.txt")),
            entry(VFSPath(backend: archive, path: "/inside.txt")),
            entry(VFSPath(backend: Self.bucketID, path: "/remote.bin"))
        ]
        let pane = pane(at: VFSPath(backend: .search, path: "/results"), rows: rows)
        pane.panel.selectAll()

        #expect(pane.clipboardTargets().map(\.name) == ["hit.txt", "remote.bin"])
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
}
