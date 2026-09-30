import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// What the ⌘Y Quick Look panel is offered for a pane, and — the half that was wrong — *which* panes
/// hand it a single file (PLAN.md §M1, §M4, §M21 Slice 10).
///
/// The panel resolves a row to bytes on disk through its own `quickLookURL(for:)`, and the Quick View
/// surfaces resolve the same question through `quickViewSourceURL`. Slice 10 taught the second one
/// about servers and left the first knowing only about this Mac and about archives, so ⌘Y on an S3
/// object reported **“No items selected”** for a row the Quick View surface beside it was drawing
/// perfectly — having spent the download on the way in, since the key does ask for one. Found live,
/// by pressing the key the placeholder card itself names.
///
/// So what is pinned here is the *set of panes that offer one file*, which is where remote had to
/// join archive. The resolver's remote branch cannot be reached headlessly — the copy it hands back
/// lives in the window's `RemoteFileCache`, and a pane with no host has no cache — so its evidence is
/// the live run and the live integration suite, not this file. The local rows below are the control
/// that says the narrowing did not spread: they resolve to real URLs with no host at all.
@MainActor
@Suite("Quick Look's items")
struct QuickLookItemsTests {
    private enum Backend {
        static let sftp = VFSBackendID.sftp(
            SFTPLocation(host: "example.com", port: 22, username: "oleg")
        )
        static let ftp = VFSBackendID.ftp(FTPLocation(host: "example.com", username: "oleg"))
        static let location = S3Location(
            host: "127.0.0.1",
            port: 9599,
            bucket: "probe",
            region: "us-east-1",
            accessKeyID: "AKIAPROBEKEYEXAMPLE",
            addressing: .path,
            usesTLS: false
        )
        static let s3 = VFSBackendID.s3(location)
        static let s3Account = VFSBackendID.s3Account(location.account)
        static let archive = VFSBackendID.archive(forArchiveAt: "/tmp/pkg.zip")

        /// Every backend whose rows are somewhere else. Remote-generic by design: pinning S3 alone
        /// would be the one-rule-several-spellings finding this milestone keeps re-deriving.
        static let elsewhere = [sftp, ftp, s3, s3Account, archive]
    }

    private static func pane(at path: VFSPath, listing entries: [FileEntry] = []) -> PanelViewController {
        let vc = PanelViewController(
            backend: LocalBackend(),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        vc.panel = Panel(model: DirectoryModel(listing: DirectoryListing(
            path: path, entries: entries
        )))
        return vc
    }

    private static func localEntry(at url: URL) throws -> FileEntry {
        try LocalBackend().stat(at: .local(url.path))
    }

    // MARK: - Which panes offer one file

    /// The rule the bug lived in. A row that is not a file on this Mac has to be brought here before
    /// anything can preview it, and only the cursor's own ever is — so these panes offer exactly one.
    @Test("a pane whose rows are elsewhere offers Quick Look only the cursor's file")
    func panesWhoseRowsAreElsewhereOfferOneFile() {
        for backend in Backend.elsewhere {
            let pane = Self.pane(at: VFSPath(backend: backend, path: "/dir"))

            #expect(pane.previewsCursorFileOnly, "\(backend)")
        }
    }

    /// The other half: a pane of local files keeps Finder's behaviour, where ⌘Y over a marked set
    /// previews all of it. Without this the fix could quietly have been "always preview one file".
    @Test("a pane of files on this Mac still offers the whole marked set")
    func localPaneOffersTheMarkedSet() {
        let pane = Self.pane(at: .local("/dir"))

        #expect(!pane.previewsCursorFileOnly)
    }

    // MARK: - The local path, end to end through the panel's own data source

    /// Driven through the `QLPreviewPanelDataSource` methods Quick Look actually calls, rather than
    /// through the private resolver behind them: the shipped bug was that the *panel* was handed
    /// nothing, so that is the level the assertion belongs at.
    @Test("the marked files are what the panel is handed, in order")
    func markedFilesReachThePanel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-quicklook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("a.txt")
        let second = root.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: first)
        try Data("b".utf8).write(to: second)
        let entries = try [Self.localEntry(at: first), Self.localEntry(at: second)]
        let pane = Self.pane(at: .local(root.path), listing: entries)

        // Nothing marked: the file under the cursor, which is where ⌘Y starts.
        #expect(pane.numberOfPreviewItems(in: nil) == 1)
        #expect(
            (pane.previewPanel(nil, previewItemAt: 0) as? NSURL)?.path == first.path
        )

        pane.panel.selectAll()
        #expect(pane.numberOfPreviewItems(in: nil) == 2)
        #expect(
            (pane.previewPanel(nil, previewItemAt: 1) as? NSURL)?.path == second.path
        )
    }

    /// A bucket row in an S3 account pane is a *directory*, so there is nothing under it to preview —
    /// the narrowness that keeps "offers one file" from becoming "offers the row it is standing on".
    @Test("a directory row offers nothing, wherever it lives")
    func directoryRowOffersNothing() {
        let bucket = FileEntry(
            path: VFSPath(backend: Backend.s3Account, path: "/probe"),
            name: "probe",
            kind: .directory,
            byteSize: 0,
            modificationDate: FileEntry.unknownDate,
            creationDate: FileEntry.unknownDate,
            isHidden: false,
            permissions: 0o755,
            inode: 0
        )
        let pane = Self.pane(at: VFSPath(backend: Backend.s3Account, path: "/"), listing: [bucket])

        #expect(pane.numberOfPreviewItems(in: nil) == 0)
    }
}
