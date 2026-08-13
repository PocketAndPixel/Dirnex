import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// What F4 does with the file under the cursor, and — the half that is actually at risk — that its
/// menu item agrees (PLAN.md §M11, §M4, §M21 Slice 10).
///
/// The key and the validator were two hand-written copies of one predicate, and they had **already**
/// drifted before this milestone touched them: the key routed an archive member to its extracted copy
/// while the validator still answered `backend == .local`, so Edit was gray inside an archive — and a
/// disabled `NSMenuItem` swallows its own key equivalent, which turns a mismatch that looks cosmetic
/// into a dead key (docs/NOTES.md ▸ AppKit, the size-bar lesson). Adding the remote branch beside it
/// would have made that two misses instead of one.
///
/// So what is pinned is not only "F4 works on a remote file" but the *agreement*: for every route,
/// the validator's answer is derived from the same `editRoute` the key switches on, and the
/// unavailable case is the only one that grays.
///
/// The panes are headless — the view is never loaded, and `editRoute` reads only the model.

/// At file scope so the parameterized `arguments:` can read them: the suite is `@MainActor`, and a
/// static on it is main-actor-isolated where the argument list is evaluated.
private enum Remote {
    static let sftp = VFSBackendID.sftp(
        SFTPLocation(host: "example.com", port: 22, username: "oleg")
    )
    static let ftp = VFSBackendID.ftp(FTPLocation(host: "example.com", username: "oleg"))
    static let s3 = VFSBackendID.s3(
        S3Location(
            host: "127.0.0.1",
            port: 9599,
            bucket: "probe",
            region: "us-east-1",
            accessKeyID: "AKIAPROBEKEYEXAMPLE",
            addressing: .path,
            usesTLS: false
        )
    )
    static let account = VFSBackendID.s3Account(
        S3Location(
            host: "127.0.0.1",
            port: 9599,
            bucket: "probe",
            region: "us-east-1",
            accessKeyID: "AKIAPROBEKEYEXAMPLE",
            addressing: .path,
            usesTLS: false
        ).account
    )

    /// Every backend the remote route must cover. Remote-generic by design: writing this against S3
    /// alone would be the one-rule-several-spellings finding this milestone keeps re-deriving.
    static let all = [sftp, ftp, s3]
}

/// One row of the key-and-menu-item agreement table, named rather than a tuple so the three fields
/// cannot be read in the wrong order.
private struct Case {
    let backend: VFSBackendID
    let kind: FileEntry.Kind
    let route: EditRoute
}

@MainActor
@Suite("F4's route")
struct EditRouteTests {
    private static func entry(
        _ name: String,
        on backend: VFSBackendID,
        kind: FileEntry.Kind = .file
    ) -> FileEntry {
        FileEntry(
            path: VFSPath(backend: backend, path: "/dir/\(name)"),
            name: name,
            kind: kind,
            byteSize: 10,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )
    }

    private static func pane(at path: VFSPath) -> PanelViewController {
        PanelViewController(
            backend: LocalBackend(),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
    }

    /// The same, holding a listing so the cursor stands on `entries[0]` — which is what the menu
    /// validator reads, where `editRoute(for:)` is handed its entry directly.
    private static func pane(listing entries: [FileEntry], at path: VFSPath) -> PanelViewController {
        let vc = pane(at: path)
        vc.panel = Panel(model: DirectoryModel(listing: DirectoryListing(
            path: path, entries: entries
        )))
        return vc
    }

    // MARK: - The three routes, and the one refusal

    @Test("a file on a server edits in place", arguments: Remote.all)
    func remoteFileEditsInPlace(backend: VFSBackendID) {
        let pane = Self.pane(at: VFSPath(backend: backend, path: "/dir"))

        #expect(pane.editRoute(for: Self.entry("notes.txt", on: backend)) == .remoteFile)
    }

    @Test("a file on this Mac is handed over as it stands")
    func localFileIsHandedOver() {
        let pane = Self.pane(at: .local("/dir"))

        #expect(pane.editRoute(for: Self.entry("notes.txt", on: .local)) == .local)
    }

    @Test("a member of a top-level archive edits its extracted copy")
    func archiveMemberEditsItsCopy() {
        let archive = VFSBackendID.archive(forArchiveAt: "/tmp/pkg.zip")
        let pane = Self.pane(at: VFSPath(backend: archive, path: "/dir"))

        #expect(pane.editRoute(for: Self.entry("notes.txt", on: archive)) == .archiveMember)
    }

    /// The narrowness, which is what keeps the route from being "anything not local". A directory
    /// inside an archive has no bytes to hand an editor, and a bucket row in an S3 account pane is a
    /// directory too — so `kind` carries both cases without either being special-cased.
    @Test("a directory is never edited, wherever it lives")
    func directoriesAreRefused() {
        let archive = VFSBackendID.archive(forArchiveAt: "/tmp/pkg.zip")
        let archivePane = Self.pane(at: VFSPath(backend: archive, path: "/dir"))
        #expect(
            archivePane.editRoute(for: Self.entry("sub", on: archive, kind: .directory))
                == .unavailable
        )

        let remotePane = Self.pane(at: VFSPath(backend: Remote.s3, path: "/dir"))
        #expect(
            remotePane.editRoute(for: Self.entry("sub", on: Remote.s3, kind: .directory))
                == .unavailable
        )
    }

    /// An S3 *account* pane lists buckets, which are directories and are on a backend that takes no
    /// uploads — so there is nothing there F4 could carry a save back to.
    @Test("a bucket row in an account pane is not editable")
    func bucketRowIsNotEditable() {
        let account = Remote.account
        let pane = Self.pane(at: VFSPath(backend: account, path: "/"))

        #expect(
            pane.editRoute(for: Self.entry("probe", on: account, kind: .directory)) == .unavailable
        )
    }

    // MARK: - The key and its menu item answer the same question

    /// The **real** validator, driven against a pane whose cursor is standing on the entry — not a
    /// restatement of `editRoute`'s own rule, which would pass however the two had drifted. What is
    /// being measured is `NSMenuItem.isEnabled` for each route the key acts on.
    ///
    /// Skipped where macOS registers no plain-text editor, because `validateEditItem` disables the
    /// item outright there and the answer would be `false` for every route including the working
    /// ones — a green run that measured the machine rather than the code.
    @Test("the menu item is enabled for exactly the routes the key acts on")
    func validatorAgreesWithTheKey() throws {
        try #require(
            ExternalTextEditorLauncher.preferredEditor() != nil,
            "no plain-text editor is registered on this Mac"
        )
        let archive = VFSBackendID.archive(forArchiveAt: "/tmp/pkg.zip")
        let cases: [Case] = [
            Case(backend: .local, kind: .file, route: .local),
            Case(backend: archive, kind: .file, route: .archiveMember),
            Case(backend: Remote.s3, kind: .file, route: .remoteFile),
            Case(backend: Remote.sftp, kind: .file, route: .remoteFile),
            Case(backend: Remote.ftp, kind: .file, route: .remoteFile),
            Case(backend: archive, kind: .directory, route: .unavailable),
            Case(backend: Remote.ftp, kind: .directory, route: .unavailable)
        ]

        for (backend, kind, expected) in cases.map({ ($0.backend, $0.kind, $0.route) }) {
            let entry = Self.entry("notes.txt", on: backend, kind: kind)
            let pane = Self.pane(listing: [entry], at: VFSPath(backend: backend, path: "/dir"))
            #expect(pane.editRoute(for: entry) == expected)

            let item = NSMenuItem()
            item.action = #selector(PanelViewController.editCursorFile(_:))
            let enabled = pane.validateEditItem(item)
            // A directory under the cursor is "something that isn't editable", which stays gray —
            // distinct from the `..` row, where F4 becomes ⇧F4's dialog instead.
            #expect(enabled == (expected != .unavailable))
        }
    }
}
